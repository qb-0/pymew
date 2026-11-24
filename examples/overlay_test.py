import math
import struct
import zlib

import pymew as pm

try:
    from imgui_bundle import imgui
except ImportError:
    print("imgui_bundle not found, imgui will be disabled")
    print("install imgui_bundle with `pip install imgui_bundle`")
    imgui = None

d = pm.draw

VIRTUAL_WIDTH = 1920
VIRTUAL_HEIGHT = 1080
GRID_COLUMNS = 5
GRID_LEFT = 40
GRID_TOP = 108
CELL_WIDTH = 240
CELL_HEIGHT = 140
RIGHT_COLUMN = 1280

WHITE = pm.color.get("white")
MUTED = pm.color.get("silver")
FAINT = pm.color.get("gray")
BLACK = pm.color.get("black")
ORANGE = pm.color.get("orange")
CYAN = pm.color.get("cyan")
LIME = pm.color.get("lime")
PINK = pm.color.get("hotpink")
YELLOW = pm.color.get("yellow")
SKY = pm.color.get("deepskyblue")
VIOLET = pm.color.get("mediumpurple")
RED = pm.color.get("tomato")


def halo(sheet, on):
    return {
        "outline": on and sheet.outlines,
        "outline_color": BLACK,
        "outline_thick": sheet.unit(sheet.outline_thick),
    }


def demo_line(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.line(
        cx - u(42),
        cy - u(24),
        cx + u(42),
        cy + u(24),
        color,
        thick=u(4),
        **halo(sheet, on),
    )


def demo_polyline(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.polyline(
        (
            (cx - u(44), cy + u(20)),
            (cx - u(15), cy - u(22)),
            (cx + u(15), cy + u(18)),
            (cx + u(44), cy - u(16)),
        ),
        color,
        thick=u(4),
        **halo(sheet, on),
    )


def demo_rect(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.rect(cx - u(45), cy - u(28), u(90), u(56), color, **halo(sheet, on))


def demo_rect_stroke(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.rect(
        cx - u(45), cy - u(28), u(90), u(56), color, fill=False, thick=u(3), **halo(sheet, on)
    )


def demo_rect_round(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.rect(cx - u(45), cy - u(28), u(90), u(56), color, round=0.5, **halo(sheet, on))


def demo_rect_gradient(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.rect_gradient(cx - u(45), cy - u(28), u(90), u(56), ORANGE, PINK, **halo(sheet, on))


def demo_rect_rotated(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.rect(
        cx - u(45),
        cy - u(28),
        u(90),
        u(56),
        color,
        round=0.25,
        rotation=time * 30.0,
        **halo(sheet, on),
    )


def demo_circle(sheet, cx, cy, on, color, time):
    d.circle(cx, cy, sheet.unit(30), color, **halo(sheet, on))


def demo_circle_stroke(sheet, cx, cy, on, color, time):
    d.circle(cx, cy, sheet.unit(30), color, fill=False, thick=sheet.unit(3), **halo(sheet, on))


def demo_sector(sheet, cx, cy, on, color, time):
    start = 30.0 + 25.0 * math.sin(time * 0.9)
    d.sector(cx, cy, sheet.unit(32), start, start + 190.0, color, **halo(sheet, on))


def demo_sector_stroke(sheet, cx, cy, on, color, time):
    start = 20.0 + 25.0 * math.sin(time * 0.9)
    d.sector(
        cx,
        cy,
        sheet.unit(32),
        start,
        start + 190.0,
        color,
        fill=False,
        **halo(sheet, on),
    )


def demo_ring(sheet, cx, cy, on, color, time):
    d.ring(cx, cy, sheet.unit(15), sheet.unit(32), color, **halo(sheet, on))


def demo_ring_stroke(sheet, cx, cy, on, color, time):
    d.ring(
        cx,
        cy,
        sheet.unit(15),
        sheet.unit(32),
        color,
        fill=False,
        **halo(sheet, on),
    )


def demo_ring_arc(sheet, cx, cy, on, color, time):
    start = 20.0 + 40.0 * math.sin(time * 0.7)
    d.ring(
        cx,
        cy,
        sheet.unit(15),
        sheet.unit(32),
        color,
        start=start,
        end=start + 250.0,
        **halo(sheet, on),
    )


def demo_ellipse(sheet, cx, cy, on, color, time):
    d.ellipse(cx, cy, sheet.unit(38), sheet.unit(22), color, **halo(sheet, on))


def demo_ellipse_stroke(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.ellipse(cx, cy, u(38), u(22), color, fill=False, thick=u(3), **halo(sheet, on))


def demo_triangle(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.triangle(
        cx,
        cy - u(32),
        cx - u(40),
        cy + u(28),
        cx + u(40),
        cy + u(24),
        color,
        **halo(sheet, on),
    )


def demo_triangle_stroke(sheet, cx, cy, on, color, time):
    u = sheet.unit
    d.triangle(
        cx,
        cy - u(32),
        cx - u(40),
        cy + u(28),
        cx + u(40),
        cy + u(24),
        color,
        fill=False,
        thick=u(3),
        **halo(sheet, on),
    )


def demo_poly(sheet, cx, cy, on, color, time):
    d.poly(cx, cy, 6, sheet.unit(32), color, rotation=time * 40.0, **halo(sheet, on))


def demo_poly_stroke(sheet, cx, cy, on, color, time):
    d.poly(
        cx,
        cy,
        6,
        sheet.unit(32),
        color,
        rotation=time * 40.0,
        fill=False,
        thick=sheet.unit(3),
        **halo(sheet, on),
    )


DEMOS = (
    ("line", demo_line, ORANGE),
    ("polyline", demo_polyline, SKY),
    ("rect", demo_rect, LIME),
    ("rect stroke", demo_rect_stroke, ORANGE),
    ("rect round", demo_rect_round, VIOLET),
    ("rect gradient", demo_rect_gradient, WHITE),
    ("circle", demo_circle, CYAN),
    ("circle stroke", demo_circle_stroke, PINK),
    ("sector", demo_sector, YELLOW),
    ("sector stroke", demo_sector_stroke, LIME),
    ("ring", demo_ring, ORANGE),
    ("ring stroke", demo_ring_stroke, SKY),
    ("ring arc", demo_ring_arc, VIOLET),
    ("ellipse", demo_ellipse, CYAN),
    ("ellipse stroke", demo_ellipse_stroke, PINK),
    ("triangle", demo_triangle, YELLOW),
    ("triangle stroke", demo_triangle_stroke, ORANGE),
    ("poly", demo_poly, LIME),
    ("poly stroke", demo_poly_stroke, SKY),
    ("rotated rect", demo_rect_rotated, VIOLET),
)


def checker_png(size=64, cell=8):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            value = 235 if (x // cell + y // cell) % 2 else 45
            rows.extend((value, value // 2, 255 - value, 255))

    def chunk(tag, payload):
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload))
        )

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(rows)))
        + chunk(b"IEND", b"")
    )


def health_color(value):
    if value > 0.6:
        return LIME
    if value > 0.3:
        return YELLOW
    return RED


class Sheet:
    def __init__(self, ov):
        self.ov = ov
        self.font = self.load_font()
        self.texture = d.load_texture_bytes("png", checker_png())
        d.set_font(self.font)
        self.scale = 1.0
        self.origin_x = 0.0
        self.origin_y = 0.0
        self.time = 0.0
        self.outlines = True
        self.outline_thick = 2.0
        self.animate = True

    @staticmethod
    def load_font():
        name = "arial.ttf" if pm.utils.os_name() == "windows" else "AdwaitaMono-Bold.ttf"
        try:
            return d.load_font(name, 32)
        except pm.errors.Error:
            return None

    def close(self):
        d.set_font(None)
        self.texture.close()
        if self.font is not None:
            self.font.close()

    def unit(self, value):
        return value * self.scale

    def x(self, value):
        return self.origin_x + value * self.scale

    def y(self, value):
        return self.origin_y + value * self.scale

    def text(self, value, x, y, size, color, align="left"):
        d.text(
            value,
            self.x(x),
            self.y(y),
            self.unit(size),
            color=color,
            align=align,
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(2),
        )

    def frame(self):
        if self.animate:
            self.time = pm.utils.time()
        width, height = self.ov.width(), self.ov.height()
        self.scale = min(width / VIRTUAL_WIDTH, height / VIRTUAL_HEIGHT)
        self.origin_x = (width - VIRTUAL_WIDTH * self.scale) / 2
        self.origin_y = (height - VIRTUAL_HEIGHT * self.scale) / 2
        self.header()
        self.shapes(self.time)
        self.texts()
        self.textures(self.time)
        self.boxes(self.time)
        self.menu()

    def menu(self):
        if imgui is None or not self.ov.imgui_active():
            return
        imgui.set_next_window_pos(
            (self.x(40), self.y(VIRTUAL_HEIGHT - 40)),
            imgui.Cond_.first_use_ever,
            (0.0, 1.0),
        )
        imgui.set_next_window_size((300, 112), imgui.Cond_.always)
        imgui.begin("controls")
        _, self.outlines = imgui.checkbox("shape outlines", self.outlines)
        _, self.outline_thick = imgui.slider_float(
            "shape outline width", self.outline_thick, 0.5, 5.0, "%.1f"
        )
        _, self.animate = imgui.checkbox("animate", self.animate)
        imgui.end()

    def header(self):
        self.text("pymew overlay test", 40, 18, 28, WHITE)
        label = str(self.ov.fps())
        width = d.measure_text_ex(self.font, label, 20.0).x
        d.fps(
            self.x(1880) - width,
            self.y(20),
            color=LIME,
            font=self.font,
            outline=True,
            outline_color=BLACK,
            outline_thick=2.0,
        )

    def shapes(self, time):
        for index, (label, painter, color) in enumerate(DEMOS):
            row, column = divmod(index, GRID_COLUMNS)
            x = GRID_LEFT + column * CELL_WIDTH
            y = GRID_TOP + row * CELL_HEIGHT
            self.text(label, x, y, 15, MUTED)
            for offset, on, caption in ((80, False, "plain"), (190, True, "outline")):
                painter(self, self.x(x + offset), self.y(y + 70), on, color, time)
                self.text(caption, x + offset, y + 120, 12, FAINT, align="center")

    def texts(self):
        x = RIGHT_COLUMN
        self.text("text", x, 108, 18, WHITE)
        d.text("plain text", self.x(x), self.y(136), self.unit(16), MUTED)
        d.text(
            "outlined",
            self.x(x + 150),
            self.y(136),
            self.unit(16),
            ORANGE,
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(3),
        )
        d.text(
            "thick outline",
            self.x(x),
            self.y(166),
            self.unit(16),
            CYAN,
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(4),
        )
        d.text(
            "right aligned",
            self.x(x + 600),
            self.y(166),
            self.unit(16),
            PINK,
            align="right",
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(2),
        )
        d.text(
            ["list entries", "become lines"],
            self.x(x),
            self.y(198),
            self.unit(16),
            SKY,
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(1.5),
        )
        d.text_ex(
            self.font,
            "text_ex",
            self.x(x + 300),
            self.y(198),
            self.unit(16),
            LIME,
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(2),
        )

    def textures(self, time):
        x = RIGHT_COLUMN
        y = 298
        self.text("texture", x, 268, 18, WHITE)
        scale = self.unit(1.5)
        size = self.texture.width() * scale
        d.texture(self.texture, self.x(x), self.y(y), scale=scale)
        d.texture(
            self.texture,
            self.x(x + 150),
            self.y(y),
            scale=scale,
            rotation=time * 40.0,
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(2),
        )
        d.texture_rect(
            self.texture,
            (0, 0, self.texture.width(), self.texture.height()),
            (self.x(x + 300), self.y(y), size, size),
            outline=True,
            outline_color=BLACK,
            outline_thick=self.unit(2),
        )
        self.text("plain", x, y + 106, 12, FAINT)
        self.text("rotated", x + 150, y + 106, 12, FAINT)
        self.text("texture_rect", x + 300, y + 106, 12, FAINT)

    def boxes(self, time):
        x = RIGHT_COLUMN
        top = 500
        width = 120
        height = 300
        spacing = 180
        left = x + (600 - width - spacing * 2) / 2
        self.text("entity box", x, 446, 18, WHITE)
        wave = (math.sin(time * 1.3) + 1.0) / 2.0
        specs = (
            ("line", ORANGE, wave, "dashed"),
            ("corner", CYAN, 1.0 - wave, "solid"),
            ("filled", pm.color.fade(LIME, 0.35), 0.35 + 0.65 * wave, "dotted"),
        )
        for index, (style, color, value, snapline) in enumerate(specs):
            box_left = left + index * spacing
            common = {
                "color": color,
                "style": style,
                "thick": self.unit(2),
                "outline": True,
                "outline_color": BLACK,
                "outline_thick": self.unit(1.5),
            }
            if style == "corner":
                box_center = box_left + width / 2
                box = d.entity_box_from_points(
                    (self.x(box_center), self.y(top)),
                    (self.x(box_center), self.y(top + height)),
                    ratio=width / height,
                    **common,
                )
            else:
                box = d.entity_box(
                    self.x(box_left),
                    self.y(top),
                    self.unit(width),
                    self.unit(height),
                    **common,
                )
            box.add_bar(
                "left",
                health_color(value),
                value=value,
                thick=self.unit(4),
                gap=self.unit(5),
                outline=True,
                outline_color=BLACK,
                outline_thick=self.unit(1),
            )
            box.add_bar(
                "right",
                SKY,
                value=1.0 - value,
                thick=self.unit(4),
                gap=self.unit(5),
                reverse=True,
            )
            box.add_text(
                "top",
                style,
                WHITE,
                size=self.unit(13),
                outline=True,
                outline_color=BLACK,
                outline_thick=self.unit(2),
            )
            box.add_snapline(
                "bottom",
                WHITE,
                source="bottom",
                style=snapline,
                thick=self.unit(1.5),
                spacing=self.unit(8),
                outline=True,
                outline_color=BLACK,
                outline_thick=self.unit(1),
            )
            box.draw()


def main():
    with pm.overlay.open(
        fps=144,
        title="pymew overlay test",
        exit_key="end",
        imgui_bundle=imgui is not None,
        imgui_key="insert" if imgui else None,
    ) as ov:
        sheet = Sheet(ov)
        if imgui:
            ov.interact(True)
        try:
            while ov.loop():
                sheet.frame()
        finally:
            sheet.close()


if __name__ == "__main__":
    main()