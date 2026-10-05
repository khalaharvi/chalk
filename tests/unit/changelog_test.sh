#!/usr/bin/env bash
# scripts/check-commit-title.sh and scripts/changelog.sh: titles are checked
# the way CI checks pull requests, and releases get the right changelog.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"

title="$CHALK_HOME/scripts/check-commit-title.sh"
changelog="$CHALK_HOME/scripts/changelog.sh"

for good in "feat: add chalk share" "fix(sandbox): keep the RAM disk on resume" \
            "feat(config)!: rename CHALK_CHEAP_MODEL" "docs: explain detention" \
            "ci: test against Postgres 17 with pgvector"; do
  check "title accepted: $good" "$title" "$good"
done
for bad in "Add chalk share" "feat:no space" "feature: add chalk share" \
           "Fix(sandbox): upper-case type" "feat(Sandbox): upper-case scope" \
           "fix: " "feat: trailing space " ""; do
  check "title rejected: ${bad:-<empty>}" eval '! "$title" "$bad"'
done

# A repository with one release and a mix of commits after it.
repo="$tmp/repo"
git init -q -b main "$repo"
cd "$repo"
commit() { git commit -q --allow-empty -m "$1" ${2:+-m "$2"}; }
commit "Initial commit"
git tag v0.1.0
commit "feat(fleet): read epics from GitHub issues (#12)"
commit "fix: stop a run that goes over budget"
commit "feat(config)!: rename CHALK_CHEAP_MODEL"
commit "refactor: move the harness behind an interface" "BREAKING CHANGE: CHALK_HARNESS replaces the claude flags"
commit "test: cover the new fake"
commit "ci: cache bash"
commit "chore(release): v0.1.0"
commit "Add a roadmap"
git remote add origin https://github.com/khalaharvi/chalk.git

export CHALK_RELEASE_DATE=2027-01-15
"$changelog" section 0.2.0 > "$tmp/section.md"
cat > "$tmp/expected.md" <<'EOF'
## 0.2.0 (2027-01-15)

### Breaking changes

- move the harness behind an interface
- **config:** rename CHALK_CHEAP_MODEL

### Features

- **fleet:** read epics from GitHub issues ([#12](https://github.com/khalaharvi/chalk/pull/12))

### Fixes

- stop a run that goes over budget

### Other changes

- Add a roadmap
EOF
check "section groups commits since the last tag" diff "$tmp/expected.md" "$tmp/section.md"
check "test, ci and release commits stay out" eval '! grep -qE "fake|cache bash|chore" "$tmp/section.md"'

"$changelog" prepend 0.2.0
check "prepend creates CHANGELOG.md with a title" grep -qx "# Changelog" CHANGELOG.md
git add CHANGELOG.md && commit "chore(release): v0.2.0"
git tag v0.2.0
commit "fix: keep the notes file on resume"
"$changelog" prepend 0.2.1
check "the newest release comes first" \
  eval '[ "$(grep -m1 "^## " CHANGELOG.md)" = "## 0.2.1 (2027-01-15)" ]'
check "earlier releases are kept" grep -qx "## 0.2.0 (2027-01-15)" CHANGELOG.md
check "the title stays at the top" eval '[ "$(head -n 1 CHANGELOG.md)" = "# Changelog" ]'

"$changelog" notes 0.2.1 > "$tmp/notes.md"
check "notes print only that release" eval \
  '[ "$(cat "$tmp/notes.md")" = "$(printf "### Fixes\n\n- keep the notes file on resume")" ]'
check "notes for a missing release print nothing" eval '[ -z "$("$changelog" notes 9.9.9)" ]'

git tag v0.2.1
"$changelog" section 0.2.2 > "$tmp/empty.md"
check "a release with nothing to report says so" grep -qx "No user-facing changes." "$tmp/empty.md"
