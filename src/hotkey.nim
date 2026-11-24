import std/[strutils, tables]
import nimpy
import nimpy/py_types

import pyutil, errors, keys
import platform/api

pyExportModule("pymew")

initHotkeyState()

const
  maxHotkeyId = 0xBFFF

type
  HotkeyBinding = object
    id: int
    combo: string
    code: int
    mods: uint8
    callback: PyObject

var
  bindings: seq[HotkeyBinding]
  comboIndex: Table[string, int]
  idIndex: Table[int, int]
  nextId = 1
  pumping = false

proc comboArg(value: PyObject): string =
  if not pyIsInstance(value, "str"):
    raise newException(PmBadType, "hotkey combo must be a str")
  value.to(string)

proc isModifier(token: string): bool =
  token in ["ctrl", "alt", "shift", "super"]

proc comboString(mods: uint8, code: int): string =
  if (mods and hmCtrl) != 0:
    result.add "ctrl+"
  if (mods and hmAlt) != 0:
    result.add "alt+"
  if (mods and hmShift) != 0:
    result.add "shift+"
  if (mods and hmSuper) != 0:
    result.add "super+"
  result.add keyName(code)

proc parseCombo(text: string): tuple[combo: string, code: int, mods: uint8] =
  let stripped = text.strip()
  if stripped.len == 0:
    raise newException(PmValueError, "hotkey combo must not be empty")
  let parts = stripped.split('+')
  var mods: uint8
  for i, part in parts:
    let token = normalizeName(part)
    if token.len == 0:
      raise newException(PmValueError, "invalid hotkey combo '" & text & "'")
    if i < parts.high:
      case token
      of "ctrl": mods = mods or hmCtrl
      of "alt": mods = mods or hmAlt
      of "shift": mods = mods or hmShift
      of "super": mods = mods or hmSuper
      else:
        raise newException(
          PmValueError,
          "unknown hotkey modifier '" & part.strip() & "'; use ctrl, alt, shift and super"
        )
    elif isModifier(token):
      raise newException(
        PmValueError,
        "hotkey combo must end with a key; use mod+key, for example ctrl+alt+h"
      )
    else:
      let code = keyCode(token)
      return (comboString(mods, code), code, mods)
  raise newException(
    PmValueError,
    "hotkey combo must end with a key; use mod+key, for example ctrl+alt+h"
  )

proc isCallable(value: PyObject): bool =
  callObject(getAttr(pyBuiltinsModule(), "callable"), value).to(bool)

proc osErrorSuffix(code: int): string =
  if code == 0:
    return ""
  when defined(windows):
    ": Windows error " & $code
  else:
    ": OS error " & $code

proc registrationError(combo: string, status: HotkeyStatus, code: int) =
  case status
  of hsOk:
    discard
  of hsConflict:
    raise newException(
      PmHotkeyError,
      "hotkey '" & combo & "' is already registered by another application"
    )
  of hsUnsupported:
    raise newException(
      PmHotkeyError,
      "hotkey '" & combo & "' cannot be registered on this system"
    )
  of hsFailure:
    raise newException(
      PmHotkeyError,
      "cannot register hotkey '" & combo & "'" & osErrorSuffix(code)
    )

proc unregistrationError(combo: string, code: int) =
  raise newException(
    PmHotkeyError,
    "cannot unregister hotkey '" & combo & "'" & osErrorSuffix(code)
  )

proc pump*() =
  if pumping:
    return
  pumping = true
  try:
    while true:
      let id = popEvent()
      if id < 0:
        break
      if not idIndex.hasKey(id):
        continue
      let index = idIndex[id]
      discard callObject(bindings[index].callback)
  finally:
    pumping = false

proc hotkeyBind*(
  value: PyObject,
  callback: PyObject = nil
): PPyObject {.exportpy: "_hotkeyBind".} =
  pyWrap:
    let parsed = parseCombo(comboArg(value))
    if callback.isNil:
      raise newException(PmBadType, "hotkey callback is required")
    if not isCallable(callback):
      raise newException(PmBadType, "hotkey callback must be callable")
    if comboIndex.hasKey(parsed.combo):
      bindings[comboIndex[parsed.combo]].callback = callback
    else:
      if nextId > maxHotkeyId:
        raise newException(
          PmError,
          "too many hotkeys were bound in this process; restart to reset hotkey ids"
        )
      var errorCode = 0
      let status = hkAdd(nextId, parsed.code, parsed.mods, errorCode)
      registrationError(parsed.combo, status, errorCode)
      bindings.add HotkeyBinding(
        id: nextId,
        combo: parsed.combo,
        code: parsed.code,
        mods: parsed.mods,
        callback: callback
      )
      comboIndex[parsed.combo] = bindings.high
      idIndex[nextId] = bindings.high
      inc nextId

proc hotkeyUnbind*(value: PyObject): PPyObject {.exportpy: "_hotkeyUnbind".} =
  pyWrap:
    let parsed = parseCombo(comboArg(value))
    if comboIndex.hasKey(parsed.combo):
      let
        index = comboIndex[parsed.combo]
        id = bindings[index].id
      var errorCode = 0
      let status = hkRemove(id, errorCode)
      if status != hsOk:
        unregistrationError(parsed.combo, errorCode)
      idIndex.del(id)
      comboIndex.del(parsed.combo)
      bindings.delete(index)
      for i in index ..< bindings.len:
        comboIndex[bindings[i].combo] = i
        idIndex[bindings[i].id] = i

proc hotkeyList*(): seq[string] {.exportpy: "_hotkeyList".} =
  for binding in bindings:
    result.add binding.combo

proc hotkeyPoll*(): PPyObject {.exportpy: "_hotkeyPoll".} =
  pyWrap:
    pump()
