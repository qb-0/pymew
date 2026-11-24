import std/[os, strutils]
import x11/[x, xlib, xtst, xi2, xinput2]

import common
import ../keys

var
  display: PDisplay
  rootWindow*: Window
  pointerId: cint
  pointerButtons: int
  xlibThreadsReady: bool

proc ensureXlibThreads*() =
  if xlibThreadsReady:
    return
  xlibThreadsReady = true
  discard XInitThreads()

proc openDisplay*(): PDisplay =
  if not display.isNil:
    return display
  ensureXlibThreads()
  if getEnv("XDG_SESSION_TYPE").toLowerAscii().strip() == "wayland":
    raise newException(
      OsUnsupported,
      "X11 is not available on Wayland; global input and window targeting need " &
        "an X11 session or XWayland"
    )
  display = XOpenDisplay(nil)
  if display.isNil:
    raise newException(
      OsUnsupported,
      "cannot open an X11 display; global input and window targeting need an X11 session " &
        "(DISPLAY is not set or the server is unreachable)"
    )
  rootWindow = XDefaultRootWindow(display)
  display

proc buttonNumber(button: MouseButton): int =
  case button
  of mbLeft: 1
  of mbRight: 3
  of mbMiddle: 2
  else: button.int + 4

proc ensurePointer() =
  if pointerId > 0:
    return
  let d = openDisplay()
  var major = cint(2)
  var minor = cint(0)
  if XIQueryVersion(d, addr major, addr minor) != 0:
    raise newException(OsUnsupported, "XInput2 is required to read mouse buttons")
  var count: cint
  let devices = XIQueryDevice(d, XIAllMasterDevices, addr count)
  if devices.isNil:
    raise newException(OsFailure, "cannot query XInput2 devices")
  try:
    let infos = cast[ptr UncheckedArray[XIDeviceInfo]](devices)
    for i in 0 ..< count.int:
      let info = infos[i]
      if info.use != XIMasterPointer:
        continue
      pointerId = info.deviceid
      pointerButtons = 3
      let classes = cast[ptr UncheckedArray[ptr XIAnyClassInfo]](info.classes)
      for j in 0 ..< info.num_classes.int:
        let cls = cast[PXIButtonClassInfo](classes[j])
        if cls.`type` == XIButtonClass:
          pointerButtons = 3 + max(0, cls.num_buttons.int - 7)
          break
      break
  finally:
    XIFreeDeviceInfo(devices)
  if pointerId <= 0:
    raise newException(OsFailure, "cannot find an XInput2 master pointer")

proc keycodeFor(code: int): KeyCode =
  result = XKeysymToKeycode(openDisplay(), KeySym(keyCodeOs(code)))
  if result == '\0':
    raise newException(OsFailure, "key is not mapped in the current X11 layout")

proc keySet(keys: chararr32, keycode: KeyCode): bool =
  keycode != '\0' and
    (ord(keys[keycode.int div 8]) and (1 shl (keycode.int mod 8))) != 0

proc keyDown*(code: int): bool =
  let
    d = openDisplay()
    keycode = XKeysymToKeycode(d, KeySym(keyCodeOs(code)))
  var keys: chararr32
  if XQueryKeymap(d, keys) == 0:
    return false
  keySet(keys, keycode)

proc keysDown*(): seq[int] =
  let d = openDisplay()
  var keys: chararr32
  if XQueryKeymap(d, keys) == 0:
    return
  for (_, code) in keyTable:
    if keySet(keys, XKeysymToKeycode(d, KeySym(keyCodeOs(code)))):
      result.add code

proc mousePosition*(): tuple[x, y: int] =
  var
    root, child: Window
    rootX, rootY, winX, winY: cint
    mask: cuint
  if XQueryPointer(
    openDisplay(),
    rootWindow,
    addr root,
    addr child,
    addr rootX,
    addr rootY,
    addr winX,
    addr winY,
    addr mask
  ) == 0:
    raise newException(OsFailure, "cannot query the X11 pointer")
  (rootX.int, rootY.int)

proc mouseButtonDown*(button: MouseButton): bool =
  let d = openDisplay()
  ensurePointer()
  var
    root, child: Window
    rootX, rootY, winX, winY: cdouble
    buttons: XIButtonState
    mods: XIModifierState
    group: XIGroupState
  if XIQueryPointer(
    d,
    pointerId,
    rootWindow,
    addr root,
    addr child,
    addr rootX,
    addr rootY,
    addr winX,
    addr winY,
    addr buttons,
    addr mods,
    addr group
  ) == 0:
    discard XFree(buttons.mask)
    raise newException(OsFailure, "cannot query the X11 pointer")
  let
    number = buttonNumber(button)
    index = number div 8
    mask = cast[ptr UncheckedArray[uint8]](buttons.mask)
  result = index < buttons.mask_len.int and
    (mask[index] and (1'u8 shl (number mod 8))) != 0
  discard XFree(buttons.mask)

proc injectKey*(code: int, down: bool) =
  let d = openDisplay()
  discard XTestFakeKeyEvent(d, keycodeFor(code).cuint, XBool(ord(down)), CurrentTime)
  discard XFlush(d)

proc injectMouseButton*(button: MouseButton, down: bool) =
  ensurePointer()
  if button.int > pointerButtons:
    raise newException(ValueError, "the pointer has no button " & $button.int)
  let d = openDisplay()
  discard XTestFakeButtonEvent(d, buttonNumber(button).cuint, XBool(ord(down)), CurrentTime)
  discard XFlush(d)

proc injectMouseMove*(x, y: int, relative: bool) =
  let d = openDisplay()
  if relative:
    discard XTestFakeRelativeMotionEvent(d, x.cint, y.cint, CurrentTime)
  else:
    discard XTestFakeMotionEvent(d, -1, x.cint, y.cint, CurrentTime)
  discard XFlush(d)

proc injectMouseScroll*(amount: float) =
  if amount == 0.0:
    return
  let
    d = openDisplay()
    steps = max(1, int(abs(amount)))
    button = if amount > 0.0: 4'u32 else: 5'u32
  for _ in 0 ..< steps:
    discard XTestFakeButtonEvent(d, button, XBool(1), CurrentTime)
    discard XTestFakeButtonEvent(d, button, XBool(0), CurrentTime)
  discard XFlush(d)

proc setCursorPos*(x, y: int) =
  let d = openDisplay()
  discard XWarpPointer(d, 0, rootWindow, 0, 0, 0, 0, x.cint, y.cint)
  discard XFlush(d)

proc ignoreXError(display: PDisplay, event: PXErrorEvent): cint {.cdecl.} =
  discard display
  discard event
  0

proc focusWindow*(handle: int) =
  if handle == 0:
    return
  let d = openDisplay()
  let previous = XSetErrorHandler(ignoreXError)
  discard XRaiseWindow(d, Window(handle))
  discard XSetInputFocus(d, Window(handle), RevertToPointerRoot, CurrentTime)
  discard XSync(d, XBool(0))
  discard XSetErrorHandler(previous)

proc clipCursor*(handle: int) =
  if handle == 0:
    return
  let d = openDisplay()
  let previous = XSetErrorHandler(ignoreXError)
  discard XGrabPointer(
    d,
    Window(handle),
    XBool(1),
    cuint(ButtonPressMask or ButtonReleaseMask or PointerMotionMask),
    GrabModeAsync,
    GrabModeAsync,
    Window(handle),
    Cursor(0),
    CurrentTime
  )
  discard XSync(d, XBool(0))
  discard XSetErrorHandler(previous)

proc releaseCursorClip*() =
  let d = openDisplay()
  discard XUngrabPointer(d, CurrentTime)
  discard XFlush(d)
