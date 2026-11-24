import nimpy
import nimpy/py_types

import pyutil, errors

pyExportModule("pymew")

const keyTable* = [
  ("a", 65), ("b", 66), ("c", 67), ("d", 68), ("e", 69), ("f", 70), ("g", 71),
  ("h", 72), ("i", 73), ("j", 74), ("k", 75), ("l", 76), ("m", 77), ("n", 78),
  ("o", 79), ("p", 80), ("q", 81), ("r", 82), ("s", 83), ("t", 84), ("u", 85),
  ("v", 86), ("w", 87), ("x", 88), ("y", 89), ("z", 90),
  ("0", 48), ("1", 49), ("2", 50), ("3", 51), ("4", 52), ("5", 53), ("6", 54),
  ("7", 55), ("8", 56), ("9", 57),
  ("apostrophe", 39), ("comma", 44), ("minus", 45), ("period", 46), ("slash", 47),
  ("semicolon", 59), ("equal", 61), ("leftbracket", 91), ("backslash", 92),
  ("rightbracket", 93), ("grave", 96),
  ("space", 32),
  ("escape", 256), ("enter", 257), ("tab", 258), ("backspace", 259),
  ("insert", 260), ("delete", 261), ("right", 262), ("left", 263), ("down", 264),
  ("up", 265), ("pageup", 266), ("pagedown", 267), ("home", 268), ("end", 269),
  ("capslock", 280), ("scrolllock", 281), ("numlock", 282),
  ("printscreen", 283), ("pause", 284),
  ("f1", 290), ("f2", 291), ("f3", 292), ("f4", 293), ("f5", 294), ("f6", 295),
  ("f7", 296), ("f8", 297), ("f9", 298), ("f10", 299), ("f11", 300), ("f12", 301),
  ("lshift", 340), ("lctrl", 341), ("lalt", 342), ("lsuper", 343),
  ("rshift", 344), ("rctrl", 345), ("ralt", 346), ("rsuper", 347), ("menu", 348),
  ("num0", 320), ("num1", 321), ("num2", 322), ("num3", 323), ("num4", 324),
  ("num5", 325), ("num6", 326), ("num7", 327), ("num8", 328), ("num9", 329),
  ("numdecimal", 330), ("numdivide", 331), ("nummultiply", 332),
  ("numsubtract", 333), ("numadd", 334), ("numenter", 335), ("numequal", 336)
]

proc findKeyName(name: string): int =
  let want = normalizeName(name)
  for i, (candidate, _) in keyTable:
    if candidate == want:
      return i
  -1

proc findKeyCode(code: int): int =
  for i, (_, candidate) in keyTable:
    if candidate == code:
      return i
  -1

proc suggestKey(name: string): string =
  var candidates: seq[string]
  for (candidate, _) in keyTable:
    candidates.add candidate
  closestName(normalizeName(name), candidates, 2)

proc keyCode*(name: string): int =
  let i = findKeyName(name)
  if i >= 0:
    return keyTable[i][1]
  var msg = "unknown key '" & name & "'; see pm.keys.names() for valid names"
  let suggestion = suggestKey(name)
  if suggestion.len > 0:
    msg.add "; did you mean '" & suggestion & "'?"
  raise newException(PmValueError, msg)

proc keyName*(code: int): string =
  let i = findKeyCode(code)
  if i >= 0:
    return keyTable[i][0]
  raise newException(PmValueError, "unknown key code " & $code & "; see pm.keys.names() for valid names")

proc keyNames*(): seq[string] =
  for (name, _) in keyTable:
    result.add name

proc keyCodeValue*(value: PyObject): int =
  if pyIsInstance(value, "bool"):
    raise newException(PmBadType, "key must be a name or a code, not bool")
  if pyIsInstance(value, "int"):
    let code = value.to(int)
    if findKeyCode(code) < 0:
      raise newException(
        PmValueError,
        "unknown key code " & $code & "; see pm.keys.names() for valid names"
      )
    return code
  if pyIsInstance(value, "str"):
    return keyCode(value.to(string))
  raise newException(PmBadType, "key must be a str (name) or an int (code)")

proc keyCodeOs*(code: int): int =
  when defined(windows):
    case code
    of 32: 0x20
    of 39: 0xDE
    of 44: 0xBC
    of 45: 0xBD
    of 46: 0xBE
    of 47: 0xBF
    of 48..57: code
    of 59: 0xBA
    of 61: 0xBB
    of 65..90: code
    of 91: 0xDB
    of 92: 0xDC
    of 93: 0xDD
    of 96: 0xC0
    of 256: 0x1B
    of 257: 0x0D
    of 258: 0x09
    of 259: 0x08
    of 260: 0x2D
    of 261: 0x2E
    of 262: 0x27
    of 263: 0x25
    of 264: 0x28
    of 265: 0x26
    of 266: 0x21
    of 267: 0x22
    of 268: 0x24
    of 269: 0x23
    of 280: 0x14
    of 281: 0x91
    of 282: 0x90
    of 283: 0x2C
    of 284: 0x13
    of 290..301: 0x70 + (code - 290)
    of 320..329: 0x60 + (code - 320)
    of 330: 0x6E
    of 331: 0x6F
    of 332: 0x6A
    of 333: 0x6D
    of 334: 0x6B
    of 335: 0x0D
    of 336: 0x92
    of 340: 0xA0
    of 341: 0xA2
    of 342: 0xA4
    of 343: 0x5B
    of 344: 0xA1
    of 345: 0xA3
    of 346: 0xA5
    of 347: 0x5C
    of 348: 0x5D
    else: 0
  else:
    case code
    of 32: 0x20
    of 39: 0x27
    of 44: 0x2C
    of 45: 0x2D
    of 46: 0x2E
    of 47: 0x2F
    of 48..57: code
    of 59: 0x3B
    of 61: 0x3D
    of 65..90: code + 32
    of 91: 0x5B
    of 92: 0x5C
    of 93: 0x5D
    of 96: 0x60
    of 256: 0xFF1B
    of 257: 0xFF0D
    of 258: 0xFF09
    of 259: 0xFF08
    of 260: 0xFF63
    of 261: 0xFFFF
    of 262: 0xFF53
    of 263: 0xFF51
    of 264: 0xFF54
    of 265: 0xFF52
    of 266: 0xFF55
    of 267: 0xFF56
    of 268: 0xFF50
    of 269: 0xFF57
    of 280: 0xFFE5
    of 281: 0xFF14
    of 282: 0xFF7F
    of 283: 0xFF61
    of 284: 0xFF13
    of 290..301: 0xFFBE + (code - 290)
    of 320..329: 0xFFB0 + (code - 320)
    of 330: 0xFFAE
    of 331: 0xFFAF
    of 332: 0xFFAA
    of 333: 0xFFAD
    of 334: 0xFFAB
    of 335: 0xFF8D
    of 336: 0xFFBD
    of 340: 0xFFE1
    of 341: 0xFFE3
    of 342: 0xFFE9
    of 343: 0xFFEB
    of 344: 0xFFE2
    of 345: 0xFFE4
    of 346: 0xFFEA
    of 347: 0xFFEC
    of 348: 0xFF67
    else: 0

proc keysCode*(value: PyObject): PPyObject {.exportpy: "_keyCode".} =
  pyWrap:
    keyCodeValue(value)

proc keysName*(value: PyObject): PPyObject {.exportpy: "_keyName".} =
  pyWrap:
    if pyIsInstance(value, "bool") or not pyIsInstance(value, "int"):
      raise newException(PmBadType, "key code must be an int")
    keyName(value.to(int))

proc keysNames*(): seq[string] {.exportpy: "_keyNames".} =
  keyNames()