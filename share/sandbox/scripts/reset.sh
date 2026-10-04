# bash 5.2 syntax: runs inside the sandbox container (see docs/bash-style.md).
# reset.sh: discards anything a read-only call left in the tree.
set -e
cd /work/repo
git reset -q --hard
git clean -fdq
