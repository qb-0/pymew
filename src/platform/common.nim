import std/locks

type
  OsHandle* = int

  RawProcess* = object
    pid*: int
    name*: string

  RawModule* = object
    name*: string
    path*: string
    base*: uint
    `end`*: uint
    size*: uint

  RawRegion* = object
    start*: uint
    `end`*: uint
    size*: uint
    protection*: string

  RawWindow* = object
    id*: int
    pid*: int
    name*: string
    title*: string
    x*: int
    y*: int
    width*: int
    height*: int
    visible*: bool

  RawMonitor* = object
    name*: string
    x*: int
    y*: int
    width*: int
    height*: int
    refresh*: int

  OsFailure* = object of CatchableError
    code*: int
    denied*: bool

  OsUnsupported* = object of CatchableError

  MouseButton* = range[1..255]

  HotkeyStatus* = enum
    hsOk
    hsConflict
    hsFailure
    hsUnsupported

  HotkeyOpKind* = enum
    hoAdd
    hoRemove
    hoStop

  HotkeyOp* = object
    kind*: HotkeyOpKind
    id*: int
    code*: int
    mods*: uint8
    status*: HotkeyStatus
    errorCode*: int
    done*: bool

  WakeProc* = proc() {.nimcall.}

const
  mbLeft* = MouseButton(1)
  mbRight* = MouseButton(2)
  mbMiddle* = MouseButton(3)
  mbX1* = MouseButton(4)
  mbX2* = MouseButton(5)

  hkMaxEvents* = 1024

  hmCtrl* = 1'u8
  hmAlt* = 2'u8
  hmShift* = 4'u8
  hmSuper* = 8'u8

var
  stateInitialized: bool
  hkLock: Lock
  hkCond: Cond
  workerReady: bool
  workerStartStatus: HotkeyStatus
  currentOp: HotkeyOp
  opQueued: bool
  opTaken: bool
  events: array[hkMaxEvents, int]
  eventHead: int
  eventTail: int
  eventCount: int

proc initHotkeyState*() =
  if stateInitialized:
    return
  initLock(hkLock)
  initCond(hkCond)
  stateInitialized = true

proc markWorkerReady*(status: HotkeyStatus) =
  withLock hkLock:
    workerStartStatus = status
    workerReady = true
    broadcast(hkCond)

proc resetWorkerState*() =
  withLock hkLock:
    workerReady = false
    workerStartStatus = hsOk

proc waitWorkerReady*(): HotkeyStatus =
  withLock hkLock:
    while not workerReady:
      wait(hkCond, hkLock)
    result = workerStartStatus

proc submitOp*(op: HotkeyOp, wake: WakeProc, errorCode: var int): HotkeyStatus =
  withLock hkLock:
    while opQueued:
      wait(hkCond, hkLock)
    currentOp = op
    currentOp.done = false
    opQueued = true
    opTaken = false
  wake()
  withLock hkLock:
    while not currentOp.done:
      wait(hkCond, hkLock)
    result = currentOp.status
    errorCode = currentOp.errorCode
    opQueued = false

proc takeOp*(op: var HotkeyOp): bool =
  withLock hkLock:
    if opQueued and not opTaken:
      opTaken = true
      op = currentOp
      result = true

proc finishOp*(status: HotkeyStatus, errorCode: int = 0) =
  withLock hkLock:
    currentOp.status = status
    currentOp.errorCode = errorCode
    currentOp.done = true
    signal(hkCond)

proc pushEvent*(id: int) =
  withLock hkLock:
    if eventCount < hkMaxEvents:
      events[eventTail] = id
      eventTail = (eventTail + 1) mod hkMaxEvents
      inc eventCount

proc popEvent*(): int =
  withLock hkLock:
    if eventCount > 0:
      result = events[eventHead]
      eventHead = (eventHead + 1) mod hkMaxEvents
      dec eventCount
    else:
      result = -1

proc betterWindow*(a, b: RawWindow): bool =
  if a.visible != b.visible:
    return a.visible
  a.width * a.height > b.width * b.height

proc pickWindow*(windows: seq[RawWindow], pid: int): int =
  result = -1
  for i, window in windows:
    if window.pid != pid:
      continue
    if result < 0 or betterWindow(window, windows[result]):
      result = i