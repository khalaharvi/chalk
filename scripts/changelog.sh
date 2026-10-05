#!/usr/bin/env bash
# CHANGELOG.md from Conventional Commits titles (scripts/check-commit-title.sh).
#
#   scripts/changelog.sh section VERSION [FROM]   print the section for FROM..HEAD
#   scripts/changelog.sh prepend VERSION [FROM]   add that section to CHANGELOG.md
#   scripts/changelog.sh notes VERSION            print VERSION's section body,
#                                                 for the GitHub Release
#
# FROM defaults to the newest v* tag before HEAD. scripts/release.sh runs
# `prepend`; .github/workflows/release.yml runs `notes`. CHALK_RELEASE_DATE
# (YYYY-MM-DD) overrides today's date, for tests.
set -euo pipefail

changelog="CHANGELOG.md"

# Sections in the order they appear. Commit types missing here (test, build,
# ci, chore, refactor) are left out unless they are breaking changes.
declare -a section_order=(breaking feat fix perf docs other)
declare -A section_title=(
  [breaking]="Breaking changes" [feat]="Features" [fix]="Fixes"
  [perf]="Performance" [docs]="Documentation" [other]="Other changes"
)

usage() {
  sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# pr_links TEXT: turns a trailing "(#12)", as GitHub adds when squashing, into
# a link to the pull request when origin is on GitHub.
pr_links() {
  local text="$1" slug
  slug="$(git remote get-url origin 2>/dev/null |
    sed -nE 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/]+)$#\2#p')"
  slug="${slug%.git}"
  if [[ -n $slug && $text =~ ^(.*)\ \(#([0-9]+)\)$ ]]; then
    text="${BASH_REMATCH[1]} ([#${BASH_REMATCH[2]}](https://github.com/$slug/pull/${BASH_REMATCH[2]}))"
  fi
  printf '%s\n' "$text"
}

# section VERSION [FROM]: the markdown section for the commits since FROM.
section() {
  local version="$1" from="${2-}" date
  if [[ -z $from ]]; then
    from="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
  fi
  date="${CHALK_RELEASE_DATE:-$(printf '%(%Y-%m-%d)T' -1)}"

  local -A lines=()
  local record subject body type scope bang desc key entry
  local re='^([a-z]+)(\(([a-z0-9._/-]+)\))?(!)?: (.+)$'
  while IFS= read -r -d $'\x1e' record; do
    record="${record#$'\n'}"
    subject="${record%%$'\x1f'*}"
    body="${record#*$'\x1f'}"
    if [[ $subject =~ $re ]]; then
      type="${BASH_REMATCH[1]}" scope="${BASH_REMATCH[3]}"
      bang="${BASH_REMATCH[4]}" desc="${BASH_REMATCH[5]}"
      [[ $type == chore && $scope == release ]] && continue
      if [[ -n $bang || $body == *"BREAKING CHANGE:"* ]]; then
        key=breaking
      elif [[ -v section_title[$type] ]]; then
        key="$type"
      else
        continue
      fi
      entry="$desc"
      if [[ -n $scope ]]; then entry="**$scope:** $desc"; fi
    else
      # Commits from before Chalk used Conventional Commits.
      key=other entry="$subject"
    fi
    lines[$key]+="- $(pr_links "$entry")"$'\n'
  done < <(git log --no-merges --format='%s%x1f%b%x1e' "${from:+$from..}HEAD")

  printf '## %s (%s)\n' "$version" "$date"
  local any=""
  for key in "${section_order[@]}"; do
    [[ -v lines[$key] ]] || continue
    printf '\n### %s\n\n%s' "${section_title[$key]}" "${lines[$key]}"
    any=1
  done
  if [[ -z $any ]]; then printf '\nNo user-facing changes.\n'; fi
}

# prepend VERSION [FROM]: writes the new section above the newest release in
# CHANGELOG.md, creating the file when it does not exist.
prepend() {
  local new head="" rest=""
  new="$(section "$@")"
  if [[ -f $changelog ]]; then
    # Everything before the first "## " heading is the file's introduction.
    head="$(awk '/^## /{exit} {print}' "$changelog")"
    rest="$(awk 'found || /^## /{found=1; print}' "$changelog")"
  else
    head="# Changelog"
  fi
  {
    printf '%s\n\n%s\n' "$head" "$new"
    if [[ -n $rest ]]; then printf '\n%s\n' "$rest"; fi
  } > "$changelog.tmp"
  mv "$changelog.tmp" "$changelog"
}

# notes VERSION: the body of VERSION's section, without its heading.
notes() {
  local version="$1"
  [[ -f $changelog ]] || { echo "error: no $changelog" >&2; exit 1; }
  awk -v v="$version" '
    /^## / { if (inside) exit; inside = ($2 == v); next }
    inside { print }
  ' "$changelog" | sed '/./,$!d'
}

cd "$(git rev-parse --show-toplevel)"
case "${1-}" in
  section) [[ $# -ge 2 ]] || usage; shift; section "$@" ;;
  prepend) [[ $# -ge 2 ]] || usage; shift; prepend "$@" ;;
  notes)   [[ $# -eq 2 ]] || usage; notes "$2" ;;
  *) usage ;;
esac
