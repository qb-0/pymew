import pymew as pm
from imgui_bundle import imgui


def main():
    text = ""
    draw_box = True

    with pm.overlay.open(
        fps=144,
        title="pymew + imgui",
        exit_key="end",
        imgui_bundle=True,
        imgui_key="insert",
    ) as ov:
        while ov.loop():
            if ov.imgui_active():
                imgui.begin("pymew + imgui")
                _, draw_box = imgui.checkbox("draw box", draw_box)
                _, text = imgui.input_text("text", text)
                imgui.text(f"{ov.fps()} fps")
                imgui.end()

            if draw_box:
                box = pm.draw.entity_box_from_points(
                    (ov.width() * 0.50, ov.height() * 0.25),
                    (ov.width() * 0.60, ov.height() * 0.65),
                    pm.color.get("orange"),
                    ratio=0.5,
                    style="corner",
                    thick=2.0,
                )
                box.add_text("top", text, size=14)
                box.draw()


if __name__ == "__main__":
    main()