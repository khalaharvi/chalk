#!/usr/bin/env bash
# Cuts a release on GitHub and publishes it to the Homebrew tap.
#
#   scripts/release.sh VERSION TAP_DIR
#
# VERSION is like 0.4.0. TAP_DIR is a clone of the tap repository, which must
# be named homebrew-chalk and belong to the same owner as this repository.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
tap="${2:-}"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: scripts/release.sh VERSION TAP_DIR   (VERSION like 0.4.0)" >&2; exit 2 ;;
esac
[ -d "$tap/.git" ] || fail "$tap is not a clone of the tap repository"

cd "$(git rev-parse --show-toplevel)"
tag="v$version"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "release from the main branch"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag already exists"

# git@github.com:owner/chalk.git and https://github.com/owner/chalk.git
# both become owner/chalk.
slug="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
case "$slug" in
  */*/*|*:*|"") fail "origin is not a GitHub repository" ;;
esac
owner="${slug%%/*}"
homepage="https://github.com/$slug"
tarball="$homepage/archive/refs/tags/$tag.tar.gz"

make check

# Set the version the CLI reports, if it is not already this one.
sed -i.bak "s/^CHALK_VERSION=.*/CHALK_VERSION=\"$version\"/" bin/chalk && rm -f bin/chalk.bak
if [ -n "$(git status --porcelain)" ]; then
  git commit -q -am "Release $tag"
fi
git tag "$tag"
git push -q origin main "$tag"

sha256="$(curl -fsSL "$tarball" | shasum -a 256 | cut -d' ' -f1)"
[ "${#sha256}" -eq 64 ] || fail "could not download $tarball"

mkdir -p "$tap/Formula"
sed -e "s#@HOMEPAGE@#$homepage#g" -e "s#@TARBALL@#$tarball#" -e "s#@SHA256@#$sha256#" \
    packaging/chalk.rb.in > "$tap/Formula/chalk.rb"
[ -f "$tap/README.md" ] || sed "s#@OWNER@#$owner#g" packaging/tap-README.md > "$tap/README.md"
git -C "$tap" add -A
git -C "$tap" commit -q -m "chalk $version"
git -C "$tap" push -q -u origin HEAD

cat <<DONE

Released $tag. Install with:

  brew install $owner/chalk/chalk

Upgrade an existing install with:

  brew update && brew upgrade chalk
DONE
