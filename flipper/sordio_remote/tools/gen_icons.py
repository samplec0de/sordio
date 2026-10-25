"""Рисует иконки экрана Flipper'а и пишет их в icons.h (формат XBM для canvas_draw_xbm).

    uv run --with pillow python -I tools/gen_icons.py [--preview out.png]

Иконки рисуются кодом, а не лежат PNG-файлами: так их размеры и формы
правятся числами, а не в графическом редакторе. icons.h — результат; руками
его править не надо.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

W, H = 48, 32  # микрофон вместе с волнами по бокам
CX = 24  # ось микрофона


def canvas():
    img = Image.new("1", (W, H), 0)
    return img, ImageDraw.Draw(img)


def mic_body(d, style):
    box = [18, 1, 30, 19]
    if style == "solid":
        d.rounded_rectangle(box, radius=6, fill=1)
    else:
        d.rounded_rectangle(box, radius=6, outline=1, width=2)
    d.arc([13, 6, 35, 26], 0, 180, fill=1, width=2)  # дужка
    d.line([CX, 26, CX, 29], fill=1, width=2)  # ножка
    d.line([17, 30, 31, 30], fill=1, width=2)  # подставка


def waves(d, count):
    # волны расходятся от центра капсюля; внутренняя — первая
    for r in (17, 23)[:count]:
        bbox = [CX - r, 10 - r, CX + r, 10 + r]
        d.arc(bbox, -30, 30, fill=1, width=2)
        d.arc(bbox, 150, 210, fill=1, width=2)


def mic_on(frame):
    """frame 0 — без волн, 1 — одна пара, 2 — две (устойчивое состояние)."""
    img, d = canvas()
    mic_body(d, "solid")
    waves(d, frame)
    return img


def mic_off():
    img, d = canvas()
    mic_body(d, "outline")
    # косая черта с белой обводкой, чтобы читалась поверх микрофона
    d.line([8, 2, 40, 29], fill=0, width=6)
    d.line([8, 2, 40, 29], fill=1, width=2)
    return img


def mic_unknown():
    """Контур без черты: микрофон есть, но управлять им сейчас нечем."""
    img, d = canvas()
    mic_body(d, "outline")
    return img


def bluetooth():
    img = Image.new("1", (7, 11), 0)
    d = ImageDraw.Draw(img)
    d.line([3, 0, 3, 10], fill=1)
    d.line([3, 0, 6, 3], fill=1)
    d.line([6, 3, 0, 8], fill=1)
    d.line([0, 3, 6, 8], fill=1)
    d.line([6, 8, 3, 10], fill=1)
    return img


def xbm_bytes(img):
    w, h = img.size
    px = img.load()
    out = []
    for y in range(h):
        for x0 in range(0, w, 8):
            byte = 0
            for bit in range(8):
                x = x0 + bit
                if x < w and px[x, y]:
                    byte |= 1 << bit  # XBM: младший бит — левый пиксель
            out.append(byte)
    return out


def c_array(name, img):
    data = xbm_bytes(img)
    rows = [", ".join(f"0x{b:02x}" for b in data[i : i + 12]) for i in range(0, len(data), 12)]
    w, h = img.size
    body = ",\n    ".join(rows)
    return (
        f"#define {name.upper()}_W {w}\n#define {name.upper()}_H {h}\n"
        f"static const uint8_t {name}[] = {{\n    {body},\n}};\n"
    )


def main():
    icons = {
        "icon_mic_on_0": mic_on(0),
        "icon_mic_on_1": mic_on(1),
        "icon_mic_on_2": mic_on(2),
        "icon_mic_off": mic_off(),
        "icon_mic_unknown": mic_unknown(),
        "icon_bluetooth": bluetooth(),
    }
    header = "#pragma once\n/* Сгенерировано tools/gen_icons.py — не править руками. */\n#include <stdint.h>\n\n"
    header += "\n".join(c_array(n, i) for n, i in icons.items())
    Path(__file__).resolve().parent.parent.joinpath("icons.h").write_text(header)

    if "--preview" in sys.argv:
        out = sys.argv[sys.argv.index("--preview") + 1]
        scale = 6
        names = list(icons)
        sheet = Image.new("L", (len(names) * (W + 4) * scale, (H + 4) * scale), 200)
        for n, name in enumerate(names):
            big = icons[name].convert("L").point(lambda v: 0 if v else 255).resize(
                (icons[name].width * scale, icons[name].height * scale), Image.NEAREST
            )
            sheet.paste(big, (n * (W + 4) * scale + 2 * scale, 2 * scale))
        sheet.save(out)


main()
