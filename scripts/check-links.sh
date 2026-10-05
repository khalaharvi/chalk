#!/usr/bin/env bash
# Checks every link in the built docs site, internal anchors included, with
# lychee (https://lychee.cli.rs). .github/workflows/docs.yml runs it after
# `mkdocs build --strict`.
#
#   scripts/check-links.sh [SITE_DIR]      SITE_DIR defaults to site/
#
# Links to this repository's main branch on GitHub are checked against the
# checkout instead, so a page can link to a file added in the same pull
# request. GITHUB_TOKEN, when set, keeps GitHub from rate-limiting lychee.
set -euo pipefail
cd "$(dirname "$0")/.."

site="${1:-site}"
lychee="${LYCHEE:-lychee}"
[[ -d $site ]] || { echo "no built site in $site; run: mkdocs build --strict" >&2; exit 1; }
command -v "$lychee" >/dev/null ||
  { echo "check-links.sh needs lychee (https://lychee.cli.rs), or LYCHEE=/path/to/lychee" >&2; exit 1; }

repo='https://github\.com/khalaharvi/chalk/(blob|tree)/main/'
excludes=(
  # Placeholders in examples and the demo, and pages that need a login.
  '^https?://([a-z0-9-]+\.)?example\.(com|org)'
  '^https://mcp\.atlassian\.com/'
  '^https://claude\.ai/settings/'
  '^https://github\.com/users/khalaharvi/projects/'
  # Edit links point at files that exist only once a change is merged.
  '^https://github\.com/khalaharvi/chalk/edit/'
  # The site's own URL (canonical links, the sitemap) before it is deployed;
  # its pages are checked as files.
  '^https://khalaharvi\.github\.io/chalk/'
)
# Pages are directories with an index.html (use_directory_urls), so a link
# to one is checked, fragment included, against that file. "." accepts a
# link to a plain directory in the checkout, such as share/prompts.
# 404.html is served at any depth, so its links are absolute (/chalk/...);
# they are the same links as on every other page.
args=(--no-progress --include-fragments --exclude-loopback --max-retries 3
      --accept "200,206,429" --index-files "index.html,." --exclude-path '404\.html$'
      --remap "^${repo}(.*)\$ file://$PWD/\$2")
for pattern in "${excludes[@]}"; do args+=(--exclude "$pattern"); done

"$lychee" "${args[@]}" "$site"
