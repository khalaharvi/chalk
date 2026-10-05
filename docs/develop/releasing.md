# Releasing

Changes reach `main` only through pull requests, each squash-merged with
its title as the commit. Titles follow
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
(`type(scope): description`), because each one becomes a line in
[CHANGELOG.md](https://github.com/khalaharvi/chalk/blob/main/CHANGELOG.md);
the `pr-title` check runs `scripts/check-commit-title.sh` on every pull
request. The rules are in
[CONTRIBUTING.md](https://github.com/khalaharvi/chalk/blob/main/CONTRIBUTING.md#commit-titles).

## Cutting a release

From a clean `main`, with the new version (the current one is in
`bin/chalk` as `CHALK_VERSION`):

```sh
scripts/release.sh 0.7.0
```

The script refuses to run off `main`, with uncommitted changes, or when
the tag already exists. It runs `make check`, sets the version, and adds a
section to `CHANGELOG.md` built from the commit titles since the last
release (`scripts/changelog.sh`; only `feat`, `fix`, `perf` and `docs`
reach it, and breaking changes get their own heading). It commits both to
`main` as `chore(release): v0.7.0`, then tags `v0.7.0` and pushes.

To reword the section first, generate it with
`scripts/changelog.sh prepend 0.7.0`, edit `CHANGELOG.md`, and commit it as
`chore(release): prepare v0.7.0`. The script then keeps your section
instead of generating a new one.

The pushed tag starts `.github/workflows/release.yml`, which:

1. checks that the tag matches `CHALK_VERSION`;
2. runs `make check` again;
3. creates the GitHub Release with the changelog section as its notes
   (`scripts/changelog.sh notes`), and fails if the section is missing;
4. points the formula in
   [khalaharvi/homebrew-chalk](https://github.com/khalaharvi/homebrew-chalk)
   at the new tarball (`scripts/update-tap.sh`, from
   `packaging/chalk.rb.in`);
5. installs Chalk from the tap on macOS to confirm it works.

If the workflow fails after the push, fix the cause and re-run it from the
Actions tab; the steps are safe to repeat.

The workflow pushes to the tap with a deploy key stored in this
repository's `TAP_DEPLOY_KEY` secret. To update the tap by hand instead,
clone the tap next to this repository and run, from this repository's
root:

```sh
scripts/update-tap.sh 0.7.0 ../homebrew-chalk
```

## The docs site

The site is not versioned: `.github/workflows/docs.yml` rebuilds and
publishes it from `main` on every push, so it describes `main`, which can
be ahead of the latest release. Pull requests build it with
`mkdocs build --strict` and check its links, without publishing.
