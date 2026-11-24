import nimpy
import nimpy/py_types

{.push warning[UnusedImport]: off.}
import src/[vec, color, keys, input, hotkey, overlay, utils, draw]
{.pop.}

import src/[pyutil, errors, mem, version]

pyExportModule("pymew")

const
  memFunctionExports = [
    ("open", "_memOpen"),
    ("processes", "_memProcesses"),
    ("exists", "_memExists"),
    ("pid", "_memPid"),
    ("name", "_memName"),
    ("path", "_memPath"),
    ("is_64bit", "_memIs64Bit"),
    ("string", "_memString"),
    ("wstring", "_memWString"),
    ("fstring", "_memFString"),
    ("bytes", "_memBytes"),
    ("array", "_memArray"),
    ("scan_bytes", "_memScanBytes")
  ]

  colorFunctionExports = [
    ("get", "color_get"),
    ("fade", "color_fade"),
    ("mix", "color_mix"),
    ("names", "color_names"),
    ("table", "color_table")
  ]

  keysFunctionExports = [
    ("code", "_keyCode"),
    ("name", "_keyName"),
    ("names", "_keyNames")
  ]

  inputFunctionExports = [
    ("key_down", "_inputKeyDown"),
    ("key_pressed", "_inputKeyPressed"),
    ("key_up", "_inputKeyUp"),
    ("mouse_pos", "_inputMousePos"),
    ("mouse_down", "_inputMouseDown"),
    ("mouse_pressed", "_inputMousePressed"),
    ("mouse_up", "_inputMouseUp"),
    ("key_press", "_inputKeyPress"),
    ("mouse_move", "_inputMouseMove"),
    ("mouse_click", "_inputMouseClick"),
    ("mouse_scroll", "_inputMouseScroll"),
    ("set_pos", "_inputSetPos")
  ]

  hotkeyFunctionExports = [
    ("bind", "_hotkeyBind"),
    ("unbind", "_hotkeyUnbind"),
    ("list", "_hotkeyList"),
    ("poll", "_hotkeyPoll")
  ]

  overlayFunctionExports = [
    ("open", "_overlayOpen")
  ]

  vecFunctionExports = [
    ("vec2", "vec2"),
    ("vec3", "vec3")
  ]

  utilsFunctionExports = [
    ("os_name", "_utilsOsName"),
    ("screen_size", "_utilsScreenSize"),
    ("monitors", "_utilsMonitors"),
    ("window_info", "_utilsWindowInfo"),
    ("windows", "_utilsWindows"),
    ("time", "_utilsTime"),
    ("set_log_level", "_utilsSetLogLevel")
  ]

  drawFunctionExports = [
    ("point", "draw_point"),
    ("line", "draw_line"),
    ("polyline", "draw_polyline"),
    ("rect", "draw_rect"),
    ("rect_gradient", "draw_rect_gradient"),
    ("circle", "draw_circle"),
    ("sector", "draw_sector"),
    ("ring", "draw_ring"),
    ("ellipse", "draw_ellipse"),
    ("triangle", "draw_triangle"),
    ("poly", "draw_poly"),
    ("text", "draw_text"),
    ("text_ex", "draw_text_ex"),
    ("measure_text", "draw_measure_text"),
    ("measure_text_ex", "draw_measure_text_ex"),
    ("set_font", "draw_set_font"),
    ("font", "draw_font"),
    ("fps", "draw_fps"),
    ("load_texture", "draw_load_texture"),
    ("load_texture_bytes", "draw_load_texture_bytes"),
    ("texture", "draw_texture"),
    ("texture_rect", "draw_texture_rect"),
    ("load_font", "draw_load_font"),
    ("load_font_bytes", "draw_load_font_bytes"),
    ("fonts", "draw_fonts"),
    ("screenshot", "draw_screenshot"),
    ("entity_box", "draw_entity_box"),
    ("entity_box_from_points", "draw_entity_box_from_points")
  ]

proc moduleObj(): PyObject =
  pyImport("pymew")

proc cacheNamespace(name: string, ns: PyObject): PPyObject =
  setAttr(moduleObj(), name, ns)
  result = nimValueToPy(ns)

proc buildMemNamespace(): PyObject =
  ensureTypes()
  let
    ns = newNamespace()
    m = moduleObj()
  for (key, exported) in memFunctionExports:
    setAttr(ns, key.cstring, getAttr(m, exported.cstring))
  for (key, desc) in [
    ("i8", descI8), ("i16", descI16), ("i32", descI32), ("i64", descI64),
    ("u8", descU8), ("u16", descU16), ("u32", descU32), ("u64", descU64),
    ("f32", descF32), ("f64", descF64), ("bool", descBool), ("ptr", descPtr),
    ("vec2", descVec2), ("vec3", descVec3)
  ]:
    setAttr(ns, key.cstring, desc)
  setAttr(ns, "Struct", structClass)
  result = ns

proc buildErrorsNamespace(): PyObject =
  ensureTypes()
  let ns = newNamespace()
  for (name, cls) in [
    ("Error", errorClass),
    ("ProcessNotFound", processNotFoundClass),
    ("ModuleNotFound", moduleNotFoundClass),
    ("AccessError", accessErrorClass),
    ("PermissionDenied", permissionDeniedClass),
    ("UnsupportedError", unsupportedClass),
    ("HotkeyError", hotkeyErrorClass),
    ("OverlayError", overlayErrorClass),
    ("WindowNotFound", windowNotFoundClass)
  ]:
    setAttr(ns, name.cstring, cls)
  result = ns

proc functionNamespace(exports: openArray[(string, string)]): PyObject =
  let
    ns = newNamespace()
    m = moduleObj()
  for (key, exported) in exports:
    setAttr(ns, key.cstring, getAttr(m, exported.cstring))
  result = ns

proc buildUtilsNamespace(): PyObject =
  ensureUtilsTypes()
  let ns = functionNamespace(utilsFunctionExports)
  setAttr(ns, "Monitor", monitorClass)
  setAttr(ns, "Window", windowClass)
  result = ns

proc buildDrawNamespace(): PyObject =
  ensureDrawTypes()
  let ns = functionNamespace(drawFunctionExports)
  setAttr(ns, "Font", fontClass)
  setAttr(ns, "Texture", textureClass)
  setAttr(ns, "EntityBox", entityBoxClass)
  result = ns

proc pyGetattr(name: string): PPyObject =
  case name
  of "__version__":
    nimValueToPy(pymewVersion)
  of "mem":
    cacheNamespace("mem", buildMemNamespace())
  of "vec":
    cacheNamespace("vec", functionNamespace(vecFunctionExports))
  of "errors":
    cacheNamespace("errors", buildErrorsNamespace())
  of "color":
    cacheNamespace("color", functionNamespace(colorFunctionExports))
  of "keys":
    cacheNamespace("keys", functionNamespace(keysFunctionExports))
  of "input":
    cacheNamespace("input", functionNamespace(inputFunctionExports))
  of "hotkey":
    cacheNamespace("hotkey", functionNamespace(hotkeyFunctionExports))
  of "overlay":
    cacheNamespace("overlay", functionNamespace(overlayFunctionExports))
  of "utils":
    cacheNamespace("utils", buildUtilsNamespace())
  of "draw":
    cacheNamespace("draw", buildDrawNamespace())
  else:
    setAttributeError("module 'pymew' has no attribute '" & name & "'")
    nil

exportAs(pyGetattr, "__getattr__")
