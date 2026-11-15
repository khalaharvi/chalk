# Exam integrity: what the harness checks about a change without asking a
# model, so that the agent cannot mark its own work.
#
#   - Protected files (CHALK_PROTECTED: the rubric's configuration, the
#     prompts and the CI gates by default) may not be changed by an agent,
#     and a spec may only have its checkpoints ticked. A loop that does
#     either is not committed (cmd_run).
#   - Tests that were deleted, skipped or left with fewer assertions since
#     the branch left its base are listed for the reviewer and on the pull
#     or merge request (CHALK_TEST_GUARD).
#
# Paths here come from an agent's diff. They are only ever compared and
# printed, never used as array keys or in arithmetic, where bash would
# evaluate them.

# A path is a test file when it matches this: a tests directory, or a test
# name as Go, JavaScript, Python, Ruby, Java, Kotlin, C#, Swift and shell
# projects write them. Tests inside source files, as in Rust, are not seen.
INTEGRITY_TEST_RE='(^|/)(tests?|__tests__|spec|e2e)/|(^|/)test_[^/]*$|[._-](tests?|spec)\.[A-Za-z0-9]+$|Tests?\.(java|kt|cs|swift)$'

# An added line that turns a test off, or narrows the run to one test.
INTEGRITY_SKIP_RE='\.(skip|only|todo)\(|(^|[^A-Za-z0-9_])(xit|xdescribe|xtest|fit|fdescribe)[ (]|@(pytest\.mark\.(skip|skipif|xfail)|unittest\.(skip|skipIf|skipUnless|expectedFailure)|Disabled|Ignore)|pytest\.skip\(|skipTest\(|(^|[^A-Za-z0-9_])t\.Skip(f|Now)?\(|#\[ignore|(^|[^A-Za-z0-9_])(skip|pending)[ (]'

# A line that asserts something.
INTEGRITY_ASSERT_RE='[Aa]ssert|(^|[^A-Za-z0-9_])(expect|should|must|require|verify|check)[ (._!]|EXPECT_|ASSERT_|(^|[^A-Za-z0-9_])t\.(Error|Fatal|Fail)|\.should[ .(]'

# integrity_protected VAR: fills the array VAR with the paths no agent may
# change: CHALK_PROTECTED, split on spaces, and the textbook. Empty when
# CHALK_PROTECTED is "none".
integrity_protected() {
  local -n __paths=$1
  local path
  __paths=()
  [[ $CHALK_PROTECTED != none ]] || return 0
  read -ra __paths <<<"$CHALK_PROTECTED"
  for path in "${__paths[@]}"; do
    [[ $CHALK_TEXTBOOK != "$path" && $CHALK_TEXTBOOK != "$path"/* ]] || return 0
  done
  __paths+=("$CHALK_TEXTBOOK")
}

# integrity_changed SANDBOX BASE SPEC: prints what the sandbox's tree
# changes since the commit BASE that an agent may not change, one per line:
# protected files, and SPEC when more than its ticks changed (see
# share/sandbox/scripts/protected.sh). Prints nothing when CHALK_PROTECTED
# is "none". Fails when the sandbox could not be asked, which a caller
# that is about to commit must treat as a change.
integrity_changed() {
  local -a paths
  [[ $CHALK_PROTECTED != none ]] || return 0
  integrity_protected paths
  sandbox_script "$1" protected "$2" "$3" "${paths[@]}"
}

# integrity_feedback CHANGED -> REPLY: what the next loop is told when the
# last one changed CHANGED, the output of integrity_changed.
integrity_feedback() {
  REPLY="the rubric passed, but nothing was committed, because this session changed files the harness protects:
$1
Put each of them back exactly as it was (git diff shows the change), then make the rubric pass without changing them. Protected files hold the rubric's configuration, the prompts and the CI gates, and a spec may only have its checkpoints ticked. If the checkpoint cannot be done without changing one, report a blocker that names the file and the change it needs; an engineer will make it."
}

# integrity_base ROOT -> REPLY: the commit where the branch checked out at
# ROOT left its base branch, or empty when the base branch is not known
# here.
integrity_base() {
  local root="$1" ref base
  for ref in "origin/$CHALK_BASE_BRANCH" "$CHALK_BASE_BRANCH"; do
    if base="$(git -C "$root" merge-base HEAD "$ref" 2>/dev/null)" && [[ -n $base ]]; then
      REPLY="$base"
      return 0
    fi
  done
  REPLY=""
}

# integrity_finding FILE EXISTED SKIPS_ADDED SKIPS_REMOVED ASSERTS_ADDED
# ASSERTS_REMOVED: prints the findings for one changed test file.
integrity_finding() {
  local file="$1" existed="$2" skips=$(($3 - $4)) added="$5" removed="$6"
  [[ -n $file ]] || return 0
  if (( skips > 0 )); then
    printf 'skip or only marker added: %s (%d)\n' "$file" "$skips"
  fi
  if [[ -n $existed ]] && (( removed > added )); then
    printf 'fewer assertions: %s (%d removed, %d added)\n' "$file" "$removed" "$added"
  fi
}

# integrity_tests ROOT BASE HEAD: prints one line per test file that was
# deleted, had a skip or only marker added, or has fewer assertion lines,
# between the commits BASE and HEAD of the repository at ROOT. These are
# counts of matching lines, not a judgement: a finding is a place for the
# reviewer to look, and no finding is not proof that no test was weakened.
integrity_tests() {
  local root="$1" base="$2" head="$3" status path line text
  local file="" existed="" in_hunk=0 skips_added=0 skips_removed=0 added=0 removed=0
  while IFS=$'\t' read -r status path _; do
    if [[ $status == D && $path =~ $INTEGRITY_TEST_RE ]]; then
      printf 'deleted test file: %s\n' "$path"
    fi
  done < <(git -C "$root" -c core.quotePath=false diff --name-status -M "$base" "$head")

  while IFS= read -r line; do
    if [[ $line == 'diff --git '* ]]; then
      integrity_finding "$file" "$existed" "$skips_added" "$skips_removed" "$added" "$removed"
      file="" existed="" in_hunk=0 skips_added=0 skips_removed=0 added=0 removed=0
    elif [[ $line == '@@'* ]]; then
      in_hunk=1
    elif (( !in_hunk )); then
      # git ends a name that holds a space with a tab.
      case "$line" in
        '--- a/'*) existed="${line#--- a/}"
                   existed="${existed%$'\t'}" ;;
        '+++ b/'*) file="${line#+++ b/}"
                   file="${file%$'\t'}"
                   [[ $file =~ $INTEGRITY_TEST_RE ]] || file="" ;;
      esac
    elif [[ -n $file && $line == [+-]* ]]; then
      text="${line:1}"
      if [[ $line == +* ]]; then
        if [[ $text =~ $INTEGRITY_SKIP_RE ]]; then skips_added=$((skips_added + 1)); fi
        if [[ $text =~ $INTEGRITY_ASSERT_RE ]]; then added=$((added + 1)); fi
      else
        if [[ $text =~ $INTEGRITY_SKIP_RE ]]; then skips_removed=$((skips_removed + 1)); fi
        if [[ $text =~ $INTEGRITY_ASSERT_RE ]]; then removed=$((removed + 1)); fi
      fi
    fi
  done < <(git -C "$root" -c core.quotePath=false diff -U0 -M --no-color --no-ext-diff "$base" "$head")
  integrity_finding "$file" "$existed" "$skips_added" "$skips_removed" "$added" "$removed"
}
