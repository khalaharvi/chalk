#!/usr/bin/env python3
"""Renders the README art: the annotated run, the run diagram and the
social preview.

  pip install fonttools brotli
  python3 scripts/render-readme-art.py

Writes docs/assets/run-banner.svg, docs/assets/run-diagram.svg and, when
rsvg-convert is installed, docs/assets/social-preview.png (upload it under
Settings > Social preview). The art is a chalkboard in both GitHub themes:
a board on a white page still reads as a board.

All text is drawn as outlines, because GitHub does not load fonts in README
images: Courier Prime for what the harness prints, Kalam for the margin
notes. The transcript follows the log format of lib/run.sh; keep it in step
when that format changes.
"""

from __future__ import annotations

import math
import shutil
import subprocess
import tempfile
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
FONTS = ROOT / "docs/assets/fonts"

# The report card's dark palette (share/dashboard.html).
BOARD = {
    "bg": "#1c342d", "text": "#f1eee3", "muted": "#a9b9ae", "rule": "#f1eee338",
    "accent": "#f0d878", "waste": "#eba39b", "pass": "#b7d6a3",
}


class Outliner:
    def __init__(self, path: Path, key: str):
        self.key = key
        self.font = TTFont(path)
        self.glyphs = self.font.getGlyphSet()
        self.cmap = self.font.getBestCmap()
        self.units = self.font["head"].unitsPerEm

    def width(self, text: str, size: float) -> float:
        advance = 0
        for ch in text:
            advance += self.glyphs[self.cmap.get(ord(ch), ".notdef")].width
        return advance * size / self.units

    def glyph(self, ch: str) -> tuple[str, str]:
        """(id, path data) of a glyph in font units, y pointing down."""
        name = self.cmap.get(ord(ch), ".notdef")
        pen = SVGPathPen(self.glyphs, ntos=lambda v: str(round(v)))
        self.glyphs[name].draw(TransformPen(pen, (1, 0, 0, -1, 0, 0)))
        return f"{self.key}{ord(ch):x}", pen.getCommands()


class Board:
    """One SVG drawing: text as uses of glyphs defined once, chalk strokes."""

    def __init__(self, fonts: dict[str, Outliner]):
        self.fonts = fonts
        self.used: dict[str, str] = {}
        self.parts: list[str] = []

    def width(self, value: str, size: float, font: str = "mono") -> float:
        return self.fonts[font].width(value, size)

    def text(self, value, x, y, size, fill, font="mono", anchor="start") -> float:
        """Draws VALUE with its baseline at (x, y); returns where it ends."""
        out = self.fonts[font]
        width = out.width(value, size)
        if anchor == "end":
            x -= width
        scale = size / out.units
        uses, cursor = [], x
        for ch in value:
            if ch != " ":
                gid, data = out.glyph(ch)
                self.used[gid] = data
                uses.append(f'<use href="#{gid}" x="{cursor / scale:.0f}"/>')
            cursor += out.width(ch, size)
        self.parts.append(
            f'<g fill="{fill}" transform="translate(0 {y}) scale({scale:.5f})">'
            + "".join(uses) + "</g>"
        )
        return x + width

    def spans(self, parts, x, y, size) -> float:
        for value, fill in parts:
            x = self.text(value, x, y, size, fill)
        return x

    def line(self, x1, y1, x2, y2, colour, width=1.0, dash=""):
        dash = f' stroke-dasharray="{dash}"' if dash else ""
        self.parts.append(
            f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{colour}" stroke-width="{width}"{dash}/>'
        )

    def stroke(self, d, colour, width=2.2):
        """A chalk stroke: round ends, slightly rough through the chalk filter."""
        self.parts.append(
            f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{width}" '
            'stroke-linecap="round" stroke-linejoin="round" filter="url(#chalk)"/>'
        )

    def arrow(self, x1, y1, x2, y2, colour, bend=18.0):
        """A hand-drawn arrow from (x1, y1) to (x2, y2), bowed by BEND."""
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2 - bend
        angle = math.atan2(y2 - my, x2 - mx)
        a1 = (x2 - 11 * math.cos(angle - 0.5), y2 - 11 * math.sin(angle - 0.5))
        a2 = (x2 - 11 * math.cos(angle + 0.5), y2 - 11 * math.sin(angle + 0.5))
        self.stroke(f"M{x1} {y1} Q{mx:.1f} {my:.1f} {x2} {y2}", colour)
        self.stroke(f"M{a1[0]:.1f} {a1[1]:.1f} L{x2} {y2} L{a2[0]:.1f} {a2[1]:.1f}", colour)

    def squiggle(self, x1, x2, y, colour):
        d, x, up = f"M{x1:.1f} {y}", x1, True
        while x < x2:
            d += f" Q{x + 4.5:.1f} {y - 3.5 if up else y + 3.5} {min(x + 9, x2):.1f} {y}"
            x, up = x + 9, not up
        self.stroke(d, colour, 2)

    def svg(self, width, height, title, colours) -> str:
        defs = "".join(f'<path id="{gid}" d="{data}"/>' for gid, data in sorted(self.used.items()))
        return "\n".join([
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height:.0f}" role="img" aria-labelledby="t">',
            f'<title id="t">{title}</title>',
            '<defs><filter id="chalk" x="-5%" y="-20%" width="110%" height="140%">'
            '<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="7" result="n"/>'
            '<feDisplacementMap in="SourceGraphic" in2="n" scale="2.2"/></filter>' + defs + "</defs>",
            f'<rect x="0.5" y="0.5" width="{width - 1}" height="{height - 1:.0f}" rx="12" '
            f'fill="{colours["bg"]}" stroke="{colours["rule"]}"/>',
            *self.parts,
            "</svg>",
        ]) + "\n"


def run_banner(fonts, c) -> str:
    """A `chalk run` transcript with each margin note under the line it explains."""
    b = Board(fonts)
    width, x, size = 1040, 56, 19
    y = 108.0

    b.text("chalk", x, y, 72, c["text"], font="mono_bold")
    b.stroke(f"M{x + 2} {y + 16} Q{x + 100} {y + 10} {x + 214} {y + 15}", c["accent"], 3)
    y += 52
    b.text("Claude Code agents that work unattended.", x, y, 24, c["text"])
    y += 32
    b.text("The harness, not the agent, decides when the work is done.", x, y, 24, c["muted"])
    y += 34
    b.line(x, y, width - x, y, c["rule"])
    y += 50

    ticket = ("[API-7] ", c["muted"])

    def line(parts) -> tuple[float, float]:
        nonlocal y
        end = b.spans(parts, x, y, size)
        row = (y, end)
        y += 36
        return row

    def note(rows, at):
        nonlocal y
        y -= 4
        b.arrow(at + 22, y + 4, at, y - 20, c["accent"], 6)
        for index, row in enumerate(rows):
            b.text(row, at + 34, y + 12 + index * 26, 20, c["accent"], font="hand")
        y += len(rows) * 26 + 22

    line([("$ ", c["muted"]), ("chalk run", c["text"])])
    line([ticket, ("starting sandbox chalk-sandbox-api-API-7 on chalk/API-7", c["text"])])
    note(["A throwaway container with no GitHub or GitLab credentials.",
          "Then a cheap model checks the spec, without a log line."], x + 90)
    line([ticket, ("loop 1 (continue): agent ok ($0.38, 94s), ", c["text"]),
          ("rubric exit 0", c["pass"]), (". Token bucket.", c["text"])])
    before = "[API-7] loop 2 (continue): agent ok ($0.61, 142s), "
    red_y, _ = line([ticket, (before[8:], c["text"]),
                     ("rubric exit 1", c["waste"]), (". Router wired.", c["text"])])
    red = x + b.width(before, size)
    b.squiggle(red, red + b.width("rubric exit 1", size), red_y + 9, c["waste"])
    note(["Red: the harness ran your tests itself. The agent gets the",
          "failure and another try. Every agent call has its own $1 cap."], x + 90)
    line([ticket, ("loop 3 (retry): agent ok ($0.27, 71s), ", c["text"]),
          ("rubric exit 0", c["pass"]), (". 429 test fixed.", c["text"])])
    line([ticket, ("final review: pass. No stubs, no weakened tests.", c["text"])])
    note(["A second agent reviews the change before anything leaves your machine."], x + 90)
    line([ticket, ("all checkpoints complete (3 loops, $1.47, 0 human interventions)", c["text"])])
    pr_y, pr_end = line([("https://github.com/acme/api/pull/42", c["accent"])])
    b.stroke(f"M{x - 4} {pr_y + 10} Q{x + 200} {pr_y + 5} {pr_end + 6:.1f} {pr_y + 9}", c["accent"], 2.4)
    note(["Only now is anything pushed."], x + 40)

    y += 6
    b.line(x, y, width - x, y, c["rule"])
    y += 30
    b.text("An illustrative run, in the log format of chalk 0.6.", x, y, 15, c["muted"])
    b.text("github.com/khalaharvi/chalk", width - x, y, 15, c["muted"], anchor="end")
    return b.svg(width, y + 30,
                 "chalk: Claude Code agents that work unattended. A sample chalk run starts a "
                 "sandbox without forge credentials, loops under a spend cap while the harness "
                 "runs the tests itself, retries after a red test run, passes an independent "
                 "review, and only then opens a pull request.", c)


def run_diagram(fonts, c) -> str:
    """The loop, the review and the pull request; below, the way out when stuck."""
    b = Board(fonts)
    width, height = 1280, 620

    def station(x, y, w, title, caption, colour=None):
        colour = colour or c["text"]
        b.text(title, x, y, 21, colour, font="mono_bold")
        b.line(x, y + 12, x + w, y + 12, colour, 1.5)
        for index, row in enumerate(caption):
            b.text(row, x, y + 42 + index * 24, 18, c["muted"])

    b.text("What one chalk run does", 64, 74, 28, c["text"], font="mono_bold")
    b.text("specs/API-7.md lists the checkpoints. The run works through them one at a time.",
           64, 106, 16, c["muted"])

    top = 196
    station(64, top, 200, "spec check", ["is every box", "small and", "testable?"])
    b.arrow(274, top - 6, 334, top - 6, c["text"], 4)

    # The loop, drawn as a chalk ring around three stations.
    t, w = top - 52, top + 112
    b.stroke(f"M336 {t} L842 {t} Q858 {t} 858 {t + 16} L858 {w - 16} Q858 {w} 842 {w} "
             f"L336 {w} Q320 {w} 320 {w - 16} L320 {t + 16} Q320 {t} 336 {t}", c["accent"], 2)
    b.text("the loop, once per checkpoint", 336, top - 64, 20, c["accent"], font="hand")
    station(344, top, 150, "agent", ["takes the", "next box,", "under a cap"])
    b.arrow(500, top - 6, 528, top - 6, c["text"], 3)
    station(534, top, 130, "rubric", ["the harness", "runs your", "tests"])
    b.arrow(670, top - 6, 698, top - 6, c["text"], 3)
    station(704, top, 140, "commit", ["ticks the", "box, moves", "your branch"], c["pass"])
    b.arrow(600, top + 100, 420, top + 100, c["waste"], -22)
    b.text("red: retry with the failure output", 410, top + 140, 18, c["waste"], font="hand")

    b.arrow(866, top - 6, 902, top - 6, c["text"], 4)
    station(910, top, 120, "review", ["a second", "agent, one", "fix round"])
    b.arrow(1040, top - 6, 1074, top - 6, c["text"], 4)
    station(1082, top, 134, "pull request", ["pushed with", "loops, cost", "and review"], c["accent"])

    b.line(64, 388, width - 64, 388, c["rule"], 1, "2 6")
    low = 470
    b.arrow(330, top + 104, 170, low - 36, c["waste"], -10)
    b.arrow(950, top + 96, 270, low - 24, c["waste"], -10)
    b.text("stuck: blocked, out of retries or loops, or the review still fails",
           560, 424, 20, c["waste"], font="hand")

    station(64, low, 210, "detention", ["work parked on", "a local branch;", "nothing pushed"], c["waste"])
    b.arrow(286, low - 6, 330, low - 6, c["text"], 4)
    station(338, low, 290, "chalk office-hours", ["you fix the blocker,", "commit, leave a note"])
    b.arrow(640, low - 6, 684, low - 6, c["text"], 4)
    station(692, low, 160, "lesson", ["kept for later", "loops, in any", "repository"])
    b.arrow(864, low - 6, 908, low - 6, c["text"], 4)
    station(916, low, 160, "resume", ["back into the", "loop, on a", "tutoring/", "branch"])

    return b.svg(width, height,
                 "What one chalk run does: a spec check, then a loop per checkpoint in which the "
                 "agent works under a spend cap, the harness runs the tests itself and commits on "
                 "green or retries on red, then an independent review and a pull request. A stuck "
                 "run goes to detention; you fix it with chalk office-hours, the fix becomes a "
                 "lesson, and the run resumes.", c)


def social_card(fonts, c) -> str:
    b = Board(fonts)
    x = 96
    b.text("chalk", x, 230, 140, c["text"], font="mono_bold")
    b.stroke(f"M{x + 4} 262 Q{x + 200} 252 {x + 418} 260", c["accent"], 5)
    b.text("Claude Code agents that work unattended.", x, 340, 36, c["text"])
    b.text("The harness, not the agent, decides when", x, 392, 36, c["muted"])
    b.text("the work is done.", x, 436, 36, c["muted"])
    b.text("spend caps · a test gate it runs itself · detention when stuck",
           x, 540, 32, c["accent"], font="hand")
    return b.svg(1280, 640, "chalk: Claude Code agents that work unattended.", c)


def main() -> None:
    fonts = {
        "mono": Outliner(FONTS / "CourierPrime-Regular.woff2", "m"),
        "mono_bold": Outliner(FONTS / "CourierPrime-Bold.woff2", "b"),
        "hand": Outliner(FONTS / "Kalam-Regular.woff2", "h"),
    }
    for name, draw in (("run-banner", run_banner), ("run-diagram", run_diagram)):
        path = ROOT / f"docs/assets/{name}.svg"
        path.write_text(draw(fonts, BOARD), encoding="utf-8")
        print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KiB)")

    rsvg = shutil.which("rsvg-convert")
    if not rsvg:
        print("skipped docs/assets/social-preview.png: needs rsvg-convert (brew install librsvg)")
        return
    png = ROOT / "docs/assets/social-preview.png"
    with tempfile.NamedTemporaryFile("w", suffix=".svg", encoding="utf-8") as card:
        card.write(social_card(fonts, BOARD))
        card.flush()
        subprocess.run([rsvg, "-w", "1280", "-h", "640", "-o", str(png), card.name], check=True)
    print(f"wrote {png.relative_to(ROOT)} ({png.stat().st_size // 1024} KiB)")


if __name__ == "__main__":
    main()
