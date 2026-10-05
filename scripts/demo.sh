#!/usr/bin/env bash
# Records the demo on the docs site and in the README: a ticket goes to
# detention, a person fixes it in office hours, and the resumed run opens a
# merge request. It runs the real chalk against the fakes in tests/fakes, so
# it needs no Docker and spends nothing, and it is the same on every machine.
#
#   scripts/demo.sh                  writes docs/assets/demo.cast and demo.txt
#   python3 scripts/render-demo.py   turns the cast into demo.svg and demo-poster.svg
#
# `make demo` does both. demo.cast is an asciinema v2 recording, so
# `asciinema play docs/assets/demo.cast` also replays it.
set -euo pipefail
cd "$(dirname "$0")/.."
here="$PWD"
cast="$here/docs/assets/demo.cast"
transcript="$here/docs/assets/demo.txt"

need() { command -v "$1" >/dev/null || { echo "demo.sh needs $1" >&2; exit 1; }; }
need git
need jq

tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# The fakes, as in tests/e2e.sh, plus two thin overlays in $tmp/bin: glab
# prints a merge request URL, and the database answers the ticket summary
# from the calls actually recorded, so the closing line adds up.
mkdir -p "$tmp/bin" "$tmp/fake" "$tmp/home"
export DEMO_FAKES="$here/tests/fakes"
cat > "$tmp/bin/glab" <<'GLAB'
#!/usr/bin/env bash
"$DEMO_FAKES/glab" "$@"
if [ "$1 $2" = "mr create" ]; then echo "https://gitlab.example.com/acme/shop/-/merge_requests/42"; fi
GLAB
cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" chalk-db psql "*) ;;
  *) exec "$DEMO_FAKES/docker" "$@" ;;
esac
sql="$(cat)"
ledger="$FAKE_STATE/demo-ledger"
touch "$ledger"
case "$sql" in
  *"INSERT INTO runs"*)
    kind="" cost=""
    for arg in "$@"; do
      case "$arg" in kind=*) kind="${arg#kind=}" ;; cost=*) cost="${arg#cost=}" ;; esac
    done
    echo "call $kind $cost" >> "$ledger" ;;
  *"SET resolution"*) echo "fix" >> "$ledger" ;;
  *"FROM runs WHERE repo"*)
    awk '$1 == "call" { cost += $3; if ($2 ~ /^(continue|retry|fix-review)$/) loops++ }
         $1 == "fix" { fixes++ }
         END { printf "%d %.2f %d\n", loops, cost, fixes }' "$ledger"
    exit 0 ;;
esac
printf '%s\n' "$sql" | "$DEMO_FAKES/docker" "$@"
DOCKER
chmod +x "$tmp/bin/glab" "$tmp/bin/docker"

export PATH="$tmp/bin:$here/tests/fakes:$here/bin:$PATH"
export FAKE_STATE="$tmp/fake" XDG_STATE_HOME="$tmp/state" HOME="$tmp/home"
export ANTHROPIC_API_KEY="demo-key"
export GIT_AUTHOR_NAME="Sam Rivera" GIT_AUTHOR_EMAIL="sam@example.com"
export GIT_COMMITTER_NAME="Sam Rivera" GIT_COMMITTER_EMAIL="sam@example.com"

# The recording: asciinema v2 events, timed in whole milliseconds so that
# no floating point is needed.
width=92 height=30 clock=0
printf '{"version": 2, "width": %d, "height": %d, "title": "Chalk: detention, office hours, merge request (simulated with the test fakes)"}\n' \
  "$width" "$height" > "$cast"
: > "$transcript"

# emit TEXT: one output event at the current time.
emit() {
  printf '[%d.%03d, "o", %s]\n' $((clock / 1000)) $((clock % 1000)) \
    "$(printf '%s' "$1" | jq -Rs .)" >> "$cast"
}
pause() { clock=$((clock + $1)); }

# Paths in the output are shown as if the demo ran in /home/sam.
show() {
  local text="${1//"$tmp/state"//home/sam/.local/state}"
  text="${text//"$tmp/work"//home/sam}"
  printf '%s' "${text//"$tmp"//home/sam}"
}

# prompt -> REPLY: the prompt, named after the current directory.
prompt() {
  REPLY="${PWD##*/} \$ "
}

# say TEXT: a comment typed at the prompt, as narration.
say() {
  prompt
  emit "$REPLY"
  type_out "# $1"
  emit $'\r\n'
  printf '%s# %s\n' "$REPLY" "$1" >> "$transcript"
  pause 900
}

# type_out TEXT: types TEXT a few characters at a time.
type_out() {
  local text="$1" i
  for ((i = 0; i < ${#text}; i += 3)); do
    emit "${text:i:3}"
    pause 45
  done
}

# step COMMAND [PAUSE_MS]: types COMMAND, runs it in this shell, and plays
# its output back a line at a time.
step() {
  local command="$1" line out status=0
  prompt
  emit "$REPLY"
  pause 300
  type_out "$command"
  pause 250
  emit $'\r\n'
  printf '%s%s\n' "$REPLY" "$command" >> "$transcript"
  out="$tmp/out"
  eval "$command" > "$out" 2>&1 || status=$?
  while IFS= read -r line; do
    line="$(show "$line")"
    emit "$line"$'\r\n'
    printf '%s\n' "$line" >> "$transcript"
    pause 220
  done < "$out"
  pause "${2:-1400}"
  return 0
}

# A repository with a rubric that rejects a stray file named BROKEN.
mkdir -p "$tmp/work"
git init -q --bare "$tmp/work/shop.git"
git init -q -b main "$tmp/work/shop"
cd "$tmp/work/shop"
git remote add origin "$tmp/work/shop.git"
printf '#!/bin/sh\nif [ -e BROKEN ]; then echo "FAIL: stray BROKEN file"; exit 1; fi\necho "2 passed"\n' > test.sh
chmod +x test.sh
chalk init >/dev/null
sed -i.bak 's|^CHALK_TEST_CMD=.*|CHALK_TEST_CMD=./test.sh|' .chalk/config && rm .chalk/config.bak
git add -A && git commit -q -m "Add Chalk"
git push -q origin main

say "Simulated with Chalk's test fakes: no Docker, no model calls, no spend."
step 'chalk new SHOP-7 "Add a discount code field"' 900
step 'cd ../shop.worktrees/SHOP-7' 300

cat > specs/SHOP-7.md <<'SPEC'
# SHOP-7: Add a discount code field

## Context
Checkout needs a field for a discount code, validated on the server.

## Checkpoints
- [ ] Validate discount codes in the checkout API, with tests
- [ ] Show the discount code field on the checkout page, with tests
SPEC
git add -A && git commit -q -m "Spec for SHOP-7"
say "Spec written and committed: two checkpoints. Each loop leaves a stray file."
export FAKE_CLAUDE_MODE=break
step 'chalk run'

detention="$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/SHOP-7-*')"
say "Nothing was pushed. A person looks at the parked work and fixes it."
step "git switch -q $detention"
step 'git rm -q BROKEN && git commit -q -m "Remove the stray BROKEN file"' 600
unset FAKE_CLAUDE_MODE
step 'chalk office-hours -m "Never commit scratch files such as BROKEN"' 4000

printf 'wrote %s (%d.%03ds) and %s\n' "${cast#"$here"/}" $((clock / 1000)) $((clock % 1000)) "${transcript#"$here"/}"
