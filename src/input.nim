import std/[math, tables]
import nimpy
import nimpy/py_types

import pyutil, errors, keys, vec
import platform/api

pyExportModule("pymew")

var
  keyStates: Table[int, bool]
  mouseStates: Table[MouseButton, bool]

const mouseButtons = [
  ("left", mbLeft),
  ("right", mbRight),
  ("middle", mbMiddle),
  ("x1", mbX1),
  ("x2", mbX2)
]

proc mouseButton(value: PyObject): MouseButton =
  if pyIsInstance(value, "bool"):
    raise newException(PmBadType, "mouse button must be a name or a number, not bool")
  if pyIsInstance(value, "int"):
    let number = value.to(int)
    if number < 1 or number > 255:
      raise newException(PmValueError, "mouse button number must be between 1 and 255")
    return MouseButton(number)
  if pyIsInstance(value, "str"):
    let
      text = value.to(string)
      name = normalizeName(text)
    for (candidate, button) in mouseButtons:
      if candidate == name:
        return button
    raise newException(
      PmValueError,
      "unknown mouse button '" & text & "'; use left, right, middle, x1, x2 or a number"
    )
  raise newException(PmBadType, "mouse button must be a str (name) or an int (number)")

proc edgePressed[T](states: var Table[T, bool], key: T, down: bool): bool =
  result = down and not states.getOrDefault(key, false)
  states[key] = down

proc edgeReleased[T](states: var Table[T, bool], key: T, down: bool): bool =
  result = not down and states.getOrDefault(key, false)
  states[key] = down

proc keyPressedState(code: int): bool =
  edgePressed(keyStates, code, keyDown(code))

proc keyReleasedState(code: int): bool =
  edgeReleased(keyStates, code, keyDown(code))

proc mousePressedState(button: MouseButton): bool =
  edgePressed(mouseStates, button, mouseButtonDown(button))

proc mouseReleasedState(button: MouseButton): bool =
  edgeReleased(mouseStates, button, mouseButtonDown(button))

proc inputKeyDown*(value: PyObject): PPyObject {.exportpy: "_inputKeyDown".} =
  pyWrap:
    keyDown(keyCodeValue(value))

proc inputKeyPressed*(value: PyObject): PPyObject {.exportpy: "_inputKeyPressed".} =
  pyWrap:
    keyPressedState(keyCodeValue(value))

proc inputKeyUp*(value: PyObject): PPyObject {.exportpy: "_inputKeyUp".} =
  pyWrap:
    keyReleasedState(keyCodeValue(value))

proc inputMousePos*(): PPyObject {.exportpy: "_inputMousePos".} =
  pyWrap:
    let pos = mousePosition()
    newVec2(float(pos.x), float(pos.y))

proc inputMouseDown*(value: PyObject): PPyObject {.exportpy: "_inputMouseDown".} =
  pyWrap:
    mouseButtonDown(mouseButton(value))

proc inputMousePressed*(value: PyObject): PPyObject {.exportpy: "_inputMousePressed".} =
  pyWrap:
    mousePressedState(mouseButton(value))

proc inputMouseUp*(value: PyObject): PPyObject {.exportpy: "_inputMouseUp".} =
  pyWrap:
    mouseReleasedState(mouseButton(value))

proc inputKeyPress*(value: PyObject): PPyObject {.exportpy: "_inputKeyPress".} =
  pyWrap:
    let code = keyCodeValue(value)
    injectKey(code, true)
    injectKey(code, false)

proc inputMouseMove*(
  x, y: float,
  relative: bool = false
): PPyObject {.exportpy: "_inputMouseMove".} =
  pyWrap:
    injectMouseMove(int(round(x)), int(round(y)), relative)

proc inputMouseClick*(value: PyObject): PPyObject {.exportpy: "_inputMouseClick".} =
  pyWrap:
    let button = mouseButton(value)
    injectMouseButton(button, true)
    injectMouseButton(button, false)

proc inputMouseScroll*(amount: float): PPyObject {.exportpy: "_inputMouseScroll".} =
  pyWrap:
    injectMouseScroll(amount)

proc inputSetPos*(x, y: float): PPyObject {.exportpy: "_inputSetPos".} =
  pyWrap:
    setCursorPos(int(round(x)), int(round(y)))
