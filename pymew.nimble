version       = "0.3.1"
author        = "pymew"
description   = "A cross-platform Python memory manipulation and overlay library designed to simplify the development of external game cheats"
license       = "MIT"
srcDir        = "."

requires "nimpy >= 0.2.1", "naylib == 26.08.0"

when defined(windows):
  requires "winim >= 4.0.0"
  bin = @["pymew.pyd"]
else:
  requires "x11 >= 1.2"
  bin = @["pymew.so"]
