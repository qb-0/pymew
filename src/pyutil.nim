import std/[dynlib, editdistance, math, strutils]
import macros
import nimpy
import nimpy/[py_types, py_utils, py_lib as pyl]

proc normalizeName*(text: string): string =
  for ch in text:
    if ch notin {'_', '-', ' '}:
      result.add toLowerAscii(ch)

proc clampFactor*(f: float): float =
  if f.isNaN: 0.0 else: clamp(f, 0.0, 1.0)

proc rawPy*(o: PyObject): PPyObject {.inline.} =
  privateRawPyObj(o)

proc closestName*(name: string, candidates: openArray[string], maxDistance: int): string =
  var bestDist = high(int)
  for candidate in candidates:
    let d = editDistance(name, candidate)
    if d < bestDist:
      bestDist = d
      result = candidate
  if bestDist > maxDistance:
    result = ""

proc isNone*(o: PyObject): bool =
  o.isNil or cast[pointer](rawPy(o)) == cast[pointer](pyl.pyLib.Py_None)

proc asPy*(o: PPyObject): PyObject =
  if o.isNil:
    return nil
  var r: PyObject
  pyValueToNim(o, r)
  r

proc argAt*(args: PPyObject, i: int): PyObject =
  if args.isNil or int(pyl.pyLib.PyTuple_Size(args)) <= i:
    return nil
  asPy(cast[PPyObject](pyl.pyLib.PyTuple_GetItem(args, i)))

proc kwArg*(kwargs: PPyObject, name: string): PyObject =
  if kwargs.isNil:
    return nil
  let item = pyl.pyLib.PyDict_GetItemString(kwargs, cstring(name))
  if item.isNil:
    return nil
  asPy(item)

proc takePy*(o: PPyObject): PyObject =
  result = asPy(o)
  decRef o

proc pyResult*(value: PyObject): PPyObject {.inline.} =
  nimValueToPy(value)

proc pyResult*(value: PPyObject): PPyObject {.inline.} =
  value

proc pyResult*[T](value: T): PPyObject =
  when T is void:
    newPyNone()
  else:
    nimValueToPy(value)

proc newPyListOf*(items: openArray[PyObject]): PyObject =
  let l = pyl.pyLib.PyList_New(items.len)
  for i, item in items:
    let raw = rawPy(item)
    incRef raw
    discard pyl.pyLib.PyList_SetItem(l, i, raw)
  result = asPy(l)
  decRef l

proc newPyListTaking*(items: openArray[PPyObject]): PyObject =
  let l = pyl.pyLib.PyList_New(items.len)
  for i, item in items:
    discard pyl.pyLib.PyList_SetItem(l, i, item)
  result = asPy(l)
  decRef l

proc pyIsType*(o: PyObject): bool =
  o.getAttr("__class__") == pyBuiltinsModule().getAttr("type")

proc pyIsInstance*(o: PyObject, name: string): bool =
  callObject(getAttr(pyBuiltinsModule(), "isinstance"), o, getAttr(pyBuiltinsModule(), name)).to(bool)

proc hasAttr*(o: PyObject, name: string): bool =
  let v = pyl.pyLib.PyObject_GetAttrString(rawPy(o), cstring(name))
  if v.isNil:
    pyl.pyLib.PyErr_Clear()
    return false
  decRef v
  result = true

proc tryGetAttr*(o: PyObject, name: string): PyObject =
  let v = pyl.pyLib.PyObject_GetAttrString(rawPy(o), cstring(name))
  if v.isNil:
    pyl.pyLib.PyErr_Clear()
    return nil
  result = asPy(v)
  decRef v

proc setPyAttr*(o: PyObject, name: string, v: PPyObject) =
  let r = pyl.pyLib.PyObject_SetAttrString(rawPy(o), cstring(name), v)
  decRef v
  if r != 0:
    raisePythonError()

proc setPyAttrStr*(o: PyObject, name: string, v: string) =
  setPyAttr(o, name, nimValueToPy(v))

proc setPyAttrInt*(o: PyObject, name: string, v: int) =
  setPyAttr(o, name, nimValueToPy(v))

proc objDict*(o: PyObject): PyObject =
  getAttr(o, "__dict__")

proc dictSet*(d, name, v: PPyObject) =
  if pyl.pyLib.PyDict_SetItem(d, name, v) != 0:
    raisePythonError()

proc dictSetOwned*(d, name, v: PPyObject) =
  dictSet(d, name, v)
  decRef v

var
  keyIsValue: PyObject
  keyAddress: PyObject
  pyTrueValue: PyObject

proc pyMetaKeys() =
  if keyIsValue.isNil:
    keyIsValue = takePy(nimValueToPy("_is_value"))
    keyAddress = takePy(nimValueToPy("_address"))
    pyTrueValue = takePy(nimValueToPy(true))

proc isValueKey*(): PPyObject =
  pyMetaKeys()
  rawPy(keyIsValue)

proc addressKey*(): PPyObject =
  pyMetaKeys()
  rawPy(keyAddress)

proc pyTrue*(): PPyObject =
  pyMetaKeys()
  rawPy(pyTrueValue)

proc isSeq*(o: PyObject): bool =
  let t = cast[ptr PyObjectObj](rawPy(o)).ob_type
  t == cast[pointer](pyl.pyLib.PyList_Type) or t == cast[pointer](pyl.pyLib.PyTuple_Type)

proc seqLen*(o: PyObject): int =
  if cast[ptr PyObjectObj](rawPy(o)).ob_type == cast[pointer](pyl.pyLib.PyList_Type):
    int(pyl.pyLib.PyList_Size(rawPy(o)))
  else:
    int(pyl.pyLib.PyTuple_Size(rawPy(o)))

proc newNamespace*(): PyObject =
  var nsCls {.global.}: PyObject
  if nsCls.isNil:
    nsCls = getAttr(pyImport("types"), "SimpleNamespace")
  result = callObject(nsCls)

proc initIgnore*(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  newPyNone()

proc rawKwFunc*(name: string, f: PyCFunctionWithKeywords): PyObject =
  let
    md = cast[ptr PyMethodDef](alloc0(sizeof(PyMethodDef)))
    cs = cast[cstring](alloc0(name.len + 1))
  if name.len > 0:
    copyMem(cs, unsafeAddr name[0], name.len)
  md.ml_name = cs
  md.ml_meth = f
  md.ml_flags = Py_MLFLAGS_VARARGS or Py_MLFLAGS_KEYWORDS
  let o = pyl.pyLib.PyCFunction_NewEx(md, cast[PPyObject](nil), cast[PPyObject](nil))
  result = asPy(o)
  decRef o

proc newPyTuple*(items: openArray[PyObject]): PyObject =
  let t = pyl.pyLib.PyTuple_New(items.len)
  for i, item in items:
    let raw = rawPy(item)
    incRef raw
    discard pyl.pyLib.PyTuple_SetItem(t, i, raw)
  result = asPy(t)
  decRef t

proc newClass*(name: string, base: PyObject, d: PyObject): PyObject =
  result = callObject(getAttr(pyBuiltinsModule(), "type"), name, newPyTuple([base]), d)
  setPyAttr(result, "__module__", nimValueToPy("pymew"))

proc newClassMulti*(name: string, bases: openArray[PyObject], d: PyObject): PyObject =
  result = callObject(getAttr(pyBuiltinsModule(), "type"), name, newPyTuple(bases), d)
  setPyAttr(result, "__module__", nimValueToPy("pymew"))

proc objectNew*(cls: PyObject): PyObject =
  let o = pyl.pyLib.PyType_GenericNew(cast[PyTypeObject](rawPy(cls)), nil, nil)
  if o.isNil:
    raisePythonError()
  result = asPy(o)
  decRef o

var
  methodClass: PyObject
  pyMethodNew: proc(fn, self: PPyObject): PPyObject {.cdecl.}

proc methodGetImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  if args.isNil or int(pyl.pyLib.PyTuple_Size(args)) < 2:
    pyl.pyLib.PyErr_SetString(pyl.pyLib.PyExc_TypeError, "descriptor '__get__' needs an instance")
    return nil
  try:
    let
      descr = argAt(args, 0)
      obj = argAt(args, 1)
      fn = getAttr(descr, "fn")
    if isNone(obj):
      result = rawPy(fn)
      incRef result
    else:
      result = pyMethodNew(rawPy(fn), rawPy(obj))
  except CatchableError as e:
    pyl.pyLib.PyErr_SetString(pyl.pyLib.PyExc_ValueError, cstring(e.msg))
    result = nil

proc makeMethod*(fn: PPyObject): PyObject =
  if methodClass.isNil:
    pyMethodNew = cast[typeof(pyMethodNew)](pyl.pyLib.module.symAddr("PyMethod_New"))
    if pyMethodNew.isNil:
      raise newException(ValueError, "PyMethod_New not found")
    var d = pyDict()
    d["__get__"] = rawKwFunc("__get__", methodGetImpl)
    methodClass = newClass("_Method", getAttr(pyBuiltinsModule(), "object"), d)
  result = callObject(methodClass)
  incRef fn
  setPyAttr(result, "fn", fn)

template bindMethod*(d: PyObject, name: string, fn: untyped) =
  d[name] = makeMethod(nimValueToPy(fn))

template bindKwMethod*(d: PyObject, name: string, fn: PyCFunctionWithKeywords) =
  d[name] = makeMethod(rawPy(rawKwFunc(name, fn)))

template bindClassMethod*(d: PyObject, name: string, fn: untyped) =
  d[name] = callObject(getAttr(pyBuiltinsModule(), "classmethod"), nimValueToPy(fn))

template bindKwClassMethod*(d: PyObject, name: string, fn: PyCFunctionWithKeywords) =
  d[name] = callObject(getAttr(pyBuiltinsModule(), "classmethod"), rawKwFunc(name, fn))

macro exportAs*(prc: typed, name: static[string]): untyped =
  var p = getImpl(prc)
  p[0] = ident(name)
  if p.params.kind == nnkFormalParams and p.params.len > 1:
    if p.params[1].kind == nnkIdentDefs and p.params[1][1].kind == nnkSym:
      p.params[1][1] = ident($p.params[1][1])
  result = newCall(bindSym"exportpy", p)
