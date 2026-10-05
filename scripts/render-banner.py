#!/usr/bin/env python3
"""Renders the README banner as a report card, in light and dark.

  pip install fonttools brotli
  python3 scripts/render-banner.py

Writes docs/assets/banner-light.svg and docs/assets/banner-dark.svg. All
text is drawn as outlines from docs/assets/fonts/CourierPrime-Regular.woff2,
because GitHub does not load fonts in README images. The rows name what
the report card measures and claim no numbers.
"""

from __future__ import annotations

from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
FONT = ROOT / "docs/assets/fonts/CourierPrime-Regular.woff2"
WIDTH, HEIGHT, MARGIN = 1280, 400, 64

PALETTES = {
    "light": {"bg": "#eef2ee", "text": "#1c342d", "muted": "#5c6f66", "accent": "#735b00", "edge": "#5c6f66"},
    "dark": {"bg": "#1c342d", "text": "#f1eee3", "muted": "#a9b9ae", "accent": "#f0d878", "edge": "#a9b9ae"},
}

TITLE = "Chalk report card"
GRADE = "Chalk"
CAPTION = ["Claude Code agents, one checkpoint at a time,", "with a spend cap and a test gate."]
ROWS = [
    ("Cost per finished checkpoint", "measured"),
    ("Loops that passed the rubric", "committed"),
    ("Detentions resolved in office hours", "learned"),
]


class Outliner:
    def __init__(self, path: Path):
        self.font = TTFont(path)
        self.glyphs = self.font.getGlyphSet()
        self.cmap = self.font.getBestCmap()
        self.units = self.font["head"].unitsPerEm

    def width(self, text: str, size: float) -> float:
        advance = 0
        for ch in text:
            name = self.cmap.get(ord(ch), ".notdef")
            advance += self.glyphs[name].width
        return advance * size / self.units

    def glyph(self, ch: str) -> tuple[str, str]:
        """(id, path data) of a glyph in font units, y pointing down."""
        name = self.cmap.get(ord(ch), ".notdef")
        pen = SVGPathPen(self.glyphs, ntos=lambda v: str(round(v)))
        self.glyphs[name].draw(TransformPen(pen, (1, 0, 0, -1, 0, 0)))
        return f"g{ord(ch):x}", pen.getCommands()

    def text(self, value: str, x: float, y: float, size: float, fill: str, used: dict) -> str:
        """VALUE with its baseline starting at (x, y), as uses of glyphs
        defined once each; USED collects the definitions."""
        scale = size / self.units
        uses = []
        cursor = x
        for ch in value:
            if ch != " ":
                gid, data = self.glyph(ch)
                used[gid] = data
                uses.append(f'<use href="#{gid}" x="{cursor / scale:.0f}"/>')
            cursor += self.width(ch, size)
        return (
            f'<g fill="{fill}" transform="translate(0 {y}) scale({scale:.5f})">'
            + "".join(uses) + "</g>"
        )


def banner(out: Outliner, colours: dict) -> str:
    used: dict = {}

    def text(value, x, y, size, fill):
        return out.text(value, x, y, size, fill, used)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-labelledby="t">',
        "<title id=\"t\">Chalk report card: Claude Code agents, one checkpoint at a time, "
        "with a spend cap and a test gate</title>",
        f'<rect x="0.5" y="0.5" width="{WIDTH - 1}" height="{HEIGHT - 1}" fill="{colours["bg"]}" '
        f'stroke="{colours["edge"]}"/>',
        text(TITLE, MARGIN, 92, 40, colours["text"]),
        f'<rect x="{MARGIN}" y="112" width="{WIDTH - 2 * MARGIN}" height="2" fill="{colours["text"]}"/>',
        text(GRADE, MARGIN, 226, 104, colours["accent"]),
    ]
    for index, line in enumerate(CAPTION):
        parts.append(text(line, 420, 182 + index * 34, 24, colours["text"]))

    left, right, size = MARGIN, WIDTH - MARGIN, 22
    for index, (label, value) in enumerate(ROWS):
        y = 290 + index * 36
        label_end = left + out.width(label, size) + 12
        value_start = right - out.width(value, size)
        parts.append(text(label, left, y, size, colours["text"]))
        parts.append(
            f'<line x1="{label_end:.1f}" y1="{y - 2}" x2="{value_start - 12:.1f}" y2="{y - 2}" '
            f'stroke="{colours["muted"]}" stroke-width="2" stroke-linecap="round" stroke-dasharray="0 7"/>'
        )
        parts.append(text(value, value_start, y, size, colours["accent"]))
    defs = "".join(f'<path id="{gid}" d="{data}"/>' for gid, data in sorted(used.items()))
    parts.insert(2, f"<defs>{defs}</defs>")
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main() -> None:
    out = Outliner(FONT)
    for name, colours in PALETTES.items():
        path = ROOT / f"docs/assets/banner-{name}.svg"
        path.write_text(banner(out, colours), encoding="utf-8")
        print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KiB)")


if __name__ == "__main__":
    main()
