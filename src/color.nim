import std/[math, strutils]
import std/colors {.all.}
import nimpy
import nimpy/[py_types, py_utils]
import raylib as rl
import raymath as rm

import pyutil, errors

pyExportModule("pymew")

proc pack(c: rl.Color): int =
  (int(c.r) shl 24) or (int(c.g) shl 16) or (int(c.b) shl 8) or int(c.a)

proc unpack(value: int): rl.Color =
  rl.getColor(uint32(value))

proc parseHexColor(text: string): rl.Color =
  var digits = text
  if digits.len > 0 and digits[0] == '#':
    digits = digits[1 .. ^1]
  if digits.len notin {3, 4, 6, 8} or not allCharsInSet(digits, HexDigits):
    raise newException(PmValueError, "invalid color '" & text & "'")
  var value: uint32
  if digits.len in {3, 4}:
    for ch in digits:
      value = value shl 8 or uint32(parseHexInt($ch) * 17)
    if digits.len == 3:
      value = value shl 8 or 0xFF
  else:
    value = uint32(parseHexInt(digits))
    if digits.len == 6:
      value = value shl 8 or 0xFF
  rl.getColor(value)

proc isHexLiteral(text: string): bool =
  text.len in {3, 4, 6, 8} and allCharsInSet(text, HexDigits)

proc suggestName(name: string): string =
  var candidates: seq[string]
  for (candidate, _) in colorNames:
    candidates.add candidate
  closestName(name, candidates, 3)

proc namedColor(text: string): rl.Color =
  let name = normalizeName(text)
  if isColor(name):
    let rgb = int(parseColor(name))
    return rl.Color(
      r: uint8(rgb shr 16 and 0xFF),
      g: uint8(rgb shr 8 and 0xFF),
      b: uint8(rgb and 0xFF),
      a: 255
    )
  var msg = "unknown color '" & text & "'"
  let suggestion = suggestName(name)
  if suggestion.len > 0:
    msg.add "; did you mean '" & suggestion & "'?"
  raise newException(PmValueError, msg)

proc colorGet*(value: PyObject): PPyObject {.exportpy: "color_get".} =
  pyWrap:
    if pyIsInstance(value, "bool"):
      raise newException(PmBadType, "color must be a name, a hex string, an int or an (r, g, b[, a]) tuple")
    if pyIsInstance(value, "int"):
      value.to(int)
    elif pyIsInstance(value, "str"):
      let
        text = value.to(string)
        c = if text.len > 0 and (text[0] == '#' or isHexLiteral(text)):
          parseHexColor(text)
        else:
          namedColor(text)
      pack(c)
    elif pyIsInstance(value, "tuple") or pyIsInstance(value, "list"):
      var channels: seq[int]
      for raw in rawItems(rawPy(value)):
        channels.add asPy(raw).to(int)
      if channels.len notin {3, 4}:
        raise newException(PmValueError, "color tuple must have 3 or 4 channels, got " & $channels.len)
      for v in channels:
        if v notin 0..255:
          raise newException(PmValueError, "color channel " & $v & " is outside 0..255")
      pack(rl.Color(
        r: uint8(channels[0]),
        g: uint8(channels[1]),
        b: uint8(channels[2]),
        a: uint8(if channels.len == 4: channels[3] else: 255)
      ))
    else:
      raise newException(PmBadType, "color must be a name, a hex string, an int or an (r, g, b[, a]) tuple")

proc roundChannel(x: float): int =
  clamp(int(round(x)), 0, 255)

proc colorFadeInt*(color: int, factor: float): PPyObject {.exportpy: "color_fade".} =
  pyWrap:
    var c = unpack(color)
    c.a = uint8(roundChannel(float(c.a) * clampFactor(factor)))
    pack(c)

proc colorMixInt*(a, b: int, factor: float): PPyObject {.exportpy: "color_mix".} =
  pyWrap:
    let
      ca = unpack(a)
      cb = unpack(b)
      t = clampFactor(factor).float32
    proc mixByte(x, y: uint8): int =
      roundChannel(float(rm.lerp(float32(x), float32(y), t)))
    pack(rl.Color(
      r: uint8(mixByte(ca.r, cb.r)),
      g: uint8(mixByte(ca.g, cb.g)),
      b: uint8(mixByte(ca.b, cb.b)),
      a: uint8(mixByte(ca.a, cb.a))
    ))

proc colorGetNames*(): seq[string] {.exportpy: "color_names".} =
  for (name, _) in colorNames:
    result.add name

proc colorGetTable*(): PPyObject {.exportpy: "color_table".} =
  pyWrap:
    var d = pyDict()
    for (name, value) in colorNames:
      d[name] = (int(value) shl 8) or 0xFF
    d