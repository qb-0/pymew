import std/[os, strutils, tables, algorithm]
import std/posix
import x11/[x, xlib, xatom, xrandr, xutil]

import common
from ./x11_input import openDisplay, rootWindow

proc process_vm_readv(
  pid: Pid,
  localIov: ptr IOVec,
  liovcnt: culong,
  remoteIov: ptr IOVec,
  riovcnt: culong,
  flags: culong
): int {.importc, header: "<sys/uio.h>".}

proc process_vm_writev(
  pid: Pid,
  localIov: ptr IOVec,
  liovcnt: culong,
  remoteIov: ptr IOVec,
  riovcnt: culong,
  flags: culong
): int {.importc, header: "<sys/uio.h>".}

proc osFailure(op: string, code: OSErrorCode): ref OsFailure =
  result = newException(OsFailure, op & " failed: " & osErrorMsg(code))
  result.code = code.int
  let c = code.int32
  result.denied = c == EPERM.int32 or c == EACCES.int32

proc permissionHint*(): string =
  "permission denied: Linux allows process_vm reads only for child processes " &
  "unless the tracer has CAP_SYS_PTRACE; set kernel.yama.ptrace_scope=0 " &
  "(sudo sysctl kernel.yama.ptrace_scope=0) or run with sudo/root"

proc processExists*(pid: int): bool

proc openProcessHandle*(pid: int): OsHandle =
  if pid <= 0 or not processExists(pid):
    raise osFailure("open process " & $pid, OSErrorCode(ESRCH))
  result = pid

proc closeProcessHandle*(h: OsHandle) =
  discard

proc readMemory*(h: OsHandle, address: uint, dst: pointer, size: int): int =
  if size == 0:
    return 0
  var local, remote: IOVec
  local.iov_base = dst
  local.iov_len = size.uint
  remote.iov_base = cast[pointer](address)
  remote.iov_len = size.uint
  let n = process_vm_readv(Pid(h), addr local, 1, addr remote, 1, 0)
  if n < 0:
    raise osFailure("read", osLastError())
  result = n

proc writeMemory*(h: OsHandle, address: uint, src: pointer, size: int): int =
  if size == 0:
    return 0
  var local, remote: IOVec
  local.iov_base = src
  local.iov_len = size.uint
  remote.iov_base = cast[pointer](address)
  remote.iov_len = size.uint
  let n = process_vm_writev(Pid(h), addr local, 1, addr remote, 1, 0)
  if n < 0:
    raise osFailure("write", osLastError())
  result = n

proc readComm(pid: int): string =
  try:
    result = readFile("/proc/" & $pid & "/comm").strip()
  except CatchableError:
    discard

proc statState(pid: int): char =
  let
    stat = readFile("/proc/" & $pid & "/stat")
    closeParen = stat.rfind(')')
  if closeParen < 0 or closeParen + 2 >= stat.len:
    return '\0'
  result = stat[closeParen + 2]

proc processExists*(pid: int): bool =
  if pid <= 0:
    return false
  try:
    let state = statState(pid)
    result = state notin {'\0', 'Z', 'X', 'x'}
  except CatchableError:
    result = false

proc readCmdlineName(pid: int): string =
  try:
    let
      raw = readFile("/proc/" & $pid & "/cmdline")
      nul = raw.find('\0')
      argv0 = if nul >= 0: raw[0 ..< nul] else: raw
    if argv0.len > 0:
      result = extractFilename(argv0)
  except CatchableError:
    discard

proc enumProcesses*(): seq[RawProcess] =
  for kind, path in walkDir("/proc", relative = true):
    if kind != pcDir and kind != pcLinkToDir:
      continue
    if path.len == 0 or path[0] notin {'0'..'9'}:
      continue
    var pid: int
    try:
      pid = parseInt(path)
    except ValueError:
      continue
    try:
      result.add RawProcess(pid: pid, name: readComm(pid))
    except CatchableError:
      discard

proc processNameByPid*(pid: int): string =
  readComm(pid)

proc processPath*(pid: int): string =
  var buf = newString(4096)
  let n = readlink(("/proc/" & $pid & "/exe").cstring, buf.cstring, buf.len)
  if n <= 0:
    raise osFailure("readlink /proc/" & $pid & "/exe", osLastError())
  result = buf[0 ..< n]

proc readExeName(pid: int): string =
  try:
    result = extractFilename(processPath(pid))
  except CatchableError:
    discard

proc processIs64Bit*(pid: int): bool =
  var f: File
  if not open(f, "/proc/" & $pid & "/exe", fmRead):
    raise osFailure("open /proc/" & $pid & "/exe", osLastError())
  defer: f.close()
  var header: array[5, byte]
  if f.readBuffer(addr header[0], header.len) != header.len:
    raise osFailure("read ELF header of " & $pid, OSErrorCode(5))
  if header[0] != 0x7F'u8 or header[1] != 'E'.ord.uint8 or header[2] != 'L'.ord.uint8 or header[3] != 'F'.ord.uint8:
    raise osFailure("validate ELF header of " & $pid, OSErrorCode(5))
  result = header[4] == 2

proc parseMapLine(line: string): tuple[start, stop: uint, perms, path: string] =
  let fields = line.splitWhitespace(maxsplit = 5)
  if fields.len < 5:
    return
  let dash = fields[0].find('-')
  if dash < 0:
    return
  try:
    result.start = uint(parseHexInt(fields[0][0 ..< dash]))
    result.stop = uint(parseHexInt(fields[0][dash + 1 .. ^1]))
  except ValueError:
    return
  result.perms = fields[1]
  if fields.len > 5:
    result.path = fields[5]

proc stripDeleted(path: string): string =
  result = path
  if result.endsWith(" (deleted)"):
    result.setLen(result.len - 10)

proc isModulePath(path: string): bool =
  if path.len == 0 or path[0] != '/':
    return false
  not (path.startsWith("/dev/") or path.startsWith("/memfd:") or path.startsWith("/SYSV"))

proc protectionOf(perms: string): string =
  if perms.len < 4:
    return perms
  result = perms[0 .. 2]
  if perms[3] == 'p':
    result.add 'p'

type ModuleAgg = object
  name, path: string
  base, stop: uint

iterator procMaps(pid: int): string =
  let path = "/proc/" & $pid & "/maps"
  var f: File
  if not open(f, path, fmRead):
    raise osFailure("open " & path, osLastError())
  defer: f.close()
  for line in f.lines:
    yield line

proc enumModules*(pid: int): seq[RawModule] =
  var byPath: Table[string, ModuleAgg]
  var order: seq[string]
  for line in procMaps(pid):
    let entry = parseMapLine(line)
    if not isModulePath(entry.path):
      continue
    let cleanPath = stripDeleted(entry.path)
    if not byPath.hasKey(cleanPath):
      byPath[cleanPath] = ModuleAgg(
        name: extractFilename(cleanPath),
        path: cleanPath,
        base: entry.start,
        stop: entry.stop
      )
      order.add cleanPath
    else:
      byPath[cleanPath].base = min(byPath[cleanPath].base, entry.start)
      byPath[cleanPath].stop = max(byPath[cleanPath].stop, entry.stop)
  var modules: seq[RawModule]
  for p in order:
    let agg = byPath[p]
    modules.add RawModule(name: agg.name, path: agg.path, base: agg.base, `end`: agg.stop, size: agg.stop - agg.base)
  modules.sort(proc(a, b: RawModule): int = cmp(a.base, b.base))
  result = modules

proc enumRegions*(pid: int): seq[RawRegion] =
  for line in procMaps(pid):
    let entry = parseMapLine(line)
    if entry.stop <= entry.start:
      continue
    result.add RawRegion(
      start: entry.start,
      `end`: entry.stop,
      size: entry.stop - entry.start,
      protection: protectionOf(entry.perms)
    )

proc processNames*(pid: int): seq[string] =
  var seen: seq[string]
  for n in [readComm(pid), readExeName(pid), readCmdlineName(pid)]:
    if n.len > 0:
      let lower = n.toLowerAscii()
      if lower notin seen:
        seen.add lower
  result = seen

proc systemFontDirs*(): seq[string] =
  let
    home = getHomeDir()
    dataHome = getEnv("XDG_DATA_HOME")
    dataDirsEnv = getEnv("XDG_DATA_DIRS")
  result.add home / ".fonts"
  result.add home / ".local" / "share" / "fonts"
  if dataHome.len > 0:
    result.add dataHome / "fonts"
  let dataDirs =
    if dataDirsEnv.len > 0: dataDirsEnv.split(':')
    else: @["/usr/local/share", "/usr/share"]
  for dir in dataDirs:
    if dir.len > 0:
      result.add dir / "fonts"
  var seen: seq[string]
  var unique: seq[string]
  for dir in result:
    let key = dir.toLowerAscii()
    if key notin seen:
      seen.add key
      unique.add dir
  result = unique

type
  XRRCrtcInfo {.final.} = object
    timestamp*: x.Time
    x*, y*: cint
    width*, height*: cuint
    mode*: RRMode
    rotation*: Rotation
    noutput*: cint
    outputs*: ptr UncheckedArray[RROutput]
    rotations*: Rotation
    npossible*: cint
    possible*: ptr UncheckedArray[RROutput]

proc XRRGetCrtcInfo(
  dpy: PDisplay,
  res: PXRRScreenResources,
  crtc: RRCrtc
): ptr XRRCrtcInfo {.cdecl, dynlib: libXrandr, importc.}

proc XRRFreeCrtcInfo(info: ptr XRRCrtcInfo) {.cdecl, dynlib: libXrandr, importc.}

proc x11ErrorHandler(d: PDisplay, event: PXErrorEvent): cint {.cdecl.} =
  discard d
  discard event
  0

var
  netWmStateAtom: Atom
  netWmStateFocusedAtom: Atom

proc prepareWindowQueries() =
  discard XSetErrorHandler(x11ErrorHandler)

proc internAtom(d: PDisplay, name: string): Atom =
  XInternAtom(d, name.cstring, 0)

proc readProperty(
  d: PDisplay,
  win: Window,
  name: string,
  reqType: Atom
): tuple[format: cint, data: seq[byte]] =
  let atom = internAtom(d, name)
  if atom == 0:
    return
  var
    actualType: Atom
    actualFormat: cint
    nitems, bytesAfter: culong
    raw: ptr uint8
  if XGetWindowProperty(
    d,
    win,
    atom,
    0,
    65536,
    0,
    reqType,
    addr actualType,
    addr actualFormat,
    addr nitems,
    addr bytesAfter,
    cast[PPcuchar](addr raw)
  ) != Success:
    return
  if raw.isNil:
    return
  defer: discard XFree(cast[pointer](raw))
  result.format = actualFormat
  let
    unit = if actualFormat == 32: sizeof(clong) else: 1
    total = int(nitems) * unit
  result.data = newSeq[byte](total)
  if total > 0:
    copyMem(addr result.data[0], raw, total)

proc isFocused(d: PDisplay, win: Window): bool =
  if netWmStateAtom == 0:
    netWmStateAtom = internAtom(d, "_NET_WM_STATE")
    netWmStateFocusedAtom = internAtom(d, "_NET_WM_STATE_FOCUSED")
  var
    actualType: Atom
    actualFormat: cint
    nitems, bytesAfter: culong
    raw: ptr uint8 = nil
  if XGetWindowProperty(
    d,
    win,
    netWmStateAtom,
    0,
    64,
    0,
    XA_ATOM,
    addr actualType,
    addr actualFormat,
    addr nitems,
    addr bytesAfter,
    cast[PPcuchar](addr raw)
  ) != Success:
    return false
  if raw.isNil:
    return false
  defer: discard XFree(cast[pointer](raw))
  let atoms = cast[ptr UncheckedArray[clong]](raw)
  for i in 0 ..< int(nitems):
    if cast[Atom](atoms[i]) == netWmStateFocusedAtom:
      return true

proc propertyWindows(d: PDisplay, win: Window, name: string): seq[Window] =
  let prop = readProperty(d, win, name, XA_WINDOW)
  if prop.format != 32:
    return
  let count = prop.data.len div sizeof(clong)
  for i in 0 ..< count:
    var value: clong
    copyMem(addr value, unsafeAddr prop.data[i * sizeof(clong)], sizeof(clong))
    result.add Window(value)

proc propertyCardinal(d: PDisplay, win: Window, name: string): uint =
  let prop = readProperty(d, win, name, XA_CARDINAL)
  if prop.format != 32 or prop.data.len < sizeof(clong):
    return 0
  var value: clong
  copyMem(addr value, unsafeAddr prop.data[0], sizeof(clong))
  uint(value and 0xFFFFFFFF'i64)

proc propertyText(d: PDisplay, win: Window, name: string): string =
  let prop = readProperty(d, win, name, AnyPropertyType)
  if prop.format != 8 or prop.data.len == 0:
    return
  result = newString(prop.data.len)
  copyMem(addr result[0], unsafeAddr prop.data[0], prop.data.len)
  let nul = result.find('\0')
  if nul >= 0:
    result.setLen(nul)

proc windowPid(d: PDisplay, win: Window): int =
  let direct = propertyCardinal(d, win, "_NET_WM_PID")
  if direct > 0:
    return int(direct)
  let leaders = propertyWindows(d, win, "WM_CLIENT_LEADER")
  for leader in leaders:
    if leader == 0 or leader == win:
      continue
    let inherited = propertyCardinal(d, leader, "_NET_WM_PID")
    if inherited > 0:
      return int(inherited)
  0

proc windowProcessName(pid: int): string =
  try:
    processNameByPid(pid)
  except OsFailure:
    ""

proc addWindow(
  d: PDisplay,
  win: Window,
  seen: var seq[Window],
  items: var seq[RawWindow]
) =
  if win in seen:
    return
  seen.add win
  var attributes: XWindowAttributes
  if XGetWindowAttributes(d, win, addr attributes) == 0:
    return
  let pid = windowPid(d, win)
  if pid <= 0:
    return
  var rootX, rootY: cint
  var child: Window
  if XTranslateCoordinates(d, win, rootWindow, 0, 0, addr rootX, addr rootY, addr child) == 0:
    return
  var title = propertyText(d, win, "_NET_WM_NAME")
  if title.len == 0:
    title = propertyText(d, win, "WM_NAME")
  items.add RawWindow(
    id: int(win),
    pid: pid,
    name: windowProcessName(pid),
    title: title,
    x: rootX.int,
    y: rootY.int,
    width: attributes.width.int,
    height: attributes.height.int,
    visible: attributes.map_state == IsViewable
  )

proc walkWindowTree(
  d: PDisplay,
  win: Window,
  depth: int,
  seen: var seq[Window],
  items: var seq[RawWindow]
) =
  if depth > 16:
    return
  var
    root, parent: Window
    children: PWindow
    count: cuint
  if XQueryTree(d, win, addr root, addr parent, addr children, addr count) == 0:
    return
  defer:
    if not children.isNil:
      discard XFree(cast[pointer](children))
  for i in 0 ..< int(count):
    let child = cast[ptr UncheckedArray[Window]](children)[i]
    var attributes: XWindowAttributes
    if XGetWindowAttributes(d, child, addr attributes) == 0:
      continue
    if attributes.override_redirect != 0 or attributes.map_state != IsViewable:
      continue
    addWindow(d, child, seen, items)
    walkWindowTree(d, child, depth + 1, seen, items)

proc windowList*(): seq[RawWindow] =
  let d = openDisplay()
  prepareWindowQueries()
  var seen: seq[Window]
  for win in propertyWindows(d, rootWindow, "_NET_CLIENT_LIST"):
    addWindow(d, win, seen, result)
  if result.len == 0:
    walkWindowTree(d, rootWindow, 0, seen, result)

proc findWindow*(pid: int): RawWindow =
  let
    windows = windowList()
    index = pickWindow(windows, pid)
  if index < 0:
    raise newException(OsFailure, "no window found for process " & $pid)
  result = windows[index]

proc windowGeometry*(id: int): RawWindow =
  let d = openDisplay()
  prepareWindowQueries()
  var attributes: XWindowAttributes
  if XGetWindowAttributes(d, Window(id), addr attributes) == 0:
    raise newException(OsFailure, "window " & $id & " no longer exists")
  var rootX, rootY: cint
  var child: Window
  if XTranslateCoordinates(
    d,
    Window(id),
    rootWindow,
    0,
    0,
    addr rootX,
    addr rootY,
    addr child
  ) == 0:
    raise newException(OsFailure, "window " & $id & " no longer exists")
  RawWindow(
    id: id,
    x: rootX.int,
    y: rootY.int,
    width: attributes.width.int,
    height: attributes.height.int,
    visible: attributes.map_state == IsViewable,
    focused: isFocused(d, Window(id))
  )

proc setFocusable*(id: int, focusable: bool) =
  if id == 0:
    return
  let d = openDisplay()
  var hints = XWMHints(
    flags: InputHint,
    input: XBool(if focusable: 1 else: 0)
  )
  discard XSetWMHints(d, Window(id), addr hints)
  discard XFlush(d)

proc setTaskbarVisible*(id: int, visible: bool) =
  if id == 0:
    return
  let
    d = openDisplay()
    win = Window(id)
    stateAtom = internAtom(d, "_NET_WM_STATE")
    skipTaskbar = internAtom(d, "_NET_WM_STATE_SKIP_TASKBAR")
    skipPager = internAtom(d, "_NET_WM_STATE_SKIP_PAGER")
  var attributes: XWindowAttributes
  if XGetWindowAttributes(d, win, addr attributes) == 0:
    raise newException(OsFailure, "window " & $id & " no longer exists")
  if attributes.map_state == IsViewable:
    var event: XEvent
    event.xclient.theType = ClientMessage
    event.xclient.send_event = XBool(1)
    event.xclient.display = d
    event.xclient.window = win
    event.xclient.message_type = stateAtom
    event.xclient.format = 32
    event.xclient.data.l[0] = if visible: 0 else: 1
    event.xclient.data.l[1] = cast[clong](skipTaskbar)
    event.xclient.data.l[2] = cast[clong](skipPager)
    event.xclient.data.l[3] = 1
    discard XSendEvent(
      d,
      rootWindow,
      XBool(0),
      SubstructureRedirectMask or SubstructureNotifyMask,
      addr event
    )
  elif not visible:
    var hints = [skipTaskbar, skipPager]
    discard XChangeProperty(
      d,
      win,
      stateAtom,
      XA_ATOM,
      32,
      PropModeAppend,
      cast[Pcuchar](addr hints[0]),
      cint(hints.len)
    )
  discard XFlush(d)

proc screenSize*(): tuple[width, height: int] =
  let
    d = openDisplay()
    screen = XDefaultScreen(d)
  (XDisplayWidth(d, screen).int, XDisplayHeight(d, screen).int)

proc monitorList*(): seq[RawMonitor] =
  let
    d = openDisplay()
    screen = XDefaultScreen(d)
    resources = XRRGetScreenResourcesCurrent(d, rootWindow)
  if resources.isNil:
    return @[RawMonitor(
      name: "",
      x: 0,
      y: 0,
      width: XDisplayWidth(d, screen).int,
      height: XDisplayHeight(d, screen).int,
      refresh: 0
    )]
  defer:
    XRRFreeScreenResources(resources)
  var seen: seq[RRCrtc]
  for i in 0 ..< resources.noutput.int:
    let
      output = resources.outputs[i]
      info = XRRGetOutputInfo(d, resources, output)
    if info.isNil:
      continue
    try:
      if info.connection != RR_Connected or info.crtc == 0:
        continue
      if info.crtc in seen:
        continue
      seen.add info.crtc
      let crtc = XRRGetCrtcInfo(d, resources, info.crtc)
      if crtc.isNil:
        continue
      try:
        if crtc.width <= 0 or crtc.height <= 0:
          continue
        var refresh = 0
        if crtc.mode != 0:
          for j in 0 ..< resources.nmode.int:
            let mode = resources.modes[j]
            if mode.id == crtc.mode:
              let pixels = int64(mode.htotal) * int64(mode.vtotal)
              if pixels > 0:
                refresh = int(float64(mode.dotClock) / float64(pixels) + 0.5)
              break
        result.add RawMonitor(
          name: if info.name.isNil: "" else: $info.name,
          x: crtc.x.int,
          y: crtc.y.int,
          width: crtc.width.int,
          height: crtc.height.int,
          refresh: refresh
        )
      finally:
        XRRFreeCrtcInfo(crtc)
    finally:
      XRRFreeOutputInfo(info)
  if result.len == 0:
    result.add RawMonitor(
      name: "",
      x: 0,
      y: 0,
      width: XDisplayWidth(d, screen).int,
      height: XDisplayHeight(d, screen).int,
      refresh: 0
    )
