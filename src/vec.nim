import std/strutils
import nimpy
import nimpy/[py_types, py_utils, py_lib as pyl]
import raylib as rl
import raymath as rm

import pyutil, errors, mem_types

pyExportModule("pymew")

var
  vec2ClassObj*: PyObject
  vec3ClassObj*: PyObject
  vecClassesReady* = false

const compNames = ["x", "y", "z"]

var compKeys: array[3, PyObject]

proc compKey(i: int): PPyObject =
  if compKeys[i].isNil:
    compKeys[i] = takePy(nimValueToPy(compNames[i]))
  rawPy(compKeys[i])

proc buildVec(cls: PyObject, vals: openArray[float]): PyObject =
  result = objectNew(cls)
  let d = rawPy(objDict(result))
  dictSet(d, isValueKey(), pyTrue())
  for i in 0 ..< vals.len:
    dictSetOwned(d, compKey(i), nimValueToPy(vals[i]))

proc vecNewImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  try:
    let
      cls = asPy(cast[PPyObject](pyl.pyLib.PyTuple_GetItem(args, 0)))
      dim = getAttr(cls, "_dim").to(int)
      inst = objectNew(cls)
    setPyAttr(inst, "_is_value", nimValueToPy(true))
    let nargs = int(pyl.pyLib.PyTuple_Size(args))
    for i in 0 ..< dim:
      var v = 0.0
      if i + 1 < nargs:
        v = asPy(cast[PPyObject](pyl.pyLib.PyTuple_GetItem(args, i + 1))).to(float)
      elif not kwargs.isNil:
        let item = pyl.pyLib.PyDict_GetItemString(kwargs, cstring(compNames[i]))
        if not item.isNil:
          v = asPy(item).to(float)
      setPyAttr(inst, compNames[i], nimValueToPy(v))
    result = rawPy(inst)
    incRef result
  except CatchableError as e:
    setPyErr(errorClass, e.msg)
    result = nil

proc comp(self: PyObject, i: int): float =
  getAttr(self, compNames[i].cstring).to(float)

proc vecDimOf(v: PyObject): int =
  getAttr(getAttr(v, "__class__"), "_dim").to(int)

proc makeVecLike(a: PyObject, vals: openArray[float]): PyObject =
  let cls = getAttr(a, "__class__")
  result = buildVec(cls, vals)

proc makeVecLike(a: PyObject, v: rl.Vector2): PyObject =
  makeVecLike(a, [float(v.x), float(v.y)])

proc makeVecLike(a: PyObject, v: rl.Vector3): PyObject =
  makeVecLike(a, [float(v.x), float(v.y), float(v.z)])

proc vec2Of(v: PyObject): rl.Vector2 =
  rl.Vector2(x: comp(v, 0).float32, y: comp(v, 1).float32)

proc vec3Of(v: PyObject): rl.Vector3 =
  rl.Vector3(x: comp(v, 0).float32, y: comp(v, 1).float32, z: comp(v, 2).float32)

proc addImpl(a, b: PyObject): PyObject =
  if vecDimOf(a) == 2:
    makeVecLike(a, rm.add(vec2Of(a), vec2Of(b)))
  else:
    makeVecLike(a, rm.add(vec3Of(a), vec3Of(b)))

proc subImpl(a, b: PyObject): PyObject =
  if vecDimOf(a) == 2:
    makeVecLike(a, rm.subtract(vec2Of(a), vec2Of(b)))
  else:
    makeVecLike(a, rm.subtract(vec3Of(a), vec3Of(b)))

proc isNumber(o: PyObject): bool =
  pyIsInstance(o, "int") or pyIsInstance(o, "float")

proc mulImpl(a, b: PyObject): PyObject =
  if isNumber(b):
    let s = b.to(float).float32
    if vecDimOf(a) == 2:
      makeVecLike(a, rm.scale(vec2Of(a), s))
    else:
      makeVecLike(a, rm.scale(vec3Of(a), s))
  elif vecDimOf(a) == 2:
    makeVecLike(a, rm.multiply(vec2Of(a), vec2Of(b)))
  else:
    makeVecLike(a, rm.multiply(vec3Of(a), vec3Of(b)))

proc divImpl(a, b: PyObject): PyObject =
  let s = 1.0'f32 / b.to(float).float32
  if vecDimOf(a) == 2:
    makeVecLike(a, rm.scale(vec2Of(a), s))
  else:
    makeVecLike(a, rm.scale(vec3Of(a), s))

proc negImpl(a: PyObject): PyObject =
  if vecDimOf(a) == 2:
    makeVecLike(a, rm.negate(vec2Of(a)))
  else:
    makeVecLike(a, rm.negate(vec3Of(a)))

proc eqImpl(a, b: PyObject): bool =
  let d = vecDimOf(a)
  if vecDimOf(b) != d:
    return false
  if d == 2:
    rm.equals(vec2Of(a), vec2Of(b)) != 0
  else:
    rm.equals(vec3Of(a), vec3Of(b)) != 0

proc lengthSqImpl(v: PyObject): float =
  if vecDimOf(v) == 2:
    float(rm.lengthSqr(vec2Of(v)))
  else:
    float(rm.lengthSqr(vec3Of(v)))

proc lengthImpl(v: PyObject): float =
  if vecDimOf(v) == 2:
    float(rm.length(vec2Of(v)))
  else:
    float(rm.length(vec3Of(v)))

proc distanceImpl(a, b: PyObject): float =
  if vecDimOf(a) == 2:
    float(rm.distance(vec2Of(a), vec2Of(b)))
  else:
    float(rm.distance(vec3Of(a), vec3Of(b)))

proc normalizedImpl(v: PyObject): PyObject =
  if vecDimOf(v) == 2:
    makeVecLike(v, rm.normalize(vec2Of(v)))
  else:
    makeVecLike(v, rm.normalize(vec3Of(v)))

proc toTupleImpl(v: PyObject): PyObject =
  var items: seq[PyObject]
  for i in 0 ..< vecDimOf(v):
    items.add takePy(nimValueToPy(comp(v, i)))
  newPyTuple(items)

proc iterImpl(v: PyObject): PyObject =
  callObject(getAttr(pyBuiltinsModule(), "iter"), toTupleImpl(v))

proc closestImpl(v, others: PyObject): PyObject =
  var best: PyObject
  var bestDist = Inf
  for raw in rawItems(rawPy(others)):
    let
      o = asPy(raw)
      dist = distanceImpl(v, o)
    if best.isNil or dist < bestDist:
      best = o
      bestDist = dist
  if best.isNil:
    raise newException(ValueError, "closest() requires a non-empty sequence")
  result = best

proc reprImpl(self: PyObject): string =
  let d = vecDimOf(self)
  var parts: seq[string]
  for i in 0 ..< d:
    parts.add $comp(self, i)
  result = "vec" & $d & "(" & parts.join(", ") & ")"

proc makeVecClass(dim: int): PyObject =
  var d = pyDict()
  d["__new__"] = rawKwFunc("__new__", vecNewImpl)
  d["__init__"] = rawKwFunc("__init__", initIgnore)

  bindMethod(d, "__add__", proc(a, b: PyObject): PyObject = addImpl(a, b))
  bindMethod(d, "__sub__", proc(a, b: PyObject): PyObject = subImpl(a, b))
  bindMethod(d, "__mul__", proc(a, b: PyObject): PyObject = mulImpl(a, b))
  bindMethod(d, "__truediv__", proc(a, b: PyObject): PyObject = divImpl(a, b))
  bindMethod(d, "__neg__", proc(a: PyObject): PyObject = negImpl(a))
  bindMethod(d, "__eq__", proc(a, b: PyObject): bool = eqImpl(a, b))
  bindMethod(d, "__iter__", proc(a: PyObject): PyObject = iterImpl(a))
  bindMethod(d, "__repr__", proc(a: PyObject): string = reprImpl(a))

  bindMethod(d, "length", proc(a: PyObject): float = lengthImpl(a))
  bindMethod(d, "length_sq", proc(a: PyObject): float = lengthSqImpl(a))
  bindMethod(d, "distance", proc(a, b: PyObject): float = distanceImpl(a, b))
  bindMethod(d, "normalized", proc(a: PyObject): PyObject = normalizedImpl(a))
  bindMethod(d, "to_tuple", proc(a: PyObject): PyObject = toTupleImpl(a))
  bindMethod(d, "closest", proc(a, b: PyObject): PyObject = closestImpl(a, b))

  result = newClass("vec" & $dim, getAttr(pyBuiltinsModule(), "object"), d)
  setPyAttrInt(result, "_dim", dim)
  let tc = if dim == 2: tcVec2 else: tcVec3
  setPyAttrInt(result, "_code", ord(tc))
  setPyAttrInt(result, "_size", ScalarSizes[tc])

proc ensureVecClasses*() =
  if vecClassesReady:
    return
  vec2ClassObj = makeVecClass(2)
  vec3ClassObj = makeVecClass(3)
  vecClassesReady = true

proc newVec2*(v: rl.Vector2): PyObject =
  ensureVecClasses()
  buildVec(vec2ClassObj, [float(v.x), float(v.y)])

proc newVec2*(x, y: float): PyObject =
  newVec2(rl.Vector2(x: x.float32, y: y.float32))

proc newVec3*(v: rl.Vector3): PyObject =
  ensureVecClasses()
  buildVec(vec3ClassObj, [float(v.x), float(v.y), float(v.z)])

proc newVec3*(x, y, z: float): PyObject =
  newVec3(rl.Vector3(x: x.float32, y: y.float32, z: z.float32))

proc vec2*(x: float = 0.0, y: float = 0.0): PyObject {.exportpy.} =
  newVec2(x, y)

proc vec3*(x: float = 0.0, y: float = 0.0, z: float = 0.0): PyObject {.exportpy.} =
  newVec3(x, y, z)
