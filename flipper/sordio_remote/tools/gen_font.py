"""Превращает BDF-шрифты в растровую таблицу font.h для приложения Flipper'а.

    python3 -I tools/gen_font.py 5x7.bdf 6x10.bdf 6x13B.bdf

Зачем свой шрифт: штатные шрифты Flipper'а (FontPrimary, FontSecondary) рисуют
только ASCII, а кириллические шрифты прошивки приложениям не экспортируются.

Берутся шрифты X11 misc-fixed (5x7, 6x10 и 6x13B) из репозитория u8g2,
`tools/font/bdf/`. Оба — общественное достояние («Public domain font.  Share
and enjoy.»). Сами BDF в репозиторий не входят; font.h — результат, руками
его править не надо.
"""
import sys
from pathlib import Path

# ASCII, русский алфавит с Ё/ё.
CODES = sorted(list(range(0x20, 0x7F)) + [0x401, 0x451] + list(range(0x410, 0x450)))


def parse_bdf(path):
    ascent = descent = cell_w = None
    glyphs = {}
    cur = None
    in_bitmap = False
    for line in Path(path).read_text(encoding="latin-1").splitlines():
        words = line.split()
        if not words:
            continue
        key = words[0]
        if in_bitmap:
            if key == "ENDCHAR":
                in_bitmap = False
                glyphs[cur["code"]] = cur
            else:
                cur["rows"].append(int(key, 16))
            continue
        if key == "FONT_ASCENT":
            ascent = int(words[1])
        elif key == "FONT_DESCENT":
            descent = int(words[1])
        elif key == "FONTBOUNDINGBOX":
            cell_w = int(words[1])
        elif key == "STARTCHAR":
            cur = {"rows": []}
        elif key == "ENCODING":
            cur["code"] = int(words[1])
        elif key == "DWIDTH":
            cur["advance"] = int(words[1])
        elif key == "BBX":
            cur["w"], cur["h"], cur["xoff"], cur["yoff"] = map(int, words[1:5])
        elif key == "BITMAP":
            in_bitmap = True
    return ascent, descent, cell_w, glyphs


def render(font_path, name):
    ascent, descent, cell_w, glyphs = parse_bdf(font_path)
    cell_h = ascent + descent
    assert cell_w <= 8, "глифы шире байта не поддержаны"
    codes, rows_out = [], []
    for code in CODES:
        g = glyphs.get(code)
        assert g, f"{name}: в шрифте нет U+{code:04X}"
        cell = [0] * cell_h
        top = ascent - (g["h"] + g["yoff"])
        for r, bits in enumerate(g["rows"]):
            y = top + r
            if not 0 <= y < cell_h:
                continue
            # BDF: строка выровнена влево по старшим битам байта.
            row = 0
            for x in range(g["w"]):
                if bits & (0x80 >> x):
                    px = g["xoff"] + x
                    if 0 <= px < cell_w:
                        row |= 1 << px  # XBM: младший бит — левый пиксель
            cell[y] = row
        codes.append(code)
        rows_out.extend(cell)
    return name, cell_w, cell_h, codes, rows_out


def emit(name, w, h, codes, rows):
    codes_c = ", ".join(f"0x{c:04x}" for c in codes)
    lines = []
    for i in range(0, len(rows), 13):
        lines.append(", ".join(f"0x{b:02x}" for b in rows[i : i + 13]))
    bits_c = ",\n    ".join(lines)
    return (
        f"static const uint16_t {name}_codes[] = {{{codes_c}}};\n"
        f"static const uint8_t {name}_bits[] = {{\n    {bits_c},\n}};\n"
        f"static const BitmapFont {name} = {{{w}, {h}, {w}, {len(codes)}, "
        f"{name}_codes, {name}_bits}};\n"
    )


def main():
    small, mid, big = sys.argv[1], sys.argv[2], sys.argv[3]
    header = (
        "#pragma once\n"
        "/* Сгенерировано tools/gen_font.py из шрифтов X11 misc-fixed 5x7, 6x10 и 6x13B\n"
        " * (общественное достояние) — не править руками. */\n"
        "#include <stdint.h>\n\n"
        "typedef struct {\n"
        "    uint8_t width;   /* ширина ячейки, она же шаг */\n"
        "    uint8_t height;\n"
        "    uint8_t advance;\n"
        "    uint16_t count;\n"
        "    const uint16_t* codes; /* по возрастанию */\n"
        "    const uint8_t* bits;   /* XBM, height байт на глиф */\n"
        "} BitmapFont;\n\n"
    )
    header += "\n".join(
        [
            emit(*render(small, "font_small")),
            emit(*render(mid, "font_mid")),
            emit(*render(big, "font_big")),
        ]
    )
    Path(__file__).resolve().parent.parent.joinpath("font.h").write_text(header)


main()
