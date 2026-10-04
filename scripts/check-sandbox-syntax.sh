#!/usr/bin/env bash
# Parses share/sandbox/scripts/*.sh with a bash 5.2, the oldest bash a
# sandbox image may have, so newer syntax cannot slip into code that runs
# in the container.
#
#   scripts/check-sandbox-syntax.sh BASH
#
# CI passes /usr/bin/bash, which is 5.2 on ubuntu-latest.
set -euo pipefail
cd "$(dirname "$0")/.."

floor="${1:?usage: scripts/check-sandbox-syntax.sh BASH}"
probe='echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"'
version="$("$floor" -c "$probe")"
if [ "$version" != "5.2" ]; then
  echo "error: $floor is bash $version; this check needs bash 5.2, the sandbox floor" >&2
  exit 1
fi

for script in share/sandbox/scripts/*.sh; do
  "$floor" -n "$script"
done
echo "sandbox scripts parse under bash $version"
