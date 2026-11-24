import std/[os, posix, strutils, typedthreads]
import x11/[x, xlib, xkblib]

import common
import ../keys
import ./x11_input as x11input

const
  maxBindings = 64
  hotkeyModMask = cuint(ShiftMask or ControlMask or Mod1Mask or Mod4Mask)

type
  X11Binding = object
    id: int
    keycode: cint
    mods: uint8
    down: bool

var
  worker: Thread[int]
  display: PDisplay
  rootWindow: Window
  connectionFd: cint
  wakePipe: array[2, cint]
  started: bool
  grabError: cint
  bindings: array[maxBindings, X11Binding]
  bindingCount: int

proc grabErrorHandler(_: PDisplay, event: PXErrorEvent): cint {.cdecl.} =
  if not event.isNil and int(event.error_code) == BadAccess:
    grabError = BadAccess
  0

proc keyModifiers(mods: uint8): cuint =
  if (mods and hmCtrl) != 0:
    result = result or cuint(ControlMask)
  if (mods and hmAlt) != 0:
    result = result or cuint(Mod1Mask)
  if (mods and hmShift) != 0:
    result = result or cuint(ShiftMask)
  if (mods and hmSuper) != 0:
    result = result or cuint(Mod4Mask)

proc grabVariants(base: cuint): array[4, cuint] =
  result[0] = base
  result[1] = base or cuint(LockMask)
  result[2] = base or cuint(Mod2Mask)
  result[3] = base or cuint(LockMask) or cuint(Mod2Mask)

proc ungrabKey(keycode: cint, mods: uint8) =
  for variant in grabVariants(keyModifiers(mods)):
    discard XUngrabKey(display, keycode, variant, rootWindow)

proc grabBinding(op: HotkeyOp): tuple[status: HotkeyStatus, errorCode: int] =
  if bindingCount >= maxBindings:
    return (hsFailure, 0)
  let keycode = XKeysymToKeycode(display, KeySym(keyCodeOs(op.code)))
  if keycode == '\0':
    return (hsUnsupported, 0)
  var binding = X11Binding(id: op.id, keycode: cint(keycode), mods: op.mods)
  let variants = grabVariants(keyModifiers(op.mods))
  discard XSync(display, 0)
  grabError = 0
  let previous = XSetErrorHandler(grabErrorHandler)
  for variant in variants:
    discard XGrabKey(
      display,
      binding.keycode,
      variant,
      rootWindow,
      XBool(0),
      GrabModeAsync,
      GrabModeAsync
    )
  discard XSync(display, 0)
  discard XSetErrorHandler(previous)
  if grabError != 0:
    for variant in variants:
      discard XUngrabKey(display, binding.keycode, variant, rootWindow)
    discard XSync(display, 0)
    return (hsConflict, 0)
  bindings[bindingCount] = binding
  inc bindingCount
  (hsOk, 0)

proc removeBinding(op: HotkeyOp): tuple[status: HotkeyStatus, errorCode: int] =
  for i in 0 ..< bindingCount:
    if bindings[i].id != op.id:
      continue
    ungrabKey(bindings[i].keycode, bindings[i].mods)
    discard XSync(display, 0)
    bindings[i] = bindings[bindingCount - 1]
    dec bindingCount
    return (hsOk, 0)
  (hsFailure, 0)

proc handleEvent(event: var XEvent) =
  if event.theType != KeyPress and event.theType != KeyRelease:
    return
  let
    key = cast[PXKeyEvent](addr event)
    state = cuint(key.state) and hotkeyModMask
  for i in 0 ..< bindingCount:
    if bindings[i].keycode != cint(key.keycode):
      continue
    if keyModifiers(bindings[i].mods) != state:
      continue
    if event.theType == KeyPress:
      if not bindings[i].down:
        bindings[i].down = true
        pushEvent(bindings[i].id)
    else:
      bindings[i].down = false
    return

proc processOps() =
  var op: HotkeyOp
  while takeOp(op):
    case op.kind
    of hoAdd:
      let outcome = grabBinding(op)
      finishOp(outcome.status, outcome.errorCode)
    of hoRemove:
      let outcome = removeBinding(op)
      finishOp(outcome.status, outcome.errorCode)
    of hoStop:
      finishOp(hsOk)

proc hotkeyWorker(_: int) {.thread.} =
  display = XOpenDisplay(nil)
  if display.isNil:
    markWorkerReady(hsUnsupported)
    return
  rootWindow = XDefaultRootWindow(display)
  connectionFd = XConnectionNumber(display)
  discard XkbSetDetectableAutoRepeat(display, true, nil)
  discard XSync(display, 0)
  markWorkerReady(hsOk)
  while true:
    var readSet: TFdSet
    FD_ZERO(readSet)
    FD_SET(connectionFd, readSet)
    FD_SET(wakePipe[0], readSet)
    let highest = max(connectionFd, wakePipe[0])
    if select(highest + 1, addr readSet, nil, nil, nil) < 0:
      continue
    if FD_ISSET(wakePipe[0], readSet) != 0:
      var buffer: array[64, byte]
      discard read(wakePipe[0], addr buffer[0], buffer.len)
      processOps()
    while XPending(display) > 0:
      var event: XEvent
      discard XNextEvent(display, addr event)
      handleEvent(event)

proc hkWake() =
  let byte = 1'u8
  discard write(wakePipe[1], unsafeAddr byte, 1)

proc hkStart*() =
  if started:
    return
  if getEnv("XDG_SESSION_TYPE").toLowerAscii().strip() == "wayland":
    raise newException(
      OsUnsupported,
      "global hotkeys are not available on Wayland; use an X11 session or XWayland"
    )
  initHotkeyState()
  resetWorkerState()
  x11input.ensureXlibThreads()
  if pipe(wakePipe) != 0:
    raise newException(OsFailure, "cannot create the hotkey wake pipe")
  try:
    createThread(worker, hotkeyWorker, 0)
  except CatchableError:
    discard close(wakePipe[0])
    discard close(wakePipe[1])
    raise
  started = true
  let status = waitWorkerReady()
  if status != hsOk:
    started = false
    discard close(wakePipe[0])
    discard close(wakePipe[1])
    raise newException(
      OsUnsupported,
      "cannot open an X11 display; global hotkeys need an X11 session " &
        "(DISPLAY is not set or the server is unreachable)"
    )

proc hkAdd*(id, code: int, mods: uint8, errorCode: var int): HotkeyStatus =
  hkStart()
  submitOp(HotkeyOp(kind: hoAdd, id: id, code: code, mods: mods), hkWake, errorCode)

proc hkRemove*(id: int, errorCode: var int): HotkeyStatus =
  if not started:
    return hsOk
  submitOp(HotkeyOp(kind: hoRemove, id: id), hkWake, errorCode)
