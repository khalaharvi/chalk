#!/usr/bin/env python3
"""Renders docs/assets/demo.cast (written by scripts/demo.sh) as SVG.

  python3 scripts/render-demo.py [CAST]

Writes, next to the cast:
  demo.svg         the recording, animated with CSS, looping
  demo-poster.svg  its last frame, still, for places where nothing should move

No dependencies beyond the standard library. The terminal is drawn in the
dark report-card palette in both light and dark page themes, with a 1px
border so it keeps an edge on a dark page. The output Chalk prints is plain
text, so this handles only newlines, carriage returns and wrapping; any ANSI
escape is dropped.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

FONT_SIZE = 15
CHAR_W = 9.0          # advance of a 15px monospace glyph, about 0.6em
LINE_H = 20
PAD = 16
BAR_H = 30            # title bar
END_HOLD = 6.0        # seconds the last frame stays before the loop restarts

BG = "#1c342d"
TEXT = "#f1eee3"
MUTED = "#a9b9ae"
ACCENT = "#f0d878"
WASTE = "#eba39b"
FONTS = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'DejaVu Sans Mono', 'Liberation Mono', monospace"

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
PROMPT = re.compile(r"^(\S+ \$ )(.*)$")


def frames(cast: Path):
    """(header, [(time, lines)]): the screen after each event."""
    events = cast.read_text(encoding="utf-8").splitlines()
    header = json.loads(events[0])
    width, height = header["width"], header["height"]
    lines = [""]
    col = 0
    out = []
    for raw in events[1:]:
        time, kind, data = json.loads(raw)
        if kind != "o":
            continue
        for ch in ANSI.sub("", data):
            if ch == "\n":
                lines.append("")
                col = 0
            elif ch == "\r":
                col = 0
            elif ch >= " ":
                if col >= width:
                    lines.append("")
                    col = 0
                line = lines[-1]
                lines[-1] = line[:col] + ch + line[col + 1:]
                col += 1
        screen = tuple(lines[-height:])
        if out and out[-1][0] == time:
            out[-1] = (time, screen)
        elif not out or out[-1][1] != screen:
            out.append((time, screen))
    return header, out


def line_svg(text: str, y: float) -> str:
    """One terminal line, coloured by what it is."""
    match = PROMPT.match(text)
    x = PAD
    if match:
        prompt, rest = match.groups()
        colour = MUTED if rest.startswith("#") else ACCENT
        return (
            f'<text x="{x}" y="{y}" xml:space="preserve"><tspan fill="{MUTED}">{escape(prompt)}</tspan>'
            f'<tspan fill="{colour}">{escape(rest)}</tspan></text>'
        )
    colour = TEXT
    if "DETENTION" in text:
        colour = WASTE
    elif text.startswith("https://"):
        colour = ACCENT
    return f'<text x="{x}" y="{y}" fill="{colour}" xml:space="preserve">{escape(text)}</text>'


def screen_svg(lines, line_ids) -> str:
    uses = []
    for row, text in enumerate(lines):
        if text:
            y = BAR_H + PAD + row * LINE_H
            uses.append(f'<use xlink:href="#{line_ids[(text, )]}" y="{y}"/>')
    return "".join(uses)


def svg(header, shots, animate: bool) -> str:
    width = round(header["width"] * CHAR_W + 2 * PAD)
    height = BAR_H + 2 * PAD + header["height"] * LINE_H - (LINE_H - FONT_SIZE)
    title = header.get("title", "Chalk demo")

    # Every distinct line is defined once and placed with <use>.
    line_ids: dict = {}
    defs = []
    for _, lines in (shots if animate else shots[-1:]):
        for text in lines:
            if text and (text, ) not in line_ids:
                line_ids[(text, )] = f"l{len(line_ids)}"
                defs.append(line_svg(text, 0).replace("<text ", f'<text id="{line_ids[(text, )]}" ', 1))

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        f'width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="t">',
        f"<title id=\"t\">{escape(title)}</title>",
        f'<style>text{{font-family:{FONTS};font-size:{FONT_SIZE}px}}</style>',
        f'<defs>{"".join(defs)}</defs>',
        f'<rect x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="6" fill="{BG}" stroke="{MUTED}"/>',
        f'<line x1="0.5" y1="{BAR_H}" x2="{width - 0.5}" y2="{BAR_H}" stroke="{MUTED}" stroke-opacity="0.4"/>',
        f'<text x="{PAD}" y="{BAR_H - 10}" fill="{MUTED}" style="font-size:13px">'
        f"chalk · simulated with the test fakes</text>",
        f'<svg x="0" y="0" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
    ]
    if not animate:
        parts.append(screen_svg(shots[-1][1], line_ids))
    else:
        total = shots[-1][0] + END_HOLD
        keys = []
        film = []
        for index, (time, lines) in enumerate(shots):
            offset = index * width
            film.append(f'<g transform="translate({offset} 0)">{screen_svg(lines, line_ids)}</g>')
            keys.append(f"{time / total * 100:.3f}%{{transform:translateX(-{offset}px)}}")
        keys.append(f"100%{{transform:translateX(-{(len(shots) - 1) * width}px)}}")
        parts.append(
            "<style>@keyframes film{" + "".join(keys) + "}"
            f".film{{animation:film {total:.2f}s steps(1,end) infinite}}"
            "@media (prefers-reduced-motion: reduce){.film{animation:none;"
            f"transform:translateX(-{(len(shots) - 1) * width}px)}}}}</style>"
        )
        parts.append(f'<g class="film">{"".join(film)}</g>')
    parts.append("</svg></svg>")
    return "\n".join(parts) + "\n"


def main() -> None:
    cast = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/assets/demo.cast")
    header, shots = frames(cast)
    if not shots:
        sys.exit(f"{cast}: no output events")
    for name, animate in (("demo.svg", True), ("demo-poster.svg", False)):
        out = cast.with_name(name)
        out.write_text(svg(header, shots, animate), encoding="utf-8")
        print(f"wrote {out} ({out.stat().st_size // 1024} KiB, {len(shots)} frames)")


if __name__ == "__main__":
    main()
