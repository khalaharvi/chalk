#!/usr/bin/env bash
# Checks that a title is a Conventional Commits header, as every pull request
# title must be: it becomes the squashed commit on main and a changelog line.
#
#   scripts/check-commit-title.sh "feat(fleet): read epics from GitHub issues"
#
# Exits 1 and says why when the title does not fit.
set -euo pipefail

# The types Chalk uses. scripts/changelog.sh decides which reach the changelog.
CHALK_COMMIT_TYPES="feat|fix|perf|docs|refactor|test|build|ci|chore|revert"
CHALK_COMMIT_TITLE_RE="^($CHALK_COMMIT_TYPES)(\([a-z0-9._/-]+\))?!?: [^ ](.*[^ ])?$"

title="${1-}"
if [[ $title =~ $CHALK_COMMIT_TITLE_RE ]]; then
  exit 0
fi

cat >&2 <<EOF
Not a conventional commit title: ${title@Q}

Write it as  type(scope): description  or  type: description
  type   one of ${CHALK_COMMIT_TYPES//|/, }
  scope  optional, lower case, e.g. fleet, sandbox, db
  !      after the type or scope marks a breaking change, e.g. feat(config)!: ...
Example: feat(fleet): read epics from GitHub issues
EOF
exit 1
