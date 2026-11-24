import common
export common

when defined(windows):
  import windows, win32_input, win32_hotkey
  export windows, win32_input, win32_hotkey
elif defined(linux):
  import linux, x11_input, x11_hotkey
  export linux, x11_input, x11_hotkey
else:
  {.error: "pymew supports only Windows and Linux".}