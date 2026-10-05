#!/usr/bin/env bash
# Points the Homebrew formula at a released tag and pushes the tap.
#
#   scripts/update-tap.sh VERSION TAP_DIR
#
# The release workflow runs this after a v* tag is pushed. TAP_DIR is a clone
# of the tap repository, which must be named homebrew-chalk and belong to the
# same owner as this repository. The tag must already be on GitHub.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
tap="${2:-}"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: scripts/update-tap.sh VERSION TAP_DIR   (VERSION like 1.2.3)" >&2; exit 2 ;;
esac
[ -d "$tap/.git" ] || fail "$tap is not a clone of the tap repository"

cd "$(git rev-parse --show-toplevel)"
tag="v$version"

# git@github.com:owner/chalk.git and https://github.com/owner/chalk.git
# both become owner/chalk.
slug="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
case "$slug" in
  */*/*|*:*|"") fail "origin is not a GitHub repository" ;;
esac
owner="${slug%%/*}"
homepage="https://github.com/$slug"
tarball="$homepage/archive/refs/tags/$tag.tar.gz"

sha256="$(curl -fsSL "$tarball" | shasum -a 256 | cut -d' ' -f1)"
[ "${#sha256}" -eq 64 ] || fail "could not download $tarball"

mkdir -p "$tap/Formula"
sed -e "s#@HOMEPAGE@#$homepage#g" -e "s#@TARBALL@#$tarball#" -e "s#@SHA256@#$sha256#" \
    packaging/chalk.rb.in > "$tap/Formula/chalk.rb"
[ -f "$tap/README.md" ] || sed "s#@OWNER@#$owner#g" packaging/tap-README.md > "$tap/README.md"
git -C "$tap" add -A
if git -C "$tap" diff --cached --quiet; then
  echo "tap already points at $tag"
  exit 0
fi
git -C "$tap" commit -q -m "chalk $version"
git -C "$tap" push -q -u origin HEAD
echo "tap updated to $tag"
