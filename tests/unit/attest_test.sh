#!/usr/bin/env bash
# lib/attest.sh: the record's subject (the tree without .chalk/evidence),
# the test files a branch changed, the DSSE encoding, signing with an SSH
# key, and what verification catches: a changed branch, a forged payload,
# an untrusted signer and costs that do not add up.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime repo state config db sandbox evidence attest

fails() { ! "$@"; }
export XDG_STATE_HOME="$tmp/state"

# A repository on main with a test, then a branch that changes it, adds
# another and deletes a third.
repo="$tmp/repo"
git init -q -b main "$repo"
mkdir -p "$repo/tests" "$repo/src"
echo a > "$repo/tests/test_a.py"; echo b > "$repo/tests/b_test.go"; echo old > "$repo/src/gone_test.js"
echo code > "$repo/src/app.py"
git -C "$repo" add -A && git -C "$repo" commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" switch -q -c chalk/T-1
echo changed >> "$repo/tests/test_a.py"
echo new > "$repo/tests/test_new.py"
git -C "$repo" rm -q "$repo/src/gone_test.js"
mkdir -p "$repo/legacy"
git -C "$repo" mv tests/b_test.go legacy/b_check.txt
echo more >> "$repo/src/app.py"
git -C "$repo" add -A && git -C "$repo" commit -q -m work

# --- the subject and the tests changed ---------------------------------------

tree="${| attest_tree "$repo"; }"
check "the subject is the branch's tree" test "$tree" = "$(git -C "$repo" rev-parse 'HEAD^{tree}')"
mkdir -p "$repo/.chalk/evidence" && echo '{}' > "$repo/.chalk/evidence/T-1.json"
git -C "$repo" add -A && git -C "$repo" commit -q -m "record"
check "... and stays the same once a record is committed under .chalk/evidence" test "${| attest_tree "$repo"; }" = "$tree"
check "existing test files the branch changed, deleted or moved away are listed; added ones are not" \
  test "$(attest_tests_changed "$repo" "$base")" = "$(printf 'src/gone_test.js\ntests/b_test.go\ntests/test_a.py')"
git -C "$repo" config diff.renames copies
check "... whatever git's rename detection is set to" \
  test "$(attest_tests_changed "$repo" "$base")" = "$(printf 'src/gone_test.js\ntests/b_test.go\ntests/test_a.py')"

# --- DSSE: what is signed ------------------------------------------------------

printf '{"a":1}' > "$tmp/body"
check "the pre-authentication encoding of DSSE v1" \
  test "$(attest_pae "$tmp/body")" = 'DSSEv1 28 application/vnd.in-toto+json 7 {"a":1}'

# --- signing and verifying ------------------------------------------------------

if ! command -v ssh-keygen >/dev/null; then
  pass "signing and verifying: skipped, ssh-keygen is not installed"
  exit 0
fi
CHALK_ATTEST_PRINCIPAL=ci@example.com
key="${| attest_key; }"
check "a signing key is made on first use, in the state directory" test -f "$key" -a -f "$key.pub"
check "... and kept" test "${| attest_key; }" = "$key"
check "the signer line names the principal and the namespace" \
  sh -c 'case "$1" in "ci@example.com namespaces=\"chalk-attestation\" ssh-ed25519 "*) exit 0;; esac; exit 1' _ "${| attest_signer_line; }"
mkdir -p "$repo/.chalk"
printf '%s\n' "${| attest_signer_line; }" > "$tmp/signers"
CHALK_ATTEST_SIGNERS="$tmp/signers"

CHALK_BASE_BRANCH=main CHALK_IMAGE=chalk-sandbox:local CHALK_TEST_CMD="pytest" CHALK_SETUP_CMD="" CHALK_FP_RULES=shadow CHALK_DECIDER=off
RUN_REVIEW_SUMMARY="Looks complete."
fake_ledger='{"loops":[{"loop":1,"kind":"continue","rubric_exit":1,"cost_usd":0.4},{"loop":2,"kind":"retry","rubric_exit":0,"cost_usd":0.6}],"lessons":[],"cost_usd":1.0}'
db_attest_ledger() { printf '%s\n' "$fake_ledger"; }
docker() { return 1; }
git -C "$repo" rm -q -r .chalk/evidence && git -C "$repo" commit -q -m "drop the stand-in record"
attest_record "$repo" T-1 chalk/T-1
check "the record is written and committed on the branch" \
  test "$REPLY:$(git -C "$repo" log -1 --format=%s)" = ".chalk/evidence/T-1.json:chalk: evidence for T-1"
record="$repo/$REPLY"
statement="$(attest_payload "$record")"
check "the record is an in-toto Statement about the branch's tree" \
  test "$(jq -r '"\(._type) \(.subject[0].name) \(.subject[0].digest.gitTree)"' <<<"$statement")" = \
    "https://in-toto.io/Statement/v1 chalk/T-1 ${| attest_tree "$repo"; }"
check "... with the base, the review, the changed tests and the ledger" \
  test "$(jq -c '[.predicate.base.commit, .predicate.review.ran, .predicate.tests_changed, .predicate.ledger.cost_usd == 1]' <<<"$statement")" = \
    "[\"$base\",true,[\"src/gone_test.js\",\"tests/b_test.go\",\"tests/test_a.py\"],true]"
check "... and the rubric and setup it ran" \
  test "$(jq -c '.predicate.rubric' <<<"$statement")" = '{"command":"pytest","setup":""}'

trusted="$base"
verify() { local -A got; attest_verify_one "$repo" "$record" 0 got "$trusted"; printf '%s\n' "${got[$1]}"; }
check "verify: the signature holds for the trusted principal" test "$(verify signature)" = "ok: signed by ci@example.com"
check "verify: the subject is this tree" sh -c 'case "$1" in "ok: the record names this tree"*) exit 0;; esac; exit 1' _ "$(verify subject)"
check "verify: the changed tests are named for the reviewer" \
  test "$(verify tests)" = "ok: existing test files changed, for the reviewer: src/gone_test.js, tests/b_test.go, tests/test_a.py"
check "verify: the costs add up" test "$(verify cost)" = 'ok: $1 over 2 recorded call(s)'

echo after >> "$repo/src/app.py"
git -C "$repo" commit -q -am "edited after the record"
check "verify: a commit after the record fails the subject" \
  sh -c 'case "$1" in "FAIL: the record names tree "*"the branch changed after it was recorded") exit 0;; esac; exit 1' _ "$(verify subject)"
git -C "$repo" reset -q --hard HEAD~1

cp "$record" "$tmp/record.json"
jq --arg p "$(attest_payload "$tmp/record.json" | jq -c '.predicate.ledger.cost_usd = 0.01' | openssl base64 -A)" \
  '.payload = $p' "$tmp/record.json" > "$record"
check "verify: a payload changed after signing fails the signature" \
  sh -c 'case "$1" in FAIL:*) exit 0;; esac; exit 1' _ "$(verify signature)"
check "... and its costs no longer add up" test "$(verify cost)" = 'FAIL: the recorded calls add up to $1, not the $0.01 recorded'
cp "$tmp/record.json" "$record"

ssh-keygen -q -t ed25519 -N '' -C other -f "$tmp/other"
printf 'ci@example.com namespaces="chalk-attestation" %s\n' "$(cut -d' ' -f1,2 "$tmp/other.pub")" > "$tmp/signers"
check "verify: a key the signers file does not trust fails" sh -c 'case "$1" in FAIL:*) exit 0;; esac; exit 1' _ "$(verify signature)"
unset CHALK_ATTEST_SIGNERS
check "verify: with no signers file at all, it says how to make one" \
  test "$(verify signature)" = "FAIL: no trusted signers: commit 'chalk attest key' output to .chalk/allowed_signers on the base branch"

# The branch's own .chalk/allowed_signers is not trusted: whoever pushes
# the branch could add their key to it. The base branch's copy is.
printf '%s\n' "${| attest_signer_line; }" > "$repo/.chalk/allowed_signers"
check "verify: a signers file only the branch has is not trusted" \
  sh -c 'case "$1" in "FAIL: no trusted signers"*) exit 0;; esac; exit 1' _ "$(verify signature)"
rm "$repo/.chalk/allowed_signers"
git -C "$repo" switch -q main
mkdir -p "$repo/.chalk" && printf '%s\n' "${| attest_signer_line; }" > "$repo/.chalk/allowed_signers"
git -C "$repo" add .chalk/allowed_signers && git -C "$repo" commit -q -m "trust the harness"
git -C "$repo" switch -q chalk/T-1
trusted="$(git -C "$repo" rev-parse main)"
check "verify: the base branch's signers file is trusted" test "$(verify signature)" = "ok: signed by ci@example.com"

# --- chalk attest verify: which records ------------------------------------------

# T-1 is merged; T-2 branches from main after it and gets its own record.
# Verify checks only the record its branch added: T-1's names a tree that
# is gone.
git -C "$repo" switch -q main
git -C "$repo" merge -q --no-ff -m "merge T-1" chalk/T-1
git -C "$repo" switch -q -c chalk/T-2
echo t2 >> "$repo/src/app.py" && git -C "$repo" commit -q -am "T-2 work"
attest_record "$repo" T-2 chalk/T-2
out="$(cd "$repo" && cmd_attest verify 2>&1)"
check "verify with no ticket checks only the records the branch added" \
  sh -c 'case "$1" in *T-1.json*) exit 1;; *".chalk/evidence/T-2.json:"*"subject: ok"*) exit 0;; esac; exit 1' _ "$out"
verify_ticket() { (cd "$repo" && cmd_attest verify "$@") >/dev/null 2>&1; }
check "... while a record merged earlier, named, fails its subject" fails verify_ticket T-1
check "--base names the base branch" sh -c 'case "$1" in *"subject: ok"*) exit 0;; esac; exit 1' _ "$(cd "$repo" && cmd_attest verify --base main 2>&1)"
