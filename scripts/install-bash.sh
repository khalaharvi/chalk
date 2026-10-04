#!/usr/bin/env bash
# Builds the bash that Chalk requires from GNU source, with the official
# patches applied, and installs it under PREFIX.
#
#   scripts/install-bash.sh PREFIX
#
# CI uses this on Linux, where the runner's bash is too old, and caches
# PREFIX. Anyone without Homebrew can use it the same way, then point
# CHALK_BASH at PREFIX/bin/bash. Downloads are checked against the
# checksums below, so bumping the version or patch level means updating
# them too.
set -euo pipefail

BASH_RELEASE="5.3"
BASH_PATCHES=20
BASH_TARBALL_SHA256="0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba"
# sha256 of patches 001..BASH_PATCHES concatenated in order.
BASH_PATCHES_SHA256="67aa3c11559c91dde818a8466a6a0b312de5f42b0c3f6b90cdd61ec4b7c8fd4d"
GNU_URL="https://ftp.gnu.org/gnu/bash"

fail() { echo "error: $*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

prefix="${1:-}"
[ -n "$prefix" ] || { echo "usage: scripts/install-bash.sh PREFIX" >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

curl -fsSL -o bash.tar.gz "$GNU_URL/bash-$BASH_RELEASE.tar.gz"
[ "$(sha256 < bash.tar.gz)" = "$BASH_TARBALL_SHA256" ] || fail "checksum mismatch for bash-$BASH_RELEASE.tar.gz"

patch_name="bash${BASH_RELEASE//./}"
for ((n = 1; n <= BASH_PATCHES; n++)); do
  curl -fsSL "$GNU_URL/bash-$BASH_RELEASE-patches/$(printf '%s-%03d' "$patch_name" "$n")"
done > patches
[ "$(sha256 < patches)" = "$BASH_PATCHES_SHA256" ] || fail "checksum mismatch for bash $BASH_RELEASE patches"

tar xzf bash.tar.gz
cd "bash-$BASH_RELEASE"
patch -s -p0 < ../patches
./configure --quiet --prefix="$prefix" --without-bash-malloc > /dev/null
make -s -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" > /dev/null
make -s install > /dev/null

"$prefix/bin/bash" --version | head -n 1
