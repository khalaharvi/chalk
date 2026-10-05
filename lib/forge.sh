# Where the repository is hosted: GitHub (pull requests via gh, gates in
# GitHub Actions) or GitLab (merge requests via glab, gates in GitLab CI).
#
# CHALK_FORGE picks one; `auto` (the default) reads the origin remote and
# chooses GitHub for github.com and GitLab for anything else, so self-hosted
# GitLab keeps working unchanged. GitHub Enterprise needs CHALK_FORGE=github.

# Per forge: the CLI, how to install it, and what it calls a review request.
declare -gA CHALK_FORGE_CLI=([github]=gh [gitlab]=glab)
declare -gA CHALK_FORGE_INSTALL=([github]="brew install gh" [gitlab]="brew install glab")
declare -gA CHALK_FORGE_REQUEST=([github]="pull request" [gitlab]="merge request")

# forge_kind -> REPLY: github or gitlab.
forge_kind() {
  case "${CHALK_FORGE:-auto}" in
    github|gitlab) REPLY="$CHALK_FORGE" ;;
    *)
      REPLY="$(git remote get-url origin 2>/dev/null || true)"
      if [[ $REPLY =~ ^(https?://|ssh://)?([^@/]+@)?github\.com[:/] ]]; then
        REPLY=github
      else
        REPLY=gitlab
      fi
      ;;
  esac
}

# forge_cli -> REPLY: gh or glab.
forge_cli() {
  forge_kind
  REPLY="${CHALK_FORGE_CLI[$REPLY]}"
}

# forge_request -> REPLY: "pull request" or "merge request".
forge_request() {
  forge_kind
  REPLY="${CHALK_FORGE_REQUEST[$REPLY]}"
}

# forge_push DIR BRANCH: pushes BRANCH of the clone at DIR to origin. On
# success, what the remote says ("remote:" lines, such as GitHub's hint to
# create a pull request) is left out, since Chalk opens the request itself;
# anything else git prints is kept. A failed push shows all of it.
forge_push() {
  local out
  if out="$(git -C "$1" push -q -u origin "$2" 2>&1)"; then
    out="$(grep -v '^remote:' <<<"$out" || true)"
    if [[ -n $out ]]; then printf '%s\n' "$out" >&2; fi
    return 0
  fi
  printf '%s\n' "$out" >&2
  die "could not push $2 to origin"
}

# forge_open_request DIR SOURCE TARGET TITLE BODY: opens a pull or merge
# request from branch SOURCE into TARGET for the clone at DIR.
forge_open_request() {
  local dir="$1" source="$2" target="$3" title="$4" body="$5"
  case "${| forge_kind; }" in
    github)
      need gh
      (cd "$dir" && gh pr create --head "$source" --base "$target" --title "$title" --body "$body")
      ;;
    gitlab)
      need glab
      (cd "$dir" && glab mr create --yes --source-branch "$source" --target-branch "$target" \
        --title "$title" --description "$body")
      ;;
  esac
}

# forge_signed_in: the forge's CLI is installed and authenticated.
forge_signed_in() {
  "${| forge_cli; }" auth status
}
