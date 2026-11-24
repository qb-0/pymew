import std/typedthreads
import winim/lean

import common
import ../keys

var
  wakeEvent: HANDLE
  worker: Thread[int]
  started: bool

proc hotkeyFlags(mods: uint8): UINT =
  result = UINT(MOD_NOREPEAT)
  if (mods and hmCtrl) != 0:
    result = result or UINT(MOD_CONTROL)
  if (mods and hmAlt) != 0:
    result = result or UINT(MOD_ALT)
  if (mods and hmShift) != 0:
    result = result or UINT(MOD_SHIFT)
  if (mods and hmSuper) != 0:
    result = result or UINT(MOD_WIN)

proc registerHotkey(op: HotkeyOp): tuple[status: HotkeyStatus, errorCode: int] =
  let vk = keyCodeOs(op.code)
  if vk == 0:
    return (hsUnsupported, 0)
  if RegisterHotKey(0, int32(op.id), hotkeyFlags(op.mods), UINT(vk)) != 0:
    return (hsOk, 0)
  let code = GetLastError().int
  if code == ERROR_HOTKEY_ALREADY_REGISTERED:
    (hsConflict, code)
  else:
    (hsFailure, code)

proc unregisterHotkey(op: HotkeyOp): tuple[status: HotkeyStatus, errorCode: int] =
  if UnregisterHotKey(0, int32(op.id)) != 0:
    (hsOk, 0)
  else:
    (hsFailure, GetLastError().int)

proc processOps() =
  var op: HotkeyOp
  while takeOp(op):
    case op.kind
    of hoAdd:
      let outcome = registerHotkey(op)
      finishOp(outcome.status, outcome.errorCode)
    of hoRemove:
      let outcome = unregisterHotkey(op)
      finishOp(outcome.status, outcome.errorCode)
    of hoStop:
      finishOp(hsOk)

proc hotkeyWorker(_: int) {.thread.} =
  var msg: MSG
  discard PeekMessage(addr msg, 0, 0, 0, UINT(PM_NOREMOVE))
  markWorkerReady(hsOk)
  while true:
    let ready = MsgWaitForMultipleObjects(
      1,
      addr wakeEvent,
      FALSE,
      DWORD(INFINITE),
      DWORD(QS_ALLINPUT)
    )
    if ready == DWORD(WAIT_OBJECT_0):
      discard ResetEvent(wakeEvent)
    while PeekMessage(addr msg, 0, 0, 0, UINT(PM_REMOVE)) != 0:
      if msg.message == UINT(WM_HOTKEY):
        pushEvent(int(msg.wParam))
    processOps()

proc hkWake() =
  discard SetEvent(wakeEvent)

proc hkStart*() =
  if started:
    return
  initHotkeyState()
  resetWorkerState()
  wakeEvent = CreateEvent(nil, FALSE, FALSE, nil)
  if wakeEvent == 0:
    raise newException(OsFailure, "cannot create the hotkey wake event")
  try:
    createThread(worker, hotkeyWorker, 0)
  except CatchableError:
    wakeEvent = 0
    raise
  started = true
  let status = waitWorkerReady()
  if status != hsOk:
    started = false
    raise newException(OsUnsupported, "cannot start the hotkey worker thread")

proc hkAdd*(id, code: int, mods: uint8, errorCode: var int): HotkeyStatus =
  hkStart()
  submitOp(HotkeyOp(kind: hoAdd, id: id, code: code, mods: mods), hkWake, errorCode)

proc hkRemove*(id: int, errorCode: var int): HotkeyStatus =
  if not started:
    return hsOk
  submitOp(HotkeyOp(kind: hoRemove, id: id), hkWake, errorCode)