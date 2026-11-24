import std/[strutils, sequtils, algorithm, os, dynlib, times]
from std/unicode import runes
import nimpy
import nimpy/[py_types, py_utils, py_lib as pyl]

import pyutil, errors, mem_types, vec
import platform/api

pyExportModule("pymew")

type
  Process* = ref object of PyNimObjectExperimental
    pid*: int
    debugFlag*: bool
    handle*: OsHandle
    closed*: bool
    is64Known*: bool
    is64Cache*: bool
    nameCache*: string
    baseCache*: uint
    baseKnown*: bool
    modulesCache*: seq[RawModule]
    modulesKnown*: bool
    regionsCache*: seq[RawRegion]
    regionsKnown*: bool

  PatternByte* = object
    value*: byte
    mask*: byte

var
  typeClass*: PyObject
  valueClass*: PyObject
  fieldClass: PyObject
  structClass*: PyObject
  moduleClass*: PyObject
  regionClass*: PyObject
  entryClass*: PyObject

  descI8*: PyObject
  descI16*: PyObject
  descI32*: PyObject
  descI64*: PyObject
  descU8*: PyObject
  descU16*: PyObject
  descU32*: PyObject
  descU64*: PyObject
  descF32*: PyObject
  descF64*: PyObject
  descBool*: PyObject
  descPtr*: PyObject
  descVec2*: PyObject
  descVec3*: PyObject

  typesReady* = false

proc `$`*(self: Process): string =
  "Process(pid=" & $self.pid & ")"

proc sizeOfDesc*(o: PyObject): int
proc usesPointers(o: PyObject): bool
proc sizeForRead(o: PyObject, ptrSize: int): int
proc readBuf*(self: Process, address: uint64, size: int): seq[byte]
proc defaultFor*(ftype: PyObject): PPyObject
proc normalizeProcName*(s: string): string

proc codeOf*(o: PyObject): int =
  let c = tryGetAttr(o, "_code")
  if c.isNil:
    return -1
  result = c.to(int)

proc isValueObj*(o: PyObject): bool =
  hasAttr(o, "_is_value")

proc fieldList(cls: PyObject): PyObject =
  result = getAttr(cls, "_fields")

iterator fields(cls: PyObject): tuple[name: PPyObject, ftype: PyObject, off, code: int] =
  for raw in rawItems(rawPy(fieldList(cls))):
    let t = cast[PPyObject](raw)
    yield (
      pyl.pyLib.PyTuple_GetItem(t, 0),
      asPy(pyl.pyLib.PyTuple_GetItem(t, 1)),
      int(pyl.pyLib.PyLong_AsLongLong(pyl.pyLib.PyTuple_GetItem(t, 2))),
      int(pyl.pyLib.PyLong_AsLongLong(pyl.pyLib.PyTuple_GetItem(t, 4)))
    )

proc fieldValue(d: PyObject, inst: PyObject, name: PPyObject): PyObject =
  let v = pyl.pyLib.PyDict_GetItem(rawPy(d), name)
  if not v.isNil:
    return asPy(v)
  let raw = pyl.pyLib.PyObject_GetAttrString(rawPy(inst), cstring(asPy(name).to(string)))
  if raw.isNil:
    raisePythonError()
  result = asPy(raw)
  decRef raw

proc structName(cls: PyObject): string =
  let n = tryGetAttr(cls, "__name__")
  if n.isNil: "struct" else: n.to(string)

proc pyRepr(o: PyObject): string =
  callObject(getAttr(pyBuiltinsModule(), "repr"), o).to(string)

proc clip(s: string, limit: int): string =
  if s.len <= limit:
    return s
  var cut = limit - 3
  while cut > 0 and (byte(s[cut]) and 0xC0'u8) == 0x80'u8:
    dec cut
  s[0 ..< cut] & "..."

proc typeLabel(desc: PyObject): string =
  let code = codeOf(desc)
  if code < 0 or code == ord(tcStruct):
    if pyIsType(desc):
      return structName(desc)
    return structName(getAttr(desc, "__class__"))
  let tc = TypeCode(code)
  case tc
  of tcString:
    "string(" & $getAttr(desc, "_size").to(int) & ")"
  of tcWString:
    "wstring(" & $(getAttr(desc, "_size").to(int) div 2) & ")"
  of tcBytes:
    "bytes(" & $getAttr(desc, "_size").to(int) & ")"
  of tcFString:
    "fstring(" & $getAttr(desc, "_char_size").to(int) & ")"
  of tcArray:
    "array(" & typeLabel(getAttr(desc, "_elem")) & ", " & $getAttr(desc, "_count").to(int) & ")"
  else:
    getAttr(desc, "_name").to(string)

proc valueRepr(v: PyObject): string =
  if codeOf(v) >= 0:
    let inner = tryGetAttr(v, "value")
    if not inner.isNil:
      return pyRepr(inner)
  pyRepr(v)

proc logAccess(op: string, address: uint64, label, data: string) =
  stderr.writeLine("[" & now().format("yyyy-MM-dd HH:mm:ss'.'fff") & "] [" & op & "] [" & label &
    "] 0x" & toHex(address, 16) & " = " & clip(data, 120))

proc isFieldMarker(o: PyObject): bool =
  not fieldClass.isNil and getAttr(o, "__class__") == fieldClass

proc makeField(ftype, offset: PyObject): PyObject =
  result = objectNew(fieldClass)
  setAttr(result, "ftype", ftype)
  setAttr(result, "offset", offset)

proc fieldReprImpl(self: PyObject): string =
  let t = getAttr(self, "ftype")
  var n = tryGetAttr(t, "_name")
  if n.isNil:
    n = tryGetAttr(t, "__name__")
  var h = toHex(getAttr(self, "offset").to(int)).strip(leading = true,
    trailing = false, chars = {'0'})
  if h.len == 0:
    h = "0"
  "<field " & (if n.isNil: "?" else: n.to(string)) & " at 0x" & h & ">"

proc typeAtImpl(self, offset: PyObject): PyObject =
  makeField(self, offset)

proc structAtImpl(cls, offset: PyObject): PyObject =
  makeField(cls, offset)

proc ensureStructInfo*(cls: PyObject) =
  if codeOf(cls) == ord(tcStruct) and hasAttr(cls, "_size"):
    return
  let classDict = getAttr(cls, "__dict__")
  var fields: seq[PyObject]
  var maxEnd = 0
  var maxEnd32 = 0
  var hasPtr = false
  for rawKey in rawItems(rawPy(classDict)):
    let
      key = asPy(rawKey).to(string)
      v = tryGetAttr(cls, key)
    if v.isNil or not isFieldMarker(v):
      continue
    let
      ftype = getAttr(v, "ftype")
      rawOff = getAttr(v, "offset")
    if not pyIsInstance(rawOff, "int") or pyIsInstance(rawOff, "bool"):
      raise newException(PmBadType, "field '" & key & "' offset must be an int")
    let off = rawOff.to(int)
    if off < 0:
      raise newException(PmValueError, "field '" & key & "' offset must not be negative")
    let
      fsz = sizeOfDesc(ftype)
      fptr = usesPointers(ftype)
      fsz32 = sizeForRead(ftype, 4)
      entry = newPyTuple([
        takePy(nimValueToPy(key)),
        ftype,
        takePy(nimValueToPy(off)),
        takePy(nimValueToPy(off + fsz)),
        takePy(nimValueToPy(codeOf(ftype)))
      ])
    fields.add entry
    maxEnd = max(maxEnd, off + fsz)
    maxEnd32 = max(maxEnd32, off + fsz32)
    hasPtr = hasPtr or fptr
  if fields.len == 0:
    raise newException(PmBadType, structName(cls) & " has no fields; declare them with pm.mem.i32.at(offset)")
  setPyAttrInt(cls, "_code", ord(tcStruct))
  setPyAttrInt(cls, "_size", maxEnd)
  setPyAttrInt(cls, "_size32", maxEnd32)
  setPyAttr(cls, "_has_ptr", nimValueToPy(hasPtr))
  setAttr(cls, "_fields", newPyListOf(fields))

proc isStructClass(o: PyObject): bool =
  if not pyIsType(o):
    return false
  let c = codeOf(o)
  c == ord(tcStruct) or c < 0

proc fieldOffset(cls: PyObject, path: string): int =
  var parts = path.split('.')
  if parts.len == 0 or parts.anyIt(it.len == 0):
    raise newException(PmValueError, "field path must not be empty")
  var cur = cls
  for i in 0 ..< parts.len:
    ensureStructInfo(cur)
    var ftype: PyObject
    var found = false
    for f in fields(cur):
      if asPy(f.name).to(string) == parts[i]:
        result += f.off
        ftype = f.ftype
        found = true
        break
    if not found:
      raise newException(PmValueError, "unknown struct field '" & parts[i] & "' in " & structName(cur))
    if i < parts.high:
      if not isStructClass(ftype):
        raise newException(PmValueError, "field '" & parts[i] & "' is not a struct")
      cur = ftype

proc structAddressImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let
      inst = argAt(args, 0)
      base = tryGetAttr(inst, "_address")
    if base.isNil:
      raise newException(PmValueError, "struct instance has no address; it was not read from memory")
    var address = base.to(uint64)
    var path = argAt(args, 1)
    if path.isNil:
      path = kwArg(kwargs, "path")
    if not path.isNil:
      if not pyIsInstance(path, "str"):
        raise newException(PmBadType, "field path must be a string")
      address += uint64(fieldOffset(getAttr(inst, "__class__"), path.to(string)))
    nimValueToPy(address)

proc structOffsetImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let cls = argAt(args, 0)
    var path = argAt(args, 1)
    if path.isNil:
      path = kwArg(kwargs, "path")
    if path.isNil:
      raise newException(PmBadType, "offset() requires a field path")
    if not pyIsInstance(path, "str"):
      raise newException(PmBadType, "field path must be a string")
    nimValueToPy(fieldOffset(cls, path.to(string)))

proc structSizeImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let cls = argAt(args, 0)
    ensureStructInfo(cls)
    nimValueToPy(getAttr(cls, "_size").to(int))

proc sizeOfDesc*(o: PyObject): int =
  let code = codeOf(o)
  if code < 0:
    ensureStructInfo(o)
    return getAttr(o, "_size").to(int)
  let tc = TypeCode(code)
  if tc in {tcString, tcWString, tcBytes, tcFString, tcArray}:
    result = getAttr(o, "_size").to(int)
  elif tc == tcStruct:
    ensureStructInfo(o)
    result = getAttr(o, "_size").to(int)
  else:
    result = ScalarSizes[tc]

proc usesPointers(o: PyObject): bool =
  let code = codeOf(o)
  if code in {ord(tcPtr), ord(tcFString)}:
    return true
  if code == ord(tcArray):
    let cached = tryGetAttr(o, "_has_ptr")
    if not cached.isNil:
      return cached.to(bool)
    return usesPointers(getAttr(o, "_elem"))
  if code < 0 or code == ord(tcStruct):
    let cached = tryGetAttr(o, "_has_ptr")
    if not cached.isNil:
      return cached.to(bool)
    ensureStructInfo(o)
    let known = tryGetAttr(o, "_has_ptr")
    if not known.isNil:
      return known.to(bool)
    return false
  false

proc arrayStride(desc: PyObject, elemSize: int): int =
  let explicit = tryGetAttr(desc, "_stride_explicit")
  if explicit.isNil or not explicit.to(bool):
    return elemSize
  getAttr(desc, "_stride").to(int)

proc sizeForRead(o: PyObject, ptrSize: int): int =
  let code = codeOf(o)
  if code < 0 or code == ord(tcStruct):
    ensureStructInfo(o)
    if ptrSize == 8:
      return getAttr(o, "_size").to(int)
    let cached = tryGetAttr(o, "_size32")
    if not cached.isNil:
      return cached.to(int)
    var maxEnd = 0
    for (_, ftype, off, _) in fields(o):
      maxEnd = max(maxEnd, off + sizeForRead(ftype, ptrSize))
    return maxEnd
  let tc = TypeCode(code)
  case tc
  of tcPtr:
    result = ptrSize
  of tcArray:
    if ptrSize == 8 or not usesPointers(o):
      return sizeOfDesc(o)
    let
      elem = getAttr(o, "_elem")
      count = getAttr(o, "_count").to(int)
      elemSize = sizeForRead(elem, ptrSize)
      stride = arrayStride(o, elemSize)
    result = stride * (count - 1) + elemSize
  of tcFString:
    result = ptrSize + 8
  of tcString, tcWString, tcBytes:
    result = getAttr(o, "_size").to(int)
  else:
    result = sizeOfDesc(o)

proc rd[T](buf: seq[byte], off: int): T =
  copyMem(addr result, unsafeAddr buf[off], sizeof(T))

proc decodeScalar(code: TypeCode, buf: seq[byte], off: int, ptrSize: int = 8): PPyObject =
  case code
  of tcI8: result = nimValueToPy(rd[int8](buf, off))
  of tcI16: result = nimValueToPy(rd[int16](buf, off))
  of tcI32: result = nimValueToPy(rd[int32](buf, off))
  of tcI64: result = nimValueToPy(rd[int64](buf, off))
  of tcU8: result = nimValueToPy(rd[uint8](buf, off))
  of tcU16: result = nimValueToPy(rd[uint16](buf, off))
  of tcU32: result = nimValueToPy(rd[uint32](buf, off))
  of tcU64: result = nimValueToPy(rd[uint64](buf, off))
  of tcF32: result = nimValueToPy(float(rd[float32](buf, off)))
  of tcF64: result = nimValueToPy(rd[float64](buf, off))
  of tcBool: result = nimValueToPy(buf[off] != 0)
  of tcPtr:
    if ptrSize == 4:
      result = nimValueToPy(rd[uint32](buf, off))
    else:
      result = nimValueToPy(rd[uint64](buf, off))
  else:
    discard

proc decodeAt*(
  ftype: PyObject,
  buf: seq[byte],
  off: int,
  address: uint64 = 0,
  addressKnown = false,
  ptrSize: int = 8,
  p: Process = nil
): PPyObject
proc decodeAtCode*(
  code: int,
  ftype: PyObject,
  buf: seq[byte],
  off: int,
  address: uint64 = 0,
  addressKnown = false,
  ptrSize: int = 8,
  p: Process = nil
): PPyObject
proc decodeValue(code: TypeCode, buf: seq[byte], off: int): PPyObject

proc decodeUtf8(buf: seq[byte], off, n: int): PPyObject =
  if n == 0:
    return pyl.pyLib.PyUnicode_FromString("")
  result = pyl.pyLib.Py_BuildValue("s#", cast[cstring](unsafeAddr buf[off]), cint(n))

type
  DecodeWideFn = proc(s: cstring, size: Py_ssize_t, errors: cstring, byteorder: ptr cint): PPyObject {.cdecl.}

var
  decodeUtf16Fn: DecodeWideFn
  decodeUtf32Fn: DecodeWideFn

proc decodeWideFn(charSize: int): DecodeWideFn =
  var slot = if charSize == 4: addr decodeUtf32Fn else: addr decodeUtf16Fn
  if slot[].isNil:
    let name = if charSize == 4: "PyUnicode_DecodeUTF32" else: "PyUnicode_DecodeUTF16"
    slot[] = cast[DecodeWideFn](symAddr(pyl.pyLib.module, cstring(name)))
    if slot[].isNil:
      raise newException(PmUnsupported, name & " is not available")
  slot[]

proc decodeWide(buf: seq[byte], off, nBytes, charSize: int): PPyObject =
  if nBytes <= 0:
    return pyl.pyLib.PyUnicode_FromString("")
  var order: cint = -1
  let fn = decodeWideFn(charSize)
  result = fn(cast[cstring](unsafeAddr buf[off]), Py_ssize_t(nBytes), "strict", addr order)

proc utf16Units(s: string): seq[uint16] =
  for r in s.runes:
    let cp = uint32(r)
    if cp <= 0xFFFF:
      result.add uint16(cp)
    else:
      let v = cp - 0x10000
      result.add uint16(0xD800'u32 or (v shr 10))
      result.add uint16(0xDC00'u32 or (v and 0x3FF))

proc utf32Units(s: string): seq[uint32] =
  for r in s.runes:
    result.add uint32(r)

proc fixedWide(s: string, size, charSize: int): seq[byte] =
  result = newSeq[byte](size)
  var units: seq[uint32]
  if charSize == 4:
    units = utf32Units(s)
  else:
    for u in utf16Units(s):
      units.add uint32(u)
  let capacity = size div charSize
  var n = min(units.len, max(capacity - 1, 0))
  if charSize == 2 and n > 0 and n < units.len and units[n - 1] >= 0xD800'u32 and units[n - 1] <= 0xDBFF'u32:
    dec n
  for i in 0 ..< n:
    for b in 0 ..< charSize:
      result[i * charSize + b] = byte((units[i] shr (8 * b)) and 0xFF)

proc trailingZeroUnits(buf: seq[byte], charSize: int): int =
  result = buf.len div charSize
  while result > 0:
    var empty = true
    for i in 0 ..< charSize:
      if buf[(result - 1) * charSize + i] != 0:
        empty = false
    if not empty:
      break
    dec result

proc decodeStruct*(
  cls: PyObject,
  buf: seq[byte],
  baseOff: int,
  address: uint64 = 0,
  addressKnown = false,
  ptrSize: int = 8,
  p: Process = nil
): PyObject =
  ensureStructInfo(cls)
  result = objectNew(cls)
  let d = rawPy(objDict(result))
  dictSet(d, isValueKey(), pyTrue())
  if addressKnown:
    dictSetOwned(d, addressKey(), nimValueToPy(address + uint64(baseOff)))
  for (name, ftype, off, code) in fields(cls):
    let v = decodeAtCode(code, ftype, buf, baseOff + off, address, addressKnown, ptrSize, p)
    if v.isNil:
      return nil
    dictSetOwned(d, name, v)

proc decodeArray*(
  desc: PyObject,
  buf: seq[byte],
  baseOff: int,
  address: uint64 = 0,
  addressKnown = false,
  ptrSize: int = 8,
  p: Process = nil
): PPyObject =
  let
    elem = getAttr(desc, "_elem")
    count = getAttr(desc, "_count").to(int)
    elemSize = sizeForRead(elem, ptrSize)
    stride = arrayStride(desc, elemSize)
  var items: seq[PPyObject]
  for i in 0 ..< count:
    let v = decodeAt(elem, buf, baseOff + i * stride, address, addressKnown, ptrSize, p)
    if v.isNil:
      for item in items:
        decRef item
      return nil
    items.add v
  result = nimValueToPy(newPyListTaking(items))

proc decodeAtCode*(
  code: int,
  ftype: PyObject,
  buf: seq[byte],
  off: int,
  address: uint64 = 0,
  addressKnown = false,
  ptrSize: int = 8,
  p: Process = nil
): PPyObject =
  if code < 0:
    let s = decodeStruct(ftype, buf, off, address, addressKnown, ptrSize, p)
    if s.isNil:
      return nil
    result = nimValueToPy(s)
    return
  let tc = TypeCode(code)
  case tc
  of tcStruct:
    let s = decodeStruct(ftype, buf, off, address, addressKnown, ptrSize, p)
    if s.isNil:
      return nil
    result = nimValueToPy(s)
  of tcArray:
    result = decodeArray(ftype, buf, off, address, addressKnown, ptrSize, p)
  of tcString:
    let size = getAttr(ftype, "_size").to(int)
    var n = 0
    while n < size and buf[off + n] != 0:
      inc n
    result = decodeUtf8(buf, off, n)
  of tcWString:
    let size = getAttr(ftype, "_size").to(int)
    var n = 0
    while n + 1 < size and (buf[off + n] != 0 or buf[off + n + 1] != 0):
      n += 2
    result = decodeWide(buf, off, n, 2)
  of tcBytes:
    let size = getAttr(ftype, "_size").to(int)
    result = pyl.pyLib.PyBytes_FromStringAndSize(if size > 0: cast[ptr char](unsafeAddr buf[off]) else: nil, size)
  of tcFString:
    if p.isNil:
      raise newException(PmBadType, "fstring is only available through a process")
    let charSize = getAttr(ftype, "_char_size").to(int)
    var dataPtr: uint64
    if ptrSize == 4:
      dataPtr = uint64(rd[uint32](buf, off))
    else:
      dataPtr = rd[uint64](buf, off)
    let count = int(rd[int32](buf, off + ptrSize))
    if dataPtr == 0 or count <= 0:
      return pyl.pyLib.PyUnicode_FromString("")
    if count > 1 shl 20:
      raise newException(PmValueError, "implausible FString length " & $count)
    let
      raw = p.readBuf(dataPtr, count * charSize)
      units = trailingZeroUnits(raw, charSize)
    result = decodeWide(raw, 0, units * charSize, charSize)
  of tcVec2, tcVec3:
    result = decodeValue(tc, buf, off)
  else:
    result = decodeScalar(tc, buf, off, ptrSize)

proc decodeAt*(
  ftype: PyObject,
  buf: seq[byte],
  off: int,
  address: uint64 = 0,
  addressKnown = false,
  ptrSize: int = 8,
  p: Process = nil
): PPyObject =
  decodeAtCode(codeOf(ftype), ftype, buf, off, address, addressKnown, ptrSize, p)

proc decodeValue(code: TypeCode, buf: seq[byte], off: int): PPyObject =
  if code == tcVec2:
    var x, y: float32
    copyMem(addr x, unsafeAddr buf[off], 4)
    copyMem(addr y, unsafeAddr buf[off + 4], 4)
    return nimValueToPy(newVec2(float(x), float(y)))
  if code == tcVec3:
    var x, y, z: float32
    copyMem(addr x, unsafeAddr buf[off], 4)
    copyMem(addr y, unsafeAddr buf[off + 4], 4)
    copyMem(addr z, unsafeAddr buf[off + 8], 4)
    return nimValueToPy(newVec3(float(x), float(y), float(z)))
  decodeScalar(code, buf, off)

proc makeDesc(tc: TypeCode, size: int, name: string): PyObject =
  result = callObject(typeClass)
  setPyAttrInt(result, "_code", ord(tc))
  setPyAttrInt(result, "_size", size)
  setPyAttrStr(result, "_name", name)

proc typeCallImpl(self, value: PyObject): PyObject =
  result = callObject(valueClass)
  setAttr(result, "_code", getAttr(self, "_code"))
  setPyAttrInt(result, "_size", sizeOfDesc(self))
  setAttr(result, "_name", getAttr(self, "_name"))
  setAttr(result, "value", value)
  setAttr(result, "_is_value", takePy(nimValueToPy(true)))
  for name in ["_elem", "_count", "_stride", "_stride_explicit", "_has_ptr", "_char_size"]:
    let v = tryGetAttr(self, name)
    if not v.isNil:
      setAttr(result, name.cstring, v)

proc typeReprImpl(self: PyObject): string =
  let n = tryGetAttr(self, "_name")
  if n.isNil:
    return "<memory type>"
  result = "<memory type " & n.to(string) & ">"

proc valueReprImpl(self: PyObject): string =
  let
    n = getAttr(self, "_name").to(string)
    v = getAttr(self, "value")
  result = n & "(" & $v & ")"

proc buildTypeClasses() =
  var d = pyDict()
  bindMethod(d, "__call__", proc(a, b: PyObject): PyObject = typeCallImpl(a, b))
  bindMethod(d, "at", proc(a, b: PyObject): PyObject = typeAtImpl(a, b))
  bindMethod(d, "__repr__", proc(a: PyObject): string = typeReprImpl(a))
  typeClass = newClass("_Type", getAttr(pyBuiltinsModule(), "object"), d)

  d = pyDict()
  bindMethod(d, "__repr__", proc(a: PyObject): string = valueReprImpl(a))
  valueClass = newClass("_Value", getAttr(pyBuiltinsModule(), "object"), d)

  d = pyDict()
  bindMethod(d, "__repr__", proc(a: PyObject): string = fieldReprImpl(a))
  fieldClass = newClass("_Field", getAttr(pyBuiltinsModule(), "object"), d)

proc structNewImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  try:
    let cls = asPy(cast[PPyObject](pyl.pyLib.PyTuple_GetItem(args, 0)))
    if int(pyl.pyLib.PyTuple_Size(args)) > 1:
      setTypeError("Struct instances take keyword arguments only")
      return nil
    ensureStructInfo(cls)
    let inst = objectNew(cls)
    setAttr(inst, "_is_value", takePy(nimValueToPy(true)))
    var known: seq[string]
    for f in fields(cls):
      let name = asPy(f.name).to(string)
      known.add name
      var provided = false
      if not kwargs.isNil:
        let item = pyl.pyLib.PyDict_GetItemString(kwargs, cstring(name))
        if not item.isNil:
          incRef item
          setPyAttr(inst, name, item)
          provided = true
      if not provided:
        setPyAttr(inst, name, defaultFor(f.ftype))
    if not kwargs.isNil:
      for raw in rawItems(pyl.pyLib.PyDict_Keys(kwargs)):
        let key = asPy(raw).to(string)
        if key notin known:
          setTypeError("unknown struct field '" & key & "'")
          return nil
    result = rawPy(inst)
    incRef result
  except CatchableError as e:
    setPyErr(errorClass, e.msg)
    result = nil

proc structReprImpl(self: PyObject): string =
  let cls = getAttr(self, "__class__")
  ensureStructInfo(cls)
  var parts: seq[string]
  for f in fields(cls):
    let name = asPy(f.name).to(string)
    parts.add name & "=" & $getAttr(self, name.cstring)
  result = self.getAttr("__class__").getAttr("__name__").to(string) & "(" & parts.join(", ") & ")"

proc buildStructClass() =
  var d = pyDict()
  d["__new__"] = rawKwFunc("__new__", structNewImpl)
  d["__init__"] = rawKwFunc("__init__", initIgnore)
  d["at"] = makeTypeMethod(nimValueToPy((proc(a, b: PyObject): PyObject = structAtImpl(a, b))))
  bindKwMethod(d, "address", structAddressImpl)
  d["offset"] = makeTypeMethod(rawPy(rawKwFunc("offset", structOffsetImpl)))
  d["size"] = makeTypeMethod(rawPy(rawKwFunc("size", structSizeImpl)))
  bindMethod(d, "__repr__", proc(a: PyObject): string = structReprImpl(a))
  structClass = newClass("Struct", getAttr(pyBuiltinsModule(), "object"), d)

proc defaultFor(ftype: PyObject): PPyObject =
  let code = codeOf(ftype)
  if code < 0:
    return nimValueToPy(callObject(ftype))
  let tc = TypeCode(code)
  case tc
  of tcI8, tcI16, tcI32, tcI64, tcU8, tcU16, tcU32, tcU64, tcPtr:
    nimValueToPy(0)
  of tcF32, tcF64:
    nimValueToPy(0.0)
  of tcBool:
    nimValueToPy(false)
  of tcVec2:
    nimValueToPy(newVec2(0.0, 0.0))
  of tcVec3:
    nimValueToPy(newVec3(0.0, 0.0, 0.0))
  of tcString, tcWString, tcFString:
    nimValueToPy("")
  of tcBytes:
    nimValueToPy(newSeq[byte]())
  of tcArray:
    let
      elem = getAttr(ftype, "_elem")
      count = getAttr(ftype, "_count").to(int)
    var items: seq[PPyObject]
    for _ in 0 ..< count:
      items.add defaultFor(elem)
    nimValueToPy(newPyListTaking(items))
  of tcStruct:
    nimValueToPy(callObject(ftype))

proc recordReprImpl(self: PyObject): string =
  let cls = getAttr(self, "__class__")
  var parts: seq[string]
  for raw in rawItems(rawPy(getAttr(cls, "_fields"))):
    let
      name = asPy(raw).to(string)
      v = getAttr(self, name.cstring)
    parts.add(name & "=" & callObject(getAttr(pyBuiltinsModule(), "repr"), v).to(string))
  cls.getAttr("__name__").to(string) & "(" & parts.join(", ") & ")"

proc buildRecordClass*(name: string, fields: seq[string]): PyObject =
  var d = pyDict()
  bindMethod(d, "__repr__", proc(a: PyObject): string = recordReprImpl(a))
  result = newClass(name, getAttr(pyBuiltinsModule(), "object"), d)
  setPyAttr(result, "_fields", nimValueToPy(fields))

proc ensureTypes*() =
  if typesReady:
    return
  initErrorClasses()
  ensureVecClasses()
  buildTypeClasses()
  buildStructClass()
  moduleClass = buildRecordClass("Module", @["name", "base", "end", "size"])
  regionClass = buildRecordClass("Region", @["start", "end", "size", "protection"])
  entryClass = buildRecordClass("ProcessEntry", @["pid", "name"])
  descI8 = makeDesc(tcI8, 1, "i8")
  descI16 = makeDesc(tcI16, 2, "i16")
  descI32 = makeDesc(tcI32, 4, "i32")
  descI64 = makeDesc(tcI64, 8, "i64")
  descU8 = makeDesc(tcU8, 1, "u8")
  descU16 = makeDesc(tcU16, 2, "u16")
  descU32 = makeDesc(tcU32, 4, "u32")
  descU64 = makeDesc(tcU64, 8, "u64")
  descF32 = makeDesc(tcF32, 4, "f32")
  descF64 = makeDesc(tcF64, 8, "f64")
  descBool = makeDesc(tcBool, 1, "bool")
  descPtr = makeDesc(tcPtr, 8, "ptr")
  descVec2 = makeDesc(tcVec2, 8, "vec2")
  descVec3 = makeDesc(tcVec3, 12, "vec3")
  typesReady = true

proc osFail(op: string, e: ref OsFailure): ref PmAccessError =
  if e.denied:
    return newException(PmPermissionDenied, op & ": " & e.msg & "\n" & permissionHint())
  newException(PmAccessError, op & ": " & e.msg)

proc checkOpen*(self: Process) =
  if self.closed:
    raise newException(PmError, "process is closed")

proc imagePath(pid: int): string =
  try:
    processPath(pid)
  except OsFailure as e:
    raise osFail("resolve path of " & $pid, e)

proc imageName(pid: int): string =
  try:
    extractFilename(processPath(pid))
  except OsFailure:
    processNameByPid(pid)

proc pointerSize(self: Process): int =
  if not self.is64Known:
    try:
      self.is64Cache = processIs64Bit(self.pid)
    except OsFailure as e:
      raise osFail("determine bitness of " & $self.pid, e)
    self.is64Known = true
  result = if self.is64Cache: 8 else: 4

proc readBuf*(self: Process, address: uint64, size: int): seq[byte] =
  checkOpen(self)
  result = newSeq[byte](size)
  if size == 0:
    return
  var n = 0
  try:
    n = readMemory(self.handle, uint(address), addr result[0], size)
  except OsFailure as e:
    raise osFail("read at 0x" & toHex(address), e)
  if n != size:
    raise newException(PmAccessError, "read at 0x" & toHex(address) & " returned " & $n & " of " & $size & " bytes")

proc writeBuf*(self: Process, address: uint64, data: seq[byte]): int =
  checkOpen(self)
  if data.len == 0:
    return 0
  try:
    result = writeMemory(self.handle, uint(address), unsafeAddr data[0], data.len)
  except OsFailure as e:
    raise osFail("write at 0x" & toHex(address), e)
  if result != data.len:
    raise newException(
      PmAccessError,
      "write at 0x" & toHex(address) & " wrote " & $result & " of " & $data.len & " bytes"
    )

proc readPointer(self: Process, address: uint64): uint64 =
  if self.pointerSize() == 4:
    result = uint64(rd[uint32](self.readBuf(address, 4), 0))
  else:
    result = rd[uint64](self.readBuf(address, 8), 0)
  if self.debugFlag:
    logAccess("READ", address, "ptr", "0x" & toHex(result, 16))

proc put[T](buf: var seq[byte], off: int, v: T) =
  copyMem(addr buf[off], unsafeAddr v, sizeof(T))

proc vecComponent(value: PyObject, name: string, index: int): float =
  if hasAttr(value, name):
    return getAttr(value, name).to(float)
  asPy(cast[PPyObject](pyl.pyLib.PyTuple_GetItem(rawPy(value), index))).to(float)

proc encodeScalar(code: TypeCode, value: PyObject, buf: var seq[byte], off: int, ptrSize: int = 8) =
  case code
  of tcI8: put(buf, off, int8(value.to(int)))
  of tcI16: put(buf, off, int16(value.to(int)))
  of tcI32: put(buf, off, int32(value.to(int)))
  of tcI64: put(buf, off, int64(value.to(int)))
  of tcU8: put(buf, off, uint8(value.to(int)))
  of tcU16: put(buf, off, uint16(value.to(int)))
  of tcU32: put(buf, off, uint32(value.to(int)))
  of tcU64: put(buf, off, uint64(value.to(uint64)))
  of tcF32: put(buf, off, float32(value.to(float)))
  of tcF64: put(buf, off, float64(value.to(float)))
  of tcBool: buf[off] = if value.to(bool): 1'u8 else: 0'u8
  of tcPtr:
    if ptrSize == 4:
      put(buf, off, uint32(value.to(uint64)))
    else:
      put(buf, off, uint64(value.to(uint64)))
  of tcVec2:
    put(buf, off, float32(vecComponent(value, "x", 0)))
    put(buf, off + 4, float32(vecComponent(value, "y", 1)))
  of tcVec3:
    put(buf, off, float32(vecComponent(value, "x", 0)))
    put(buf, off + 4, float32(vecComponent(value, "y", 1)))
    put(buf, off + 8, float32(vecComponent(value, "z", 2)))
  of tcString:
    let
      size = getAttr(value, "_size").to(int)
      s = getAttr(value, "value").to(string)
    for i in 0 ..< size:
      buf[off + i] = if i < s.len: byte(s[i]) else: 0'u8
  of tcWString:
    let
      size = getAttr(value, "_size").to(int)
      bytes = fixedWide(getAttr(value, "value").to(string), size, 2)
    for i in 0 ..< size:
      buf[off + i] = bytes[i]
  of tcBytes:
    let
      size = getAttr(value, "_size").to(int)
      b = getAttr(value, "value").to(seq[byte])
    for i in 0 ..< size:
      buf[off + i] = if i < b.len: b[i] else: 0'u8
  else:
    discard

proc encodeAt*(ftype: PyObject, value: PyObject, buf: var seq[byte], off: int, ptrSize: int = 8, p: Process = nil)
proc encodeAtCode*(
  code: int,
  ftype: PyObject,
  value: PyObject,
  buf: var seq[byte],
  off: int,
  ptrSize: int = 8,
  p: Process = nil
)

proc encodeArray(
  elem: PyObject,
  count, stride: int,
  value: PyObject,
  buf: var seq[byte],
  off: int,
  ptrSize: int = 8,
  p: Process = nil
) =
  if not isSeq(value):
    raise newException(PmBadType, "array value must be a list or tuple")
  var i = 0
  for raw in rawItems(rawPy(value)):
    if i < count:
      encodeAt(elem, asPy(raw), buf, off + i * stride, ptrSize, p)
    inc i
  if i != count:
    raise newException(PmValueError, "array expects " & $count & " elements, got " & $i)

proc encodeStruct(inst: PyObject, buf: var seq[byte], baseOff: int, ptrSize: int = 8, p: Process = nil) =
  let cls = asPy(cast[PPyObject](cast[ptr PyObjectObj](rawPy(inst)).ob_type))
  ensureStructInfo(cls)
  let d = objDict(inst)
  for (name, ftype, off, code) in fields(cls):
    encodeAtCode(code, ftype, fieldValue(d, inst, name), buf, baseOff + off, ptrSize, p)

proc encodeFString(self: Process, desc: PyObject, value: PyObject, buf: var seq[byte], off, ptrSize: int) =
  let charSize = getAttr(desc, "_char_size").to(int)
  var dataPtr: uint64
  if ptrSize == 4:
    dataPtr = uint64(rd[uint32](buf, off))
  else:
    dataPtr = rd[uint64](buf, off)
  let
    maxCount = int(rd[int32](buf, off + ptrSize + 4))
    v = tryGetAttr(value, "value")
    s = if v.isNil: value.to(string) else: v.to(string)
  var units: seq[uint32]
  if charSize == 4:
    units = utf32Units(s)
  else:
    for u in utf16Units(s):
      units.add uint32(u)
  if dataPtr == 0:
    raise newException(PmValueError, "FString has no data buffer; cannot write")
  if maxCount <= 0:
    raise newException(PmValueError, "FString has no capacity (Max is " & $maxCount & ")")
  if units.len + 1 > maxCount:
    raise newException(PmValueError, "FString capacity is " & $maxCount & " characters, text needs " & $(units.len + 1))
  var data = newSeq[byte]((units.len + 1) * charSize)
  for i, u in units:
    for b in 0 ..< charSize:
      data[i * charSize + b] = byte((u shr (8 * b)) and 0xFF)
  discard self.writeBuf(dataPtr, data)
  put(buf, off + ptrSize, int32(units.len + 1))

proc encodeAtCode*(
  code: int,
  ftype: PyObject,
  value: PyObject,
  buf: var seq[byte],
  off: int,
  ptrSize: int = 8,
  p: Process = nil
) =
  if code < 0:
    encodeStruct(value, buf, off, ptrSize, p)
    return
  let tc = TypeCode(code)
  case tc
  of tcStruct: encodeStruct(value, buf, off, ptrSize, p)
  of tcArray:
    let
      elem = getAttr(ftype, "_elem")
      count = getAttr(ftype, "_count").to(int)
      elemSize = sizeForRead(elem, ptrSize)
      stride = arrayStride(ftype, elemSize)
    encodeArray(elem, count, stride, value, buf, off, ptrSize, p)
  of tcString:
    let
      size = getAttr(ftype, "_size").to(int)
      v = tryGetAttr(value, "value")
      s = if v.isNil: value.to(string) else: v.to(string)
    for i in 0 ..< size:
      buf[off + i] = if i < s.len: byte(s[i]) else: 0'u8
  of tcWString:
    let
      size = getAttr(ftype, "_size").to(int)
      v = tryGetAttr(value, "value")
      s = if v.isNil: value.to(string) else: v.to(string)
      bytes = fixedWide(s, size, 2)
    for i in 0 ..< size:
      buf[off + i] = bytes[i]
  of tcBytes:
    let
      size = getAttr(ftype, "_size").to(int)
      v = tryGetAttr(value, "value")
      b = if v.isNil: value.to(seq[byte]) else: v.to(seq[byte])
    for i in 0 ..< size:
      buf[off + i] = if i < b.len: b[i] else: 0'u8
  of tcFString:
    if p.isNil:
      raise newException(PmBadType, "fstring is only available through a process")
    encodeFString(p, ftype, value, buf, off, ptrSize)
  else:
    encodeScalar(tc, value, buf, off, ptrSize)

proc encodeAt*(ftype: PyObject, value: PyObject, buf: var seq[byte], off: int, ptrSize: int = 8, p: Process = nil) =
  encodeAtCode(codeOf(ftype), ftype, value, buf, off, ptrSize, p)

proc resolveTargetPid*(target: PyObject): int =
  if pyIsInstance(target, "bool"):
    raise newException(PmBadType, "target must be an int (pid) or a str (process name)")
  if pyIsInstance(target, "int"):
    let pid = target.to(int)
    if pid <= 0:
      raise newException(PmProcessNotFound, "invalid pid " & $pid)
    if not processExists(pid):
      raise newException(PmProcessNotFound, "process with pid " & $pid & " not found")
    return pid
  if not pyIsInstance(target, "str"):
    raise newException(PmBadType, "target must be an int (pid) or a str (process name)")
  let want = normalizeProcName(target.to(string))
  if want.len == 0:
    raise newException(PmProcessNotFound, "empty process name")
  var exact: seq[int]
  var partial: seq[int]
  var candidateText: seq[string]
  for rp in enumProcesses():
    var isExact = false
    var isPartial = false
    for rawName in processNames(rp.pid):
      let n = normalizeProcName(rawName)
      if n == want:
        isExact = true
      if want in n:
        isPartial = true
        candidateText.add rawName & " (" & $rp.pid & ")"
    if isExact:
      exact.add rp.pid
    elif isPartial:
      partial.add rp.pid
  if exact.len > 0:
    exact.sort()
    return exact[0]
  let uniq = partial.deduplicate()
  if uniq.len == 1:
    return uniq[0]
  if uniq.len == 0:
    raise newException(PmProcessNotFound, "no running process matches '" & target.to(string) & "'")
  raise newException(
    PmProcessNotFound,
    "process name '" & target.to(string) & "' is ambiguous: " & candidateText.join(", ")
  )

proc normalizeProcName*(s: string): string =
  result = s.strip().toLowerAscii()
  if result.endsWith(".exe"):
    result.setLen(result.len - 4)

proc anyProcessNameMatches*(want: string): bool =
  for rp in enumProcesses():
    for rawName in processNames(rp.pid):
      let n = normalizeProcName(rawName)
      if n == want or want in n:
        return true
  false

proc makeRecord*(cls: PyObject, pairs: openArray[(string, PPyObject)]): PyObject =
  result = callObject(cls)
  for (k, v) in pairs:
    setPyAttr(result, k, v)

proc makeModuleRecord*(m: RawModule): PyObject =
  result = makeRecord(moduleClass, [
    ("name", nimValueToPy(m.name)),
    ("base", nimValueToPy(m.base)),
    ("end", nimValueToPy(m.`end`)),
    ("size", nimValueToPy(m.size))
  ])

proc makeRegionRecord*(r: RawRegion): PyObject =
  result = makeRecord(regionClass, [
    ("start", nimValueToPy(r.start)),
    ("end", nimValueToPy(r.`end`)),
    ("size", nimValueToPy(r.size)),
    ("protection", nimValueToPy(r.protection))
  ])

proc makeEntryRecord*(p: RawProcess): PyObject =
  result = makeRecord(entryClass, [
    ("pid", nimValueToPy(p.pid)),
    ("name", nimValueToPy(p.name))
  ])

proc refreshModules*(self: Process) =
  if not self.modulesKnown:
    try:
      self.modulesCache = enumModules(self.pid)
    except OsFailure as e:
      raise osFail("enumerate modules", e)
    self.modulesKnown = true

proc refreshRegions*(self: Process) =
  if not self.regionsKnown:
    try:
      self.regionsCache = enumRegions(self.pid)
    except OsFailure as e:
      raise osFail("enumerate regions", e)
    self.regionsKnown = true

proc findModule*(self: Process, name: string): RawModule =
  refreshModules(self)
  let want = name.toLowerAscii()
  var best: RawModule
  var found = false
  for m in self.modulesCache:
    if m.name.toLowerAscii() == want:
      if not found or m.base < best.base:
        best = m
        found = true
  if not found:
    raise newException(PmModuleNotFound, "module '" & name & "' not found in process " & $self.pid)
  result = best

proc mainModule*(self: Process): RawModule =
  refreshModules(self)
  let exe = try:
      processPath(self.pid)
    except OsFailure:
      ""
  if exe.len > 0:
    let exeName = extractFilename(exe)
    for m in self.modulesCache:
      if m.name == exeName:
        return m
  if self.modulesCache.len == 0:
    raise newException(PmModuleNotFound, "no module found in process " & $self.pid)
  result = self.modulesCache[0]

proc mainModuleBase*(self: Process): uint =
  if not self.baseKnown:
    self.baseCache = self.mainModule().base
    self.baseKnown = true
  self.baseCache

proc readTyped(self: Process, address: uint64, typeDesc: PyObject, count: int): PPyObject =
  if isValueObj(typeDesc):
    raise newException(PmBadType, "read() expects a type (pm.mem.i32 or a Struct class), not a value")
  let
    code = codeOf(typeDesc)
    isArray = code == ord(tcArray)
    isStruct = code == ord(tcStruct) or (code < 0 and pyIsType(typeDesc))
    ptrSize =
      if code in {ord(tcPtr), ord(tcFString)}:
        self.pointerSize()
      elif isArray or isStruct:
        if usesPointers(typeDesc): self.pointerSize() else: 8
      else:
        8
  if isArray or isStruct:
    if count != 0:
      raise newException(PmValueError, (if isArray:
        "read count is not supported for an array descriptor"
      else:
        "read count is not supported for a Struct; use pm.mem.array(cls, n)"))
    let decoded = decodeAt(
      typeDesc,
      self.readBuf(address, sizeForRead(typeDesc, ptrSize)),
      0,
      address,
      true,
      ptrSize,
      self
    )
    if decoded.isNil:
      return nil
    if self.debugFlag:
      logAccess("READ", address, typeLabel(typeDesc), pyRepr(asPy(decoded)))
    return decoded
  if code < 0:
    raise newException(PmBadType, "read() expects a type (pm.mem.i32 or a Struct class)")
  let size = sizeForRead(typeDesc, ptrSize)
  if count < 0:
    raise newException(PmValueError, "read count must not be negative")
  if count > 0:
    let buf = self.readBuf(address, size * count)
    var items: seq[PPyObject]
    for i in 0 ..< count:
      let item = decodeAt(typeDesc, buf, i * size, address, true, ptrSize, self)
      if item.isNil:
        for x in items:
          decRef x
        return nil
      items.add item
    let list = nimValueToPy(newPyListTaking(items))
    if self.debugFlag:
      logAccess("READ", address, typeLabel(typeDesc) & "[" & $count & "]", pyRepr(asPy(list)))
    return list
  let buf = self.readBuf(address, size)
  result = decodeAt(typeDesc, buf, 0, address, true, ptrSize, self)
  if self.debugFlag and not result.isNil:
    logAccess("READ", address, typeLabel(typeDesc), pyRepr(asPy(result)))

proc processRead*(self: Process, address: uint64, typeDesc: PyObject, count: int = 0): PPyObject {.exportpy: "read".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    readTyped(self, address, typeDesc, count)

proc processWrite*(self: Process, address: uint64, valueObj: PyObject): PPyObject {.exportpy: "write".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    if pyIsType(valueObj):
      raise newException(PmBadType, "write() expects a value such as pm.mem.i32(5), not a type")
    let code = codeOf(valueObj)
    if code < 0:
      raise newException(PmBadType, "write() expects a value such as pm.mem.i32(5), not a type")
    let
      tc = TypeCode(code)
      ptrSize =
        if tc in {tcPtr, tcFString}:
          self.pointerSize()
        elif tc in {tcArray, tcStruct}:
          if usesPointers(valueObj): self.pointerSize() else: 8
        else:
          8
    let written = case tc
    of tcString, tcWString, tcBytes:
      var buf = newSeq[byte](getAttr(valueObj, "_size").to(int))
      encodeScalar(tc, valueObj, buf, 0, ptrSize)
      self.writeBuf(address, buf)
    of tcArray:
      var buf = newSeq[byte](sizeForRead(valueObj, ptrSize))
      encodeAtCode(code, valueObj, getAttr(valueObj, "value"), buf, 0, ptrSize, self)
      self.writeBuf(address, buf)
    of tcStruct:
      var buf = self.readBuf(address, sizeForRead(valueObj, ptrSize))
      encodeStruct(valueObj, buf, 0, ptrSize, self)
      self.writeBuf(address, buf)
    of tcFString:
      var buf = self.readBuf(address, sizeForRead(valueObj, ptrSize))
      encodeAtCode(code, valueObj, getAttr(valueObj, "value"), buf, 0, ptrSize, self)
      self.writeBuf(address, buf)
    of tcVec2, tcVec3:
      var buf = newSeq[byte](ScalarSizes[tc])
      let v = tryGetAttr(valueObj, "value")
      encodeScalar(tc, if v.isNil: valueObj else: v, buf, 0, ptrSize)
      self.writeBuf(address, buf)
    else:
      let
        v = getAttr(valueObj, "value")
        size = if tc == tcPtr: ptrSize else: ScalarSizes[tc]
        seq = isSeq(v)
      var buf = newSeq[byte](if seq: size * seqLen(v) else: size)
      if seq:
        var i = 0
        for raw in rawItems(rawPy(v)):
          encodeScalar(tc, asPy(raw), buf, i * size, ptrSize)
          inc i
      else:
        encodeScalar(tc, v, buf, 0, ptrSize)
      self.writeBuf(address, buf)
    if self.debugFlag:
      logAccess("WRITE", address, typeLabel(valueObj), valueRepr(valueObj))
    written

proc chainAddress*(self: Process, base: uint64, offsets: PyObject): uint64 =
  var offs: seq[uint64]
  for raw in rawItems(rawPy(offsets)):
    offs.add asPy(raw).to(uint64)
  result = self.readPointer(base)
  if offs.len > 0:
    for i in 0 ..< offs.len - 1:
      result = self.readPointer(result + offs[i])
    result = result + offs[^1]

proc processChain*(self: Process, base: uint64, offsets: PyObject): PPyObject {.exportpy: "chain".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    chainAddress(self, base, offsets)

proc processReadChain*(
  self: Process,
  base: uint64,
  offsets: PyObject,
  typeDesc: PyObject
): PPyObject {.exportpy: "read_chain".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    readTyped(self, chainAddress(self, base, offsets), typeDesc, 0)

proc processResolveRip*(
  self: Process,
  address: uint64,
  offset: int = 3,
  size: int = 7
): PPyObject {.exportpy: "resolve_rip".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    let buf = self.readBuf(address + uint64(offset), 4)
    var disp: int32
    copyMem(addr disp, unsafeAddr buf[0], 4)
    let target = int64(address) + int64(size) + int64(disp)
    uint64(target)

proc parsePattern*(pattern: string): seq[PatternByte] =
  for tok in pattern.splitWhitespace():
    if tok == "?" or tok == "??":
      result.add PatternByte(value: 0, mask: 0)
    elif tok.len == 2:
      var value = 0'u8
      var mask = 0'u8
      try:
        if tok[0] == '?':
          mask = mask or 0x0F'u8
        else:
          value = value or (byte(parseHexInt($tok[0])) shl 4)
          mask = mask or 0xF0'u8
        if tok[1] == '?':
          mask = mask or 0xF0'u8
        else:
          value = value or byte(parseHexInt($tok[1]))
          mask = mask or 0x0F'u8
      except ValueError:
        raise newException(PmValueError, "invalid pattern token '" & tok & "'")
      result.add PatternByte(value: value, mask: mask)
    else:
      raise newException(PmValueError, "invalid pattern token '" & tok & "'")
  if result.len == 0:
    raise newException(PmValueError, "empty pattern")

proc findPattern*(buf: openArray[byte], pat: seq[PatternByte]): seq[int] =
  if pat.len == 0 or buf.len < pat.len:
    return
  for i in 0 .. buf.len - pat.len:
    var ok = true
    for j in 0 ..< pat.len:
      if (buf[i + j] and pat[j].mask) != pat[j].value:
        ok = false
        break
    if ok:
      result.add i

proc scanAddressRange*(self: Process, pat: seq[PatternByte], start, stop: uint64, maxResults: int = 0): seq[uint64] =
  refreshRegions(self)
  for r in self.regionsCache:
    if r.`end` <= start or r.start >= stop:
      continue
    if r.protection.len == 0 or r.protection[0] != 'r':
      continue
    let
      lo = max(r.start, start)
      hi = min(r.`end`, stop)
    if hi <= lo:
      continue
    const chunk = 1 shl 20
    let overlap = if pat.len > 1: pat.len - 1 else: 0
    var pos = lo
    while pos < hi:
      let
        span = min(uint64(chunk), hi - pos)
        got = min(uint64(overlap), hi - (pos + span))
        buf = try:
            self.readBuf(pos, int(span + got))
          except PmAccessError:
            break
      for off in findPattern(buf, pat):
        if uint64(off) < span:
          result.add pos + uint64(off)
          if maxResults > 0 and result.len >= maxResults:
            return
      pos += span

proc processScan*(
  self: Process,
  pattern: string,
  module: string = "",
  first: bool = false
): PPyObject {.exportpy: "scan".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    let
      pat = parsePattern(pattern)
      m = if module.len > 0: self.findModule(module) else: self.mainModule()
      start = m.base
      stop = m.`end`
    if first:
      let hits = scanAddressRange(self, pat, start, stop, 1)
      if hits.len == 0:
        takePy(newPyNone())
      else:
        takePy(nimValueToPy(hits[0]))
    else:
      let hits = scanAddressRange(self, pat, start, stop)
      var items: seq[PPyObject]
      for h in hits:
        items.add nimValueToPy(h)
      newPyListTaking(items)

proc processScanRange*(self: Process, pattern: string, start, stop: uint64): PPyObject {.exportpy: "scan_range".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    if stop < start:
      raise newException(PmValueError, "scan_range() stop must not be smaller than start")
    let hits = scanAddressRange(self, parsePattern(pattern), start, stop)
    var items: seq[PPyObject]
    for h in hits:
      items.add nimValueToPy(h)
    newPyListTaking(items)

proc memScanBytes*(pattern: string, data: PyObject): PPyObject {.exportpy: "_memScanBytes".} =
  pyWrap:
    let
      pat = parsePattern(pattern)
      buf = data.to(seq[byte])
    var items: seq[PPyObject]
    for off in findPattern(buf, pat):
      items.add nimValueToPy(off)
    newPyListTaking(items)

proc memOpen*(target: PyObject, debug: bool = false): PPyObject {.exportpy: "_memOpen".} =
  pyWrap:
    ensureTypes()
    let pid = resolveTargetPid(target)
    var h: OsHandle
    try:
      h = openProcessHandle(pid)
    except OsFailure as e:
      raise osFail("open process " & $pid, e)
    Process(pid: pid, handle: h, debugFlag: debug)

proc memProcesses*(): PPyObject {.exportpy: "_memProcesses".} =
  pyWrap:
    ensureTypes()
    var items: seq[PyObject]
    for p in enumProcesses():
      items.add makeEntryRecord(p)
    newPyListOf(items)

proc memExists*(target: PyObject): PPyObject {.exportpy: "_memExists".} =
  pyWrap:
    ensureTypes()
    if pyIsInstance(target, "bool"):
      raise newException(PmBadType, "target must be an int (pid) or a str (process name)")
    if pyIsInstance(target, "int"):
      processExists(target.to(int))
    elif pyIsInstance(target, "str"):
      anyProcessNameMatches(normalizeProcName(target.to(string)))
    else:
      raise newException(PmBadType, "target must be an int (pid) or a str (process name)")

proc memPid*(target: PyObject): PPyObject {.exportpy: "_memPid".} =
  pyWrap:
    ensureTypes()
    resolveTargetPid(target)

proc memName*(target: PyObject): PPyObject {.exportpy: "_memName".} =
  pyWrap:
    ensureTypes()
    imageName(resolveTargetPid(target))

proc memPath*(target: PyObject): PPyObject {.exportpy: "_memPath".} =
  pyWrap:
    ensureTypes()
    imagePath(resolveTargetPid(target))

proc memIs64Bit*(target: PyObject): PPyObject {.exportpy: "_memIs64Bit".} =
  pyWrap:
    ensureTypes()
    let pid = resolveTargetPid(target)
    try:
      processIs64Bit(pid)
    except OsFailure as e:
      raise osFail("determine bitness of " & $pid, e)

proc memString*(arg: PyObject = nil): PPyObject {.exportpy: "_memString".} =
  pyWrap:
    ensureTypes()
    if arg.isNil:
      makeDesc(tcString, 32, "string")
    elif pyIsInstance(arg, "int"):
      let n = arg.to(int)
      if n <= 0:
        raise newException(PmValueError, "string size must be positive")
      makeDesc(tcString, n, "string")
    else:
      callObject(makeDesc(tcString, arg.to(string).len + 1, "string"), arg)

proc memWString*(arg: PyObject = nil): PPyObject {.exportpy: "_memWString".} =
  pyWrap:
    ensureTypes()
    if arg.isNil:
      makeDesc(tcWString, 64, "wstring")
    elif pyIsInstance(arg, "int"):
      let n = arg.to(int)
      if n <= 0:
        raise newException(PmValueError, "wstring size must be positive")
      makeDesc(tcWString, n * 2, "wstring")
    else:
      let units = utf16Units(arg.to(string))
      callObject(makeDesc(tcWString, (units.len + 1) * 2, "wstring"), arg)

proc memFString*(arg: PyObject = nil, char_size: int = 2): PPyObject {.exportpy: "_memFString".} =
  pyWrap:
    ensureTypes()
    if char_size notin {2, 4}:
      raise newException(PmValueError, "fstring char_size must be 2 or 4")
    let desc = makeDesc(tcFString, 16, "fstring")
    setPyAttrInt(desc, "_char_size", char_size)
    if arg.isNil:
      desc
    elif pyIsInstance(arg, "str"):
      callObject(desc, arg)
    else:
      raise newException(PmBadType, "fstring expects a str value or no argument; use char_size=2 or 4")

proc memBytes*(arg: PyObject): PPyObject {.exportpy: "_memBytes".} =
  pyWrap:
    ensureTypes()
    if pyIsInstance(arg, "int"):
      let n = arg.to(int)
      if n <= 0:
        raise newException(PmValueError, "bytes size must be positive")
      makeDesc(tcBytes, n, "bytes")
    else:
      let desc = makeDesc(tcBytes, arg.to(seq[byte]).len, "bytes")
      callObject(desc, arg)

proc memArray*(elem: PyObject, count: int, stride: int = 0): PPyObject {.exportpy: "_memArray".} =
  pyWrap:
    ensureTypes()
    if count <= 0:
      raise newException(PmValueError, "array count must be positive")
    let
      esz = sizeOfDesc(elem)
      st = if stride == 0: esz else: stride
    if st < esz:
      raise newException(PmValueError, "array stride (" & $st & ") is smaller than element size (" & $esz & ")")
    let desc = makeDesc(tcArray, st * (count - 1) + esz, "array")
    setAttr(desc, "_elem", elem)
    setPyAttrInt(desc, "_count", count)
    setPyAttrInt(desc, "_stride", st)
    setPyAttr(desc, "_stride_explicit", nimValueToPy(stride != 0))
    setPyAttr(desc, "_has_ptr", nimValueToPy(usesPointers(elem)))
    desc

proc processPid*(self: Process): int {.exportpy: "pid".} =
  result = self.pid

proc processName*(self: Process): string {.exportpy: "name".} =
  if self.nameCache.len == 0:
    try:
      self.nameCache = imageName(self.pid)
    except OsFailure:
      discard
  result = self.nameCache

proc processPathM*(self: Process): PPyObject {.exportpy: "path".} =
  pyWrap:
    ensureTypes()
    imagePath(self.pid)

proc processAlive*(self: Process): bool {.exportpy: "alive".} =
  if self.closed:
    return false
  result = processExists(self.pid)

proc processIs64*(self: Process): PPyObject {.exportpy: "is_64bit".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    self.pointerSize() == 8

proc processBase*(self: Process, module: string = ""): PPyObject {.exportpy: "base".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    if module.len == 0:
      mainModuleBase(self)
    else:
      findModule(self, module).base

proc processModules*(self: Process): PPyObject {.exportpy: "modules".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    refreshModules(self)
    var items: seq[PyObject]
    for m in self.modulesCache:
      items.add makeModuleRecord(m)
    newPyListOf(items)

proc processModule*(self: Process, name: string): PPyObject {.exportpy: "module".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    makeModuleRecord(findModule(self, name))

proc processRegions*(self: Process): PPyObject {.exportpy: "regions".} =
  pyWrap:
    ensureTypes()
    checkOpen(self)
    refreshRegions(self)
    var items: seq[PyObject]
    for r in self.regionsCache:
      items.add makeRegionRecord(r)
    newPyListOf(items)

proc processRefresh*(self: Process) {.exportpy: "refresh".} =
  self.baseKnown = false
  self.modulesKnown = false
  self.regionsKnown = false

proc processSetDebug*(self: Process, flag: bool) {.exportpy: "set_debug".} =
  self.debugFlag = flag

proc processClose*(self: Process) {.exportpy: "close".} =
  if not self.closed:
    self.closed = true
    closeProcessHandle(self.handle)

proc enterImpl(self: Process): Process =
  self

proc exitImpl(self: Process, a, b, c: PyObject): bool =
  processClose(self)
  false

exportAs(enterImpl, "__enter__")
exportAs(exitImpl, "__exit__")
