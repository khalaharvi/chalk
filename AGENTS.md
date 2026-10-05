# Notes for coding agents

Chalk is a bash 5.3 CLI. Before changing code:

1. Read [docs/bash-style.md](docs/bash-style.md). Its rules are not
   optional. In particular, a value function (`-> REPLY`) must never return
   non-zero, because a failing `${| … }` ends Chalk.
2. Follow [CONTRIBUTING.md](CONTRIBUTING.md) for setup and pull requests.
   `make check` must pass, with bash 5.3 first on `PATH`.
3. Every external program the harness calls has a fake in `tests/fakes/`.
   The tests never run real Docker, `claude`, `gh` or `glab`, so say in the
   pull request what was and was not tried for real.

Planned work and its design notes are in [docs/roadmap.md](docs/roadmap.md)
and [docs/designs/roadmap-2026-27.md](docs/designs/roadmap-2026-27.md).
