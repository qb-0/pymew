import std/[os, strutils, algorithm]
import winim/lean
import winim/inc/tlhelp32
import winim/inc/wingdi
import common

proc osFailure(op: string, code: int = GetLastError().int): ref OsFailure =
  var msg = ""
  try:
    msg = osErrorMsg(OSErrorCode(code))
  except CatchableError:
    discard
  if msg.len == 0:
    msg = "Windows error " & $code
  result = newException(OsFailure, op & " failed: " & msg)
  result.code = code
  result.denied = code == ERROR_ACCESS_DENIED.int or code == ERROR_PRIVILEGE_NOT_HELD.int

proc permissionHint*(): string =
  "permission denied: the target process may be elevated or protected; " &
  "run pymew from an elevated (administrator) process or disable the " &
  "protection of the target"

proc wcharz(p: pointer): string =
  $cast[WideCString](p)

proc processExists*(pid: int): bool =
  if pid <= 0:
    return false
  let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, DWORD(pid))
  if h != 0:
    discard CloseHandle(h)
    return true
  result = GetLastError() == ERROR_ACCESS_DENIED

proc openProcessHandle*(pid: int): OsHandle =
  let
    access = DWORD(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ or PROCESS_VM_WRITE or PROCESS_VM_OPERATION)
    h = OpenProcess(access, FALSE, DWORD(pid))
  if h == 0:
    raise osFailure("open process " & $pid)
  result = cast[int](h)

proc closeProcessHandle*(h: OsHandle) =
  if h != 0:
    discard CloseHandle(cast[HANDLE](h))

proc readMemory*(h: OsHandle, address: uint, dst: pointer, size: int): int =
  if size == 0:
    return 0
  var n: SIZE_T
  if ReadProcessMemory(cast[HANDLE](h), cast[LPCVOID](address), dst, SIZE_T(size), addr n) == 0:
    raise osFailure("read at 0x" & toHex(address))
  result = int(n)

proc writeMemory*(h: OsHandle, address: uint, src: pointer, size: int): int =
  if size == 0:
    return 0
  var n: SIZE_T
  if WriteProcessMemory(cast[HANDLE](h), cast[LPVOID](address), src, SIZE_T(size), addr n) == 0:
    raise osFailure("write at 0x" & toHex(address))
  result = int(n)

proc processNameByPid*(pid: int): string =
  let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
  if snap == INVALID_HANDLE_VALUE:
    raise osFailure("snapshot processes")
  defer: discard CloseHandle(snap)
  var pe: PROCESSENTRY32W
  pe.dwSize = DWORD(sizeof(pe))
  var ok = Process32FirstW(snap, addr pe)
  while ok != 0:
    if int(pe.th32ProcessID) == pid:
      return wcharz(addr pe.szExeFile[0])
    ok = Process32NextW(snap, addr pe)
  raise osFailure("find process " & $pid, ERROR_NOT_FOUND.int)

proc enumProcesses*(): seq[RawProcess] =
  let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
  if snap == INVALID_HANDLE_VALUE:
    raise osFailure("snapshot processes")
  defer: discard CloseHandle(snap)
  var pe: PROCESSENTRY32W
  pe.dwSize = DWORD(sizeof(pe))
  var ok = Process32FirstW(snap, addr pe)
  while ok != 0:
    result.add RawProcess(pid: int(pe.th32ProcessID), name: wcharz(addr pe.szExeFile[0]))
    ok = Process32NextW(snap, addr pe)

proc processPath*(pid: int): string =
  let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, DWORD(pid))
  if h == 0:
    raise osFailure("open process " & $pid)
  defer: discard CloseHandle(h)
  var buf: array[32768, WCHAR]
  var size = DWORD(buf.len)
  if QueryFullProcessImageNameW(h, 0, cast[LPWSTR](addr buf[0]), addr size) == 0:
    raise osFailure("query path of process " & $pid)
  result = wcharz(addr buf[0])

proc processIs64Bit*(pid: int): bool =
  let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, DWORD(pid))
  if h == 0:
    raise osFailure("open process " & $pid)
  defer: discard CloseHandle(h)
  var wow: WINBOOL
  if IsWow64Process(h, addr wow) == 0:
    raise osFailure("query bitness of process " & $pid)
  result = wow == 0

proc enumModules*(pid: int): seq[RawModule] =
  let snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE or TH32CS_SNAPMODULE32, DWORD(pid))
  if snap == INVALID_HANDLE_VALUE:
    raise osFailure("snapshot modules of process " & $pid)
  defer: discard CloseHandle(snap)
  var me: MODULEENTRY32W
  me.dwSize = DWORD(sizeof(me))
  var ok = Module32FirstW(snap, addr me)
  while ok != 0:
    let
      base = cast[uint](me.modBaseAddr)
      size = uint(me.modBaseSize)
    result.add RawModule(
      name: wcharz(addr me.szModule[0]),
      path: wcharz(addr me.szExePath[0]),
      base: base,
      `end`: base + size,
      size: size
    )
    ok = Module32NextW(snap, addr me)
  result.sort(proc(a, b: RawModule): int = cmp(a.base, b.base))

proc protectionOf(protect, kind: DWORD): string =
  let p = int(protect) and 0xFF
  if p == PAGE_NOACCESS:
    result = "---"
  elif p == PAGE_READONLY:
    result = "r--"
  elif p in [PAGE_READWRITE, PAGE_WRITECOPY]:
    result = "rw-"
  elif p == PAGE_EXECUTE:
    result = "--x"
  elif p == PAGE_EXECUTE_READ:
    result = "r-x"
  elif p in [PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_WRITECOPY]:
    result = "rwx"
  else:
    result = "---"
  if kind == MEM_PRIVATE:
    result.add 'p'

proc enumRegions*(pid: int): seq[RawRegion] =
  let h = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, DWORD(pid))
  if h == 0:
    raise osFailure("open process " & $pid)
  defer: discard CloseHandle(h)
  var address: uint = 0
  var mbi: MEMORY_BASIC_INFORMATION
  while VirtualQueryEx(h, cast[LPCVOID](address), addr mbi, SIZE_T(sizeof(mbi))) == SIZE_T(sizeof(mbi)):
    let
      base = cast[uint](mbi.BaseAddress)
      size = uint(mbi.RegionSize)
    if size == 0 or base + size <= address:
      break
    if mbi.State == MEM_COMMIT:
      result.add RawRegion(start: base, `end`: base + size, size: size, protection: protectionOf(mbi.Protect, mbi.Type))
    address = base + size

proc processNames*(pid: int): seq[string] =
  var seen: seq[string]
  var names: seq[string]
  try: names.add processNameByPid(pid) except OsFailure: discard
  try: names.add extractFilename(processPath(pid)) except OsFailure: discard
  for n in names:
    if n.len > 0:
      let lower = n.toLowerAscii()
      if lower notin seen:
        seen.add lower
  result = seen

type
  WindowEnumCtx = object
    items: seq[RawWindow]

proc windowTitle(hwnd: HWND): string =
  let length = GetWindowTextLengthW(hwnd)
  if length <= 0:
    return ""
  var buffer = newSeq[WCHAR](length + 1)
  let got = GetWindowTextW(hwnd, cast[LPWSTR](addr buffer[0]), length + 1)
  if got <= 0:
    return ""
  wcharz(addr buffer[0])

proc collectWindow(hwnd: HWND, lparam: LPARAM): WINBOOL {.stdcall.} =
  let ctx = cast[ptr WindowEnumCtx](lparam)
  var pid: DWORD
  discard GetWindowThreadProcessId(hwnd, addr pid)
  if pid == 0:
    return TRUE
  var name = ""
  try:
    name = processNameByPid(int(pid))
  except OsFailure:
    discard
  if name.len == 0:
    return TRUE
  var rect: RECT
  if GetClientRect(hwnd, addr rect) == 0:
    return TRUE
  var origin: POINT
  origin.x = 0
  origin.y = 0
  if ClientToScreen(hwnd, addr origin) == 0:
    return TRUE
  ctx.items.add RawWindow(
    id: int(hwnd),
    pid: int(pid),
    name: name,
    title: windowTitle(hwnd),
    x: int(origin.x),
    y: int(origin.y),
    width: int(rect.right - rect.left),
    height: int(rect.bottom - rect.top),
    visible: IsWindowVisible(hwnd) != 0
  )
  TRUE

proc windowList*(): seq[RawWindow] =
  var ctx: WindowEnumCtx
  discard EnumWindows(collectWindow, cast[LPARAM](addr ctx))
  result = ctx.items

proc findWindow*(pid: int): RawWindow =
  let
    windows = windowList()
    index = pickWindow(windows, pid)
  if index < 0:
    raise newException(OsFailure, "no window found for process " & $pid)
  result = windows[index]

proc windowGeometry*(id: int): RawWindow =
  let hwnd = cast[HWND](id)
  if IsWindow(hwnd) == 0:
    raise newException(OsFailure, "window " & $id & " no longer exists")
  var rect: RECT
  if GetClientRect(hwnd, addr rect) == 0:
    raise newException(OsFailure, "window " & $id & " no longer exists")
  var origin: POINT
  origin.x = 0
  origin.y = 0
  if ClientToScreen(hwnd, addr origin) == 0:
    raise newException(OsFailure, "window " & $id & " no longer exists")
  RawWindow(
    id: id,
    x: int(origin.x),
    y: int(origin.y),
    width: int(rect.right - rect.left),
    height: int(rect.bottom - rect.top),
    visible: IsWindowVisible(hwnd) != 0
  )

proc screenSize*(): tuple[width, height: int] =
  (
    GetSystemMetrics(SM_CXVIRTUALSCREEN).int,
    GetSystemMetrics(SM_CYVIRTUALSCREEN).int
  )

proc collectMonitor(
  monitor: HMONITOR,
  hdc: HDC,
  rect: LPRECT,
  data: LPARAM
): WINBOOL {.stdcall.} =
  let items = cast[ptr seq[RawMonitor]](data)
  var info: MONITORINFOEXW
  info.struct1.cbSize = DWORD(sizeof(MONITORINFOEXW))
  if GetMonitorInfoW(monitor, cast[LPMONITORINFO](addr info)) == 0:
    return TRUE
  var mode: DEVMODEW
  mode.dmSize = WORD(sizeof(DEVMODEW))
  var refresh = 0
  if EnumDisplaySettingsW(cast[LPCWSTR](addr info.szDevice[0]), ENUM_CURRENT_SETTINGS, addr mode) != 0:
    refresh = int(mode.dmDisplayFrequency)
  items[].add RawMonitor(
    name: wcharz(addr info.szDevice[0]),
    x: int(info.struct1.rcMonitor.left),
    y: int(info.struct1.rcMonitor.top),
    width: int(info.struct1.rcMonitor.right - info.struct1.rcMonitor.left),
    height: int(info.struct1.rcMonitor.bottom - info.struct1.rcMonitor.top),
    refresh: refresh
  )
  TRUE

proc monitorList*(): seq[RawMonitor] =
  var items: seq[RawMonitor]
  discard EnumDisplayMonitors(
    cast[HDC](0),
    cast[LPCRECT](nil),
    collectMonitor,
    cast[LPARAM](addr items)
  )
  result = items

proc systemFontDirs*(): seq[string] =
  var dirs: seq[string]
  for root in [getEnv("WINDIR"), getEnv("SystemRoot")]:
    if root.len > 0:
      dirs.add root / "Fonts"
  let localAppData = getEnv("LOCALAPPDATA")
  if localAppData.len > 0:
    dirs.add localAppData / "Microsoft" / "Windows" / "Fonts"
  var seen: seq[string]
  for dir in dirs:
    let key = dir.toLowerAscii()
    if key notin seen:
      seen.add key
      result.add dir
