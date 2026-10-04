#!/usr/bin/env bash
# lib/repo.sh and lib/state.sh: value functions, and git asked once per
# working directory for the repository's identity.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime repo state

# A git that counts how often it is asked for the common dir.
real_git="$(command -v git)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/git" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" --git-common-dir "*) echo x >> "$tmp/common-dir-calls" ;; esac
exec "$real_git" "\$@"
FAKE
chmod +x "$tmp/bin/git"
PATH="$tmp/bin:$PATH"

git init -q -b main "$tmp/my-repo"
git -C "$tmp/my-repo" commit -q --allow-empty -m init
git -C "$tmp/my-repo" worktree add -q -b chalk/PROJ-9 "$tmp/my-repo.worktrees/PROJ-9"
cd "$tmp/my-repo.worktrees/PROJ-9"
XDG_STATE_HOME="$tmp/state"

check "repo_name is the primary checkout's name, even in a worktree" test "${| repo_name; }" = "my-repo"
check "main_root is the primary checkout" test "${| main_root; }" = "$(cd "$tmp/my-repo" && pwd -P)"
check "worktree_dir sits next to the primary checkout" \
  test "${| worktree_dir PROJ-10; }" = "$(cd "$tmp/my-repo" && pwd -P).worktrees/PROJ-10"
check "run_dir is under the state directory" test "${| run_dir PROJ-9; }" = "$tmp/state/chalk/my-repo/runs/PROJ-9"
check "current_branch reads the branch" test "${| current_branch; }" = "chalk/PROJ-9"
check "git was asked for the common dir once" test "$(wc -l < "$tmp/common-dir-calls")" -eq 1

check "ticket_from_branch finds the key" test "${| ticket_from_branch detention/PROJ-12-1700000000; }" = "PROJ-12"
check "ticket_from_branch is empty without a key" test -z "${| ticket_from_branch main; }"

mkdir -p "$tmp/run"
check "run_pid is empty when no pid is recorded" test -z "${| run_pid "$tmp/run"; }"
check "a run with no pid is not alive" eval '! run_is_alive "$tmp/run"'
echo $$ > "$tmp/run/pid"
check "run_pid reads the recorded pid" test "${| run_pid "$tmp/run"; }" = "$$"
check "a run with a live pid is alive" run_is_alive "$tmp/run"
