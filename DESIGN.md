---
name: Chalk
description: Claude Code agents that work unattended; the harness grades the work on a chalkboard.
colors:
  board: "#1c342d"
  board-deep: "#142822"
  chalk: "#f1eee3"
  chalk-muted: "#a9b9ae"
  chalk-yellow: "#f0d878"
  chalk-red: "#eba39b"
  chalk-green: "#b7d6a3"
  paper: "#eef2ee"
  paper-code: "#e2e8e2"
  ink-muted: "#5c6f66"
  ink-yellow: "#735b00"
  ink-red: "#b3402e"
  ink-green: "#4f7a3a"
typography:
  display:
    fontFamily: "Courier Prime, Courier New, serif"
    fontSize: "clamp(3.5rem, 12vw, 6rem)"
    fontWeight: 400
    lineHeight: 1
  headline:
    fontFamily: "Courier Prime, Courier New, serif"
    fontSize: "1.5rem"
    fontWeight: 400
    lineHeight: 1.2
  title:
    fontFamily: "Courier Prime, Courier New, serif"
    fontSize: "1.25rem"
    fontWeight: 400
    lineHeight: 1.3
  body:
    fontFamily: "Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Avenir Next, Segoe UI, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 600
    lineHeight: 1.4
  transcript:
    fontFamily: "Courier Prime, ui-monospace, monospace"
    fontWeight: 400
  margin-note:
    fontFamily: "Kalam, cursive"
    fontWeight: 400
rounded:
  board: "12px"
components:
  board-art:
    backgroundColor: "{colors.board}"
    textColor: "{colors.chalk}"
    rounded: "{rounded.board}"
  grade-figure:
    textColor: "{colors.chalk-yellow}"
    typography: "{typography.display}"
  link:
    textColor: "{colors.chalk-yellow}"
---

# Design System: Chalk

## Overview

**Creative North Star: "The Graded Chalkboard"**

Chalk's surfaces are a classroom board on which the harness writes what happened and a teacher marks it up. The harness speaks in typewriter mono: the transcript, the station names, the grade. The teacher speaks in a hand (Kalam) in chalk yellow, with hand-wobbled arrows, underlines and squiggles pointing at the line being explained. Nothing is decorative; every mark annotates a real line of output.

Two surfaces share one palette. The report card (`chalk dashboard`) and the docs site follow the reader's scheme: a pale green-grey paper in light, the green board in dark. The README art is always the board, in both GitHub themes, because a board on a white page still reads as a board. The art draws all text as outlines (GitHub loads no fonts in README images).

Density is low and typographic: ruled lines, dotted leaders, tabular figures, no cards or panels.

**Key Characteristics:**
- Dark green board, cream chalk, one yellow accent for the teacher's voice and for links.
- Three roles of colour beyond text: yellow annotates, red marks waste and detention, green marks a passing rubric.
- Typewriter mono for the harness, handwriting only for margin notes.
- Hand-drawn wobble only on strokes (arrows, underlines, squiggles, rings), never on text or rules.
- Flat: depth is ruled lines, never shadow.

## Colors

A two-scheme chalkboard: every role has a dark (chalk on board) and a light (ink on paper) value, each checked for contrast against its own background.

### Primary
- **Chalk Yellow** (`chalk-yellow` dark / `ink-yellow` light): the teacher's voice. Margin notes, annotation arrows, the underline under the wordmark, links, the pull request line, the grade figure, the loop ring in the diagram.

### Secondary
- **Correction Red** (`chalk-red` dark / `ink-red` light): waste and failure. A red rubric exit, the squiggle under it, the retry arrow, detention, spend that made no progress, the spend cap marker.
- **Rubric Green** (`chalk-green` dark / `ink-green` light): pass. "rubric exit 0", the commit station. Used sparingly; most success is plain chalk.

### Neutral
- **Board Green** (`board`): the dark background, and the text colour on light paper. Badges in the README use it as their label/colour.
- **Deep Board** (`board-deep`): code blocks, header and footer on the dark docs site; footer on light.
- **Chalk Cream** (`chalk`): primary text on the board.
- **Dusty Chalk** (`chalk-muted`) / **Slate Ink** (`ink-muted`): secondary text, ticket prefixes, prompts, captions, footers, dotted leaders.
- **Classroom Paper** (`paper`) / **Code Paper** (`paper-code`): light background and light code background.
- **Rule**: chalk or board at about 20% alpha (`rgba(241,238,227,.22)` dark, `rgba(28,52,45,.2)` light; the README art uses `#f1eee338`). Hairlines, table rows, the board's own edge.

### Named Rules
**The Teacher's Pen Rule.** Yellow is the annotator's colour. It marks notes, links and the one outcome that matters (the pull request, the grade), never body text or chrome.

**The Three Marks Rule.** Beyond text and muted, only yellow, red and green carry meaning, and each keeps one meaning on every surface. The report card's per-kind chart series (retry, review, spec check and so on) are data colours for that chart only.

## Typography

**Display Font:** Courier Prime (with Courier New, serif)
**Body Font:** Avenir Next (with Segoe UI, system-ui, sans-serif)
**Transcript Font:** Courier Prime Regular and Bold, outlined in README art; the demo recording uses the system monospace stack
**Margin-note Font:** Kalam Regular, subset in `docs/assets/fonts`

**Character:** A typewriter that prints the facts and a hand that comments on them. The sans body stays plain so the two voices stand out.

### Hierarchy
- **Display** (400, `clamp(3.5rem, 12vw, 6rem)`, 1): the report card's grade figure; in art, the "chalk" wordmark (72px banner, 140px social card) in Courier Prime Bold.
- **Headline** (400, 1.5rem, 1.2): page title (h1).
- **Title** (400, 1.25rem, 1.3): section heads (h2), underlined by a rule on the docs site.
- **Body** (400, 16px, 1.5): prose, max about 42rem; tabular figures in the report card.
- **Label** (600, 1rem, 1.4): h3/h4 and table headers, in the body face so they are not mistaken for code.
- **Transcript** (400, 19px in the banner): harness output, one line per log line, in the log format of `lib/run.sh`.
- **Margin note** (400, 20px in the banner): Kalam in chalk yellow, or red when it explains a failure.

### Named Rules
**The Two Voices Rule.** Mono is what the harness printed; Kalam is what the teacher wrote about it. Never set harness output in Kalam or a note in mono.

**The Outline Rule.** Text in README images is drawn as glyph outlines from the bundled fonts, so it renders without web fonts.

## Layout

The report card is one column, `max-width: 58rem`, with page padding `2.5rem 1.25rem 4rem`; prose caps at 42 to 44rem. Score lines use a dotted leader between label and value in an auto-fit grid (`minmax(17rem, 1fr)`). Tables right-align numbers and scroll horizontally on narrow screens.

The README banner is a 1040-wide board with a 56px inset; transcript lines step 36px, margin notes sit directly under the line they explain, indented and led by a short arrow. The diagram is 1280x620, stations in a row joined by arrows, a dashed rule separating the happy path from the stuck path below it. The social card is 1280x640.

## Elevation & Depth

Flat. No surface casts a shadow. Structure comes from rules: a 2px text-colour rule under the report card header and above the cost range, 1px rules at about 20% alpha between rows and under h2, a dashed rule in the diagram. The board's edge is a 1px rule at the same alpha.

### Named Rules
**The Ruled Board Rule.** Separate with chalk lines, not elevation or filled panels.

## Shapes

Square by default: report card, tables and bars have no radius. The only corner is the board itself (12px) in README art. Hand-drawn strokes are round-capped and round-joined, 2 to 3px (5px on the social card), roughened by the chalk filter (`feTurbulence` fractal noise 0.9, displacement scale 2.2). Arrows are quadratic curves with a two-stroke open head.

**The Chalk Stroke Rule.** The wobble belongs to hand marks only (arrows, underlines, squiggles, the loop ring). Text, rules and the board edge stay crisp.

## Components

### Board Art (README banner, diagram, social card)
Generated by `scripts/render-readme-art.py`; edit the script, not the SVGs. Board background, cream transcript, muted ticket prefix, yellow notes with arrows, red squiggle under a failing exit, yellow underline under the pull request link. Footer row in muted 15px, separated by a rule.

### Diagram Station
A mono bold title (21px) over a 1.5px rule in the station's colour, with a three-line muted caption (18px). Station colour carries meaning: green for commit, yellow for pull request, red for detention, chalk otherwise.

### Grade Figure
The report card's headline number, display size in yellow, followed by a body-size sentence saying what it measures.

### Score Line
Label, dotted muted leader, value in 600 weight.

### Links
Yellow, underlined (1px, offset 0.15em) in body text so colour is not the only cue. Glossary terms use a dotted muted underline.

### Notes and Collapsibles (docs site)
Muted border, title bar tinted with yellow at 10% alpha, yellow icon.

## Do's and Don'ts

### Do:
- **Do** put every margin note directly under the line it explains, with an arrow pointing at it.
- **Do** keep each colour on one meaning: yellow annotates, red is waste or detention, green is a passing rubric.
- **Do** give every role a light and a dark value with stated contrast against its own background (light accent `ink-yellow` is 5.8:1 on paper).
- **Do** draw README text as outlines from the bundled Courier Prime and Kalam files.
- **Do** keep transcripts in the real log format of the shipped version, and say the run is illustrative.

### Don't:
- **Don't** add shadows, gradients or filled cards; the board is flat and ruled.
- **Don't** apply the chalk filter to text or to structural rules.
- **Don't** use yellow for body text or decoration.
- **Don't** set prose or harness output in Kalam.
- **Don't** invent numbers, users or testimonials in art; figures are illustrative and labelled so.
