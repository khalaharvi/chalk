# bash 5.2 syntax: runs inside the sandbox container (see docs/bash-style.md).
# clone.sh BRANCH AUTHOR EMAIL: clones the branch into the RAM disk, borrowing
# objects from the read-only host store so nothing is copied.
set -e
git config --global --add safe.directory "*"
git config --global user.name "$2"
git config --global user.email "$3"
git clone -q --shared --branch "$1" /src.git /work/repo
