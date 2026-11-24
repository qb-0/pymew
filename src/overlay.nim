import std/[monotimes, times]
import nimpy
import nimpy/py_types
import raylib

import pyutil, errors, keys, vec, mem, hotkey, utils, draw, imgui_bridge
import platform/api

pyExportModule("pymew")

type
  Overlay* = ref object of PyNimObjectExperimental
    opened*: bool
    closed*: bool
    frameOpen*: bool
    exitKey*: int
    exitDown*: bool
    trackTarget*: bool
    targetPid*: int
    targetId*: int
    lastResolve*: MonoTime
    lastX*: int
    lastY*: int
    lastW*: int
    lastH*: int
    clickthroughOn*: bool
    topmostOn*: bool
    imgui*: ImGuiBridge
    imguiKey*: int
    interactOn*: bool
    interactDown*: bool
    interactSince*: MonoTime

proc checkOpen(self: Overlay) =
  if self.closed:
    raise newException(PmOverlayError, "overlay is closed")

proc isFullscreenTarget(target: PyObject): bool =
  isNone(target)

proc applyWindowFlag(self: Overlay, enabled: bool, flag: ConfigFlags, current: var bool) =
  if enabled == current:
    return
  if enabled:
    setWindowState(flags(flag))
  else:
    clearWindowState(flags(flag))
  current = enabled

proc imguiActive(self: Overlay): bool =
  not self.imgui.isNil and (self.imguiKey < 0 or self.interactOn)

proc nativeHandle(): int =
  let handle = getWindowHandle()
  when defined(windows):
    cast[int](handle)
  else:
    if handle.isNil: 0 else: int(cast[ptr culong](handle)[])

proc enterInteract(self: Overlay) =
  if self.interactOn:
    return
  self.interactOn = true
  self.interactSince = getMonoTime()
  if isWindowReady():
    self.applyWindowFlag(false, WindowMousePassthrough, self.clickthroughOn)
    let handle = nativeHandle()
    if handle != 0:
      focusWindow(handle)
      clipCursor(handle)
  if not self.imgui.isNil:
    setMouseDrawCursor(self.imgui, true)

proc leaveInteract(self: Overlay) =
  if not self.interactOn:
    return
  self.interactOn = false
  if not self.imgui.isNil:
    releaseInput(self.imgui)
    setMouseDrawCursor(self.imgui, false)
  releaseCursorClip()
  if isWindowReady():
    self.applyWindowFlag(true, WindowMousePassthrough, self.clickthroughOn)
  if self.targetId > 0:
    focusWindow(self.targetId)

proc updateInteract(self: Overlay) =
  if self.imgui.isNil or self.imguiKey < 0:
    return
  let down = keyDown(self.imguiKey)
  if down and not self.interactDown:
    if self.interactOn: self.leaveInteract() else: self.enterInteract()
  self.interactDown = down
  if self.interactOn and
    (getMonoTime() - self.interactSince).inMilliseconds >= 250 and
    not isWindowFocused():
    self.leaveInteract()

proc endFrame(self: Overlay) =
  if not self.frameOpen:
    return
  try:
    if not self.imgui.isNil:
      endImGui(self.imgui)
    endDrawing()
  except RaylibError as e:
    raise newException(PmOverlayError, "cannot end overlay frame: " & e.msg)
  finally:
    self.frameOpen = false
    setFrameOpen(false)

proc beginFrame(self: Overlay) =
  if self.frameOpen:
    raise newException(PmOverlayError, "a frame is already open")
  self.updateInteract()
  beginDrawing()
  self.frameOpen = true
  setFrameOpen(true)
  clearBackground(Blank)
  if self.imguiActive():
    beginImGui(self.imgui)

proc closeImpl(self: Overlay) =
  if self.closed:
    return
  self.endFrame()
  self.leaveInteract()
  if not self.imgui.isNil:
    closeImGui(self.imgui)
    self.imgui = nil
  if self.opened and isWindowReady():
    resetDrawState()
    closeWindow()
  self.opened = false
  self.closed = true
  self.frameOpen = false

proc applyGeometry(self: Overlay, geometry: RawWindow) =
  if geometry.width <= 0 or geometry.height <= 0:
    return
  if geometry.width != self.lastW or geometry.height != self.lastH:
    setWindowSize(geometry.width.int32, geometry.height.int32)
    self.lastW = geometry.width
    self.lastH = geometry.height
  if geometry.x != self.lastX or geometry.y != self.lastY:
    setWindowPosition(geometry.x.int32, geometry.y.int32)
    self.lastX = geometry.x
    self.lastY = geometry.y

proc exitPressed(self: Overlay): bool =
  let down = keyDown(self.exitKey)
  result = down and not self.exitDown
  self.exitDown = down

proc track(self: Overlay) =
  if not self.trackTarget or self.targetPid <= 0:
    return
  try:
    let geometry = windowGeometry(self.targetId)
    self.applyGeometry(geometry)
    return
  except OsFailure:
    discard
  let now = getMonoTime()
  if (now - self.lastResolve).inMilliseconds < 1000:
    return
  self.lastResolve = now
  try:
    let window = findWindow(self.targetPid)
    self.targetId = window.id
    self.applyGeometry(window)
  except OsFailure:
    discard

proc overlayOpen*(
  target: PyObject = nil,
  fps: int = 0,
  title: string = "pymew",
  exit_key: PyObject = nil,
  track: bool = false,
  log_level: PyObject = nil,
  imgui_bundle: bool = false,
  imgui_key: PyObject = nil,
  msaa: bool = true
): PPyObject {.exportpy: "_overlayOpen".} =
  pyWrap:
    if fps < 0:
      raise newException(PmValueError, "fps must not be negative")
    if isWindowReady():
      raise newException(
        PmOverlayError,
        "an overlay is already open; close it before opening another"
      )
    let
      exitKey = if isNone(exit_key): keyCode("insert") else: keyCodeValue(exit_key)
      interactKey = if isNone(imgui_key): -1 else: keyCodeValue(imgui_key)
      logLevel = parseTraceLogLevel(log_level)
    if interactKey >= 0:
      if not imgui_bundle:
        raise newException(PmValueError, "imgui_key requires imgui_bundle=True")
      if interactKey == exitKey:
        raise newException(PmValueError, "imgui_key must differ from exit_key")
    var targetPid = 0
    var fullscreen = true
    var targetWindow: RawWindow
    if not isFullscreenTarget(target):
      targetPid = resolveTargetPid(target)
      fullscreen = false
      try:
        targetWindow = findWindow(targetPid)
      except OsFailure as e:
        raise newException(
          PmWindowNotFound,
          "no window found for target " & $targetPid & ": " & e.msg
        )

    setTraceLogLevel(logLevel)
    setTargetFPS(fps.int32)
    var config = @[
      WindowUndecorated,
      WindowTransparent,
      WindowTopmost,
      WindowMousePassthrough,
      WindowHidden
    ]
    if msaa:
      config.add Msaa4xHint
    setConfigFlags(flags(config))

    try:
      initWindow(1, 1, title)
    except RaylibError as e:
      if isWindowReady():
        closeWindow()
      raise newException(PmOverlayError, "cannot create overlay window: " & e.msg)

    resetDrawState()
    var self = Overlay(
      opened: true,
      exitKey: exitKey,
      trackTarget: track and not fullscreen,
      targetPid: targetPid,
      targetId: targetWindow.id,
      lastResolve: getMonoTime(),
      clickthroughOn: true,
      topmostOn: true,
      imguiKey: interactKey
    )
    try:
      if imgui_bundle:
        self.imgui = openImGuiBundle()
      if fullscreen:
        if getMonitorCount() <= 0:
          raise newException(PmOverlayError, "no monitor available")
        let
          monitor = getMonitorPosition(0)
          width = getMonitorWidth(0)
          height = getMonitorHeight(0)
        if width <= 0 or height <= 0:
          raise newException(PmOverlayError, "the primary monitor has no usable resolution")
        setWindowSize(width, height)
        setWindowPosition(int32(monitor.x), int32(monitor.y))
        self.lastX = int(monitor.x)
        self.lastY = int(monitor.y)
        self.lastW = int(width)
        self.lastH = int(height)
      else:
        setWindowSize(targetWindow.width.int32, targetWindow.height.int32)
        setWindowPosition(targetWindow.x.int32, targetWindow.y.int32)
        self.lastX = targetWindow.x
        self.lastY = targetWindow.y
        self.lastW = targetWindow.width
        self.lastH = targetWindow.height
      setExitKey(KeyboardKey.Null)
      clearWindowState(flags(WindowHidden))
    except CatchableError:
      self.closeImpl()
      raise
    self

proc overlayLoop*(self: Overlay): PPyObject {.exportpy: "loop".} =
  pyWrap:
    if self.closed:
      false
    else:
      self.endFrame()
      pump()
      if self.exitPressed() or windowShouldClose():
        self.closeImpl()
        false
      else:
        self.track()
        self.beginFrame()
        true

proc overlayBegin*(self: Overlay): PPyObject {.exportpy: "begin".} =
  pyWrap:
    self.checkOpen()
    self.beginFrame()

proc overlayEnd*(self: Overlay): PPyObject {.exportpy: "end".} =
  pyWrap:
    if not self.closed:
      self.endFrame()

proc overlayClose*(self: Overlay): PPyObject {.exportpy: "close".} =
  pyWrap:
    self.closeImpl()

proc overlayWidth*(self: Overlay): PPyObject {.exportpy: "width".} =
  pyWrap:
    self.checkOpen()
    int(getScreenWidth())

proc overlayHeight*(self: Overlay): PPyObject {.exportpy: "height".} =
  pyWrap:
    self.checkOpen()
    int(getScreenHeight())

proc overlayPos*(self: Overlay): PPyObject {.exportpy: "pos".} =
  pyWrap:
    self.checkOpen()
    let position = getWindowPosition()
    newVec2(float(position.x), float(position.y))

proc overlaySetPos*(self: Overlay, x, y: int): PPyObject {.exportpy: "set_pos".} =
  pyWrap:
    self.checkOpen()
    setWindowPosition(x.int32, y.int32)
    self.lastX = x
    self.lastY = y

proc overlaySetSize*(self: Overlay, width, height: int): PPyObject {.exportpy: "set_size".} =
  pyWrap:
    self.checkOpen()
    if width <= 0 or height <= 0:
      raise newException(PmValueError, "overlay size must be positive")
    setWindowSize(width.int32, height.int32)
    self.lastW = width
    self.lastH = height

proc overlaySetTitle*(self: Overlay, title: string): PPyObject {.exportpy: "set_title".} =
  pyWrap:
    self.checkOpen()
    setWindowTitle(title)

proc overlayMonitor*(self: Overlay, index: int): PPyObject {.exportpy: "monitor".} =
  pyWrap:
    self.checkOpen()
    if index < 0 or index >= int(getMonitorCount()):
      raise newException(PmValueError, "monitor index out of range")
    setWindowMonitor(index.int32)
    self.lastX = -1
    self.lastY = -1

proc overlayClickthrough*(self: Overlay, enabled: bool): PPyObject {.exportpy: "clickthrough".} =
  pyWrap:
    self.checkOpen()
    self.applyWindowFlag(enabled, WindowMousePassthrough, self.clickthroughOn)

proc overlayTopmost*(self: Overlay, enabled: bool): PPyObject {.exportpy: "topmost".} =
  pyWrap:
    self.checkOpen()
    self.applyWindowFlag(enabled, WindowTopmost, self.topmostOn)

proc overlayInteract*(self: Overlay, enabled: bool): PPyObject {.exportpy: "interact".} =
  pyWrap:
    self.checkOpen()
    if enabled: self.enterInteract() else: self.leaveInteract()
    newPyNone()

proc overlayFps*(self: Overlay): PPyObject {.exportpy: "fps".} =
  pyWrap:
    self.checkOpen()
    int(getFPS())

proc overlayImguiActive*(self: Overlay): PPyObject {.exportpy: "imgui_active".} =
  pyWrap:
    self.checkOpen()
    self.imguiActive()

proc overlaySetFps*(self: Overlay, fps: int): PPyObject {.exportpy: "set_fps".} =
  pyWrap:
    self.checkOpen()
    if fps < 0:
      raise newException(PmValueError, "fps must not be negative")
    setTargetFPS(fps.int32)

proc overlayScreenshot*(self: Overlay, path: string): PPyObject {.exportpy: "screenshot".} =
  pyWrap:
    self.checkOpen()
    captureScreen(path, "screenshot")

proc enterImpl(self: Overlay): Overlay =
  self

proc exitImpl(self: Overlay, exceptionType, exceptionValue, traceback: PyObject): bool =
  discard exceptionType
  discard exceptionValue
  discard traceback
  self.closeImpl()
  false

exportAs(enterImpl, "__enter__")
exportAs(exitImpl, "__exit__")
