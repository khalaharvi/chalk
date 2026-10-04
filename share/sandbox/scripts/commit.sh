# bash 5.2 syntax: runs inside the sandbox container (see docs/bash-style.md).
# commit.sh MESSAGE [--allow-empty]: commits everything in the tree, if there
# is anything to commit or --allow-empty is given.
set -e
cd /work/repo
git add -A
if [ -n "$2" ] || ! git diff --cached --quiet; then
  git commit -q ${2:+"$2"} -m "$1"
fi
