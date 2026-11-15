#!/usr/bin/env bash
# lib/integrity.sh: protected paths, and the tests a branch removed or
# weakened.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime integrity

declare -a paths
CHALK_TEXTBOOK=.chalk/textbook.md
CHALK_PROTECTED=".chalk .github/workflows"
integrity_protected paths
check "protected paths are CHALK_PROTECTED, split on spaces" test "${paths[*]}" = ".chalk .github/workflows"
CHALK_TEXTBOOK=docs/rules.md
integrity_protected paths
check "a textbook outside the protected paths is protected too" test "${paths[*]}" = ".chalk .github/workflows docs/rules.md"
CHALK_PROTECTED=none
integrity_protected paths
check "CHALK_PROTECTED=none protects nothing, the textbook included" test "${#paths[@]}" -eq 0
check "with nothing protected, the sandbox is not asked what changed" \
  test -z "$(integrity_changed no-such-sandbox HEAD specs/X-1.md)"

is_test() { [[ $1 =~ $INTEGRITY_TEST_RE ]]; }
for path in tests/unit/run_test.sh test/api.test.ts src/__tests__/a.js pkg/limiter_test.go \
            tests/test_api.py test_api.py spec/models/user_spec.rb src/FooTest.java app/FooTests.kt \
            web/button.spec.tsx e2e/login.js; do
  check "a test file: $path" is_test "$path"
done
for path in src/contest.js specs/PROJ-1.md lib/latest.py src/attestation.go docs/testing.md src/inspector.rb; do
  check "not a test file: $path" eval '! is_test "$path"'
done

# A repository whose branch deletes one test, skips another, drops
# assertions from a third, and adds a new test file.
repo="$tmp/repo"
git init -q -b main "$repo"
cd "$repo"
mkdir -p test src
printf 'it("adds", () => {\n  expect(add(1, 2)).toBe(3);\n});\n' > test/gone.test.js
printf 'it("keeps", () => {\n  expect(keep()).toBe(true);\n});\n' > test/skipped.test.js
printf 'def test_expiry():\n    assert token.expired\n    assert token.age > 10\n    assert token.owner\n' > test/test_auth.py
printf 'func TestMove(t *testing.T) {\n\tif got != want {\n\t\tt.Errorf("got %%v", got)\n\t}\n}\n' > test/moved_test.go
printf 'it("same", () => {\n  expect(a).toBe(1);\n});\n' > test/same.test.js
printf 'assert(ready)\n' > src/main.js
git add -A && git commit -q -m base
base="$(git rev-parse HEAD)"

git switch -q -c chalk/X-1
git rm -q test/gone.test.js
printf 'it.skip("keeps", () => {\n  expect(keep()).toBe(true);\n});\n' > test/skipped.test.js
printf 'def test_expiry():\n    assert token.expired\n' > test/test_auth.py
git mv test/moved_test.go test/renamed_test.go
printf 'it("same", () => {\n  expect(a).toBe(1);\n  expect(b).toBe(2);\n});\n' > test/same.test.js
printf 'it.skip("new and skipped", () => {});\nit("new", () => { expect(1).toBe(1); });\n' > test/new.test.js
printf 'ready()\n' > src/main.js
git add -A && git commit -q -m branch

findings="$(integrity_tests "$repo" "$base" HEAD)"
has() { grep -qxF "$1" <<<"$findings"; }
check "a deleted test file is listed" has 'deleted test file: test/gone.test.js'
check "a test given a skip marker is listed" has 'skip or only marker added: test/skipped.test.js (1)'
check "a test with fewer assertions is listed, with the counts" has 'fewer assertions: test/test_auth.py (2 removed, 0 added)'
check "a skip marker in a new test file is listed" has 'skip or only marker added: test/new.test.js (1)'
check "a renamed test file is not listed as deleted" eval '! grep -q moved_test <<<"$findings"'
check "a test that gained assertions is not listed" eval '! grep -q same.test <<<"$findings"'
check "assertions removed outside test files are not listed" eval '! grep -q src/main <<<"$findings"'
check "nothing else is listed" test "$(grep -c '' <<<"$findings")" -eq 4
check "a branch that left the tests alone has no findings" test -z "$(integrity_tests "$repo" HEAD HEAD)"

# A file name is an agent's to choose. It is printed, never evaluated.
git switch -q -c hostile
# shellcheck disable=SC2016 # the name is meant literally
name='test/a[$(touch pwned)].test.js'
printf 'it.skip("x", () => {});\n' > "$name"
git add -A && git commit -q -m hostile
findings="$(integrity_tests "$repo" "$base" HEAD)"
check "a hostile file name is listed as text" has "skip or only marker added: $name (1)"
check "a hostile file name runs nothing" test ! -e pwned -a ! -e test/pwned

CHALK_BASE_BRANCH=main
check "the base of a branch is where it left the base branch" \
  test "${| integrity_base "$repo"; }" = "$base"
CHALK_BASE_BRANCH=no-such-branch
check "an unknown base branch gives no base, and does not fail" test -z "${| integrity_base "$repo"; }"

feedback="${| integrity_feedback ".chalk/config"; }"
check "the feedback names the file and says to report a blocker" \
  eval '[[ $feedback == *$'"'"'\n.chalk/config\n'"'"'* && $feedback == *"report a blocker"* ]]'
