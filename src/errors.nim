import nimpy
import nimpy/py_lib as pyl

import pyutil
import platform/common

type
  PmError* = object of CatchableError
  PmProcessNotFound* = object of PmError
  PmModuleNotFound* = object of PmError
  PmAccessError* = object of PmError
  PmPermissionDenied* = object of PmAccessError
  PmUnsupported* = object of PmError
  PmBadType* = object of PmError
  PmValueError* = object of PmError
  PmHotkeyError* = object of PmError
  PmOverlayError* = object of PmError
  PmWindowNotFound* = object of PmError

var
  errorClass*: PyObject
  processNotFoundClass*: PyObject
  moduleNotFoundClass*: PyObject
  accessErrorClass*: PyObject
  permissionDeniedClass*: PyObject
  unsupportedClass*: PyObject
  hotkeyErrorClass*: PyObject
  overlayErrorClass*: PyObject
  windowNotFoundClass*: PyObject

proc initErrorClasses*() =
  if errorClass.isNil:
    errorClass = newClass("Error", getAttr(pyBuiltinsModule(), "Exception"), pyDict())
    processNotFoundClass = newClassMulti(
      "ProcessNotFound", [errorClass, getAttr(pyBuiltinsModule(), "LookupError")], pyDict()
    )
    moduleNotFoundClass = newClassMulti(
      "ModuleNotFound", [errorClass, getAttr(pyBuiltinsModule(), "LookupError")], pyDict()
    )
    accessErrorClass = newClassMulti(
      "AccessError", [errorClass, getAttr(pyBuiltinsModule(), "OSError")], pyDict()
    )
    permissionDeniedClass = newClassMulti(
      "PermissionDenied", [accessErrorClass, getAttr(pyBuiltinsModule(), "PermissionError")], pyDict()
    )
    unsupportedClass = newClassMulti(
      "UnsupportedError", [errorClass, getAttr(pyBuiltinsModule(), "NotImplementedError")], pyDict()
    )
    hotkeyErrorClass = newClass("HotkeyError", errorClass, pyDict())
    overlayErrorClass = newClass("OverlayError", errorClass, pyDict())
    windowNotFoundClass = newClass("WindowNotFound", errorClass, pyDict())

proc setPyErr*(cls: PyObject, msg: string) =
  let target = if cls.isNil: getAttr(pyBuiltinsModule(), "Exception") else: cls
  pyl.pyLib.PyErr_SetString(rawPy(target), cstring(msg))

proc setValueError*(msg: string) =
  pyl.pyLib.PyErr_SetString(pyl.pyLib.PyExc_ValueError, cstring(msg))

proc setTypeError*(msg: string) =
  pyl.pyLib.PyErr_SetString(pyl.pyLib.PyExc_TypeError, cstring(msg))

proc setAttributeError*(msg: string) =
  var cls {.global.}: PyObject
  if cls.isNil:
    cls = getAttr(pyBuiltinsModule(), "AttributeError")
  pyl.pyLib.PyErr_SetString(rawPy(cls), cstring(msg))

proc setPyErrFor*(e: ref CatchableError) =
  if e of PmProcessNotFound:
    setPyErr(processNotFoundClass, e.msg)
  elif e of PmModuleNotFound:
    setPyErr(moduleNotFoundClass, e.msg)
  elif e of PmPermissionDenied:
    setPyErr(permissionDeniedClass, e.msg)
  elif e of PmAccessError:
    setPyErr(accessErrorClass, e.msg)
  elif e of PmUnsupported:
    setPyErr(unsupportedClass, e.msg)
  elif e of PmBadType:
    setTypeError(e.msg)
  elif e of PmValueError:
    setValueError(e.msg)
  elif e of PmHotkeyError:
    setPyErr(hotkeyErrorClass, e.msg)
  elif e of PmOverlayError:
    setPyErr(overlayErrorClass, e.msg)
  elif e of PmWindowNotFound:
    setPyErr(windowNotFoundClass, e.msg)
  elif e of ValueError:
    setValueError(e.msg)
  elif e of OsUnsupported:
    setPyErr(unsupportedClass, e.msg)
  elif e of LibraryError:
    setPyErr(unsupportedClass, e.msg)
  elif e of OsFailure:
    setPyErr(accessErrorClass, e.msg)
  else:
    setPyErr(errorClass, e.msg)

template pyWrap*(body: untyped) =
  try:
    initErrorClasses()
    result = pyResult(block: body)
  except CatchableError as e:
    setPyErrFor(e)
    result = nil
