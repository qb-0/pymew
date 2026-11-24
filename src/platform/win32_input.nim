import std/math
import winim/lean

import common
import ../keys

proc inputFailure(op: string): ref OsFailure =
  let code = GetLastError().int
  var msg = op & " failed: Windows error " & $code
  if code == ERROR_REQUIRES_INTERACTIVE_WINDOWSTATION:
    msg.add " (needs an interactive desktop session, not a service/SSH session)"
  newException(OsFailure, msg)

proc sendInput(inp: var INPUT, op: string) =
  if SendInput(1, addr inp, sizeof(INPUT).int32) == 0:
    raise inputFailure(op)

proc vkDown(vk: int32): bool =
  (int(GetAsyncKeyState(vk)) and 0x8000) != 0

proc keyDown*(code: int): bool =
  let vk = keyCodeOs(code)
  vk != 0 and vkDown(int32(vk))

proc keysDown*(): seq[int] =
  for (_, code) in keyTable:
    let vk = keyCodeOs(code)
    if vk != 0 and vkDown(int32(vk)):
      result.add code

proc mousePosition*(): tuple[x, y: int] =
  var p: POINT
  if GetCursorPos(addr p) == 0:
    raise inputFailure("read cursor position")
  (p.x.int, p.y.int)

proc mouseButtonVk(button: MouseButton): int32 =
  case button
  of mbLeft: VK_LBUTTON
  of mbRight: VK_RBUTTON
  of mbMiddle: VK_MBUTTON
  of mbX1: VK_XBUTTON1
  of mbX2: VK_XBUTTON2
  else:
    raise newException(
      OsUnsupported,
      "Windows exposes only left, right, middle, x1 and x2 through GetAsyncKeyState"
    )

proc mouseButtonDown*(button: MouseButton): bool =
  (int(GetAsyncKeyState(mouseButtonVk(button))) and 0x8000) != 0

proc isExtended(code: int): bool =
  case code
  of 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 282, 283, 331, 335, 345, 346:
    true
  else:
    false

proc injectKey*(code: int, down: bool) =
  var inp: INPUT
  inp.`type` = INPUT_KEYBOARD
  inp.ki.wVk = WORD(keyCodeOs(code))
  if not down:
    inp.ki.dwFlags = DWORD(KEYEVENTF_KEYUP)
  if isExtended(code):
    inp.ki.dwFlags = inp.ki.dwFlags or DWORD(KEYEVENTF_EXTENDEDKEY)
  sendInput(inp, "inject key")

proc sendMouse(dwFlags: DWORD, dx: LONG = 0, dy: LONG = 0, data: DWORD = 0) =
  var inp: INPUT
  inp.`type` = INPUT_MOUSE
  inp.mi.dx = dx
  inp.mi.dy = dy
  inp.mi.mouseData = data
  inp.mi.dwFlags = dwFlags
  sendInput(inp, "inject mouse")

proc injectMouseButton*(button: MouseButton, down: bool) =
  case button
  of mbLeft:
    sendMouse(if down: DWORD(MOUSEEVENTF_LEFTDOWN) else: DWORD(MOUSEEVENTF_LEFTUP))
  of mbRight:
    sendMouse(if down: DWORD(MOUSEEVENTF_RIGHTDOWN) else: DWORD(MOUSEEVENTF_RIGHTUP))
  of mbMiddle:
    sendMouse(if down: DWORD(MOUSEEVENTF_MIDDLEDOWN) else: DWORD(MOUSEEVENTF_MIDDLEUP))
  of mbX1, mbX2:
    let data = if button == mbX1: DWORD(XBUTTON1) else: DWORD(XBUTTON2)
    sendMouse(if down: DWORD(MOUSEEVENTF_XDOWN) else: DWORD(MOUSEEVENTF_XUP), data = data)
  else:
    raise newException(
      OsUnsupported,
      "Windows can inject only left, right, middle, x1 and x2"
    )

proc injectMouseMove*(x, y: int, relative: bool) =
  if relative:
    sendMouse(DWORD(MOUSEEVENTF_MOVE), LONG(x), LONG(y))
  elif SetCursorPos(x.int32, y.int32) == 0:
    raise inputFailure("move cursor")

proc injectMouseScroll*(amount: float) =
  if amount == 0.0:
    return
  let delta = cast[uint32](int32(round(amount * WHEEL_DELTA.float)))
  sendMouse(DWORD(MOUSEEVENTF_WHEEL), data = DWORD(delta))

proc setCursorPos*(x, y: int) =
  if SetCursorPos(x.int32, y.int32) == 0:
    raise inputFailure("move cursor")

proc focusWindow*(handle: int) =
  let
    hwnd = HWND(handle)
    foreground = GetForegroundWindow()
  if foreground == hwnd:
    return
  let
    foregroundThread =
      if foreground != 0: GetWindowThreadProcessId(foreground, nil) else: 0
    currentThread = GetCurrentThreadId()
  let attached =
    foregroundThread != 0 and
    foregroundThread != currentThread and
    AttachThreadInput(foregroundThread, currentThread, TRUE) != 0
  discard BringWindowToTop(hwnd)
  discard SetForegroundWindow(hwnd)
  discard SetActiveWindow(hwnd)
  discard SetFocus(hwnd)
  if attached:
    discard AttachThreadInput(foregroundThread, currentThread, FALSE)

proc clipCursor*(handle: int) =
  let hwnd = HWND(handle)
  var
    rect: RECT
    topLeft, bottomRight: POINT
  if GetClientRect(hwnd, addr rect) == 0:
    return
  topLeft = POINT(x: rect.left, y: rect.top)
  bottomRight = POINT(x: rect.right, y: rect.bottom)
  if ClientToScreen(hwnd, addr topLeft) == 0 or
    ClientToScreen(hwnd, addr bottomRight) == 0:
    return
  var clip = RECT(
    left: topLeft.x,
    top: topLeft.y,
    right: bottomRight.x,
    bottom: bottomRight.y
  )
  discard ClipCursor(addr clip)

proc releaseCursorClip*() =
  discard ClipCursor(nil)
