#!/usr/bin/env bash
# Tags a release and pushes it. GitHub Actions does the rest.
#
#   scripts/release.sh VERSION
#
# VERSION is like 0.5.0. Pushing the v* tag starts .github/workflows/release.yml,
# which runs the checks, creates the GitHub Release and updates the Homebrew tap.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: scripts/release.sh VERSION   (VERSION like 0.5.0)" >&2; exit 2 ;;
esac

cd "$(git rev-parse --show-toplevel)"
tag="v$version"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "release from the main branch"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag already exists"

make check

# Set the version the CLI reports, if it is not already this one.
sed -i.bak "s/^CHALK_VERSION=.*/CHALK_VERSION=\"$version\"/" bin/chalk && rm -f bin/chalk.bak
if [ -n "$(git status --porcelain)" ]; then
  git commit -q -am "Release $tag"
fi
git tag "$tag"
git push -q origin main "$tag"

slug="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
cat <<DONE

Pushed $tag. The release workflow now publishes it:

  https://github.com/$slug/actions/workflows/release.yml
DONE
