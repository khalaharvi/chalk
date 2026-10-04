#!/usr/bin/env bash
# lib/forge.sh: choosing GitHub or GitLab, and opening the review request.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime forge

git init -q "$tmp/repo"
cd "$tmp/repo"

# kind_for URL [CHALK_FORGE]: prints the forge chosen for an origin at URL.
kind_for() {
  git remote remove origin 2>/dev/null || true
  if [[ -n $1 ]]; then git remote add origin "$1"; fi
  CHALK_FORGE="${2:-auto}"
  forge_kind
  printf '%s\n' "$REPLY"
}

for url in git@github.com:acme/app.git https://github.com/acme/app.git \
           ssh://git@github.com/acme/app.git https://token@github.com/acme/app; do
  check "auto picks GitHub for $url" test "$(kind_for "$url")" = github
done
for url in git@gitlab.com:acme/app.git https://gitlab.example.com/acme/app.git \
           https://github.com.evil.example/acme/app.git /srv/git/app.git; do
  check "auto picks GitLab for $url" test "$(kind_for "$url")" = gitlab
done
check "no origin falls back to GitLab" test "$(kind_for "")" = gitlab
check "CHALK_FORGE=github wins over a GitLab remote" \
  test "$(kind_for git@gitlab.example.com:a/b.git github)" = github
check "CHALK_FORGE=gitlab wins over a GitHub remote" \
  test "$(kind_for git@github.com:a/b.git gitlab)" = gitlab

kind_for git@github.com:a/b.git >/dev/null
check "GitHub uses gh" test "${| forge_cli; }" = gh
check "GitHub calls it a pull request" test "${| forge_request; }" = "pull request"
kind_for git@gitlab.com:a/b.git >/dev/null
check "GitLab uses glab" test "${| forge_cli; }" = glab
check "GitLab calls it a merge request" test "${| forge_request; }" = "merge request"

# The request goes to the right CLI with the branches, title and body.
mkdir -p "$tmp/bin"
for cli in gh glab; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/%s.args"\n' "$tmp" "$cli" > "$tmp/bin/$cli"
  chmod +x "$tmp/bin/$cli"
done
PATH="$tmp/bin:$PATH"

CHALK_FORGE=github
forge_open_request "$tmp/repo" chalk/PROJ-1 main "A title" "A body"
check "a pull request is opened from the branch into the base" \
  diff <(printf '%s\n' pr create --head chalk/PROJ-1 --base main --title "A title" --body "A body") "$tmp/gh.args"

CHALK_FORGE=gitlab
forge_open_request "$tmp/repo" chalk/PROJ-1 main "A title" "A body"
check "a merge request is opened from the branch into the base" \
  diff <(printf '%s\n' mr create --yes --source-branch chalk/PROJ-1 --target-branch main \
         --title "A title" --description "A body") "$tmp/glab.args"
