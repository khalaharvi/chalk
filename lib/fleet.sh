# Workstreams: one ticket = one branch (chalk/TICKET) = one worktree = one spec.

# Creates branch chalk/TICKET in a new sibling worktree and prints its path.
workstream_create() {
  local ticket="$1" branch="chalk/$1" dir
  dir="${| worktree_dir "$ticket"; }"
  git -C "${| main_root; }" worktree add -q -b "$branch" "$dir" "$CHALK_BASE_BRANCH"
  mkdir -p "$dir/specs"
  printf '%s\n' "$dir"
}

workstream_exists() {
  git show-ref --verify --quiet "refs/heads/chalk/$1"
}

cmd_new() {
  local ticket="${1:-}" title dir
  is_ticket "$ticket" || die "usage: chalk new TICKET [title]   (TICKET like PROJ-123)"
  shift
  title="${*:-Describe the change}"
  need git
  load_config "${| repo_root; }"
  ! workstream_exists "$ticket" || die "branch chalk/$ticket already exists"

  dir="$(workstream_create "$ticket")"
  cat > "$dir/specs/$ticket.md" <<SPEC
# $ticket: $title

## Context
What is being built and why. Link the ticket. Name the files or modules involved.

## Checkpoints
Each checkpoint must be small enough for one agent loop and provable by a test.
- [ ] First checkpoint
- [ ] Second checkpoint
SPEC
  info "created $dir on branch chalk/$ticket"
  info "next: edit specs/$ticket.md, commit it, then run 'chalk run' from that directory"
}

# Asks Claude (on the host, with your MCP servers) to split an epic into a plan.
fleet_plan() {
  local epic="$1" prompt
  need claude
  prompt="${| prompt_file "${| repo_root; }" breakdown; }"
  { cat "$prompt"; printf '\nEpic: %s\n' "$epic"; } |
    claude -p --output-format json --json-schema "${CHALK_SCHEMA[plan]}" \
      --max-budget-usd "$CHALK_BUDGET_USD" |
    jq -e '.structured_output'
}

fleet_validate() {
  jq -e '
    (.workstreams | length > 0) and
    all(.workstreams[];
        (.ticket | test("^[A-Z][A-Z0-9]+-[0-9]+$")) and
        (.title | length > 0) and
        (.checkpoints | length > 0))
  ' "$1" >/dev/null 2>&1
}

fleet_running_count() {
  local dir count=0
  for dir in "${| state_dir; }"/runs/*/; do
    if run_is_alive "${dir%/}"; then count=$((count + 1)); fi
  done
  printf '%s\n' "$count"
}

cmd_fleet() {
  local epic="" plan_file="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) plan_file="${2:-}"; shift ;;
      --yes|-y) yes=1 ;;
      -*) die "usage: chalk fleet EPIC [--plan FILE] [--yes]" ;;
      *) epic="$1" ;;
    esac
    shift
  done
  is_ticket "$epic" || die "usage: chalk fleet EPIC [--plan FILE] [--yes]"

  need git docker jq
  load_config "${| repo_root; }"
  agent_auth_present || die "no agent credentials; export one of: ${CHALK_AUTH_VARS[*]}"

  # The plan is saved so that re-running the command launches what is left.
  local saved
  saved="${| state_dir; }/plans/$epic.json"
  mkdir -p "$(dirname "$saved")"
  if [ -n "$plan_file" ]; then
    cp "$plan_file" "$saved"
  elif [ ! -f "$saved" ]; then
    info "asking Claude to break down $epic"
    fleet_plan "$epic" > "$saved.tmp" ||
      die "could not generate a plan; write one by hand and pass --plan (format: README, 'Fleet plans')"
    mv "$saved.tmp" "$saved"
  fi
  fleet_validate "$saved" || die "invalid plan: $saved (format: README, 'Fleet plans')"

  info "plan for $epic ($saved):"
  jq -r '.workstreams[] | "  \(.ticket)  \(.title)  (\(.checkpoints | length) checkpoints)"' "$saved"
  if [ "$yes" -ne 1 ]; then
    printf 'Launch these agents? [y/N] '
    local answer
    read -r answer
    case "$answer" in y|Y|yes) ;; *) die "aborted; edit the plan and re-run" ;; esac
  fi

  local item ticket dir slots
  local -a items
  slots=$((CHALK_MAX_PARALLEL - $(fleet_running_count)))
  mapfile -t items < <(jq -c '.workstreams[]' "$saved")
  for item in "${items[@]}"; do
    ticket="$(jq -r '.ticket' <<<"$item")"
    if workstream_exists "$ticket"; then
      info "$ticket: already started, skipping"
      continue
    fi
    if [ "$slots" -le 0 ]; then
      info "$ticket: waiting (CHALK_MAX_PARALLEL=$CHALK_MAX_PARALLEL); re-run 'chalk fleet $epic --yes' when a slot frees up"
      continue
    fi

    dir="$(workstream_create "$ticket")"
    jq -r '"# \(.ticket): \(.title)\n\n## Context\n\(.context // "")\n\n## Checkpoints\n"
           + (.checkpoints | map("- [ ] " + .) | join("\n"))' <<<"$item" > "$dir/specs/$ticket.md"
    git -C "$dir" add "specs/$ticket.md"
    git -C "$dir" commit -q -m "chalk($ticket): spec"
    (cd "$dir" && "$BASH" "$CHALK_HOME/bin/chalk" run --detach)
    slots=$((slots - 1))
  done
}
