#!/usr/bin/env bash
# Captures the report card screenshots on the docs site and in the README,
# light and dark, 1280px wide, from the sample in docs/assets/report-card.json.
#
#   scripts/screenshots.sh        CHROME=/path/to/chrome picks the browser
#
# The sample is put into share/dashboard.html the way `chalk dashboard`
# does it (lib/dashboard.sh), so the screenshots show the real page.
set -euo pipefail
cd "$(dirname "$0")/.."

chrome="${CHROME:-}"
if [[ -z $chrome ]]; then
  for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                   google-chrome chromium chromium-browser; do
    if [[ -x $candidate ]] || command -v "$candidate" >/dev/null; then
      chrome="$candidate"
      break
    fi
  done
fi
[[ -n $chrome ]] || { echo "screenshots.sh needs Chrome or Chromium; set CHROME" >&2; exit 1; }
command -v jq >/dev/null || { echo "screenshots.sh needs jq" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# As in lib/dashboard.sh: "</" is escaped, and the data replaces the
# template line holding the /*CHALK_DATA*/ marker.
data="$(jq -c 'del(.sample)' docs/assets/report-card.json)"
data="${data//<\//<\\/}"
mapfile -t page < share/dashboard.html
for line in "${page[@]}"; do
  if [[ $line == *'/*CHALK_DATA*/'* ]]; then line="$data"; fi
  printf '%s\n' "$line"
done > "$tmp/report-card.html"

# Blink's preferredColorScheme is 0 for dark and 1 for light, whatever the
# machine's own setting. The page shows times in the reader's zone; TZ=UTC
# keeps reruns the same.
declare -A schemes=([light]=1 [dark]=0)
for scheme in light dark; do
  TZ=UTC "$chrome" --headless --disable-gpu --hide-scrollbars --window-size=1280,1000 \
    "--blink-settings=preferredColorScheme=${schemes[$scheme]}" \
    "--screenshot=$PWD/docs/assets/report-card-$scheme.png" \
    "file://$tmp/report-card.html" 2>/dev/null
done
ls -l docs/assets/report-card-*.png
