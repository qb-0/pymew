import std/[algorithm, math, os, sets, strutils, tables, unicode]
import nimpy
import nimpy/[py_types, py_utils, py_lib as pyl]
import raylib as rl
from rlgl import drawRenderBatchActive

import pyutil, errors, vec
import platform/api

pyExportModule("pymew")

const
  DefaultColor* = 0xFFFFFFFF
  DefaultSegments = 16
  CornerShare = 0.25
  TwoPi = 6.2831855'f32
  DegToRad = 0.017453292'f32
  TextOutlineSteps = 16

type
  BoxStyle = enum
    bsLine
    bsCorner
    bsFilled

  LineStyle = enum
    lsSolid
    lsDashed
    lsDotted

  TextAlign = enum
    taLeft
    taCenter
    taRight

var
  drawReady* = false
  fontClass*: PyObject
  textureClass*: PyObject
  entityBoxClass*: PyObject
  currentFont: PyObject
  fontCache = initTable[string, PyObject]()
  defaultFontData: ptr rl.Font
  fontHandles: seq[PyObject]
  textureHandles: seq[PyObject]
  inFrame* = false

proc ensureDrawTypes*()

proc setFrameOpen*(value: bool) =
  inFrame = value

proc forgetHandle(handles: var seq[PyObject], inst: PyObject) =
  for i in 0 ..< handles.len:
    if rawPy(handles[i]) == rawPy(inst):
      handles.delete(i)
      return

proc alphaOf(c: int): int =
  c and 0xFF

proc withAlpha(c: int, factor: float): int =
  let alpha = int(round(float(alphaOf(c)) * clampFactor(factor)))
  int((uint32(c) and 0xFFFFFF00'u32) or uint32(clamp(alpha, 0, 255)))

proc darkened(c: int): int =
  let
    u = uint32(c)
    r = (u shr 24 and 0xFF) * 55 div 100
    g = (u shr 16 and 0xFF) * 55 div 100
    b = (u shr 8 and 0xFF) * 55 div 100
  int((r shl 24) or (g shl 16) or (b shl 8) or (u and 0xFF))

proc outlineActive(on: bool, thick: float32, color: int): bool =
  on and thick > 0 and alphaOf(color) > 0

proc param(args, kwargs: PPyObject, i: int, name: string): PyObject =
  result = argAt(args, i)
  if result.isNil:
    result = kwArg(kwargs, name)

proc methodFloat(args, kwargs: PPyObject, i: int, name: string, default: float): float =
  let v = param(args, kwargs, i, name)
  if isNone(v):
    return default
  v.to(float)

proc methodBool(args, kwargs: PPyObject, i: int, name: string, default: bool): bool =
  let v = param(args, kwargs, i, name)
  if isNone(v):
    return default
  v.to(bool)

proc methodStr(args, kwargs: PPyObject, i: int, name: string, default: string): string =
  let v = param(args, kwargs, i, name)
  if isNone(v):
    return default
  if not pyIsInstance(v, "str"):
    raise newException(PmBadType, name & " must be a str")
  v.to(string)

proc textLines(value: PyObject): string =
  if value.isNil:
    raise newException(PmBadType, "text must be a str or a list of str")
  if isSeq(value):
    var parts: seq[string]
    for i in 0 ..< seqLen(value):
      parts.add value[i].to(string)
    return parts.join("\n")
  if not pyIsInstance(value, "str"):
    raise newException(PmBadType, "text must be a str or a list of str")
  value.to(string)

proc methodText(args, kwargs: PPyObject, i: int, name: string, default: string): string =
  let v = param(args, kwargs, i, name)
  if isNone(v):
    return default
  textLines(v)

proc methodColor(args, kwargs: PPyObject, i: int, name: string, default: int): int =
  let v = param(args, kwargs, i, name)
  if isNone(v):
    return default
  if not pyIsInstance(v, "int"):
    raise newException(PmBadType, name & " must be an int (0xRRGGBBAA)")
  v.to(int)

proc methodOptional(args, kwargs: PPyObject, i: int, name: string): PyObject =
  param(args, kwargs, i, name)

proc pointOf(o: PyObject): rl.Vector2 =
  if isNone(o):
    raise newException(PmBadType, "expected a vec2 or an (x, y) pair")
  if hasAttr(o, "x") and hasAttr(o, "y"):
    return rl.Vector2(x: getAttr(o, "x").to(float).float32, y: getAttr(o, "y").to(float).float32)
  if isSeq(o) and seqLen(o) >= 2:
    return rl.Vector2(x: o[0].to(float).float32, y: o[1].to(float).float32)
  raise newException(PmBadType, "expected a vec2 or an (x, y) pair")

proc pointsOf(o: PyObject): seq[rl.Vector2] =
  if not isSeq(o):
    raise newException(PmBadType, "points must be a list or tuple of (x, y)")
  for i in 0 ..< seqLen(o):
    result.add pointOf(o[i])

proc rectOf(o: PyObject): rl.Rectangle =
  if not isSeq(o) or seqLen(o) < 4:
    raise newException(PmBadType, "expected an (x, y, width, height) tuple")
  rl.Rectangle(
    x: o[0].to(float).float32,
    y: o[1].to(float).float32,
    width: o[2].to(float).float32,
    height: o[3].to(float).float32
  )

proc parseStyle(s: string): BoxStyle =
  case normalizeName(s)
  of "", "line", "normal", "box": bsLine
  of "corner", "corners": bsCorner
  of "filled", "fill": bsFilled
  else:
    raise newException(
      PmValueError,
      "unknown box style '" & s & "'; use line, corner or filled"
    )

proc parseAlign(s: string): TextAlign =
  case normalizeName(s)
  of "", "left": taLeft
  of "center", "centre", "middle": taCenter
  of "right": taRight
  else:
    raise newException(
      PmValueError,
      "unknown text align '" & s & "'; use left, center or right"
    )

proc parseLineStyle(s: string): LineStyle =
  case normalizeName(s)
  of "", "solid", "line": lsSolid
  of "dashed", "dash": lsDashed
  of "dotted", "dot": lsDotted
  else:
    raise newException(
      PmValueError,
      "unknown line style '" & s & "'; use solid, dashed or dotted"
    )

proc checkSnaplineSource(s: string) =
  case normalizeName(s)
  of "bottom", "center", "top": discard
  else:
    raise newException(
      PmValueError,
      "unknown snapline source '" & s & "'; use bottom, center or top"
    )

proc pyOrNone(o: PyObject): PPyObject =
  if o.isNil: newPyNone() else: nimValueToPy(o)

proc slot(o: PyObject, name: string): PyObject =
  if not pyIsInstance(o, "dict"):
    return tryGetAttr(o, name)
  let v = pyl.pyLib.PyDict_GetItemString(rawPy(o), cstring(name))
  if v.isNil:
    pyl.pyLib.PyErr_Clear()
    return nil
  asPy(v)

proc listAppend(l: PyObject, item: PyObject) =
  discard l.callMethod("append", item)

proc addItem(inst, item: PyObject): PPyObject =
  listAppend(getAttr(inst, "_items"), item)
  newPyNone()

proc itemFloat(item: PyObject, name: string): float =
  let v = slot(item, name)
  if v.isNil:
    return 0.0
  v.to(float)

proc itemInt(item: PyObject, name: string): int =
  let v = slot(item, name)
  if v.isNil:
    return 0
  v.to(int)

proc itemStr(item: PyObject, name: string): string =
  let v = slot(item, name)
  if v.isNil:
    return ""
  v.to(string)

proc itemBool(item: PyObject, name: string): bool =
  let v = slot(item, name)
  if v.isNil:
    return false
  v.to(bool)

proc slotFont(item: PyObject): PyObject =
  slot(item, "font")

proc slotOutlineColor(item: PyObject): PyObject =
  slot(item, "outline_color")

proc resolveOutline(custom: PyObject, color: int): int =
  if isNone(custom):
    darkened(color)
  else:
    custom.to(int)

proc derivedOutline(item: PyObject, color: int): int =
  resolveOutline(slotOutlineColor(item), color)

proc barAlpha(color: int): float =
  float(alphaOf(color)) / 255.0

proc barOutline(item: PyObject, color: int): int =
  let custom = slotOutlineColor(item)
  if isNone(custom):
    withAlpha(0x000000FF, barAlpha(color))
  else:
    custom.to(int)

proc defaultFont(): ptr rl.Font =
  if defaultFontData.isNil:
    defaultFontData = create(rl.Font)
    var raw = rl.getFontDefault()
    defaultFontData[] = move(raw)
  defaultFontData

proc fontPtrOf(o: PyObject): ptr rl.Font =
  if isNone(o) or not hasAttr(o, "_data"):
    raise newException(PmBadType, "expected a Font object")
  let raw = getAttr(o, "_data")
  if isNone(raw):
    raise newException(PmValueError, "font is closed")
  cast[ptr rl.Font](raw.to(int))

proc texturePtrOf(o: PyObject): ptr rl.Texture =
  if isNone(o) or not hasAttr(o, "_data"):
    raise newException(PmBadType, "expected a Texture object")
  let raw = getAttr(o, "_data")
  if isNone(raw):
    raise newException(PmValueError, "texture is closed")
  cast[ptr rl.Texture](raw.to(int))

proc fontData(o: PyObject): ptr rl.Font =
  if isNone(o):
    return defaultFont()
  fontPtrOf(o)

proc textureData(o: PyObject): ptr rl.Texture =
  texturePtrOf(o)

proc textSize(p: ptr rl.Font, text: string, size, spacing: float32): rl.Vector2 =
  if text.len == 0:
    return rl.Vector2(x: 0.0, y: 0.0)
  rl.measureText(p[], text, size, spacing)

proc textOrigin(x: float32, width: float32, align: TextAlign): float32 =
  case align
  of taLeft: x
  of taCenter: x - width / 2
  of taRight: x - width

proc drawTextLine(
  p: ptr rl.Font,
  text: string,
  x, y: float32,
  size, spacing: float32,
  color: int,
  align: TextAlign
) =
  if text.len == 0 or alphaOf(color) == 0:
    return
  let width = textSize(p, text, size, spacing).x
  rl.drawText(
    p[],
    text,
    rl.Vector2(x: textOrigin(x, width, align), y: y),
    size,
    spacing,
    rl.getColor(uint32(color))
  )

proc drawOutlinedTextLine(
  p: ptr rl.Font,
  text: string,
  x, y: float32,
  size, spacing: float32,
  color, outlineColor: int,
  outlineThick: float32,
  outlineOn: bool,
  align: TextAlign
) =
  if outlineOn and outlineThick > 0 and alphaOf(outlineColor) > 0:
    let
      width = textSize(p, text, size, spacing).x
      x0 = textOrigin(x, width, align)
      c = rl.getColor(uint32(outlineColor))
    for i in 0 ..< TextOutlineSteps:
      let angle = TwoPi * float32(i) / float32(TextOutlineSteps)
      rl.drawText(
        p[],
        text,
        rl.Vector2(
          x: x0 + cos(angle) * outlineThick,
          y: y + sin(angle) * outlineThick
        ),
        size,
        spacing,
        c
      )
  drawTextLine(p, text, x, y, size, spacing, color, align)

proc drawTextBlock(
  p: ptr rl.Font,
  text: string,
  x, y: float32,
  size, spacing: float32,
  color, outlineColor: int,
  outlineThick: float32,
  outlineOn: bool,
  align: TextAlign
) =
  let lines = text.split('\n')
  if lines.len == 1:
    drawOutlinedTextLine(
      p, text, x, y, size, spacing, color, outlineColor, outlineThick, outlineOn, align
    )
    return
  let
    measured = textSize(p, text, size, spacing)
    lineHeight = (measured.y - size) / float32(lines.len - 1)
  var lineY = y
  for line in lines:
    drawOutlinedTextLine(
      p, line, x, lineY, size, spacing, color, outlineColor, outlineThick, outlineOn, align
    )
    lineY += lineHeight

proc drawTextAt(
  p: ptr rl.Font,
  text: string,
  x, y: float32,
  size, spacing: float32,
  color: int,
  align: TextAlign
) =
  drawTextBlock(p, text, x, y, size, spacing, color, 0, 0.0, false, align)

proc drawOutlinedText(
  p: ptr rl.Font,
  text: string,
  x, y: float32,
  size, spacing: float32,
  color, outlineColor: int,
  outlineThick: float32,
  outlineOn: bool,
  align: TextAlign
) =
  drawTextBlock(p, text, x, y, size, spacing, color, outlineColor, outlineThick, outlineOn, align)

proc strokeRect(r: rl.Rectangle, thick: float32, c: rl.Color) =
  rl.drawRectangleLines(r, max(thick, 0.1), c)

proc expanded(r: rl.Rectangle, amount: float32): rl.Rectangle =
  rl.Rectangle(
    x: r.x - amount,
    y: r.y - amount,
    width: r.width + 2 * amount,
    height: r.height + 2 * amount
  )

proc shrunk(r: rl.Rectangle, amount: float32): rl.Rectangle =
  rl.Rectangle(
    x: r.x + amount,
    y: r.y + amount,
    width: max(r.width - 2 * amount, 0.0),
    height: max(r.height - 2 * amount, 0.0)
  )

proc cornerSegments(r: rl.Rectangle, length: float32): array[8, (rl.Vector2, rl.Vector2)] =
  let
    x1 = r.x
    y1 = r.y
    x2 = r.x + r.width
    y2 = r.y + r.height
    len = clamp(length, 0.0, min(r.width, r.height) / 2)
  result = [
    (rl.Vector2(x: x1, y: y1), rl.Vector2(x: x1 + len, y: y1)),
    (rl.Vector2(x: x1, y: y1), rl.Vector2(x: x1, y: y1 + len)),
    (rl.Vector2(x: x2, y: y1), rl.Vector2(x: x2 - len, y: y1)),
    (rl.Vector2(x: x2, y: y1), rl.Vector2(x: x2, y: y1 + len)),
    (rl.Vector2(x: x1, y: y2), rl.Vector2(x: x1 + len, y: y2)),
    (rl.Vector2(x: x1, y: y2), rl.Vector2(x: x1, y: y2 - len)),
    (rl.Vector2(x: x2, y: y2), rl.Vector2(x: x2 - len, y: y2)),
    (rl.Vector2(x: x2, y: y2), rl.Vector2(x: x2, y: y2 - len))
  ]

proc strokeCorners(
  r: rl.Rectangle,
  width, length: float32,
  c: rl.Color
) =
  let half = width / 2
  for (first, second) in cornerSegments(r, length):
    let
      dx = second.x - first.x
      dy = second.y - first.y
      span = sqrt(dx * dx + dy * dy)
    if span > 0:
      rl.drawLine(
        rl.Vector2(
          x: first.x - dx / span * half,
          y: first.y - dy / span * half
        ),
        second,
        width,
        c
      )

proc cornerLength(r: rl.Rectangle, width: float32): float32 =
  max(min(r.width, r.height) * CornerShare, width * 2)

proc strokeBox(r: rl.Rectangle, style: BoxStyle, thick: float32, c: rl.Color) =
  if style == bsCorner:
    let width = max(thick, 0.1)
    strokeCorners(r, width, cornerLength(r, width), c)
  else:
    strokeRect(r, thick, c)

proc strokeBoxHalo(
  r: rl.Rectangle,
  style: BoxStyle,
  thick, outline: float32,
  c: rl.Color
) =
  if style == bsCorner:
    let
      width = max(thick, 0.1)
      halo = width + 2 * outline
      length = cornerLength(r, width)
    strokeCorners(r, halo, length, c)
    for (_, second) in cornerSegments(r, length):
      rl.drawCircle(second, halo / 2, c)
  else:
    strokeBox(expanded(r, outline), style, thick + 2 * outline, c)

proc rotatedCorners(
  r: rl.Rectangle,
  rotation: float32,
  origin: rl.Vector2
): array[4, rl.Vector2] =
  let
    rad = rotation * DegToRad
    co = cos(rad)
    si = sin(rad)
    corners = [
      rl.Vector2(x: r.x, y: r.y),
      rl.Vector2(x: r.x + r.width, y: r.y),
      rl.Vector2(x: r.x + r.width, y: r.y + r.height),
      rl.Vector2(x: r.x, y: r.y + r.height)
    ]
  for i in 0 ..< 4:
    let
      dx = corners[i].x - origin.x
      dy = corners[i].y - origin.y
    result[i] = rl.Vector2(
      x: origin.x + dx * co - dy * si,
      y: origin.y + dx * si + dy * co
    )

proc strokeLine(a, b: rl.Vector2, width: float32, c: rl.Color) =
  if width <= 1.0:
    rl.drawLine(a, b, c)
  else:
    rl.drawLine(a, b, width, c)

proc strokeDot(p: rl.Vector2, width: float32, c: rl.Color) =
  if width > 0:
    rl.drawCircle(p, width / 2, c)

proc extendPoint(p, toward: rl.Vector2, amount: float32): rl.Vector2 =
  let
    dx = p.x - toward.x
    dy = p.y - toward.y
    span = sqrt(dx * dx + dy * dy)
  if span <= 0:
    return p
  rl.Vector2(x: p.x + dx / span * amount, y: p.y + dy / span * amount)

proc strokePathHalo(
  pts: seq[rl.Vector2],
  width, outline: float32,
  c: rl.Color
) =
  if pts.len < 2:
    return
  let halo = width + 2 * outline
  for i in 0 ..< pts.len - 1:
    var
      a = pts[i]
      b = pts[i + 1]
    if i == 0:
      a = extendPoint(a, b, outline)
    if i == pts.len - 2:
      b = extendPoint(b, a, outline)
    strokeLine(a, b, halo, c)
  for i in 1 ..< pts.len - 1:
    strokeDot(pts[i], halo, c)

proc strokePath(
  pts: seq[rl.Vector2],
  width: float32,
  c: rl.Color,
  closed = false,
  joins = false
) =
  if pts.len < 2:
    return
  if closed:
    for i in 0 ..< pts.len:
      strokeLine(pts[i], pts[(i + 1) mod pts.len], width, c)
    if joins:
      for p in pts:
        strokeDot(p, width, c)
  else:
    if width <= 1.0:
      rl.drawLineStrip(pts, c)
    else:
      for i in 0 ..< pts.len - 1:
        strokeLine(pts[i], pts[i + 1], width, c)
    if joins:
      for i in 1 ..< pts.len - 1:
        strokeDot(pts[i], width, c)

proc rotatedPoint(
  p, origin: rl.Vector2,
  cosA, sinA: float32
): rl.Vector2 =
  let
    dx = p.x - origin.x
    dy = p.y - origin.y
  rl.Vector2(x: origin.x + dx * cosA - dy * sinA, y: origin.y + dx * sinA + dy * cosA)

proc roundedRectPoints(
  r: rl.Rectangle,
  roundness, rotation: float32,
  segments: int32
): seq[rl.Vector2] =
  let
    radius = min(max(roundness, 0.0), 1.0) * min(r.width, r.height) / 2
    count = max(int(segments), 4)
  if radius <= 0:
    result = @[
      rl.Vector2(x: r.x, y: r.y),
      rl.Vector2(x: r.x + r.width, y: r.y),
      rl.Vector2(x: r.x + r.width, y: r.y + r.height),
      rl.Vector2(x: r.x, y: r.y + r.height)
    ]
  else:
    let corners = [
      (rl.Vector2(x: r.x + radius, y: r.y + radius), 180.0'f32),
      (rl.Vector2(x: r.x + r.width - radius, y: r.y + radius), 270.0'f32),
      (rl.Vector2(x: r.x + r.width - radius, y: r.y + r.height - radius), 0.0'f32),
      (rl.Vector2(x: r.x + radius, y: r.y + r.height - radius), 90.0'f32)
    ]
    for (corner, start) in corners:
      for i in 0 .. count:
        let angle = (start + 90.0 * float32(i) / float32(count)) * DegToRad
        result.add rl.Vector2(
          x: corner.x + cos(angle) * radius,
          y: corner.y + sin(angle) * radius
        )
  if rotation != 0.0:
    let
      origin = rl.Vector2(x: r.x + r.width / 2, y: r.y + r.height / 2)
      rad = rotation * DegToRad
      cosA = cos(rad)
      sinA = sin(rad)
    for p in result.mitems:
      p = rotatedPoint(p, origin, cosA, sinA)
  result.reverse()

proc strokeRectShape(
  r: rl.Rectangle,
  thick, roundness: float32,
  count: int32,
  rotation: float32,
  c: rl.Color
) =
  let width = max(thick, 0.1)
  if rotation != 0.0:
    strokePath(roundedRectPoints(r, roundness, rotation, count), width, c, true, true)
  elif roundness > 0:
    rl.drawRectangleRoundedLines(r, min(roundness, 1.0), count, width, c)
  else:
    rl.drawRectangleLines(r, width, c)

proc fillRectShape(
  r: rl.Rectangle,
  roundness: float32,
  count: int32,
  rotation: float32,
  c: rl.Color
) =
  if rotation != 0.0:
    if roundness > 0:
      rl.drawTriangleFan(roundedRectPoints(r, roundness, rotation, count), c)
    else:
      rl.drawRectangle(r, rl.Vector2(x: r.width / 2, y: r.height / 2), rotation, c)
  elif roundness > 0:
    rl.drawRectangleRounded(r, min(roundness, 1.0), count, c)
  else:
    rl.drawRectangle(r, c)

proc rectBorder(
  r: rl.Rectangle,
  thick, roundness: float32,
  count: int32,
  rotation: float32,
  c: rl.Color
) =
  if rotation != 0.0:
    strokeRectShape(expanded(r, thick / 2), thick, roundness, count, rotation, c)
  elif roundness > 0:
    strokeRectShape(r, thick, roundness, count, 0.0, c)
  else:
    strokeRectShape(expanded(r, thick), thick, 0.0, count, 0.0, c)

proc rectHalo(
  r: rl.Rectangle,
  thick, outline, roundness: float32,
  count: int32,
  rotation: float32,
  c: rl.Color
) =
  if rotation != 0.0:
    strokeRectShape(r, thick + 2 * outline, roundness, count, rotation, c)
  elif roundness > 0:
    strokeRectShape(shrunk(r, outline), thick + 2 * outline, roundness, count, 0.0, c)
  else:
    strokeRectShape(expanded(r, outline), thick + 2 * outline, 0.0, count, 0.0, c)

proc ellipsePoints(center: rl.Vector2, rx, ry: float32): seq[rl.Vector2] =
  for i in 0 ..< 64:
    let angle = TwoPi * float32(i) / 64.0
    result.add rl.Vector2(
      x: center.x + cos(angle) * rx,
      y: center.y + sin(angle) * ry
    )

proc strokeEllipse(center: rl.Vector2, rx, ry, width: float32, c: rl.Color) =
  strokePath(ellipsePoints(center, rx, ry), width, c, true)

proc anglePoint(center: rl.Vector2, radius, degrees: float32): rl.Vector2 =
  let rad = degrees * DegToRad
  rl.Vector2(x: center.x + cos(rad) * radius, y: center.y + sin(rad) * radius)

proc strokeRadial(
  center: rl.Vector2,
  inner, outer, degrees, width: float32,
  c: rl.Color
) =
  strokeLine(
    anglePoint(center, inner, degrees),
    anglePoint(center, outer, degrees),
    width,
    c
  )

proc polygonPoints(
  center: rl.Vector2,
  sides: int32,
  radius, rotation: float32
): seq[rl.Vector2] =
  for i in 0 ..< int(sides):
    result.add anglePoint(
      center,
      radius,
      rotation + 360.0 * float32(i) / float32(sides)
    )

proc strokeSector(
  center: rl.Vector2,
  radius, start, stop, width: float32,
  count: int32,
  c: rl.Color
) =
  var
    first = start
    last = stop
  if first == last:
    return
  if last < first:
    swap(first, last)
  let segments = max(int(count), 16)
  var arc: seq[rl.Vector2]
  for i in 0 .. segments:
    arc.add anglePoint(
      center,
      radius,
      first + (last - first) * float32(i) / float32(segments)
    )
  strokeLine(center, arc[0], width, c)
  strokeLine(center, arc[^1], width, c)
  strokePath(arc, width, c)
  if last - first < 360.0:
    for p in [center, arc[0], arc[^1]]:
      strokeDot(p, width, c)

proc anchorPoint(kind: string, r: rl.Rectangle): rl.Vector2 =
  let
    left = r.x
    right = r.x + r.width
    top = r.y
    bottom = r.y + r.height
    midX = r.x + r.width / 2
    midY = r.y + r.height / 2
  case normalizeName(kind)
  of "topleft": rl.Vector2(x: left, y: top)
  of "top": rl.Vector2(x: midX, y: top)
  of "topright": rl.Vector2(x: right, y: top)
  of "left": rl.Vector2(x: left, y: midY)
  of "right": rl.Vector2(x: right, y: midY)
  of "bottomleft": rl.Vector2(x: left, y: bottom)
  of "bottom", "": rl.Vector2(x: midX, y: bottom)
  of "bottomright": rl.Vector2(x: right, y: bottom)
  else:
    raise newException(
      PmValueError,
      "unknown anchor '" & kind & "'; use top-left, top, top-right, left, right, " &
        "bottom-left, bottom or bottom-right"
    )

proc textAnchorOrigin(anchor: string, r: rl.Rectangle, width, height, gap: float32): rl.Vector2 =
  let
    key = normalizeName(anchor)
    left = r.x
    right = r.x + r.width
    top = r.y
    bottom = r.y + r.height
    midX = r.x + r.width / 2
    midY = r.y + r.height / 2
  var
    x = midX - width / 2
    y = top - gap - height
  case key
  of "topleft":
    x = left
    y = top - gap - height
  of "top":
    x = midX - width / 2
    y = top - gap - height
  of "topright":
    x = right - width
    y = top - gap - height
  of "left":
    x = left - gap - width
    y = midY - height / 2
  of "right":
    x = right + gap
    y = midY - height / 2
  of "bottomleft":
    x = left
    y = bottom + gap
  of "bottom", "":
    x = midX - width / 2
    y = bottom + gap
  of "bottomright":
    x = right - width
    y = bottom + gap
  else:
    raise newException(
      PmValueError,
      "unknown anchor '" & anchor & "'; use top-left, top, top-right, left, right, " &
        "bottom-left, bottom or bottom-right"
    )
  rl.Vector2(x: x, y: y)

proc anchorAlign(anchor: string): TextAlign =
  case normalizeName(anchor)
  of "topleft", "left", "bottomleft": taLeft
  of "topright", "right", "bottomright": taRight
  else: taCenter

proc drawDashed(a, b: rl.Vector2, thick: float32, c: rl.Color, dash, gap: float32) =
  let
    delta = rl.Vector2(x: b.x - a.x, y: b.y - a.y)
    span = sqrt(delta.x * delta.x + delta.y * delta.y)
  if span <= 0:
    return
  let
    ux = delta.x / span
    uy = delta.y / span
    step = max(dash + gap, 0.5)
  var offset = 0.0'f32
  while offset < span:
    let stop = min(offset + dash, span)
    rl.drawLine(
      rl.Vector2(x: a.x + ux * offset, y: a.y + uy * offset),
      rl.Vector2(x: a.x + ux * stop, y: a.y + uy * stop),
      thick,
      c
    )
    offset += step

proc dashPattern(style: LineStyle, thick, spacing: float32): tuple[dash, gap: float32] =
  let gap = max(spacing, 0.0)
  case style
  of lsSolid:
    (0.0'f32, 0.0'f32)
  of lsDashed:
    (max(thick * 6, 8.0), if gap > 0: gap else: max(thick * 4, 6.0))
  of lsDotted:
    (max(thick, 2.0), if gap > 0: gap else: max(thick * 3, 6.0))

proc drawStyledLine(
  a, b: rl.Vector2,
  style: LineStyle,
  thick: float32,
  c: rl.Color,
  dash, gap: float32
) =
  case style
  of lsSolid:
    rl.drawLine(a, b, thick, c)
  of lsDashed, lsDotted:
    drawDashed(a, b, thick, c, dash, gap)

proc checkOverlay(op: string) =
  if not rl.isWindowReady():
    raise newException(PmOverlayError, op & ": no overlay is open")

proc glyphCodepoints(chars: string): seq[int32] =
  case normalizeName(chars)
  of "", "latin":
    for cp in 0x20'i32 .. 0xFF'i32:
      result.add cp
  of "cyrillic":
    for cp in 0x20'i32 .. 0x7F'i32:
      result.add cp
    for cp in 0x400'i32 .. 0x4FF'i32:
      result.add cp
  of "greek":
    for cp in 0x20'i32 .. 0x7F'i32:
      result.add cp
    for cp in 0x370'i32 .. 0x3FF'i32:
      result.add cp
  of "all":
    for cp in 0x20'i32 .. 0x2FFF'i32:
      result.add cp
  else:
    for r in runes(chars):
      result.add int32(r)

proc makeFontPy(data: ptr rl.Font, key: string): PyObject =
  ensureDrawTypes()
  let inst = objectNew(fontClass)
  setPyAttr(inst, "_data", nimValueToPy(cast[int](data)))
  setPyAttr(inst, "_key", nimValueToPy(key))
  fontHandles.add inst
  inst

proc systemFontFiles(): seq[string] =
  for dir in systemFontDirs():
    if not dirExists(dir):
      continue
    try:
      for path in walkDirRec(dir):
        let ext = splitFile(path).ext.toLowerAscii()
        if ext == ".ttf" or ext == ".otf":
          result.add path
    except CatchableError:
      discard

proc findSystemFont(name: string): string =
  let
    wanted = name.toLowerAscii()
    hasExt = wanted.endsWith(".ttf") or wanted.endsWith(".otf")
  var matches: seq[string]
  for path in systemFontFiles():
    let file = extractFilename(path).toLowerAscii()
    if file == wanted or (not hasExt and (file == wanted & ".ttf" or file == wanted & ".otf")):
      matches.add path
  if matches.len > 0:
    matches.sort()
    result = matches[0]

proc resolveFontPath(path: string): string =
  let direct = absolutePath(path)
  if fileExists(direct):
    return direct
  if path.contains(DirSep) or path.contains(AltSep):
    return direct
  findSystemFont(path)

proc loadFontFile(path: string, size: int, chars: string): PyObject =
  if size <= 0:
    raise newException(PmValueError, "font size must be positive")
  let
    target = resolveFontPath(path)
    key = target & "\x1f" & $size & "\x1f" & chars
    cached = fontCache.getOrDefault(key)
  if not cached.isNil:
    return cached
  checkOverlay("load_font")
  if target.len == 0 or not fileExists(target):
    raise newException(PmValueError, "font not found: '" & path & "'")
  let codepoints = glyphCodepoints(chars)
  var raw: rl.Font
  try:
    raw = rl.loadFont(target, int32(size), codepoints)
  except RaylibError as e:
    raise newException(PmOverlayError, "cannot load font '" & path & "': " & e.msg)
  let data = create(rl.Font)
  data[] = move(raw)
  result = makeFontPy(data, key)
  fontCache[key] = result

proc loadFontBuffer(data: seq[uint8], size: int, chars: string, kind: string): PyObject =
  if size <= 0:
    raise newException(PmValueError, "font size must be positive")
  checkOverlay("load_font_bytes")
  let
    ext = if kind.len == 0: ".ttf" else: (if kind.startsWith("."): kind else: "." & kind)
    codepoints = glyphCodepoints(chars)
  var raw: rl.Font
  try:
    raw = rl.loadFontFromMemory(ext, data, int32(size), codepoints)
  except RaylibError as e:
    raise newException(PmOverlayError, "cannot load font from memory: " & e.msg)
  let handleData = create(rl.Font)
  handleData[] = move(raw)
  makeFontPy(handleData, "")

proc makeTexturePy(data: ptr rl.Texture): PyObject =
  ensureDrawTypes()
  let inst = objectNew(textureClass)
  setPyAttr(inst, "_data", nimValueToPy(cast[int](data)))
  textureHandles.add inst
  inst

proc loadTextureFile(path: string): PyObject =
  checkOverlay("load_texture")
  let target = absolutePath(path)
  if not fileExists(target):
    raise newException(PmValueError, "texture file not found: '" & path & "'")
  var raw: rl.Texture
  try:
    raw = rl.loadTexture(target)
  except RaylibError as e:
    raise newException(PmOverlayError, "cannot load texture '" & path & "': " & e.msg)
  let data = create(rl.Texture)
  data[] = move(raw)
  makeTexturePy(data)

proc loadTextureBuffer(kind: string, payload: PyObject): PyObject =
  checkOverlay("load_texture_bytes")
  let
    ext = if kind.len == 0: ".png" else: (if kind.startsWith("."): kind else: "." & kind)
    bytes = payload.to(seq[uint8])
  if bytes.len == 0:
    raise newException(PmValueError, "texture data must not be empty")
  var raw: rl.Texture
  try:
    var image = rl.loadImageFromMemory(ext, bytes)
    raw = rl.loadTextureFromImage(image)
    wasMoved(image)
  except RaylibError as e:
    raise newException(PmOverlayError, "cannot load texture from memory: " & e.msg)
  let data = create(rl.Texture)
  data[] = move(raw)
  makeTexturePy(data)

proc fontSizeImpl(self: PyObject): int =
  int(fontPtrOf(self)[].baseSize)

proc releaseFont(data: ptr rl.Font) =
  var owned = move(data[])
  discard owned

proc fontCloseImpl(self: PyObject) =
  if isNone(self) or not hasAttr(self, "_data"):
    return
  let raw = getAttr(self, "_data")
  if isNone(raw):
    return
  let data = cast[ptr rl.Font](raw.to(int))
  setPyAttr(self, "_data", newPyNone())
  if data != nil:
    if data[].texture.id > 0:
      releaseFont(data)
    dealloc(data)
  let key = tryGetAttr(self, "_key")
  if not isNone(key) and key.to(string).len > 0:
    fontCache.del(key.to(string))
    setPyAttr(self, "_key", newPyNone())
  forgetHandle(fontHandles, self)

proc fontFilterImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let
      data = fontPtrOf(argAt(args, 0))
      name = methodStr(args, kwargs, 1, "filter", "bilinear")
      filter = case normalizeName(name)
      of "point", "nearest": rl.TextureFilter.Point
      of "bilinear", "linear", "": rl.TextureFilter.Bilinear
      of "trilinear": rl.TextureFilter.Trilinear
      of "anisotropic4x", "aniso4x": rl.TextureFilter.Anisotropic4x
      of "anisotropic8x", "aniso8x": rl.TextureFilter.Anisotropic8x
      of "anisotropic16x", "aniso16x": rl.TextureFilter.Anisotropic16x
      else:
        raise newException(
          PmValueError,
          "unknown texture filter '" & name & "'; use point, bilinear, trilinear or anisotropic"
        )
    rl.setTextureFilter(data[].texture, filter)
    newPyNone()

proc fontReprImpl(self: PyObject): string =
  if isNone(self) or not hasAttr(self, "_data"):
    return "Font(closed)"
  let raw = getAttr(self, "_data")
  if isNone(raw):
    "Font(closed)"
  else:
    "Font(size=" & $cast[ptr rl.Font](raw.to(int))[].baseSize & ")"

proc fontTextImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    checkOverlay("font.text")
    let
      data = fontPtrOf(argAt(args, 0))
      text = methodText(args, kwargs, 1, "text", "")
      x = methodFloat(args, kwargs, 2, "x", 0.0).float32
      y = methodFloat(args, kwargs, 3, "y", 0.0).float32
      size = methodFloat(args, kwargs, 4, "size", 20.0).float32
      color = methodColor(args, kwargs, 5, "color", DefaultColor)
      align = parseAlign(methodStr(args, kwargs, 6, "align", "left"))
    drawTextAt(data, text, x, y, size, 1.0, color, align)
    newPyNone()

proc fontMeasureImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    checkOverlay("font.measure")
    let
      data = fontPtrOf(argAt(args, 0))
      text = methodText(args, kwargs, 1, "text", "")
      size = methodFloat(args, kwargs, 2, "size", 20.0).float32
      spacing = methodFloat(args, kwargs, 3, "spacing", 1.0).float32
      measured = textSize(data, text, size, spacing)
    nimValueToPy(newVec2(measured))

proc textureWidthImpl(self: PyObject): int =
  int(texturePtrOf(self)[].width)

proc textureHeightImpl(self: PyObject): int =
  int(texturePtrOf(self)[].height)

proc releaseTexture(data: ptr rl.Texture) =
  var owned = move(data[])
  discard owned

proc textureCloseImpl(self: PyObject) =
  if isNone(self) or not hasAttr(self, "_data"):
    return
  let raw = getAttr(self, "_data")
  if isNone(raw):
    return
  let data = cast[ptr rl.Texture](raw.to(int))
  setPyAttr(self, "_data", newPyNone())
  if data != nil:
    if data[].id > 0:
      releaseTexture(data)
    dealloc(data)
  forgetHandle(textureHandles, self)

proc resetDrawState*() =
  let
    fonts = fontHandles
    textures = textureHandles
  fontHandles = @[]
  textureHandles = @[]
  fontCache.clear()
  currentFont = nil
  for handle in fonts:
    fontCloseImpl(handle)
  for handle in textures:
    textureCloseImpl(handle)
  if defaultFontData != nil:
    dealloc(defaultFontData)
    defaultFontData = nil

proc textureReprImpl(self: PyObject): string =
  if isNone(self) or not hasAttr(self, "_data"):
    return "Texture(closed)"
  let raw = getAttr(self, "_data")
  if isNone(raw):
    "Texture(closed)"
  else:
    let data = cast[ptr rl.Texture](raw.to(int))
    "Texture(" & $data[].width & "x" & $data[].height & ")"

proc boxRect(self: PyObject): rl.Rectangle =
  rl.Rectangle(
    x: itemFloat(self, "x").float32,
    y: itemFloat(self, "y").float32,
    width: itemFloat(self, "w").float32,
    height: itemFloat(self, "h").float32
  )

proc boxReprImpl(self: PyObject): string =
  "EntityBox(" & $itemFloat(self, "x") & ", " & $itemFloat(self, "y") & ", " &
    $itemFloat(self, "w") & ", " & $itemFloat(self, "h") & ")"

proc barPart(
  bar: rl.Rectangle,
  cursor, size: float32,
  horizontal, fromEnd: bool
): rl.Rectangle =
  if horizontal:
    rl.Rectangle(
      x: (if fromEnd: cursor - size else: cursor),
      y: bar.y,
      width: size,
      height: bar.height
    )
  else:
    rl.Rectangle(
      x: bar.x,
      y: (if fromEnd: cursor - size else: cursor),
      width: bar.width,
      height: size
    )

proc alignedStart(start, total, span: float32, align, near, far: string): float32 =
  if align == near: start
  elif align == far: start + total - span
  else: start + (total - span) / 2

proc drawBarItem(item: PyObject, r: rl.Rectangle) =
  let
    side = normalizeName(itemStr(item, "side"))
    color = itemInt(item, "color")
    value = clamp(itemFloat(item, "value"), 0.0, 1.0).float32
    thick = max(itemFloat(item, "thick"), 0.5).float32
    gap = itemFloat(item, "gap").float32
    length = clamp(itemFloat(item, "length"), 0.0, 1.0).float32
    align = normalizeName(itemStr(item, "align"))
    reverse = itemBool(item, "reverse")
    outlineOn = itemBool(item, "outline")
    outlineThick = itemFloat(item, "outline_thick").float32
    index = itemInt(item, "index")
    offset = gap + float32(index) * (thick + gap)
  var
    bar: rl.Rectangle
    horizontal = false
  case side
  of "left", "right":
    let
      span = r.height * length
      x = if side == "left": r.x - offset - thick else: r.x + r.width + offset
    bar = rl.Rectangle(
      x: x,
      y: alignedStart(r.y, r.height, span, align, "top", "bottom"),
      width: thick,
      height: span
    )
  of "top", "bottom":
    let
      span = r.width * length
      y = if side == "top": r.y - offset - thick else: r.y + r.height + offset
    bar = rl.Rectangle(
      x: alignedStart(r.x, r.width, span, align, "left", "right"),
      y: y,
      width: span,
      height: thick
    )
    horizontal = true
  else:
    raise newException(
      PmValueError,
      "unknown bar side '" & side & "'; use top, bottom, left or right"
    )
  if alphaOf(color) == 0:
    return
  let outlineColor = barOutline(item, color)
  if outlineOn and outlineThick > 0 and alphaOf(outlineColor) > 0:
    rectBorder(bar, outlineThick, 0.0, 0, 0.0, rl.getColor(uint32(outlineColor)))
  rl.drawRectangle(bar, rl.getColor(uint32(withAlpha(0x000000FF, barAlpha(color) * 0.35))))
  if value <= 0:
    return
  let
    total = if horizontal: bar.width else: bar.height
    fillLen = total * value
    fromEnd = if horizontal: reverse else: not reverse
    origin = if fromEnd:
      (if horizontal: bar.x + bar.width else: bar.y + bar.height)
    else:
      (if horizontal: bar.x else: bar.y)
  var cursor = origin

  template drawPart(size: float32, partColor: int) =
    if size > 0:
      rl.drawRectangle(
        barPart(bar, cursor, size, horizontal, fromEnd),
        rl.getColor(uint32(partColor))
      )
      cursor += (if fromEnd: -size else: size)

  let segments = slot(item, "segments")
  if isNone(segments) or not isSeq(segments):
    drawPart(fillLen, color)
    return
  var used = 0.0'f32
  for i in 0 ..< seqLen(segments):
    let entry = segments[i]
    if not isSeq(entry) or seqLen(entry) < 1:
      raise newException(PmBadType, "bar segments must be (fraction, color) pairs")
    let
      fraction = clamp(entry[0].to(float), 0.0, 1.0).float32
      segColor =
        if seqLen(entry) > 1 and not isNone(entry[1]): entry[1].to(int)
        else: color
      part = fillLen * fraction
    if part <= 0:
      continue
    drawPart(part, segColor)
    used += fraction
  drawPart(clamp(1.0 - used, 0.0, 1.0) * fillLen, color)

proc drawTextItem(item: PyObject, r: rl.Rectangle) =
  let
    text = itemStr(item, "text")
    color = itemInt(item, "color")
    size = max(itemFloat(item, "size"), 1.0).float32
    gap = itemFloat(item, "gap").float32
    nudgeX = itemFloat(item, "nudge_x").float32
    nudgeY = itemFloat(item, "nudge_y").float32
    outlineOn = itemBool(item, "outline")
    outlineThick = itemFloat(item, "outline_thick").float32
    font = slotFont(item)
    p = fontData(if isNone(font): currentFont else: font)
    outlineColor = derivedOutline(item, color)
    anchor = itemStr(item, "anchor")
    align = anchorAlign(anchor)
    measured = textSize(p, text, size, 1.0)
    origin = textAnchorOrigin(anchor, r, measured.x, measured.y, gap)
    anchorX = case align
      of taLeft: origin.x
      of taCenter: origin.x + measured.x / 2
      of taRight: origin.x + measured.x
  drawOutlinedText(
    p,
    text,
    anchorX + nudgeX,
    origin.y + nudgeY,
    size,
    1.0,
    color,
    outlineColor,
    outlineThick,
    outlineOn,
    align
  )

proc drawSnaplineItem(item: PyObject, r: rl.Rectangle) =
  let
    color = itemInt(item, "color")
    thick = max(itemFloat(item, "thick"), 0.5).float32
    outlineOn = itemBool(item, "outline")
    outlineThick = itemFloat(item, "outline_thick").float32
    style = parseLineStyle(itemStr(item, "style"))
    screenWidth = rl.getScreenWidth().float32
    screenHeight = rl.getScreenHeight().float32
    target = anchorPoint(itemStr(item, "to"), r)
    start = case normalizeName(itemStr(item, "source"))
      of "bottom": rl.Vector2(x: screenWidth / 2, y: screenHeight)
      of "center": rl.Vector2(x: screenWidth / 2, y: screenHeight / 2)
      of "top": rl.Vector2(x: screenWidth / 2, y: 0.0)
      else:
        raise newException(
          PmValueError,
          "unknown snapline source '" & itemStr(item, "source") &
            "'; use bottom, center or top"
        )
    outlineColor = derivedOutline(item, color)
    (dash, gap) = dashPattern(style, thick, itemFloat(item, "spacing").float32)
  if outlineOn and outlineThick > 0 and alphaOf(outlineColor) > 0:
    drawStyledLine(
      start, target, style, thick + 2 * outlineThick, rl.getColor(uint32(outlineColor)), dash, gap
    )
  if alphaOf(color) > 0:
    drawStyledLine(start, target, style, thick, rl.getColor(uint32(color)), dash, gap)

proc drawBox(inst: PyObject) =
  let
    r = boxRect(inst)
    color = itemInt(inst, "color")
    style = parseStyle(itemStr(inst, "style"))
    fill = clampFactor(itemFloat(inst, "fill"))
    thick = max(itemFloat(inst, "thick"), 0.1).float32
    outlineOn = itemBool(inst, "outline")
    outlineThick = max(itemFloat(inst, "outline_thick"), 0.0).float32
    outlineColor = derivedOutline(inst, color)
  if style == bsFilled:
    if outlineActive(outlineOn, outlineThick, outlineColor):
      rectBorder(r, outlineThick, 0.0, 0, 0.0, rl.getColor(uint32(outlineColor)))
    if alphaOf(color) > 0:
      rl.drawRectangle(r, rl.getColor(uint32(color)))
  else:
    if fill > 0 and alphaOf(color) > 0:
      rl.drawRectangle(r, rl.getColor(uint32(withAlpha(color, fill))))
    if outlineActive(outlineOn, outlineThick, outlineColor):
      strokeBoxHalo(r, style, thick, outlineThick, rl.getColor(uint32(outlineColor)))
    if alphaOf(color) > 0:
      strokeBox(r, style, thick, rl.getColor(uint32(color)))
  let items = tryGetAttr(inst, "_items")
  if items.isNil:
    return
  for i in 0 ..< seqLen(items):
    let item = items[i]
    case itemStr(item, "kind")
    of "bar": drawBarItem(item, r)
    of "text": drawTextItem(item, r)
    of "snapline": drawSnaplineItem(item, r)
    else: discard

proc entityBoxDrawImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    checkOverlay("EntityBox.draw")
    drawBox(argAt(args, 0))
    newPyNone()

proc entityBoxClearImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let empty = newPyListOf(newSeq[PyObject]())
    setPyAttr(argAt(args, 0), "_items", nimValueToPy(empty))
    newPyNone()

proc entityBoxSetBoxImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let
      inst = argAt(args, 0)
      x = methodFloat(args, kwargs, 1, "x", 0.0)
      y = methodFloat(args, kwargs, 2, "y", 0.0)
      w = methodFloat(args, kwargs, 3, "w", 0.0)
      h = methodFloat(args, kwargs, 4, "h", 0.0)
    if w < 0 or h < 0:
      raise newException(PmValueError, "box size must not be negative")
    setPyAttr(inst, "x", nimValueToPy(x))
    setPyAttr(inst, "y", nimValueToPy(y))
    setPyAttr(inst, "w", nimValueToPy(w))
    setPyAttr(inst, "h", nimValueToPy(h))
    newPyNone()

proc barCountOnSide(inst: PyObject, side: string): int =
  let items = tryGetAttr(inst, "_items")
  if items.isNil:
    return 0
  for i in 0 ..< seqLen(items):
    let item = items[i]
    if itemStr(item, "kind") == "bar" and itemStr(item, "side") == side:
      inc result

proc entityBoxAddBarImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let
      inst = argAt(args, 0)
      side = normalizeName(methodStr(args, kwargs, 1, "side", ""))
      color = methodColor(args, kwargs, 2, "color", DefaultColor)
      value = methodFloat(args, kwargs, 3, "value", 1.0)
      thick = methodFloat(args, kwargs, 4, "thick", 4.0)
      gap = methodFloat(args, kwargs, 5, "gap", 6.0)
      segments = methodOptional(args, kwargs, 6, "segments")
      length = methodFloat(args, kwargs, 7, "length", 1.0)
      align = methodStr(args, kwargs, 8, "align", "center")
      reverse = methodBool(args, kwargs, 9, "reverse", false)
      outlineOn = methodBool(args, kwargs, 10, "outline", true)
      outlineColor = methodOptional(args, kwargs, 11, "outline_color")
      outlineThick = methodFloat(args, kwargs, 12, "outline_thick", 1.0)
      maxValue = methodFloat(args, kwargs, 13, "max", 1.0)
      item = pyDict()
      index = barCountOnSide(inst, side)
    if side notin ["left", "right", "top", "bottom"]:
      raise newException(
        PmValueError,
        "unknown bar side '" & side & "'; use top, bottom, left or right"
      )
    if thick <= 0:
      raise newException(PmValueError, "thick must be positive")
    if maxValue <= 0 or maxValue.isNaN:
      raise newException(PmValueError, "max must be positive")
    if not isNone(segments):
      if not isSeq(segments):
        raise newException(PmBadType, "segments must be a list of (fraction, color) pairs")
      item["segments"] = segments
    item["kind"] = "bar"
    item["side"] = side
    item["color"] = color
    item["value"] = value / maxValue
    item["thick"] = thick
    item["gap"] = gap
    item["length"] = length
    item["align"] = align
    item["reverse"] = reverse
    item["outline"] = outlineOn
    item["outline_thick"] = outlineThick
    item["index"] = index
    if not isNone(outlineColor):
      item["outline_color"] = outlineColor
    addItem(inst, item)

proc entityBoxAddTextImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let
      inst = argAt(args, 0)
      anchor = methodStr(args, kwargs, 1, "anchor", "top")
      value = textLines(param(args, kwargs, 2, "text"))
      color = methodColor(args, kwargs, 3, "color", DefaultColor)
      size = methodFloat(args, kwargs, 4, "size", 12.0)
      font = methodOptional(args, kwargs, 5, "font")
      gap = methodFloat(args, kwargs, 6, "gap", 0.0)
      nudge = methodOptional(args, kwargs, 7, "nudge")
      outlineOn = methodBool(args, kwargs, 8, "outline", true)
      outlineColor = methodOptional(args, kwargs, 9, "outline_color")
      outlineThick = methodFloat(args, kwargs, 10, "outline_thick", 1.0)
      item = pyDict()
      nudgePoint =
        if isNone(nudge): rl.Vector2(x: 0.0, y: 0.0)
        else: pointOf(nudge)
    discard anchorPoint(anchor, rl.Rectangle(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
    if size <= 0:
      raise newException(PmValueError, "size must be positive")
    item["kind"] = "text"
    item["anchor"] = anchor
    item["text"] = value
    item["color"] = color
    item["size"] = size
    item["gap"] = gap
    item["nudge_x"] = float(nudgePoint.x)
    item["nudge_y"] = float(nudgePoint.y)
    item["outline"] = outlineOn
    item["outline_thick"] = outlineThick
    if not isNone(font):
      item["font"] = font
    if not isNone(outlineColor):
      item["outline_color"] = outlineColor
    addItem(inst, item)

proc entityBoxAddSnaplineImpl(self, args, kwargs: PPyObject): PPyObject {.cdecl.} =
  pyWrap:
    let
      inst = argAt(args, 0)
      target = methodStr(args, kwargs, 1, "to", "bottom")
      color = methodColor(args, kwargs, 2, "color", DefaultColor)
      source = methodStr(args, kwargs, 3, "source", "bottom")
      style = methodStr(args, kwargs, 4, "style", "solid")
      thick = methodFloat(args, kwargs, 5, "thick", 1.0)
      spacing = methodFloat(args, kwargs, 6, "spacing", 0.0)
      outlineOn = methodBool(args, kwargs, 7, "outline", true)
      outlineColor = methodOptional(args, kwargs, 8, "outline_color")
      outlineThick = methodFloat(args, kwargs, 9, "outline_thick", 1.0)
      item = pyDict()
    discard anchorPoint(target, rl.Rectangle(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
    checkSnaplineSource(source)
    discard parseLineStyle(style)
    if thick <= 0:
      raise newException(PmValueError, "thick must be positive")
    if spacing < 0:
      raise newException(PmValueError, "spacing must not be negative")
    item["kind"] = "snapline"
    item["to"] = target
    item["color"] = color
    item["source"] = source
    item["style"] = style
    item["thick"] = thick
    item["spacing"] = spacing
    item["outline"] = outlineOn
    item["outline_thick"] = outlineThick
    if not isNone(outlineColor):
      item["outline_color"] = outlineColor
    addItem(inst, item)

proc makeEntityBox(
  x, y, w, h: float,
  color: int,
  style: string,
  fill: float,
  thick: float,
  outline: bool,
  outlineColor: PyObject,
  outlineThick: float
): PyObject =
  ensureDrawTypes()
  discard parseStyle(style)
  if w < 0 or h < 0:
    raise newException(PmValueError, "box size must not be negative")
  if thick <= 0:
    raise newException(PmValueError, "thick must be positive")
  if outlineThick < 0:
    raise newException(PmValueError, "outline_thick must not be negative")
  let inst = objectNew(entityBoxClass)
  setPyAttr(inst, "x", nimValueToPy(x))
  setPyAttr(inst, "y", nimValueToPy(y))
  setPyAttr(inst, "w", nimValueToPy(w))
  setPyAttr(inst, "h", nimValueToPy(h))
  setPyAttr(inst, "color", nimValueToPy(color))
  setPyAttr(inst, "style", nimValueToPy(style))
  setPyAttr(inst, "fill", nimValueToPy(clampFactor(fill)))
  setPyAttr(inst, "thick", nimValueToPy(thick))
  setPyAttr(inst, "outline", nimValueToPy(outline))
  setPyAttr(inst, "outline_thick", nimValueToPy(outlineThick))
  setPyAttr(inst, "outline_color", pyOrNone(outlineColor))
  setPyAttr(inst, "_items", nimValueToPy(newPyListOf(newSeq[PyObject]())))
  inst

template resourceMethods(dict: PyObject, closeFn, reprFn: untyped) =
  bindMethod(dict, "close", proc(a: PyObject) = closeFn(a))
  bindMethod(dict, "__enter__", proc(a: PyObject): PyObject = a)
  bindMethod(dict, "__exit__", proc(a, b, c, e: PyObject): bool =
    closeFn(a)
    false)
  bindMethod(dict, "__repr__", proc(a: PyObject): string = reprFn(a))

proc ensureDrawTypes*() =
  if drawReady:
    return
  drawReady = true

  var fontDict = pyDict()
  bindKwMethod(fontDict, "text", fontTextImpl)
  bindKwMethod(fontDict, "measure", fontMeasureImpl)
  bindKwMethod(fontDict, "filter", fontFilterImpl)
  bindMethod(fontDict, "size", proc(a: PyObject): int = fontSizeImpl(a))
  resourceMethods(fontDict, fontCloseImpl, fontReprImpl)
  fontClass = newClass("Font", getAttr(pyBuiltinsModule(), "object"), fontDict)

  var textureDict = pyDict()
  bindMethod(textureDict, "width", proc(a: PyObject): int = textureWidthImpl(a))
  bindMethod(textureDict, "height", proc(a: PyObject): int = textureHeightImpl(a))
  resourceMethods(textureDict, textureCloseImpl, textureReprImpl)
  textureClass = newClass("Texture", getAttr(pyBuiltinsModule(), "object"), textureDict)

  var boxDict = pyDict()
  bindKwMethod(boxDict, "set_box", entityBoxSetBoxImpl)
  bindKwMethod(boxDict, "add_bar", entityBoxAddBarImpl)
  bindKwMethod(boxDict, "add_text", entityBoxAddTextImpl)
  bindKwMethod(boxDict, "add_snapline", entityBoxAddSnaplineImpl)
  bindKwMethod(boxDict, "draw", entityBoxDrawImpl)
  bindKwMethod(boxDict, "clear", entityBoxClearImpl)
  bindMethod(boxDict, "__repr__", proc(a: PyObject): string = boxReprImpl(a))
  entityBoxClass = newClass("EntityBox", getAttr(pyBuiltinsModule(), "object"), boxDict)

proc drawPoint*(x, y: float, color: int = DefaultColor): PPyObject {.exportpy: "draw_point".} =
  pyWrap:
    checkOverlay("draw_point")
    rl.drawPixel(int32(math.round(x)), int32(math.round(y)), rl.getColor(uint32(color)))

proc drawLine*(
  x1, y1, x2, y2: float,
  color: int = DefaultColor,
  thick: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_line".} =
  pyWrap:
    checkOverlay("draw_line")
    let
      a = rl.Vector2(x: x1.float32, y: y1.float32)
      b = rl.Vector2(x: x2.float32, y: y2.float32)
      c = rl.getColor(uint32(color))
      width = max(thick, 0.1).float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
    if outlineActive(outline, border, outlineColor):
      strokePathHalo(@[a, b], width, border, rl.getColor(uint32(outlineColor)))
    strokeLine(a, b, width, c)

proc drawPolyline*(
  points: PyObject,
  color: int = DefaultColor,
  thick: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_polyline".} =
  pyWrap:
    checkOverlay("draw_polyline")
    let
      pts = pointsOf(points)
      c = rl.getColor(uint32(color))
      width = max(thick, 0.1).float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
    if outlineActive(outline, border, outlineColor):
      strokePathHalo(pts, width, border, rl.getColor(uint32(outlineColor)))
    strokePath(pts, width, c, joins = true)

proc drawRect*(
  x, y, w, h: float,
  color: int = DefaultColor,
  fill: bool = true,
  thick: float = 1.0,
  `round`: float = 0.0,
  segments: int = 0,
  rotation: float = 0.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_rect".} =
  pyWrap:
    checkOverlay("draw_rect")
    let
      r = rl.Rectangle(x: x.float32, y: y.float32, width: w.float32, height: h.float32)
      c = rl.getColor(uint32(color))
      width = max(thick, 0.1).float32
      roundness = max(`round`, 0.0).float32
      count = if segments > 0: int32(segments) else: int32(DefaultSegments)
      angle = rotation.float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
    if fill:
      if outlineActive(outline, border, outlineColor):
        rectBorder(r, border, roundness, count, angle, rl.getColor(uint32(outlineColor)))
      fillRectShape(r, roundness, count, angle, c)
    else:
      if outlineActive(outline, border, outlineColor):
        rectHalo(
          r, width, border, roundness, count, angle, rl.getColor(uint32(outlineColor))
        )
      strokeRectShape(r, width, roundness, count, angle, c)

proc drawRectGradient*(
  x, y, w, h: float,
  top, bottom: int,
  horizontal: bool = false,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_rect_gradient".} =
  pyWrap:
    checkOverlay("draw_rect_gradient")
    let
      r = rl.Rectangle(x: x.float32, y: y.float32, width: w.float32, height: h.float32)
      ix = int32(math.round(x))
      iy = int32(math.round(y))
      iw = int32(math.round(w))
      ih = int32(math.round(h))
      first = rl.getColor(uint32(top))
      second = rl.getColor(uint32(bottom))
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, top)
    if outlineActive(outline, border, outlineColor):
      rectBorder(r, border, 0.0, 0, 0.0, rl.getColor(uint32(outlineColor)))
    if horizontal:
      rl.drawRectangleGradientH(ix, iy, iw, ih, first, second)
    else:
      rl.drawRectangleGradientV(ix, iy, iw, ih, first, second)

proc drawCircle*(
  cx, cy, r: float,
  color: int = DefaultColor,
  fill: bool = true,
  thick: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_circle".} =
  pyWrap:
    checkOverlay("draw_circle")
    let
      center = rl.Vector2(x: cx.float32, y: cy.float32)
      radius = max(r, 0.1).float32
      c = rl.getColor(uint32(color))
      width = max(thick, 0.1).float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
      hasOutline = outlineActive(outline, border, outlineColor)
      oc = rl.getColor(uint32(outlineColor))
    if fill:
      if hasOutline:
        rl.drawRing(center, radius, radius + border, 0.0, 360.0, 0, oc)
      rl.drawCircle(center, radius, c)
    else:
      if hasOutline:
        let half = width / 2
        rl.drawRing(
          center,
          max(radius - half - border, 0.0),
          radius + half + border,
          0.0,
          360.0,
          0,
          oc
        )
      if width <= 1.0:
        rl.drawCircleLines(center, radius, c)
      else:
        rl.drawRing(
          center,
          max(radius - width / 2, 0.0),
          radius + width / 2,
          0.0,
          360.0,
          0,
          c
        )

proc drawSector*(
  cx, cy, r, start, `end`: float,
  color: int = DefaultColor,
  fill: bool = true,
  segments: int = 36,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_sector".} =
  pyWrap:
    checkOverlay("draw_sector")
    let
      center = rl.Vector2(x: cx.float32, y: cy.float32)
      radius = max(r, 0.1).float32
      c = rl.getColor(uint32(color))
      count = int32(max(segments, 0))
      startA = start.float32
      endA = `end`.float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
      hasOutline = outlineActive(outline, border, outlineColor)
      oc = rl.getColor(uint32(outlineColor))
    if fill:
      if hasOutline:
        strokeSector(center, radius, startA, endA, 2 * border, count, oc)
      rl.drawCircleSector(center, radius, startA, endA, count, c)
    else:
      if hasOutline:
        strokeSector(center, radius, startA, endA, 1.0 + 2 * border, count, oc)
      rl.drawCircleSectorLines(center, radius, startA, endA, count, c)

proc drawRing*(
  cx, cy, rInner, rOuter: float,
  color: int = DefaultColor,
  start: float = 0.0,
  `end`: float = 360.0,
  fill: bool = true,
  segments: int = 36,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_ring".} =
  pyWrap:
    checkOverlay("draw_ring")
    let
      center = rl.Vector2(x: cx.float32, y: cy.float32)
      inner = max(rInner, 0.0).float32
      outer = max(rOuter, 0.0).float32
      c = rl.getColor(uint32(color))
      count = int32(max(segments, 0))
      startA = start.float32
      endA = `end`.float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
      hasOutline = outlineActive(outline, border, outlineColor)
      oc = rl.getColor(uint32(outlineColor))
      partial = endA != startA and abs(endA - startA) < 360.0
    if fill:
      if hasOutline:
        rl.drawRing(center, outer, outer + border, startA, endA, count, oc)
        if inner > 0:
          rl.drawRing(
            center, max(inner - border, 0.0), inner, startA, endA, count, oc
          )
        if partial:
          strokeRadial(
            center,
            max(inner - border, 0.0),
            outer + border,
            startA,
            2 * border,
            oc
          )
          strokeRadial(
            center,
            max(inner - border, 0.0),
            outer + border,
            endA,
            2 * border,
            oc
          )
      rl.drawRing(center, inner, outer, startA, endA, count, c)
    else:
      if hasOutline:
        const half = 0.5'f32
        if inner > 0:
          rl.drawRing(
            center,
            max(inner - half - border, 0.0),
            inner + half + border,
            startA,
            endA,
            count,
            oc
          )
        rl.drawRing(
          center,
          max(outer - half - border, 0.0),
          outer + half + border,
          startA,
          endA,
          count,
          oc
        )
        if partial:
          let
            low = max(inner - half - border, 0.0)
            high = outer + half + border
            radial = 1.0 + 2.0 * border
          strokeRadial(center, low, high, startA, radial, oc)
          strokeRadial(center, low, high, endA, radial, oc)
      rl.drawRingLines(center, inner, outer, startA, endA, count, c)

proc drawEllipse*(
  cx, cy, rx, ry: float,
  color: int = DefaultColor,
  fill: bool = true,
  thick: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_ellipse".} =
  pyWrap:
    checkOverlay("draw_ellipse")
    let
      center = rl.Vector2(x: cx.float32, y: cy.float32)
      radiusH = max(rx, 0.1).float32
      radiusV = max(ry, 0.1).float32
      c = rl.getColor(uint32(color))
      width = max(thick, 0.1).float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
      hasOutline = outlineActive(outline, border, outlineColor)
      oc = rl.getColor(uint32(outlineColor))
    if fill:
      if hasOutline:
        strokeEllipse(center, radiusH, radiusV, 2 * border, oc)
      rl.drawEllipse(center, radiusH, radiusV, c)
    else:
      if hasOutline:
        strokeEllipse(center, radiusH, radiusV, width + 2 * border, oc)
      if width <= 1.0:
        rl.drawEllipseLines(center, radiusH, radiusV, c)
      else:
        strokeEllipse(center, radiusH, radiusV, width, c)

proc drawTriangle*(
  x1, y1, x2, y2, x3, y3: float,
  color: int = DefaultColor,
  fill: bool = true,
  thick: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_triangle".} =
  pyWrap:
    checkOverlay("draw_triangle")
    let
      a = rl.Vector2(x: x1.float32, y: y1.float32)
      b = rl.Vector2(x: x2.float32, y: y2.float32)
      d = rl.Vector2(x: x3.float32, y: y3.float32)
      c = rl.getColor(uint32(color))
      width = max(thick, 0.1).float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
      hasOutline = outlineActive(outline, border, outlineColor)
      oc = rl.getColor(uint32(outlineColor))
      corners = @[a, b, d]
    if fill:
      if hasOutline:
        strokePath(corners, 2 * border, oc, true, joins = true)
      rl.drawTriangle(a, b, d, c)
    else:
      if hasOutline:
        strokePath(corners, width + 2 * border, oc, true, joins = true)
      if width <= 1.0:
        rl.drawTriangleLines(a, b, d, c)
      else:
        strokePath(corners, width, c, true, joins = true)

proc drawPoly*(
  cx, cy: float,
  sides: int,
  radius: float,
  color: int = DefaultColor,
  rotation: float = 0.0,
  fill: bool = true,
  thick: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_poly".} =
  pyWrap:
    checkOverlay("draw_poly")
    let
      center = rl.Vector2(x: cx.float32, y: cy.float32)
      count = int32(max(sides, 3))
      size = max(radius, 0.1).float32
      c = rl.getColor(uint32(color))
      width = max(thick, 0.1).float32
      angle = rotation.float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
      hasOutline = outlineActive(outline, border, outlineColor)
      oc = rl.getColor(uint32(outlineColor))
      points = polygonPoints(center, count, size, angle)
    if fill:
      if hasOutline:
        strokePath(points, 2 * border, oc, true, joins = true)
      rl.drawPoly(center, count, size, angle, c)
    else:
      if hasOutline:
        strokePath(points, width + 2 * border, oc, true, joins = true)
      if width <= 1.0:
        rl.drawPolyLines(center, count, size, angle, width, c)
      else:
        strokePath(points, width, c, true, joins = true)

proc drawText*(
  text: PyObject,
  x, y, size: float,
  color: int = DefaultColor,
  align: string = "left",
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_text".} =
  pyWrap:
    checkOverlay("draw_text")
    let
      p = fontData(currentFont)
      fontSize = max(size, 1.0).float32
      body = textLines(text)
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
    drawOutlinedText(
      p,
      body,
      x.float32,
      y.float32,
      fontSize,
      1.0,
      color,
      outlineColor,
      border,
      outlineActive(outline, border, outlineColor),
      parseAlign(align)
    )

proc drawTextEx*(
  font: PyObject,
  text: PyObject,
  x, y, size: float,
  color: int = DefaultColor,
  spacing: float = 1.0,
  align: string = "left",
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_text_ex".} =
  pyWrap:
    checkOverlay("draw_text_ex")
    let
      p = fontData(font)
      fontSize = max(size, 1.0).float32
      body = textLines(text)
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
    drawOutlinedText(
      p,
      body,
      x.float32,
      y.float32,
      fontSize,
      max(spacing, 0.0).float32,
      color,
      outlineColor,
      border,
      outlineActive(outline, border, outlineColor),
      parseAlign(align)
    )

proc drawMeasureText*(
  text: PyObject,
  size: float,
  spacing: float = 1.0
): PPyObject {.exportpy: "draw_measure_text".} =
  pyWrap:
    checkOverlay("draw_measure_text")
    let measured = textSize(
      fontData(currentFont),
      textLines(text),
      max(size, 1.0).float32,
      max(spacing, 0.0).float32
    )
    newVec2(measured)

proc drawMeasureTextEx*(
  font: PyObject,
  text: PyObject,
  size: float,
  spacing: float = 1.0
): PPyObject {.exportpy: "draw_measure_text_ex".} =
  pyWrap:
    checkOverlay("draw_measure_text_ex")
    let measured = textSize(
      fontData(font),
      textLines(text),
      max(size, 1.0).float32,
      max(spacing, 0.0).float32
    )
    newVec2(measured)

proc drawSetFont*(font: PyObject = nil): PPyObject {.exportpy: "draw_set_font".} =
  pyWrap:
    if isNone(font):
      currentFont = nil
    else:
      discard fontData(font)
      currentFont = font
    nil

proc drawFont*(): PPyObject {.exportpy: "draw_font".} =
  pyWrap:
    if currentFont.isNil:
      newPyNone()
    else:
      nimValueToPy(currentFont)

proc drawFps*(
  x, y: float,
  color: int = DefaultColor,
  font: PyObject = nil,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_fps".} =
  pyWrap:
    checkOverlay("draw_fps")
    let
      p = if isNone(font): fontData(currentFont) else: fontData(font)
      label = $int(rl.getFPS())
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, color)
    drawOutlinedText(
      p,
      label,
      x.float32,
      y.float32,
      20.0,
      1.0,
      color,
      outlineColor,
      border,
      outlineActive(outline, border, outlineColor),
      taLeft
    )

proc drawLoadTexture*(path: string): PPyObject {.exportpy: "draw_load_texture".} =
  pyWrap:
    loadTextureFile(path)

proc drawLoadTextureBytes*(
  kind: string,
  data: PyObject
): PPyObject {.exportpy: "draw_load_texture_bytes".} =
  pyWrap:
    loadTextureBuffer(kind, data)

proc drawTexture*(
  texture: PyObject,
  x, y: float,
  scale: float = 1.0,
  rotation: float = 0.0,
  tint: int = DefaultColor,
  opacity: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_texture".} =
  pyWrap:
    checkOverlay("draw_texture")
    let
      p = textureData(texture)
      blended = withAlpha(tint, opacity)
      scaleFactor = max(scale, 0.0).float32
      angle = rotation.float32
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, tint)
    if outlineActive(outline, border, outlineColor):
      let
        origin = rl.Vector2(x: x.float32, y: y.float32)
        bounds = rl.Rectangle(
          x: origin.x,
          y: origin.y,
          width: float32(p[].width) * scaleFactor,
          height: float32(p[].height) * scaleFactor
        )
        corners = rotatedCorners(expanded(bounds, border / 2), angle, origin)
      for i in 0 ..< 4:
        rl.drawLine(
          corners[i],
          corners[(i + 1) mod 4],
          border,
          rl.getColor(uint32(outlineColor))
        )
    if alphaOf(blended) > 0:
      rl.drawTexture(
        p[],
        rl.Vector2(x: x.float32, y: y.float32),
        angle,
        scaleFactor,
        rl.getColor(uint32(blended))
      )

proc drawTextureRect*(
  texture: PyObject,
  source: PyObject,
  dest: PyObject,
  tint: int = DefaultColor,
  opacity: float = 1.0,
  outline: bool = false,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_texture_rect".} =
  pyWrap:
    checkOverlay("draw_texture_rect")
    let
      p = textureData(texture)
      src = rectOf(source)
      dst = rectOf(dest)
      blended = withAlpha(tint, opacity)
      border = max(outline_thick, 0.0).float32
      outlineColor = resolveOutline(outline_color, tint)
    if outlineActive(outline, border, outlineColor):
      rectBorder(dst, border, 0.0, 0, 0.0, rl.getColor(uint32(outlineColor)))
    if alphaOf(blended) > 0:
      rl.drawTexture(p[], src, dst, rl.Vector2(x: 0.0, y: 0.0), 0.0, rl.getColor(uint32(blended)))

proc drawLoadFont*(
  path: string,
  size: int,
  chars: string = "latin"
): PPyObject {.exportpy: "draw_load_font".} =
  pyWrap:
    loadFontFile(path, size, chars)

proc drawLoadFontBytes*(
  data: PyObject,
  size: int,
  chars: string = "latin",
  kind: string = "ttf"
): PPyObject {.exportpy: "draw_load_font_bytes".} =
  pyWrap:
    loadFontBuffer(data.to(seq[uint8]), size, chars, kind)

proc drawFonts*(): PPyObject {.exportpy: "draw_fonts".} =
  pyWrap:
    var names: seq[string]
    for path in systemFontFiles():
      names.add extractFilename(path)
    names.sort(proc(a, b: string): int = cmp(a.toLowerAscii(), b.toLowerAscii()))
    var
      items: seq[PPyObject]
      seen = initHashSet[string]()
    for name in names:
      if seen.containsOrIncl(name.toLowerAscii()):
        continue
      items.add nimValueToPy(name)
    newPyListTaking(items)

proc captureScreen*(path, op: string) =
  checkOverlay(op)
  if path.len == 0:
    raise newException(PmValueError, "screenshot path must not be empty")
  if not inFrame:
    raise newException(
      PmOverlayError,
      "screenshot must be called while a frame is open (between loop() and end())"
    )
  drawRenderBatchActive()
  let
    target = absolutePath(path)
    image = rl.loadImageFromScreen()
    saved = rl.exportImage(image, target)
  if not saved:
    raise newException(PmOverlayError, "cannot save screenshot to '" & path & "'")

proc drawScreenshot*(path: string): PPyObject {.exportpy: "draw_screenshot".} =
  pyWrap:
    captureScreen(path, "draw_screenshot")

proc drawEntityBox*(
  x, y, w, h: float,
  color: int = DefaultColor,
  style: string = "line",
  fill: float = 0.0,
  thick: float = 1.5,
  outline: bool = true,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_entity_box".} =
  pyWrap:
    makeEntityBox(x, y, w, h, color, style, fill, thick, outline, outline_color, outline_thick)

proc drawEntityBoxFromPoints*(
  top, bottom: PyObject,
  color: int = DefaultColor,
  ratio: float = 0.85,
  style: string = "line",
  fill: float = 0.0,
  thick: float = 1.5,
  outline: bool = true,
  outline_color: PyObject = nil,
  outline_thick: float = 1.0
): PPyObject {.exportpy: "draw_entity_box_from_points".} =
  pyWrap:
    let
      head = pointOf(top)
      feet = pointOf(bottom)
      height = max(feet.y - head.y, 0.0)
      width = height * (if ratio > 0: ratio else: 0.85).float32
      x = (head.x + feet.x) / 2 - width / 2
    makeEntityBox(
      float(x),
      float(head.y),
      float(width),
      float(height),
      color,
      style,
      fill,
      thick,
      outline,
      outline_color,
      outline_thick
    )