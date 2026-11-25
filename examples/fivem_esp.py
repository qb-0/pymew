import pymew as pm

OFFSETS = {
    "FiveM_b2060_GTAProcess.exe": (0x24C8858, 0x1EC3828, 0x1F6A7E0, 0x1400, 0x10C8),
    "FiveM_b2189_GTAProcess.exe": (0x24E6D90, 0x1EE18A8, 0x1F888C0, 0x1400, 0x10C8),
    "FiveM_b2372_GTAProcess.exe": (0x252DCD8, 0x1F05208, 0x1F9E9F0, 0x1400, 0x10C8),
    "FiveM_b2545_GTAProcess.exe": (0x25667E8, 0x1F2E7A8, 0x1FD6F70, 0x1450, 0x10A8),
    "FiveM_b2612_GTAProcess.exe": (0x2567DB0, 0x1F77EF0, 0x1FD8570, 0x1450, 0x10A8),
    "FiveM_b2699_GTAProcess.exe": (0x26684D8, 0x20304C8, 0x20D8C90, 0x1450, 0x10A8),
    "FiveM_b2802_GTAProcess.exe": (0x254D448, 0x1F5B820, 0x1FBC100, 0x1430, 0x10A8),
    "FiveM_b2944_GTAProcess.exe": (0x257BEA0, 0x1F42068, 0x1FEAAC0, 0x1430, 0x10A8),
    "FiveM_b3095_GTAProcess.exe": (0x2593320, 0x1F58B58, 0x20019E0, 0x1430, 0x10A8),
    "FiveM_b3258_GTAProcess.exe": (0x25B14B0, 0x1FBD4F0, 0x201DBA0, 0x1430, 0x10A8),
    "FiveM_b3407_GTAProcess.exe": (0x25D7108, 0x1F9A9D8, 0x20431C0, 0x1430, 0x10A8),
    "FiveM_b3570_GTAProcess.exe": (0x25EC580, 0x1FB0418, 0x2058BA0, 0x1430, 0x10A8),
    "FiveM_b3751_GTAProcess.exe": (0x2603908, 0x1FC38A8, 0x206C060, 0x12B8, 0x10A8),
    "FiveM_b3788_GTAProcess.exe": (0x26068E0, 0x1FC68A8, 0x206F060, 0x12B8, 0x10A8),
}

class Entity:
    def __init__(self, address=None):
        self.address = address

    def __iter__(self):
        iface = process.read(replay + 0x18, pm.mem.ptr)
        count = process.read(iface + 0x108, pm.mem.i32)
        ped_list = process.read(iface + 0x100, pm.mem.ptr)

        if ped_list and 0 < count <= 10000:
            addresses = process.read(ped_list, pm.mem.array(pm.mem.ptr, count, stride=0x10))

            for address in addresses:
                if address and address != local_player:
                    yield Entity(address)

    def pos(self):
        return process.read(self.address + 0x90, pm.mem.vec3)

    def health(self):
        return process.read(self.address + 0x280, pm.mem.f32)

    def name(self):
        cpi = process.read(self.address + OFFSETS[name][4], pm.mem.ptr)
        net_id = process.read(cpi + 0x30, pm.mem.u32) if cpi and process.read(cpi, pm.mem.ptr) > 0x70000000 else 0
        sentinel = process.read(name_map, pm.mem.ptr)
        node = process.read(sentinel, pm.mem.ptr)

        while node and node != sentinel:
            if process.read(node + 0x10, pm.mem.i32) == net_id:
                text = node + 0x18
                short = process.read(text + 0x18, pm.mem.u16) <= 15
                pointer = text if short else process.read(text, pm.mem.ptr)
                return process.read(pointer, pm.mem.string(16 if short else 64)) if pointer else "NPC"

            next_node = process.read(node, pm.mem.ptr)

            if next_node == node:
                break

            node = next_node
        return "NPC"

    def bone_index(self, skeleton, mask):
        hash_data = process.read(skeleton, pm.mem.ptr)
        count = process.read(hash_data + 0x18, pm.mem.u16)

        if count and process.read(hash_data + 0x1A, pm.mem.i16):
            node = process.read(process.read(hash_data + 0x10, pm.mem.ptr) + 8 * (mask % count), pm.mem.ptr)

            while node:
                if process.read(node, pm.mem.i32) == mask:
                    return process.read(node + 4, pm.mem.i32)

                node = process.read(node + 8, pm.mem.ptr)
            return None

        return mask if mask < process.read(skeleton + 0x5E, pm.mem.u16) else None

    def positions(self, chains):
        skeleton = process.chain(self.address + OFFSETS[name][3], [0x68, 0x178, 0])
        base_matrix = process.read(process.read(skeleton + 0x8, pm.mem.ptr), pm.mem.array(pm.mem.f32, 16))
        bone_array = process.read(skeleton + 0x18, pm.mem.ptr)
        result = dict.fromkeys(sum(chains, ()))

        for mask in result:
            index = self.bone_index(skeleton, mask)

            if index is not None:
                translation = process.read(bone_array + index * 64 + 0x30, pm.mem.vec3)
                result[mask] = tuple(base_matrix[axis] * translation.x + base_matrix[axis + 4] * translation.y + base_matrix[axis + 8] * translation.z + base_matrix[axis + 12] for axis in range(3))

        return result

    def screen(self, position):
        if position:
            x, y, z = position
            clip_x = matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13]
            clip_y = matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14]
            clip_w = matrix[3] * x + matrix[7] * y + matrix[11] * z + matrix[15]

            if clip_w > 0.001:
                return (size.x * (0.5 + 0.5 * clip_x / clip_w) + 0.5, size.y * (0.5 - 0.5 * clip_y / clip_w) - 0.5)

        return None

name = next((p.name for p in pm.mem.processes() if p.name in OFFSETS), None) or exit()
process = pm.mem.open(name)
world, replay, viewport = (process.read(process.base() + offset, pm.mem.ptr) for offset in OFFSETS[name][:3])
citizen_playernames_five = process.module("citizen-playernames-five.dll")
name_map = process.resolve_rip(hits[0]) if (hits := process.scan_range("48 8B 15 ?? ?? ?? ?? 48 C1 E1", citizen_playernames_five.base, citizen_playernames_five.end)) else 0

with process, pm.overlay.open(fps=144, title="pymew") as overlay:
    overlay.set_size(overlay.width(), overlay.height() - 1)
    pm.draw.set_font(pm.draw.load_font("segoeui.ttf", 16))
    red, white, lime, black = pm.color.get("red"), pm.color.get("white"), pm.color.get("lime"), pm.color.get("black")
    chains = ((0x9995, 0xB1C5, 0xEEEB, 0x49D9), (0x9995, 0x9D4D, 0x6E5C, 0xDEAD), (0x9995, 0x60F2, 0x2E28), (0x2E28, 0xE39F, 0xF9BB, 0x3779), (0x2E28, 0xCA72, 0x9000, 0xCC4D), (0x796E, 0x3779, 0xCC4D))
    box_chain, line_chains = chains[-1], chains[:-1]

    while True:
        overlay.begin()
        local_player = process.read(world + 0x8, pm.mem.ptr)
        local_pos = process.read(local_player + 0x90, pm.mem.vec3) if local_player else None
        matrix = process.read(viewport + 0x24C, pm.mem.array(pm.mem.f32, 16))
        size = pm.vec2(overlay.width(), overlay.height())

        for ent in Entity():
            try:
                positions = ent.positions(chains)
                head, left, right = [ent.screen(positions[mask]) for mask in box_chain]
                height = max(left[1], right[1]) - head[1] if all((head, left, right)) else 0

                if height >= 4:
                    box_height = height * 1.2
                    box_width = height / 1.8
                    center_x = (left[0] + right[0]) / 2
                    top = head[1] - height * 0.1
                    left_edge = center_x - box_width / 2

                    for chain in line_chains:
                        points = [ent.screen(positions[mask]) for mask in chain]

                        if all(points):
                            pm.draw.polyline(points, red, thick=1.5)

                    label = f"{ent.name()} ({ent.pos().distance(local_pos):.0f}m)"
                    percent = (min(max(ent.health(), 100.0), 200.0) - 100.0) / 100.0
                    
                    box = pm.draw.entity_box(left_edge, top, box_width, box_height, 0x00000000, outline=False)
                    box.add_bar("left", lime, value=percent, thick=2.0, gap=3.0, outline=True)
                    box.add_text("bottom", label, white, size=16.0, gap=3.0, outline=True, outline_color=black)
                    box.draw()
            except Exception:
                pass

        overlay.end()
