#!/usr/bin/env bash
# Seeded environment faults, for the evaluation of evidence-carrying lessons
# (paper Section 5, experiments/README.md). Each fault is a small task whose
# rubric needs something the sandbox image lacks. The agent runs as a
# non-root user with no sudo, so it cannot install it: a genuine
# environment blocker. Each comes with the oracle fix an engineer would make
# (an image that has it) and the note they would write.
#
#   experiments/faults.sh OUT_DIR [--build]
#
# Writes OUT_DIR/corpus/FAULT.json instances and OUT_DIR/repos/FAULT task
# repositories. --build builds the faulty and fixed images with docker,
# FROM ${EXP_BASE_IMAGE:-chalk-sandbox:local}.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=experiments/lib.sh
. "$here/lib.sh"

out="${1:-}" build=0
[[ -n $out ]] || exp_die "usage: experiments/faults.sh OUT_DIR [--build]"
[[ ${2:-} != --build ]] || build=1
base="${EXP_BASE_IMAGE:-chalk-sandbox:local}"
exp_need git jq

# The catalogue: ID, then what the faulty image removes (empty: the base
# image already lacks it), what the fixed image installs (empty: the base
# image has it), the rubric, and the note.
declare -A remove=() install=() rubric=() note=()
ids=(python3 gcc make jq)
install[python3]="python3"
rubric[python3]="python3 -m unittest -q"
note[python3]="The sandbox image had no python3; this repository's image now installs it."
install[gcc]="gcc libc6-dev"
rubric[gcc]="cc -o /tmp/calc_test calc_test.c calc.c && /tmp/calc_test"
note[gcc]="The sandbox image had no C compiler; this repository's image now installs gcc and libc6-dev."
install[make]="make"
rubric[make]="make test"
note[make]="The sandbox image had no make; this repository's image now installs it."
remove[jq]="/usr/bin/jq"
rubric[jq]="jq -e '.ok == true' status.json"
note[jq]="jq was missing from the sandbox image; this repository's image restores it."

# task FAULT DIR: writes the task repository for FAULT into DIR: a failing
# test and the code it needs, small enough for one loop.
task() {
  case "$1" in
    python3)
      printf 'def add(a, b):\n    raise NotImplementedError\n' > "$2/calc.py"
      printf 'import unittest\nfrom calc import add\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n' > "$2/test_calc.py" ;;
    gcc)
      printf 'int add(int a, int b) { return 0; }\n' > "$2/calc.c"
      printf 'int add(int, int);\nint main(void) { return add(2, 3) == 5 ? 0 : 1; }\n' > "$2/calc_test.c" ;;
    make)
      printf 'module.exports = (a, b) => 0;\n' > "$2/add.js"
      printf "const add = require('./add');\nif (add(2, 3) !== 5) { console.error('add is wrong'); process.exit(1); }\n" > "$2/add.test.js"
      printf 'test:\n\tnode add.test.js\n' > "$2/Makefile" ;;
    jq)
      printf '{"ok": false}\n' > "$2/status.json" ;;
  esac
}

mkdir -p "$out/corpus" "$out/repos"
out="$(cd "$out" && pwd)"
for id in "${ids[@]}"; do
  repo="$out/repos/$id"
  rm -rf "$repo"
  mkdir -p "$repo"
  task "$id" "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" add -A
  git -C "$repo" -c user.name=exp -c user.email=exp@localhost commit -q -m "task: $id"
  faulty="$base" fixed="$base"
  [[ -z ${remove[$id]-} ]] || faulty="chalk-exp-$id-faulty"
  [[ -z ${install[$id]-} ]] || fixed="chalk-exp-$id-fixed"
  jq -n --arg id "$id" --arg repo "../repos/$id" --arg rubric "${rubric[$id]}" --arg image "$faulty" \
     --arg fixed "$fixed" --arg note "${note[$id]}" '
    {id: "fault-\($id)", kind: "fault", repo: $repo, workspace: "fault-\($id)",
     title: "Make the test pass (\($id))",
     problem: "Make the failing test pass. The rubric is `\($rubric)`.",
     checkpoints: ["Make the rubric `\($rubric)` pass"],
     test_cmd: $rubric, image: $image,
     oracle: {image: $fixed, note: $note}}' > "$out/corpus/fault-$id.json"
  if (( build )); then
    exp_need docker
    if [[ -n ${remove[$id]-} ]]; then
      printf 'FROM %s\nUSER root\nRUN rm -f %s\n' "$base" "${remove[$id]}" | docker build -q -t "$faulty" - >/dev/null
    fi
    if [[ -n ${install[$id]-} ]]; then
      printf 'FROM %s\nUSER root\nRUN apt-get update && apt-get install -y --no-install-recommends %s && rm -rf /var/lib/apt/lists/*\n' \
        "$base" "${install[$id]}" | docker build -q -t "$fixed" - >/dev/null
    fi
  fi
  exp_info "fault-$id: image $faulty, fixed by $fixed"
done
exp_info "corpus: $out/corpus"
