#!/usr/bin/env python3
"""Check the bundled iOS settings font and its UI character coverage."""
from pathlib import Path
import re
import struct

root = Path(__file__).resolve().parents[1]
font_path = root / "assets/fonts/WWHDSettingsSansSC-Regular.ttf"
font = font_path.read_bytes()


def u16(offset: int) -> int:
    return struct.unpack_from(">H", font, offset)[0]


def u32(offset: int) -> int:
    return struct.unpack_from(">I", font, offset)[0]


assert u32(0) == 0x00010000, "expected a TrueType glyf font"
table_count = u16(4)
assert 12 + table_count * 16 <= len(font)
tables = {}
for index in range(table_count):
    record = 12 + index * 16
    tag = font[record:record + 4].decode("ascii")
    offset, length = u32(record + 8), u32(record + 12)
    assert offset + length <= len(font), f"invalid {tag} table bounds"
    tables[tag] = (offset, length)
assert "glyf" in tables and "cmap" in tables and "fvar" not in tables
os2_offset, os2_length = tables["OS/2"]
assert os2_length >= 6 and u16(os2_offset + 4) == 400, "font must be static regular weight"

cmap_offset, cmap_length = tables["cmap"]
assert cmap_length >= 4 and u16(cmap_offset) == 0
subtables = []
for index in range(u16(cmap_offset + 2)):
    record = cmap_offset + 4 + index * 8
    assert record + 8 <= cmap_offset + cmap_length
    subtable = cmap_offset + u32(record + 4)
    assert subtable + 2 <= cmap_offset + cmap_length
    subtables.append((u16(subtable), subtable))


def has_glyph(codepoint: int) -> bool:
    for fmt, offset in subtables:
        if fmt == 12:
            if offset + 16 > len(font):
                continue
            count = u32(offset + 12)
            if offset + 16 + count * 12 > len(font):
                continue
            for index in range(count):
                group = offset + 16 + index * 12
                first, last, glyph = u32(group), u32(group + 4), u32(group + 8)
                if first <= codepoint <= last:
                    return glyph + codepoint - first != 0
        elif fmt == 4 and codepoint <= 0xFFFF:
            if offset + 14 > len(font):
                continue
            count = u16(offset + 6) // 2
            ends = offset + 14
            starts = ends + count * 2 + 2
            deltas = starts + count * 2
            ranges = deltas + count * 2
            if ranges + count * 2 > len(font):
                continue
            for index in range(count):
                first = u16(starts + index * 2)
                last = u16(ends + index * 2)
                if first <= codepoint <= last:
                    delta = u16(deltas + index * 2)
                    range_offset_at = ranges + index * 2
                    range_offset = u16(range_offset_at)
                    if range_offset == 0:
                        return ((codepoint + delta) & 0xFFFF) != 0
                    glyph_at = range_offset_at + range_offset + (codepoint - first) * 2
                    if glyph_at + 2 > len(font):
                        return False
                    glyph = u16(glyph_at)
                    return glyph != 0 and ((glyph + delta) & 0xFFFF) != 0
    return False


files = list((root / "src/overlay").glob("*.cpp")) + list((root / "src/overlay").glob("*.h"))
files.append(root / "src/platform/ios/controls.mm")
string_literal = re.compile(r'(?<!\\)"(?:\\.|[^"\\])*"')
ui_codepoints = set()
for path in files:
    text = path.read_text(encoding="utf-8")
    for literal in string_literal.findall(text):
        ui_codepoints.update(ord(char) for char in literal if ord(char) > 127)
ui_codepoints.update(map(ord, "△○×□"))
missing = sorted(codepoint for codepoint in ui_codepoints if not has_glyph(codepoint))
assert not missing, "bundled font misses UI glyphs: " + " ".join(f"U+{cp:04X}" for cp in missing)
print(f"PASS: bundled regular TTF, {len(ui_codepoints)} UI symbols and CJK code points, including △○×□")
