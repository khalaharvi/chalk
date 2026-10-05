# Docs site and README visuals: design

Date: 2026-10-03. Status: revised after an Impeccable critique (25/40),
awaiting spec review.

## Goal

The repository is plain text: a 327-line README, no images, no docs folder.
Make the GitHub page show what Chalk does at a glance, and give users and
contributors real documentation.

Success means:

- A visitor to github.com/khalaharvi/chalk learns within the first screen that
  Chalk runs agents with a spend cap and a test gate, on GitLab repositories,
  and reaches Install within 1.5 screens.
- The school terms (rubric, textbook, detention, office hours, tutoring,
  report card) are explained wherever they appear.
- A user can install, set up a repository and run a ticket from the site.
- A contributor can learn where each part of a run lives in `lib/` and how to
  test a change without reading every file.
- Every image works in GitHub's light and dark themes and has alt text.
- The site rebuilds on every push to `main`, and CI fails on broken links.

## Decisions

| Question | Decision |
| :-- | :-- |
| Audience | Users and contributors, in one site with two sections |
| Visual identity | The report card in `share/dashboard.html`: typewriter headings, ruled lines with dotted leaders, a large grade figure, chalkboard and cream. Not a drawn blackboard |
| School metaphor | Taught: kept everywhere, defined in a glossary, with hover definitions on every site page |
| Hero | A report-card banner with a grade, not a wordmark |
| Demo | A failure and recovery: detention, office hours, success. Recorded against the test fakes so it is free and repeatable |
| Site generator | MkDocs with the Material theme |
| Hosting | GitHub Pages at https://khalaharvi.github.io/chalk, deployed by Actions |
| Source | Markdown in `docs/`; `docs/superpowers/`, `docs/designs/` and `docs/specs/` are excluded from the build |
| Diagrams | Mermaid, unstyled, so GitHub and Material each theme them for light and dark |

Rejected: Mintlify (needs an account and a hosted service), plain `docs/`
Markdown without a site, and a chalk-on-blackboard wordmark (literal, and it
hides the report card, which is the most distinctive visual Chalk has).

## Palette

One set of tokens for the banner, the site and the recording. Light mode uses
the dashboard's light background; chalk yellow is never used on it.

| Token | Light | Dark | Use |
| :-- | :-- | :-- | :-- |
| background | `#eef2ee` | `#1c342d` | Page, banner |
| text | `#1c342d` (11.8:1) | `#f1eee3` (11.5:1) | Body and headings |
| muted | `#5c6f66` (4.7:1) | `#a9b9ae` (6.5:1) | Secondary text |
| accent | `#735b00` (5.8:1) | `#f0d878` (9.4:1) | Links, grade figure |
| waste | `#b3402e` (5.0:1) | `#eba39b` (6.5:1) | Detention, wasted spend |

Ratios are against the background in the same column. `#8a6d00` (4.35:1) is no
longer used for text. The dashboard's light retry colour `#b8860b` (2.88:1) is
darkened to `#8a6400` (4.8:1) in `share/dashboard.html` so the report card
screenshot passes 3:1 for its bars.

Type: headings in the typewriter stack, self-hosted Courier Prime as the
fallback outside macOS; body in the system sans stack. Headings h3 and below
use the body face so they are not mistaken for code.

## README

Top to bottom, Install within 1.5 screens:

1. **Banner.** A report card, about 1280×400: the title "Chalk report card",
   a ruled line, then the three things Chalk grades, as dotted-leader rows
   with no invented numbers: cost per finished checkpoint, loops that passed
   the rubric, detentions resolved in office hours. The grade figure is the
   word "Chalk" set where the dashboard puts its dollar figure, so the banner
   claims nothing it cannot back up. The report card screenshot (item 7)
   and its sample data are captioned as a sample. Two files, `banner-light.svg` and
   `banner-dark.svg`, chosen with `<picture>` and `prefers-color-scheme`.
   All text is converted to outline paths, because GitHub does not load fonts
   in README images. Each has a 1px border so it keeps an edge on GitHub's
   dark page. Alt text is the pitch.
2. **Pitch and status.** Two sentences that name GitLab, then one line:
   "Early: covered by end-to-end tests with fakes; few real-world runs yet."
3. **Badges.** CI, latest version, license; colour `1c342d`.
4. **Demo.** A static poster image (`demo-poster.png`, the last frame) that
   links to the GIF, so nothing autoplays. A `<details>` block below holds a
   text transcript.
5. **Install and quick start.** Including the Docker and `glab` requirements.
6. **How a run works.** The loop diagram, left to right, followed by the
   numbered list that already exists in the README, as its text alternative.
7. **Report card.** `report-card-light.png` and `report-card-dark.png` via
   `<picture>`, with a sentence on what it measures.
8. **Links.** Guide, Develop, Glossary, Contributing, License.

## Demo recording

- `docs/assets/demo.tape` (vhs) drives a scripted session against
  `tests/fakes/` in a throwaway repository, using the e2e failure scenario:
  `chalk run` reaches detention, the human fixes the blocker and runs
  `chalk office-hours -m "…"`, and the resumed run finishes.
- A `scripts/demo-setup.sh` prepares the repository and fakes so the tape is
  reproducible. The recording says "simulated with the test fakes" in its
  first frame.
- vhs theme in the palette above. Width 960px or less, font 16px or larger,
  GIF under about 2 MB. The last frame shows the cost line and the merge
  request link, and is exported as `demo-poster.png`.

## Report card screenshots

`docs/assets/report-card.json` is a checked-in sample in the shape that
`share/dashboard.sql` produces. `scripts/screenshots.sh` injects it the way
`lib/dashboard.sh` does and captures light and dark PNGs at 1280px wide with
headless Chrome.

## Site structure

```
docs/
  index.md                    Home: what Chalk is, the loop diagram, where to start
  getting-started.md          Install, chalk doctor, chalk init, first ticket
  guide/
    running/
      workflow.md             One ticket, what a run does, writing a good spec
      failures.md             Detention, office hours, lessons (with diagram)
      fleet.md                Epics, plans, parallel runs
    configuring/
      configuration.md        Every .chalk/config key, from the template
      permissions.md          Auto mode, what the sandbox allows, compliance note
      prompts.md              Listing and ejecting prompts
      lesson-memory.md        Hindsight
    operating/
      merge-request-gates.md  The GitLab CI gates
      report-card.md          Dashboard, OpenTelemetry
      troubleshooting.md      chalk doctor failures and common run problems
  reference/
    commands.md               Every chalk subcommand and flag, from bin/chalk
    glossary.md               Each school term and the mechanism it names
  develop/
    architecture.md           Components diagram; what each lib/*.sh file owns;
                              a run traced through the functions it calls
    sandbox.md                Container layout, mounts, credentials, why the RAM disk
    database.md               Tables, what is recorded per loop, the dashboard query
    testing.md                make check, the fakes, adding an e2e case, test-db
    releasing.md              release.sh, the release workflow, the tap, deploy key
  includes/abbreviations.md   Glossary terms as abbreviations, appended to every page
  stylesheets/extra.css       Palette tokens and fonts
  assets/                     banners, demo, report card images and fixture
  superpowers/, designs/, specs/   Design notes and specs, not published
mkdocs.yml
```

Top-level tabs: Home, Getting started, Guide, Reference, Develop. No level has
more than five siblings.

Content comes from the current README, CONTRIBUTING.md and the code. Every
command, flag and config key is checked against `bin/chalk` and
`share/templates/config`. `CONTRIBUTING.md` keeps the ground rules and links
to `develop/` instead of repeating the layout table.

## Diagrams

Three Mermaid diagrams, unstyled, each followed by a numbered prose version:

1. **The loop** (left to right; README and home page): spec check, then per
   checkpoint agent, rubric, commit or retry; review and fix round; merge
   request. Every failure leaves through one "detention" exit.
2. **Failure lifecycle** (`guide/running/failures.md`): detention branch,
   human fix, office hours, distilled lesson, tutoring branch, resume.
3. **Architecture** (`develop/architecture.md`): host with `chalk` and the
   worktree; sandbox container with the RAM-disk clone, `claude` and the
   rubric; `chalk-db` Postgres; optional Hindsight; GitLab reached only from
   the host.

## Build and deploy

- `mkdocs.yml`: Material with `font: false`, light and dark palettes with a
  toggle, `primary: custom` and `docs/stylesheets/extra.css`; navigation tabs;
  search; `pymdownx.superfences` with the Mermaid fence; `abbr` with
  `pymdownx.snippets` auto-appending `includes/abbreviations.md`;
  `exclude_docs` lists `superpowers/`, `designs/` and `specs/`; `strict: true`.
- Courier Prime is self-hosted under `docs/assets/fonts/` (SIL Open Font
  License, licence file included).
- `docs/requirements.txt` pins `mkdocs-material`.
- `.github/workflows/docs.yml`: on push to `main` and on pull requests, run
  `mkdocs build --strict`; on `main`, also deploy with `actions/deploy-pages`.
- GitHub Pages enabled for the repository with source "GitHub Actions".
- `make docs` serves the site locally.

## Out of scope

- The bash 3.2 sandbox mismatch and the cost formatting found during the demo
  run. Separate changes. The demo uses the fakes, so it does not show either.
- The report card's own mobile issues (chart labels about 6px at 390px wide,
  a range label in the gutter, notes at about 86 characters a line), beyond
  the retry colour above.
- A custom domain, versioned docs, or a logo.

## Checks

- `mkdocs build --strict` passes locally and in CI.
- The README is checked on GitHub in light and dark: banners, poster, report
  card and the loop diagram all render with visible edges and readable text.
- Every image has alt text; every diagram has a prose version.
- Install is visible within 1.5 screens at 1280×800.
- `scripts/demo-setup.sh` plus `vhs docs/assets/demo.tape` reproduces the GIF.
- The Pages URL serves the site after the first deploy.
- `make check` still passes.
