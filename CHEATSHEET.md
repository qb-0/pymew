# pymew cheatsheet

```python
import pymew as pm
```

## Memory

```python
# target: process name or pid
p = pm.mem.open(target, debug=False)  # -> Process
p.pid()                               # -> int
p.name()                              # -> str
p.path()                              # -> str
p.alive()                             # -> bool
p.is_64bit()                          # -> bool
p.base(module="")                     # -> int
p.modules()                           # -> list[Module] .name .base .end .size
p.module(name)                        # -> Module
p.regions()                           # -> list[Region] .start .end .size .protection
p.refresh()                           # -> None
p.set_debug(True)                     # -> None
p.close()                             # -> None

pm.mem.processes()                    # -> list[ProcessEntry] .pid .name
pm.mem.exists(target)                 # -> bool
pm.mem.pid(target)                    # -> int
pm.mem.name(target)                   # -> str
pm.mem.path(target)                   # -> str
pm.mem.is_64bit(target)               # -> bool
```

### Types

```python
pm.mem.i8
pm.mem.i16
pm.mem.i32
pm.mem.i64
pm.mem.u8
pm.mem.u16
pm.mem.u32
pm.mem.u64
pm.mem.f32
pm.mem.f64
pm.mem.bool
pm.mem.ptr
pm.mem.vec2
pm.mem.vec3

pm.mem.string(size)                  # -> Type    UTF-8 buffer
pm.mem.wstring(size)                 # -> Type    UTF-16 buffer
pm.mem.fstring(char_size=2)          # -> Type    Unreal FString
pm.mem.bytes(size)                   # -> Type
pm.mem.array(elem, count, stride=0)  # -> Type    fixed array / struct list
```

### Read / write

```python
p.read(address, typeDesc, count=0)       # -> Any    depends on typeDesc
p.read(address, pm.mem.i32)              # -> int
p.read(address, pm.mem.i32, count=16)    # -> list[int]
p.read(address, pm.mem.string(32))       # -> str
p.read(address, pm.mem.bytes(16))        # -> bytes    raw, not list[int]
p.read(address, pm.mem.f32, count=3)     # -> list[float]
p.read(address, Player)                  # -> Player

p.write(address, value)                  # -> int    bytes written
p.write(address, pm.mem.i32(5))          # -> int
p.write(address, pm.mem.i32([1, 2, 3]))  # -> int
p.write(address, pm.mem.wstring("hi"))   # -> int
p.write(address, pm.mem.string("hi"))    # -> int
p.write(address, pm.mem.bytes(b"\x90"))  # -> int

# read() takes a type (pm.mem.i32)
# write() takes a value (pm.mem.i32(5))
```

### Structs

```python
class Weapon(pm.mem.Struct):
    id = pm.mem.i32.at(0x00)
    ammo = pm.mem.i16.at(0x04)

class Player(pm.mem.Struct):
    pos = pm.mem.vec3.at(0x08)
    health = pm.mem.i32.at(0x100)
    name = pm.mem.string(32).at(0x219)
    weapon = Weapon.at(0x2A0)

pl = p.read(address, Player)                           # -> Player
pl.health                                              # -> int
pl.name                                                # -> str
pl.pos.x                                               # -> float
pl.weapon.ammo                                         # -> int

pl.health = 100
p.write(address, pl)                                   # -> int

pl.address(field="")                                   # -> int
Player.offset(field)                                   # -> int
Player.size()                                          # -> int
Player(health=100, pos=pm.vec3(1, 2, 3))               # -> Player

class Loadout(pm.mem.Struct):
    slots = pm.mem.array(Weapon, 3).at(0x10)

p.read(address, pm.mem.array(Weapon, 2))               # -> list[Weapon]
p.read(address, pm.mem.array(Weapon, 2, stride=0x20))  # -> list[Weapon]
lo = p.read(address, Loadout)                          # -> Loadout
lo.slots                                               # -> list[Weapon]
```

### Pointers / scan

```python
p.chain(base, offsets)                    # -> int
p.read_chain(base, offsets, typeDesc)     # -> Any    depends on typeDesc
p.resolve_rip(address, offset=3, size=7)  # -> int
p.scan(pattern, module="", first=False)   # -> list[int] | int | None
p.scan_range(pattern, start, stop)        # -> list[int]
pm.mem.scan_bytes(pattern, data)          # -> list[int]
```

## Overlay

```python
ov = pm.overlay.open(
    target=None,
    fps=0,
    title="pymew",
    exit_key=None,
    track=True,
    log_level=None,
    imgui_bundle=False,
    imgui_key=None,
    msaa=True,
    taskbar=False
)  # -> Overlay

while ov.loop():                                                    # -> bool
    pm.draw.text("hi", 10, 10, 20, color=0xFFFFFFFF, align="left")  # -> None

ov.width()                                                          # -> int
ov.height()                                                         # -> int
ov.pos()                                                            # -> vec2
ov.set_pos(x, y)                                                    # -> None
ov.set_size(width, height)                                          # -> None
ov.set_title(title)                                                 # -> None
ov.monitor(index)                                                   # -> None
ov.clickthrough(True)                                               # -> None
ov.topmost(True)                                                    # -> None
ov.interact(True)                                                   # -> None
ov.active()                                                         # -> bool
ov.hide(True)                                                       # -> None
ov.fps()                                                            # -> int
ov.set_fps(fps)                                                     # -> None
ov.screenshot(path)                                                 # -> None
ov.imgui_active()                                                   # -> bool
ov.begin()                                                          # -> None
ov.end()                                                            # -> None
ov.close()                                                          # -> None

# loop() stays True until the exit key or window close
# interact() enters the input mode that imgui_key also toggles
# begin()/end() is only required for manual frame handling
# track=True follows the target geometry and hides the overlay while the target is not focused
# active() is True while the target window is focused (track=True only)
# hide(False) clears the manual hide; track decides visibility again
```

## Draw

### Shapes

```python
d = pm.draw

d.point(x, y, color=0xFFFFFFFF)  # -> None
d.line(
    x1, y1, x2, y2,
    color=0xFFFFFFFF,
    thick=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.polyline(
    points,
    color=0xFFFFFFFF,
    thick=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.rect(
    x, y, w, h,
    color=0xFFFFFFFF,
    fill=True,
    thick=1.0,
    round=0.0,
    segments=0,
    rotation=0.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.rect_gradient(
    x, y, w, h,
    top, bottom,
    horizontal=False,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.circle(
    cx, cy, r,
    color=0xFFFFFFFF,
    fill=True,
    thick=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.sector(
    cx, cy, r, start, end,
    color=0xFFFFFFFF,
    fill=True,
    segments=36,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.ring(
    cx, cy, r_inner, r_outer,
    color=0xFFFFFFFF,
    start=0.0,
    end=360.0,
    fill=True,
    segments=36,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.ellipse(
    cx, cy, rx, ry,
    color=0xFFFFFFFF,
    fill=True,
    thick=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.triangle(
    x1, y1, x2, y2, x3, y3,
    color=0xFFFFFFFF,
    fill=True,
    thick=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.poly(
    cx, cy, sides, radius,
    color=0xFFFFFFFF,
    rotation=0.0,
    fill=True,
    thick=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
```

### Text / fonts

```python
# align: left | center | right
# text: str or list[str], list entries become lines
d.text(
    text, x, y, size,
    color=0xFFFFFFFF,
    align="left",
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.text_ex(
    font, text, x, y, size,
    color=0xFFFFFFFF,
    spacing=1.0,
    align="left",
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.measure_text(text, size, spacing=1.0)  # -> vec2
d.measure_text_ex(font, text, size, spacing=1.0)  # -> vec2

# chars: latin | cyrillic | greek | all
d.load_font(path, size, chars="latin")                                          # -> Font
d.load_font_bytes(data, size, chars="latin", kind="ttf")                        # -> Font
d.fonts()                                                                       # -> list[str]

d.set_font(font=None)                                                           # -> None
d.font()                                                                        # -> Font | None
font.text(
    text, x, y, size=20.0,
    color=0xFFFFFFFF,
    align="left",
    spacing=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
font.measure(text, size=20.0, spacing=1.0)                                      # -> vec2
# filter: point | bilinear | trilinear
font.filter(filter="bilinear")                                                  # -> None
font.size()                                                                     # -> int
font.close()                                                                    # -> None

d.fps(
    x, y,
    color=0xFFFFFFFF,
    font=None,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None    defaults to active font
```

### Textures

```python
tex = d.load_texture(path)                                                       # -> Texture
tex = d.load_texture_bytes(kind, data)                                           # -> Texture

tex.width()                                                                      # -> int
tex.height()                                                                     # -> int
d.texture(
    texture, x, y,
    scale=1.0,
    rotation=0.0,
    tint=0xFFFFFFFF,
    opacity=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.texture_rect(
    texture, source, dest,
    tint=0xFFFFFFFF,
    opacity=1.0,
    outline=False,
    outline_color=None,
    outline_thick=1.0
)  # -> None
d.screenshot(path)                                                               # -> None
tex.close()                                                                      # -> None
```

### Entity box

```python
# style: corner | line | filled
eb = d.entity_box(
    x, y, w, h,
    color=0xFFFFFFFF,
    style="line",
    fill=0.0,
    thick=1.5,
    outline=True,
    outline_color=None,
    outline_thick=1.0
)  # -> EntityBox
eb = d.entity_box_from_points(
    top, bottom,
    color=0xFFFFFFFF,
    ratio=0.85,
    style="line",
    fill=0.0,
    thick=1.5,
    outline=True,
    outline_color=None,
    outline_thick=1.0
)  # -> EntityBox

eb.set_box(x, y, w, h)  # -> None
eb.x                    # -> float
eb.y                    # -> float
eb.w                    # -> float
eb.h                    # -> float
eb.color                # -> int
eb.style                # -> str
eb.fill                 # -> float
eb.thick                # -> float
eb.outline              # -> bool
eb.outline_color        # -> int | None
eb.outline_thick        # -> float

# side: left | right | top | bottom
# align: left | center | right
# reverse flips the fill direction
# max: value at a full bar, value/max is the fill fraction (default 1.0)
eb.add_bar(
    side,
    color,
    value=1.0,
    thick=4.0,
    gap=6.0,
    segments=None,
    length=1.0,
    align="center",
    reverse=False,
    outline=True,
    outline_color=None,
    outline_thick=1.0,
    max=1.0
)  # -> None
# anchor: top-left | top | top-right | left | right | bottom-left | bottom | bottom-right
# text: str or list[str]
eb.add_text(
    anchor,
    text,
    color,
    size=12.0,
    font=None,
    gap=0.0,
    nudge=None,
    outline=True,
    outline_color=None,
    outline_thick=1.0
)  # -> None
# source: bottom | center | top
# style: solid | dashed | dotted
# spacing: gap in px
eb.add_snapline(
    to,
    color,
    source="bottom",
    style="solid",
    thick=1.0,
    spacing=0.0,
    outline=True,
    outline_color=None,
    outline_thick=1.0
)  # -> None

eb.draw()               # -> None
eb.clear()              # -> None
```

## Input

```python
# key value: name ("w", "f1") or code (87)
pm.input.key_down(value)                   # -> bool
pm.input.key_down("w")                     # -> bool
pm.input.key_down(87)                      # -> bool
pm.input.key_pressed(value)                # -> bool
pm.input.key_up(value)                     # -> bool
pm.input.mouse_pos()                       # -> vec2
# value: left | right | middle | x1 | x2 | 1..255
pm.input.mouse_down(value)                 # -> bool
pm.input.mouse_pressed(value)              # -> bool
pm.input.mouse_up(value)                   # -> bool

pm.input.key_press(value)                  # -> None
pm.input.mouse_move(x, y, relative=False)  # -> None
pm.input.mouse_click(value)                # -> None
pm.input.mouse_scroll(amount)              # -> None
pm.input.set_pos(x, y)                     # -> None
```

## Hotkeys

```python
pm.hotkey.bind(value, callback=None)  # -> None
pm.hotkey.list()                      # -> list[str]
pm.hotkey.unbind(value)               # -> None
pm.hotkey.poll()                      # -> None    only required without ov.loop()
```

Modifiers: `ctrl alt shift super`.

## Vectors

```python
v = pm.vec2(x=0.0, y=0.0)         # -> vec2
w = pm.vec3(x=0.0, y=0.0, z=0.0)  # -> vec3
v.x                               # -> float
v.y                               # -> float
w.z                               # -> float

v + v                             # -> vec2
v - v                             # -> vec2
v * 2                             # -> vec2
v / 2                             # -> vec2

v.length()                        # -> float
v.length_sq()                     # -> float
v.distance(other)                 # -> float
v.normalized()                    # -> vec2
v.closest(others)                 # -> vec2
v.to_tuple()                      # -> tuple[float, float]
```

## Colors

```python
pm.color.get(value)             # -> int
pm.color.get("lime")            # -> int
pm.color.get("#f00")            # -> int
pm.color.get("#ff000080")       # -> int
pm.color.get((255, 0, 0, 128))  # -> int
pm.color.get(0xFF0000FF)        # -> int    int passed through

pm.color.fade(color, factor)    # -> int
pm.color.mix(a, b, factor)      # -> int
pm.color.names()                # -> list[str]
pm.color.table()                # -> dict[str, int]
```

## Keys

```python
pm.keys.code(value)  # -> int    name -> code
pm.keys.code("w")    # -> int
pm.keys.name(value)  # -> str    code -> name
pm.keys.name(87)     # -> str
pm.keys.names()      # -> list[str]
```

Modifiers: `lshift rshift lctrl rctrl lalt ralt lsuper rsuper`.

## Utils

```python
pm.utils.os_name()             # -> str
pm.utils.screen_size()         # -> tuple[int, int]
pm.utils.monitors()            # -> list[Monitor]    .name .x .y .width .height .refresh
# target: pid | process name | window title
pm.utils.window_info(target)   # -> Window
pm.utils.windows()             # -> list[Window]    .id .pid .name .title .x .y .width .height
pm.utils.time()                # -> float
pm.utils.set_log_level(level)  # -> None
```

## Errors

```python
pm.errors.Error
pm.errors.ProcessNotFound
pm.errors.ModuleNotFound
pm.errors.AccessError
pm.errors.PermissionDenied
pm.errors.UnsupportedError
pm.errors.HotkeyError
pm.errors.OverlayError
pm.errors.WindowNotFound
```
