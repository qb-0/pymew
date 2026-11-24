type
  TypeCode* = enum
    tcI8 = 0,
    tcI16,
    tcI32,
    tcI64,
    tcU8,
    tcU16,
    tcU32,
    tcU64,
    tcF32,
    tcF64,
    tcBool,
    tcPtr,
    tcVec2,
    tcVec3,
    tcString,
    tcWString,
    tcBytes,
    tcFString,
    tcArray,
    tcStruct

const
  ScalarSizes*: array[TypeCode, int] = [
    1, 2, 4, 8,
    1, 2, 4, 8,
    4, 8,
    1, 8,
    8, 12,
    0, 0,
    0, 0,
    0, 0
  ]
