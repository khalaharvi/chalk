# Docs site and README visuals: design

Date: 2026-10-03. Status: approved in conversation, awaiting spec review.

## Goal

The repository is plain text: a 327-line README, no images, no docs folder.
Make the GitHub page show what Chalk does at a glance, and give users and
contributors real documentation.

Success means:

- A visitor to github.com/khalaharvi/chalk sees a banner, badges, a recording
  of a real run and diagrams of the loop before the first wall of text.
- A user can install, set up a repository and run a ticket from the site.
- A contributor can learn where each part of a run lives in `lib/` and how to
  test a change without reading every file.
- The site rebuilds on every push to `main`, and CI fails on broken links.

## Decisions

| Question | Decision |
| :-- | :-- |
| Audience | Both users and contributors, in one site with two sections |
| Site generator | MkDocs with the Material theme |
| Hosting | GitHub Pages at https://khalaharvi.github.io/chalk, deployed by Actions |
| Source | Markdown in `docs/`; `docs/superpowers/` is excluded from the build |
| README | Shrinks to pitch, visuals, quick start and links; detail moves to the site |
| Diagrams | Mermaid, drawn by GitHub and by Material, so no image files to keep in sync |
| Look | Reuse the report card palette: chalkboard `#1c342d`, cream `#f1eee3`, chalk yellow `#f0d878`, typewriter display font |

Rejected: Mintlify (needs an account and a hosted service) and plain
`docs/` Markdown without a site (not a site).

## README

Top to bottom:

1. Banner: `docs/assets/banner.svg`, a chalk wordmark on a blackboard with the
   one-line pitch, drawn by hand in SVG so it stays sharp and small.
2. Badges: CI, Release, latest release version, license.
3. Two-sentence pitch (the current first paragraph, tightened).
4. Demo: `docs/assets/demo.gif`, about 20 seconds of a real `chalk run` on a
   toy ticket, recorded with `vhs` from a checked-in `docs/assets/demo.tape`.
5. "How a run works": the loop as a Mermaid flowchart, plus three lines.
6. Install and quick start (current Install section and the one-ticket
   commands).
7. Report card: `docs/assets/report-card.png`, a screenshot of
   `share/dashboard.html` filled with sample data.
8. Links to the site sections, Status, Contributing, License.

Target length: under 120 lines.

## Site structure

```
docs/
  index.md                    Home: what Chalk is, the loop diagram, where to start
  getting-started.md          Install, chalk doctor, chalk init, first ticket
  guide/
    workflow.md               One ticket, what a run does, writing a good spec
    failures.md               Detention, office hours, lessons (with diagram)
    fleet.md                  Epics, plans, parallel runs
    configuration.md          Every .chalk/config key, from the template
    merge-request-gates.md    The GitLab CI gates
    report-card.md            Dashboard, OpenTelemetry
    permissions.md            Auto mode, what the sandbox allows, compliance note
    prompts.md                Listing and ejecting prompts
    lesson-memory.md          Hindsight
    troubleshooting.md        chalk doctor failures and common run problems
  develop/
    architecture.md           Components diagram; what each lib/*.sh file owns;
                              a run traced through the functions it calls
    sandbox.md                Container layout, mounts, credentials, why the RAM disk
    database.md               Tables, what is recorded per loop, the dashboard query
    testing.md                make check, the fakes, adding an e2e case, test-db
    releasing.md              release.sh, the release workflow, the tap, deploy key
  assets/                     banner.svg, demo.gif, demo.tape, report-card.png
  superpowers/                Design notes, not published
mkdocs.yml
```

Content comes from the current README, CONTRIBUTING.md and the code. Nothing
in the user guide is invented: every command and config key is checked against
`bin/chalk` and `share/templates/config`.

`CONTRIBUTING.md` keeps the ground rules and links to `develop/`.

## Diagrams

Three Mermaid diagrams, each used in the README and the site:

1. **The loop** (flowchart): spec check, then for each checkpoint agent,
   rubric, commit or retry; then review, fix round, merge request; any failure
   path ends in detention.
2. **Failure lifecycle** (flowchart): detention branch, human fix, office
   hours, distilled lesson, tutoring branch, resume.
3. **Architecture** (flowchart): host with `chalk` and the worktree; sandbox
   container with the RAM-disk clone, `claude` and the rubric; `chalk-db`
   Postgres; optional Hindsight; GitLab reached only from the host.

## Build and deploy

- `mkdocs.yml`: Material theme with light and dark palettes from the colours
  above, navigation tabs for Guide and Develop, search, `pymdownx.superfences`
  with the Mermaid fence, `exclude_docs: superpowers/`, `strict: true`.
- `docs/requirements.txt` pins `mkdocs-material`.
- `.github/workflows/docs.yml`: on push to `main` and on pull requests, run
  `mkdocs build --strict`; on `main`, also deploy with `actions/deploy-pages`.
- GitHub Pages enabled for the repository with source "GitHub Actions".
- `make docs` serves the site locally.

## Out of scope

- Fixing the bash 3.2 sandbox mismatch and the cost formatting found during
  the demo run. Separate changes.
- A custom domain, versioned docs, or a logo beyond the banner.

## Checks

- `mkdocs build --strict` passes locally and in CI (no broken links or
  missing nav entries).
- README renders on GitHub with the banner, GIF, image and Mermaid diagrams.
- The Pages URL serves the site after the first deploy.
- `make check` still passes.
