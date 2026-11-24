import pymew as pm


isWindows = pm.utils.os_name() == "windows"


class Options:
    process = "ac_client.exe" if isWindows else "linux_64_client"
    max_entities = 32
    fps = 144
    title = f"pymew cross platform esp"
    exit_key = "end"
    track = True

    color_enemy = pm.color.get("orange")
    color_team = pm.color.get("cyan")
    color_name = pm.color.get("white")
    color_outline = pm.color.get("black")
    color_outline_bar = pm.color.get("white")
    health_high = pm.color.get("lime")
    health_mid = pm.color.get("yellow")
    health_low = pm.color.get("red")
    health_mid_at = 50
    health_low_at = 25

    box_style = "corner"
    box_fill = 0.05
    box_ratio = 0.7
    box_thick = 1.5
    box_outline = True
    box_outline_thick = 1.0

    bar_side = "left"
    bar_thick = 4
    bar_gap = 6
    bar_reverse = False
    bar_outline_thick = 1.0

    font_name = "arial.ttf" if isWindows else "AdwaitaMono-Bold.ttf"
    font_size = 14

    name_anchor = "top"
    name_size = 14
    name_nudge = (0, -5)
    name_outline_thick = 2.0

    snapline_anchor = "bottom"
    snapline_source = "bottom"
    snapline_style = "dashed"
    snapline_spacing = 8.0
    snapline_outline_thick = 1.0

    show_fps = True


class Pointer:
    if isWindows:
        entity_list = 0x18AC04
        local_player = 0x18AC00
        view_matrix = 0x17DFD0
    else:
        entity_list = 0x1A3520
        local_player = 0x1A3518
        view_matrix = 0x1B4FCC


class Offsets:
    if isWindows:
        name = 0x205
        health = 0xEC
        team = 0x30C
        pos = 0x04
        feet = 0x50
        head = 0x58
    else:
        name = 0x219
        health = 0x100
        team = 0x320
        pos = 0x08
        feet = 0x54
        head = 0x5C


class Entity(pm.mem.Struct):
    pos = pm.mem.vec3.at(Offsets.pos)
    feet = pm.mem.f32.at(Offsets.feet)
    head = pm.mem.f32.at(Offsets.head)
    health = pm.mem.i32.at(Offsets.health)
    name = pm.mem.string(30).at(Offsets.name)
    team = pm.mem.i32.at(Offsets.team)

    view = None

    @property
    def alive(self):
        return self.health > 0 and self.health <= 100

    @property
    def feetpos(self):
        return self.project(self.pos.z - self.feet)

    @property
    def headpos(self):
        return self.project(self.pos.z + self.head)

    def project(self, z):
        matrix, width, height = self.view
        x, y = self.pos.x, self.pos.y
        clip_w = x * matrix[3] + y * matrix[7] + z * matrix[11] + matrix[15]
        if clip_w < 0.2:
            return None
        clip_x = x * matrix[0] + y * matrix[4] + z * matrix[8] + matrix[12]
        clip_y = x * matrix[1] + y * matrix[5] + z * matrix[9] + matrix[13]
        return pm.vec2(
            width * 0.5 * (1.0 + clip_x / clip_w),
            height * 0.5 * (1.0 - clip_y / clip_w),
        )


def main():
    if not pm.mem.exists(Options.process):
        print(f"{Options.process} is not running")
        return

    d = pm.draw

    with pm.mem.open(Options.process) as p:
        base = p.base()
        pointer_size = 8 if p.is_64bit() else 4
        with pm.overlay.open(
            target=Options.process,
            fps=Options.fps,
            title=Options.title,
            exit_key=Options.exit_key,
            track=Options.track,
        ) as ov:
            try:
                font = d.load_font(Options.font_name, Options.font_size)
            except pm.errors.Error:
                print(f"font '{Options.font_name}' not found, using the default font")
                font = None
            d.set_font(font)

            while ov.loop():
                if not p.alive():
                    break
                width = ov.width()
                height = ov.height()
                matrix = p.read(base + Pointer.view_matrix, pm.mem.f32, 16)
                entity_list = p.read(base + Pointer.entity_list, pm.mem.ptr)
                local_addr = p.read(base + Pointer.local_player, pm.mem.ptr)
                local_player = p.read(local_addr, Entity) if local_addr else None

                if Options.show_fps:
                    d.fps(10, 10)

                if not entity_list:
                    continue

                for i in range(Options.max_entities):
                    addr = p.read(entity_list + i * pointer_size, pm.mem.ptr)
                    if not addr or addr == local_addr:
                        continue

                    try:
                        ent = p.read(addr, Entity)
                    except (pm.errors.Error, UnicodeDecodeError):
                        continue

                    if not ent.alive:
                        continue

                    ent.view = (matrix, width, height)
                    feet = ent.feetpos
                    top = ent.headpos
                    if feet is None or top is None:
                        continue

                    friendly = local_player.team in (0, 1) and ent.team == local_player.team
                    color = Options.color_team if friendly else Options.color_enemy

                    if ent.health <= Options.health_low_at:
                        bar_color = Options.health_low
                    elif ent.health <= Options.health_mid_at:
                        bar_color = Options.health_mid
                    else:
                        bar_color = Options.health_high

                    box = d.entity_box_from_points(
                        top, feet, color,
                        ratio=Options.box_ratio,
                        style=Options.box_style,
                        fill=Options.box_fill,
                        thick=Options.box_thick,
                        outline=Options.box_outline,
                        outline_color=Options.color_outline,
                        outline_thick=Options.box_outline_thick,
                    )
                    box.add_bar(
                        Options.bar_side, bar_color,
                        value=ent.health / 100.0,
                        thick=Options.bar_thick,
                        gap=Options.bar_gap,
                        reverse=Options.bar_reverse,
                        outline_color=Options.color_outline_bar,
                        outline_thick=Options.bar_outline_thick,
                    )
                    box.add_text(
                        Options.name_anchor, ent.name or "player", Options.color_name,
                        size=Options.name_size,
                        font=font,
                        nudge=Options.name_nudge,
                        outline_color=Options.color_outline,
                        outline_thick=Options.name_outline_thick,
                    )
                    box.add_text(
                        "bottom",
                        [f"{ent.health} HP", f"{int(ent.pos.distance(local_player.pos))}m"],
                        Options.color_name,
                        size=Options.name_size,
                        font=font,
                        nudge=(0, 5),
                        outline_color=Options.color_outline,
                        outline_thick=Options.name_outline_thick,
                    )
                    box.add_snapline(
                        Options.snapline_anchor, pm.color.fade(color, 0.3),
                        source=Options.snapline_source,
                        style=Options.snapline_style,
                        spacing=Options.snapline_spacing,
                        outline_thick=Options.snapline_outline_thick,
                    )
                    box.draw()


if __name__ == "__main__":
    main()