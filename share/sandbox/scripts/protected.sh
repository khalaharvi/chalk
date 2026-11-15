# bash 5.2 syntax: runs inside the sandbox container (see docs/bash-style.md).
# protected.sh BASE SPEC [PATH...]: prints, one per line, what the tree
# changes since the commit BASE that an agent may not change:
#   - every file at or under a PATH that was changed, deleted or added,
#     whether the agent committed it or not;
#   - SPEC, when its text differs in anything but ticked checkpoints.
# Prints nothing when there is no such change. Fails when it cannot tell,
# as when BASE is not a commit here: the caller must not take silence from
# a failed check for "nothing changed".
set -e
cd /work/repo
base="$1" spec="$2"
shift 2
git cat-file -e "$base^{commit}"

checkpoints() {
  sed 's/- \[[xX]\]/- [ ]/'
}

if [ -n "$spec" ] && git cat-file -e "$base:$spec" 2>/dev/null; then
  was="$(git show "$base:$spec" | checkpoints)"
  now=""
  if [ -f "$spec" ]; then now="$(checkpoints < "$spec")"; fi
  if [ "$was" != "$now" ]; then
    printf '%s (only ticking a checkpoint is allowed)\n' "$spec"
  fi
fi

# Each git command is run on its own, not in a pipeline, so that its
# failure stops the script.
if [ $# -gt 0 ]; then
  changed="$(git -c core.quotePath=false diff --name-only "$base" -- "$@")"
  added="$(git -c core.quotePath=false ls-files --others --exclude-standard -- "$@")"
  printf '%s\n%s\n' "$changed" "$added" | sed '/^$/d' | sort -u
fi
