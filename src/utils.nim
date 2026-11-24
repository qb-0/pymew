import std/[monotimes, strutils, times]
import nimpy
import nimpy/py_types
import raylib

import pyutil, errors, mem
import platform/api

pyExportModule("pymew")

const
  osName* = when defined(windows): "windows" else: "linux"

var
  startTime = getMonoTime()
  utilsReady = false
  monitorClass*: PyObject
  windowClass*: PyObject

proc ensureUtilsTypes*() =
  if utilsReady:
    return
  utilsReady = true
  monitorClass = buildRecordClass("Monitor", @["name", "x", "y", "width", "height", "refresh"])
  windowClass = buildRecordClass(
    "Window",
    @["id", "pid", "name", "title", "x", "y", "width", "height"]
  )

proc parseTraceLogLevel*(value: PyObject): TraceLogLevel =
  if isNone(value):
    return TraceLogLevel.Error
  if pyIsInstance(value, "bool"):
    raise newException(PmBadType, "log_level must be a name or a number, not bool")
  if pyIsInstance(value, "int"):
    let level = value.to(int)
    if level < 0 or level > ord(TraceLogLevel.None):
      raise newException(PmValueError, "log_level must be between 0 and 7")
    return TraceLogLevel(level)
  if not pyIsInstance(value, "str"):
    raise newException(PmBadType, "log_level must be a str (name) or an int")
  case normalizeName(value.to(string))
  of "all": TraceLogLevel.All
  of "trace": TraceLogLevel.Trace
  of "debug": TraceLogLevel.Debug
  of "info": TraceLogLevel.Info
  of "warning": TraceLogLevel.Warning
  of "error": TraceLogLevel.Error
  of "fatal": TraceLogLevel.Fatal
  of "none": TraceLogLevel.None
  else:
    raise newException(
      PmValueError,
      "unknown log level '" & value.to(string) & "'; use all, trace, debug, info, " &
        "warning, error, fatal or none"
    )

proc monitorRecord(monitor: RawMonitor): PyObject =
  ensureUtilsTypes()
  makeRecord(monitorClass, [
    ("name", nimValueToPy(monitor.name)),
    ("x", nimValueToPy(monitor.x)),
    ("y", nimValueToPy(monitor.y)),
    ("width", nimValueToPy(monitor.width)),
    ("height", nimValueToPy(monitor.height)),
    ("refresh", nimValueToPy(monitor.refresh))
  ])

proc windowRecord(window: RawWindow): PyObject =
  ensureUtilsTypes()
  makeRecord(windowClass, [
    ("id", nimValueToPy(window.id)),
    ("pid", nimValueToPy(window.pid)),
    ("name", nimValueToPy(window.name)),
    ("title", nimValueToPy(window.title)),
    ("x", nimValueToPy(window.x)),
    ("y", nimValueToPy(window.y)),
    ("width", nimValueToPy(window.width)),
    ("height", nimValueToPy(window.height))
  ])

proc utilsOsName*(): string {.exportpy: "_utilsOsName".} =
  osName

proc utilsScreenSize*(): PPyObject {.exportpy: "_utilsScreenSize".} =
  pyWrap:
    let size = screenSize()
    newPyTuple([
      takePy(nimValueToPy(size.width)),
      takePy(nimValueToPy(size.height))
    ])

proc utilsMonitors*(): PPyObject {.exportpy: "_utilsMonitors".} =
  pyWrap:
    var items: seq[PyObject]
    for monitor in monitorList():
      items.add monitorRecord(monitor)
    newPyListOf(items)

proc utilsWindows*(): PPyObject {.exportpy: "_utilsWindows".} =
  pyWrap:
    var items: seq[PyObject]
    for window in windowList():
      items.add windowRecord(window)
    newPyListOf(items)

proc utilsWindowInfo*(target: PyObject): PPyObject {.exportpy: "_utilsWindowInfo".} =
  pyWrap:
    const badType = "target must be an int (pid), a str (process name) or a str (window title)"
    if isNone(target):
      raise newException(PmBadType, badType)
    if pyIsInstance(target, "int"):
      let pid = resolveTargetPid(target)
      try:
        windowRecord(findWindow(pid))
      except OsFailure as e:
        raise newException(
          PmWindowNotFound,
          "no window found for target " & $pid & ": " & e.msg
        )
    elif pyIsInstance(target, "str"):
      let
        windows = windowList()
        text = target.to(string)
        wantProc = normalizeProcName(text)
        wantTitle = normalizeName(text)
      var
        best = -1
        bestRank = high(int)
      for i, window in windows:
        let
          procName = normalizeProcName(window.name)
          title = normalizeName(window.title)
        var rank = high(int)
        if wantProc.len > 0 and procName == wantProc:
          rank = 0
        elif wantTitle.len > 0 and title == wantTitle:
          rank = 1
        elif wantProc.len > 0 and wantProc in procName:
          rank = 2
        elif wantTitle.len > 0 and wantTitle in title:
          rank = 3
        if rank == high(int):
          continue
        if rank < bestRank or
            (rank == bestRank and best >= 0 and betterWindow(window, windows[best])):
          best = i
          bestRank = rank
      if best >= 0:
        windowRecord(windows[best])
      else:
        discard resolveTargetPid(target)
        raise newException(
          PmWindowNotFound,
          "no window found for target '" & text & "'"
        )
    else:
      raise newException(PmBadType, badType)

proc utilsTime*(): float64 {.exportpy: "_utilsTime".} =
  (getMonoTime() - startTime).inMilliseconds.float64 / 1000.0

proc utilsSetLogLevel*(level: PyObject = nil): PPyObject {.exportpy: "_utilsSetLogLevel".} =
  pyWrap:
    setTraceLogLevel(parseTraceLogLevel(level))
