# Loop fingerprints and verdicts. After each rubric run the harness reduces
# the loop to three facts and compares them with the last loop of the
# current non-progress streak:
#   T  the failing test set: sorted, unique test IDs, or UNKNOWN
#   E  the first error line, normalized so that runs of the same failure match
#   D  the working tree's identity, as a git tree ID
# CHALK_FP_RULES decides what is done with the verdict: off computes
# nothing, shadow only records it, on detains the run on a stopping verdict.

# A line that names an error. The first such line in rubric.log is E.
# ERR! catches npm's banner, so that it can be judged generic.
FP_ERROR_LINE='error|Error:|ERR!|FAIL|panic|Traceback|assert'

# sed expressions that turn test runner output into test IDs:
# pytest, go, cargo and jest, in that order.
declare -ga FP_TEST_PATTERNS=(
  -e 's/^FAILED ([^[:space:]]+::[^[:space:]]+).*/\1/p'
  -e 's/^[[:space:]]*--- FAIL: ([^[:space:]]+).*/\1/p'
  -e 's/^test ([^[:space:]]+) \.\.\. FAILED.*/\1/p'
  -e 's/^[[:space:]]*● (.* › .*[^[:space:]])[[:space:]]*$/\1/p'
)

# sed expressions that strip what differs between two runs of the same
# failure. Timestamps go before :line:col, which would eat their colons.
declare -ga FP_NORMALIZE=(
  -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2}([.,][0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?/<time>/g'
  -e 's/[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?/<time>/g'
  -e 's/0x[0-9a-fA-F]+/0x?/g'
  -e 's#(/private)?/(tmp|var/tmp|var/folders)/[^[:space:]:"()]*#<tmp>#g'
  -e 's/:[0-9]+(:[0-9]+)?//g'
  -e 's/[0-9]+(\.[0-9]+)? ?(ns|us|ms|s|m|h)([^[:alnum:]_]|$)/<d>\3/g'
  -e 's/[[:space:]]+/ /g'
  -e 's/^ //'
  -e 's/ $//'
)

# A normalized E matching one of these is only a runner's banner and says
# nothing about which failure it was. Each has a fixture in
# tests/unit/fingerprint_test.sh.
declare -ga FP_GENERIC=(
  '^FAIL( .*)?$'                            # go: FAIL <pkg>; jest: FAIL <file>
  '^npm ERR! Test failed'                   # npm test
  '^error:?$'                               # a bare error:
  '^[= ]*[0-9]+ failed([ ,].*)?$'           # N failed, e.g. pytest's summary
  '^error: test failed'                     # cargo test
  '^=+ FAILURES =+$'                        # pytest's section banner
  '^Traceback \(most recent call last\):$'  # python
)

# Prints the failing tests in a JUnit XML report as CLASSNAME::NAME: each
# <testcase> element with a <failure> or <error> child. Single quotes
# are written as \047 so this stays one shell string.
FP_JUNIT_AWK='
function attr(tag, key,   v) {
  if (!match(tag, "[[:space:]]" key "=\"[^\"]*\"")) return ""
  v = substr(tag, RSTART + length(key) + 3, RLENGTH - length(key) - 4)
  gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&quot;/, "\"", v)
  gsub(/&apos;/, "\047", v); gsub(/&amp;/, "\\&", v)
  return v
}
{ xml = xml $0 "\n" }
END {
  s = xml
  while ((i = index(s, "<testcase")) > 0) {
    s = substr(s, i + 9)
    if (substr(s, 1, 1) !~ /[[:space:]\/>]/) continue
    j = index(s, ">")
    if (!j) break
    tag = " " substr(s, 1, j - 1)
    s = substr(s, j + 1)
    if (tag ~ /\/[[:space:]]*$/) continue
    k = index(s, "</testcase>")
    body = k ? substr(s, 1, k - 1) : s
    if (body ~ /<(failure|error)[[:space:]\/>]/) {
      name = attr(tag, "name"); cls = attr(tag, "classname")
      print (cls == "" ? name : cls "::" name)
    }
    s = k ? substr(s, k + 11) : ""
  }
}'

# Where the repository is checked out in the sandbox. jest --json names test
# files by absolute path; IDs use the path relative to this.
FP_SANDBOX_REPO=/work/repo

# Prints the failing tests in a `jest --json` report as FILE::TITLES: FILE
# relative to the repository, TITLES the describe blocks and the test's
# title joined with " › ", as jest prints them in its output (and as
# FP_TEST_PATTERNS reads them). A suite that failed to run names no test.
FP_JEST_JQ='.testResults[]? | ((.name // "") | ltrimstr($root)) as $file
  | .assertionResults[]? | select(.status == "failed")
  | ([(.ancestorTitles // [])[], .title] | map(strings) | join(" › ")) as $name
  | (if $file == "" then $name else "\($file)::\($name)" end) | gsub("[\r\n]+"; " ")'

# Prints the failing tests in `go test -json` output as PACKAGE::TEST, the
# IDs go-junit-report gives as classname::name. Read one line at a time, so
# lines that are not JSON (such as a build error on stderr) are skipped. A
# fail event without a Test is a package's, which names no test.
FP_GO_JQ='fromjson? | objects | select(.Action == "fail" and (.Test | strings) != "")
  | (.Package | strings // "") as $pkg
  | (if $pkg == "" then .Test else "\($pkg)::\(.Test)" end) | gsub("[\r\n]+"; " ")'

# Run in the sandbox's repo (bash 5.2) with the test report's path as $1:
# the tree ID of everything in the working tree, untracked files included,
# except the notes file, which the prompts tell the agent to update every
# loop, and the report, which the rubric rewrites every run. A copy of the
# real index keeps git's stat cache; it lives under .git, so it is never
# part of the tree.
FP_TREE_SCRIPT='set -e
cp .git/index .git/chalk-fp-index
export GIT_INDEX_FILE=.git/chalk-fp-index
git add -A -- . ":(exclude)specs/*.notes.md" ${1:+":(exclude)$1"}
git write-tree'

# fp_clean FILE: prints FILE without ANSI codes or carriage returns.
fp_clean() {
  LC_ALL=C sed -E -e "s/"$'\e'"\[[0-9;?]*[A-Za-z]//g" -e "s/"$'\r'"//g" "$1"
}

fp_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}

# fp_report_tests REPORT: prints the failing test IDs in a test report,
# unsorted. The format is told by content, not by file name: XML is JUnit;
# a single JSON object with testResults is `jest --json`; anything else is
# read as `go test -json`'s stream of events, one per line. Fails when a
# jest report cannot be read whole.
fp_report_tests() {
  local first
  first="$(LC_ALL=C awk 'NR == 1 { sub(/^\357\273\277/, "") }
    match($0, /[^[:space:]]/) { print substr($0, RSTART, 1); exit }' "$1")"
  if [[ $first == '<' ]]; then
    LC_ALL=C awk "$FP_JUNIT_AWK" "$1"
  elif jq -e -n '[inputs] | length == 1 and (.[0] | type == "object" and has("testResults"))' \
       "$1" >/dev/null 2>&1; then
    jq -r --arg root "$FP_SANDBOX_REPO/" "$FP_JEST_JQ" "$1"
  else
    jq -R -r "$FP_GO_JQ" "$1"
  fi
}

# fp_failing_tests LOG [REPORT] -> REPLY: T, one test ID per line, sorted.
# From the REPORT (JUnit XML, `go test -json` or `jest --json`) when there
# is one, otherwise from the runner's output in LOG. Finding no test IDs,
# or a report that cannot be read, means UNKNOWN, never zero failures.
fp_failing_tests() {
  local log="$1" report="${2:-}" ids
  if [[ -n $report && -s $report && -r $report ]]; then
    ids="$(fp_report_tests "$report" 2>/dev/null)" || ids=""
    REPLY="$(printf '%s' "$ids" | LC_ALL=C sort -u || true)"
  else
    REPLY="$(fp_clean "$log" 2>/dev/null | LC_ALL=C sed -n -E "${FP_TEST_PATTERNS[@]}" | LC_ALL=C sort -u || true)"
  fi
  [[ -n $REPLY ]] || REPLY=UNKNOWN
}

# fp_first_error LOG -> REPLY: E, normalized; empty when no line matches.
fp_first_error() {
  REPLY="$(fp_clean "$1" 2>/dev/null | LC_ALL=C grep -m 1 -E "$FP_ERROR_LINE" |
    LC_ALL=C sed -E "${FP_NORMALIZE[@]}" || true)"
}

# fp_generic E: true when E is only a runner's banner.
fp_generic() {
  local pattern
  for pattern in "${FP_GENERIC[@]}"; do
    [[ $1 =~ $pattern ]] && return 0
  done
  return 1
}

# fp_tree_id SANDBOX -> REPLY: D for the sandbox's working tree; empty when
# git could not say.
fp_tree_id() {
  REPLY="$(sandbox_sh "$1" "$FP_TREE_SCRIPT" "${CHALK_TEST_REPORT:-}" 2>/dev/null || true)"
  [[ $REPLY =~ ^[0-9a-f]{40,64}$ ]] || REPLY=""
}

# fp_report_clear SANDBOX: deletes CHALK_TEST_REPORT in the sandbox before a
# rubric run, so a report left by an earlier run is never read.
fp_report_clear() {
  [[ -n ${CHALK_TEST_REPORT:-} ]] || return 0
  sandbox_sh "$1" 'rm -f -- "$1"' "$CHALK_TEST_REPORT" >/dev/null 2>&1 || true
}

# fp_report_fetch SANDBOX FILE: copies this run's CHALK_TEST_REPORT out of
# the sandbox to FILE, or removes FILE when there is none.
fp_report_fetch() {
  rm -f "$2"
  [[ -n ${CHALK_TEST_REPORT:-} ]] || return 0
  sandbox_sh "$1" 'cat -- "$1"' "$CHALK_TEST_REPORT" > "$2" 2>/dev/null || rm -f "$2"
}

# fp_compute VAR SANDBOX LOG [REPORT]: fills the associative array VAR with
# a failed rubric run's fingerprint:
#   tests        T, one ID per line, or UNKNOWN
#   tests_hash   sha256 of T; empty when T is UNKNOWN
#   failing      how many tests failed; empty when T is UNKNOWN
#   first_error  E, possibly empty
#   generic      1 when E is only a runner's banner, else 0
#   tree_id      D, empty when git could not say
#   fingerprint  the lesson fingerprint: sha256 of T and E, set only when T
#                is known or E is specific
fp_compute() {
  local -n __fp=$1
  local sandbox="$2" log="$3" report="${4:-}" tests error tree generic=0 failing="" hash="" print=""
  local -a ids
  tests="${| fp_failing_tests "$log" "$report"; }"
  error="${| fp_first_error "$log"; }"
  tree="${| fp_tree_id "$sandbox"; }"
  if [[ -n $error ]] && fp_generic "$error"; then generic=1; fi
  if [[ $tests != UNKNOWN ]]; then
    mapfile -t ids <<<"$tests"
    failing="${#ids[@]}"
    hash="$(printf '%s\n' "$tests" | fp_sha256)"
  fi
  if [[ $tests != UNKNOWN ]] || [[ -n $error && $generic == 0 ]]; then
    print="$(printf '%s\n\n%s\n' "$tests" "$error" | fp_sha256)"
  fi
  __fp=(["tests"]="$tests" ["tests_hash"]="$hash" ["failing"]="$failing" ["first_error"]="$error"
        ["generic"]="$generic" ["tree_id"]="$tree" ["fingerprint"]="$print")
}

# fp_verdict REASON PREV CUR -> REPLY: the verdict for a loop that made no
# progress. PREV and CUR name associative arrays filled like fp_compute's:
# PREV is the baseline, the latest loop of this streak with a fingerprint
# (empty when there is none), and CUR is this loop, with CUR[open_match]=1
# when an open lesson for another ticket in this repository shares its
# fingerprint. No I/O. REASON is how the loop ended:
#
#   blocked      the agent reported a blocker            -> blocked
#   agent_error  the agent stopped early                 -> agent_error
#   passed       rubric passed, no checkpoint ticked     -> first | no_change | other (D only)
#   failed       rubric failed; the first rule that matches wins:
#     1 deja_vu    T known, and CUR[open_match] is 1 (needs no baseline)
#     2 first      no baseline
#     3 repeat     D unchanged, and T unchanged and known, or T UNKNOWN on
#                  both loops and E unchanged and specific
#     4 no_change  D unchanged
#     5 improving  T known on both loops, with fewer tests failing now
#     6 spinning   T unchanged and known, or T UNKNOWN on both loops and E
#                  unchanged and specific
#     7 other      anything else
#
# "Specific" means non-empty and not generic. An empty D is never unchanged.
fp_verdict() {
  local reason="$1"
  local -n __prev=$2 __cur=$3
  local known_cur=0 known_prev=0 same_tree=0 same_tests=0 same_error=0
  case "$reason" in
    blocked|agent_error) REPLY="$reason"; return 0 ;;
  esac

  if [[ -n ${__cur[tree_id]-} && ${__cur[tree_id]} == "${__prev[tree_id]-}" ]]; then same_tree=1; fi
  if [[ $reason == passed ]]; then
    if (( ${#__prev[@]} == 0 )); then REPLY=first
    elif (( same_tree )); then REPLY=no_change
    else REPLY=other
    fi
    return 0
  fi

  [[ ${__cur[tests]:-UNKNOWN} == UNKNOWN ]] || known_cur=1
  [[ ${__prev[tests]:-UNKNOWN} == UNKNOWN ]] || known_prev=1
  if (( known_cur && known_prev )) && [[ ${__cur[tests]} == "${__prev[tests]}" ]]; then same_tests=1; fi
  # E only counts when T is UNKNOWN on both loops.
  if (( !known_cur && !known_prev )) && [[ -n ${__cur[first_error]-} && ${__cur[generic]:-0} != 1 &&
        ${__cur[first_error]} == "${__prev[first_error]-}" ]]; then
    same_error=1
  fi

  if (( known_cur )) && [[ ${__cur[open_match]-} == 1 ]]; then REPLY=deja_vu
  elif (( ${#__prev[@]} == 0 )); then REPLY=first
  elif (( same_tree && (same_tests || same_error) )); then REPLY=repeat
  elif (( same_tree )); then REPLY=no_change
  elif (( known_cur && known_prev && ${__cur[failing]:-0} < ${__prev[failing]:-0} )); then REPLY=improving
  elif (( same_tests || same_error )); then REPLY=spinning
  else REPLY=other
  fi
}

# fp_stops VERDICT: true for the verdicts that detain a run when
# CHALK_FP_RULES is on.
fp_stops() {
  case "$1" in deja_vu|repeat|no_change) return 0 ;; esac
  return 1
}
