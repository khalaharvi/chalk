# bash 5.2 syntax: runs inside the sandbox container (see docs/bash-style.md).
# export.sh BASE: writes commits made since BASE to /chalk/out.bundle, or
# removes the file when there are none.
set -e
cd /work/repo
rm -f /chalk/out.bundle
if [ "$(git rev-parse HEAD)" != "$1" ]; then
  git bundle create /chalk/out.bundle "$1..HEAD" >/dev/null 2>&1
fi
