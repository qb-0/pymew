import std/[sets, tables]
import nimpy
import raylib
from rlgl import GlVersion, drawRenderBatchActive, getVersion

import errors, keys, pyutil
import platform/api

type
  ImGuiBridge* = ref object
    module: PyObject
    io: PyObject
    backend: PyObject
    ownsContext: bool
    keyMap: Table[int, PyObject]
    downKeys: Table[int, bool]
    downMouse: Table[int, bool]
    frameOpen: bool

const imguiMouseButtons = [mbLeft, mbRight, mbMiddle, mbX1, mbX2]

proc imguiKeyName(code: int): string =
  case code
  of 32: "space"
  of 39: "apostrophe"
  of 44: "comma"
  of 45: "minus"
  of 46: "period"
  of 47: "slash"
  of 48..57: "_" & $char(code)
  of 59: "semicolon"
  of 61: "equal"
  of 65..90: $char(code + 32)
  of 91: "left_bracket"
  of 92: "backslash"
  of 93: "right_bracket"
  of 96: "grave_accent"
  of 256: "escape"
  of 257: "enter"
  of 258: "tab"
  of 259: "backspace"
  of 260: "insert"
  of 261: "delete"
  of 262: "right_arrow"
  of 263: "left_arrow"
  of 264: "down_arrow"
  of 265: "up_arrow"
  of 266: "page_up"
  of 267: "page_down"
  of 268: "home"
  of 269: "end"
  of 280: "caps_lock"
  of 281: "scroll_lock"
  of 282: "num_lock"
  of 283: "print_screen"
  of 284: "pause"
  of 290..301: "f" & $(code - 289)
  of 320..329: "keypad" & $(code - 320)
  of 330: "keypad_decimal"
  of 331: "keypad_divide"
  of 332: "keypad_multiply"
  of 333: "keypad_subtract"
  of 334: "keypad_add"
  of 335: "keypad_enter"
  of 336: "keypad_equal"
  of 340: "left_shift"
  of 341: "left_ctrl"
  of 342: "left_alt"
  of 343: "left_super"
  of 344: "right_shift"
  of 345: "right_ctrl"
  of 346: "right_alt"
  of 347: "right_super"
  of 348: "menu"
  else: ""

proc glslVersion(): string =
  case getVersion()
  of Opengl11Software, Opengl11: "#version 110"
  of Opengl21: "#version 120"
  of Opengl33, Opengl43: "#version 330"
  of OpenglEs20: "#version 100"
  of OpenglEs30: "#version 300 es"

proc loadModule(): PyObject =
  try:
    pyImport("imgui_bundle.imgui")
  except CatchableError as e:
    raise newException(
      PmModuleNotFound,
      "imgui_bundle is not available (" & e.msg &
        "); install it with 'pip install imgui-bundle'"
    )

proc buildKeyMap(module: PyObject): Table[int, PyObject] =
  let keyEnum = getAttr(module, "Key")
  for (_, code) in keyTable:
    let name = imguiKeyName(code)
    if name.len > 0:
      result[code] = getAttr(keyEnum, name.cstring)

proc openImGuiBundle*(): ImGuiBridge =
  let
    module = loadModule()
    keyMap = buildKeyMap(module)
  let ownsContext = isNone(callMethod(module, "get_current_context"))
  if ownsContext:
    discard callMethod(module, "create_context")
  let bridge = ImGuiBridge(
    module: module,
    ownsContext: ownsContext,
    keyMap: keyMap
  )
  try:
    bridge.io = callMethod(module, "get_io")
    if ownsContext:
      discard callMethod(bridge.io, "set_ini_filename", newPyNone())
    bridge.backend = getAttr(module, "backends")
    if not callObject(getAttr(bridge.backend, "opengl3_init"), glslVersion()).to(bool):
      raise newException(
        PmOverlayError,
        "the imgui_bundle OpenGL3 backend could not be initialized"
      )
  except CatchableError:
    if ownsContext:
      discard callMethod(module, "destroy_context")
    raise
  bridge

proc feedMouse(bridge: ImGuiBridge) =
  let
    position = mousePosition()
    origin = getWindowPosition()
  discard callMethod(
    bridge.io,
    "add_mouse_pos_event",
    float(position.x) - float(origin.x),
    float(position.y) - float(origin.y)
  )
  for index, button in imguiMouseButtons:
    let down = mouseButtonDown(button)
    if down != bridge.downMouse.getOrDefault(index, false):
      bridge.downMouse[index] = down
      discard callMethod(bridge.io, "add_mouse_button_event", index, down)

proc characterFor(code: int, shift: bool): string =
  case code
  of 32: " "
  of 48..57: $char(code)
  of 65..90: $char(if shift: code else: code + 32)
  else: ""

proc feedKeys(bridge: ImGuiBridge) =
  let held = keysDown().toHashSet()
  let shift = 340 in held or 344 in held
  for code, key in bridge.keyMap:
    let down = code in held
    if down != bridge.downKeys.getOrDefault(code, false):
      bridge.downKeys[code] = down
      discard callMethod(bridge.io, "add_key_event", key, down)
      if down:
        let text = characterFor(code, shift)
        if text.len > 0:
          discard callMethod(bridge.io, "add_input_characters_utf8", text)

proc feedInput(bridge: ImGuiBridge) =
  let size = callMethod(
    bridge.module,
    "ImVec2",
    float(getScreenWidth()),
    float(getScreenHeight())
  )
  setPyAttr(bridge.io, "display_size", nimValueToPy(size))
  setPyAttr(bridge.io, "delta_time", nimValueToPy(float(getFrameTime())))
  bridge.feedMouse()
  bridge.feedKeys()

proc setMouseDrawCursor*(bridge: ImGuiBridge, enabled: bool) =
  setPyAttr(bridge.io, "mouse_draw_cursor", nimValueToPy(enabled))

proc releaseInput*(bridge: ImGuiBridge) =
  for code, down in bridge.downKeys:
    if down:
      discard callMethod(bridge.io, "add_key_event", bridge.keyMap[code], false)
  bridge.downKeys.clear()
  for index, down in bridge.downMouse:
    if down:
      discard callMethod(bridge.io, "add_mouse_button_event", index, false)
  bridge.downMouse.clear()

proc beginImGui*(bridge: ImGuiBridge) =
  bridge.feedInput()
  discard callMethod(bridge.backend, "opengl3_new_frame")
  discard callMethod(bridge.module, "new_frame")
  bridge.frameOpen = true

proc endImGui*(bridge: ImGuiBridge) =
  if not bridge.frameOpen:
    return
  bridge.frameOpen = false
  discard callMethod(bridge.module, "render")
  let drawData = callMethod(bridge.module, "get_draw_data")
  drawRenderBatchActive()
  discard callMethod(bridge.backend, "opengl3_render_draw_data", drawData)

proc closeImGui*(bridge: ImGuiBridge) =
  try:
    discard callMethod(bridge.backend, "opengl3_shutdown")
    if bridge.ownsContext:
      discard callMethod(bridge.module, "destroy_context")
  except CatchableError:
    discard