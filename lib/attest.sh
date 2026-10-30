# Evidence-carrying pull requests (docs/designs/evidence-prs.md). With
# CHALK_ATTEST=true, a finished branch carries a signed record of how its
# work was checked: the loops the harness ran and recorded (rubric exits,
# fingerprints, tree IDs, verdicts, cost), the final review, the lessons and
# their probes, the sandbox image and the saved needs, and which existing
# test files the branch changed. It is an in-toto Statement in a DSSE
# envelope, signed with an SSH key the host holds (ssh-keygen -Y sign); the
# sandbox never sees the key. Its subject is the branch's git tree without
# .chalk/evidence/, so the record can be committed to the branch it
# describes. chalk attest verify checks it in CI, and with --rerun runs the
# rubric and the needs again in a fresh sandbox.
#
# A record proves who signed it and what the harness saw, not that the
# change is correct.

ATTEST_DIR=.chalk/evidence
ATTEST_PAYLOAD_TYPE="application/vnd.in-toto+json"
ATTEST_NAMESPACE=chalk-attestation
ATTEST_PREDICATE="https://github.com/khalaharvi/chalk/blob/main/docs/reference/attestation.md"
# Signers CI trusts, one per line in ssh-keygen's allowed_signers format.
ATTEST_SIGNERS_FILE=.chalk/allowed_signers
# Existing test files a branch changed or deleted are listed in its record,
# for the reviewer: an agent that edits a test to pass it is the failure
# this record is meant to show. A path is a test file when it matches this.
ATTEST_TEST_PATHS='(^|/)(tests?|spec|specs|__tests__)/|(_test|\.test|_spec|\.spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$'

# attest_key -> REPLY: the private key that signs: CHALK_ATTEST_KEY, or
# Chalk's own ed25519 key, made on first use under the state directory.
attest_key() {
  REPLY="${CHALK_ATTEST_KEY:-}"
  [[ -z $REPLY ]] || return 0
  REPLY="${| state_dir; }/attest/id_ed25519"
  if [[ ! -f $REPLY ]]; then
    mkdir -p "${REPLY%/*}"
    chmod 700 "${REPLY%/*}"
    ssh-keygen -q -t ed25519 -N '' -C chalk-attest -f "$REPLY" >/dev/null
  fi
}

# attest_principal -> REPLY: who signs, as allowed_signers names them:
# CHALK_ATTEST_PRINCIPAL, else the git email, else "chalk".
attest_principal() {
  REPLY="${CHALK_ATTEST_PRINCIPAL:-}"
  [[ -n $REPLY ]] || REPLY="$(git config user.email 2>/dev/null || true)"
  REPLY="${REPLY:-chalk}"
}

# attest_signer_line -> REPLY: the line for ATTEST_SIGNERS_FILE that lets
# CI trust this machine's key.
attest_signer_line() {
  local key
  key="${| attest_key; }"
  REPLY="${| attest_principal; } namespaces=\"$ATTEST_NAMESPACE\" $(cut -d' ' -f1,2 "$key.pub")"
}

# attest_tree DIR [REV] -> REPLY: the git tree of REV (HEAD) in the
# repository at DIR, without ATTEST_DIR: what a record's subject names.
attest_tree() {
  local index
  index="$(mktemp)"
  rm -f "$index"
  REPLY="$(GIT_INDEX_FILE="$index" git -C "$1" read-tree "${2:-HEAD}" &&
           GIT_INDEX_FILE="$index" git -C "$1" rm -r -q --cached --ignore-unmatch "$ATTEST_DIR" &&
           GIT_INDEX_FILE="$index" git -C "$1" write-tree)" || REPLY=""
  rm -f "$index"
}

# attest_tests_changed DIR BASE [REV]: prints, one per line and sorted,
# the test files (ATTEST_TEST_PATHS) that existed at BASE and that REV
# (HEAD) changed or deleted. Added tests are not listed: writing them is
# the work.
attest_tests_changed() {
  # A test renamed and edited, or moved out of the test paths, counts as
  # the existing test deleted, whatever git's rename detection is set to.
  git -C "$1" diff --no-renames --name-only --diff-filter=MD "$2" "${3:-HEAD}" -- . ":(exclude).chalk" |
    grep -E "$ATTEST_TEST_PATHS" | LC_ALL=C sort || true
}

# attest_pae BODY_FILE: prints the DSSE pre-authentication encoding of the
# payload in BODY_FILE, which is what is signed.
attest_pae() {
  printf 'DSSEv1 %d %s %d ' "${#ATTEST_PAYLOAD_TYPE}" "$ATTEST_PAYLOAD_TYPE" "$(wc -c < "$1" | tr -d ' ')"
  cat "$1"
}

# attest_statement DIR TICKET BRANCH BASE LEDGER: prints the in-toto
# Statement for TICKET's branch at DIR, whose merge base with the base
# branch is BASE. LEDGER is db_attest_ledger's JSON. Review and harness
# settings come from the RUN_* and CHALK_* globals of the run.
attest_statement() {
  local dir="$1" ticket="$2" branch="$3" base="$4" ledger="$5" tree base_tree image_id needs tests
  local -a need_lines
  tree="${| attest_tree "$dir"; }"
  base_tree="${| attest_tree "$dir" "$base"; }"
  image_id="$(docker image inspect -f '{{.Id}}' "$CHALK_IMAGE" 2>/dev/null || true)"
  evidence_needs "$dir" need_lines 2>/dev/null
  needs="$(printf '%s\n' "${need_lines[@]}" | jq -Rc 'select(. != "") | split("\t") | {probe: .[0], kind: .[1], ticket: .[2]}' | jq -sc .)"
  tests="$(attest_tests_changed "$dir" "$base" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  jq -n --arg ticket "$ticket" --arg branch "$branch" --arg tree "$tree" --arg base "$base" \
     --arg base_tree "$base_tree" --arg base_branch "$CHALK_BASE_BRANCH" --arg version "${CHALK_VERSION:-}" \
     --arg prompts "${RUN_PROMPTS:-}" --arg fp_rules "${CHALK_FP_RULES:-}" --arg decider "${CHALK_DECIDER:-}" \
     --arg image "$CHALK_IMAGE" --arg image_id "$image_id" --argjson needs "$needs" \
     --arg rubric "$CHALK_TEST_CMD" --arg setup "$CHALK_SETUP_CMD" --arg review "${RUN_REVIEW_SUMMARY:-}" --arg review_error "${RUN_REVIEW_ERROR:-}" \
     --argjson tests "$tests" --argjson ledger "$ledger" --arg type "$ATTEST_PREDICATE" \
     --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {_type: "https://in-toto.io/Statement/v1",
     subject: [{name: $branch, digest: {gitTree: $tree}}],
     predicateType: $type,
     predicate: {
       version: 0, ticket: $ticket, created: $created,
       base: {branch: $base_branch, commit: $base, tree: $base_tree},
       harness: {chalk: $version, prompts: $prompts, fp_rules: $fp_rules, decider: $decider},
       sandbox: {image: $image, image_id: $image_id, needs: $needs},
       rubric: {command: $rubric, setup: $setup},
       review: (if $review != "" then {ran: true, summary: $review}
                else {ran: false, error: $review_error} end),
       tests_changed: $tests,
       ledger: $ledger}}'
}

# attest_sign STATEMENT_FILE: prints the DSSE envelope that signs the
# Statement in STATEMENT_FILE with attest_key.
attest_sign() {
  local key pae sig fingerprint
  key="${| attest_key; }"
  pae="$(mktemp)"
  attest_pae "$1" > "$pae"
  sig="$(ssh-keygen -Y sign -f "$key" -n "$ATTEST_NAMESPACE" < "$pae" 2>/dev/null)" || { rm -f "$pae"; return 1; }
  rm -f "$pae"
  fingerprint="$(ssh-keygen -l -f "$key.pub" | cut -d' ' -f2)"
  jq -n --arg type "$ATTEST_PAYLOAD_TYPE" --arg payload "$(openssl base64 -A < "$1")" \
     --arg keyid "${| attest_principal; } $fingerprint" --arg sig "$(printf '%s\n' "$sig" | openssl base64 -A)" \
     '{payloadType: $type, payload: $payload, signatures: [{keyid: $keyid, sig: $sig}]}'
}

# attest_record DIR TICKET BRANCH: writes and commits ATTEST_DIR/TICKET.json
# on the branch checked out at DIR, and sets REPLY to its path; REPLY is
# empty when it was not made. Best effort: the branch is submitted with or
# without it, and a warning says why when it is not made.
attest_record() {
  local dir="$1" ticket="$2" branch="$3" base ledger file statement
  REPLY=""
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    warn "CHALK_ATTEST=true, but ssh-keygen is not installed: the branch is submitted without its evidence record"
    return 0
  fi
  base="$(git -C "$dir" merge-base "$CHALK_BASE_BRANCH" HEAD 2>/dev/null || true)"
  ledger="$(db_attest_ledger "$ticket" 2>/dev/null || true)"
  if [[ -z $base ]]; then
    warn "the evidence record could not be made: this branch has no merge base with $CHALK_BASE_BRANCH; it is submitted without it"
    return 0
  fi
  if ! jq -e '.loops | type == "array"' >/dev/null 2>&1 <<<"$ledger"; then
    warn "the evidence record could not be made: the telemetry database did not give the run's ledger; the branch is submitted without it"
    return 0
  fi
  file="$dir/$ATTEST_DIR/$ticket.json"
  statement="$(mktemp)"
  attest_statement "$dir" "$ticket" "$branch" "$base" "$ledger" > "$statement"
  mkdir -p "${file%/*}"
  if ! attest_sign "$statement" > "$file.tmp"; then
    rm -f "$statement" "$file.tmp"
    warn "the evidence record could not be signed with ${| attest_key; }; the branch is submitted without it"
    return 0
  fi
  rm -f "$statement"
  mv "$file.tmp" "$file"
  git -C "$dir" add -f "$ATTEST_DIR/$ticket.json"
  git -C "$dir" commit -q -m "chalk: evidence for $ticket" -m "Signed record of how this branch was checked; verify with: chalk attest verify"
  REPLY="$ATTEST_DIR/$ticket.json"
}

# attest_payload FILE: prints the Statement inside the envelope in FILE.
attest_payload() {
  jq -r '.payload' "$1" | openssl base64 -d -A
}

# attest_trusted DIR REF -> REPLY: the commit whose ATTEST_SIGNERS_FILE
# verification trusts: the merge base of HEAD with REF, the base branch.
# The branch's own copy is never trusted, since whoever pushes the branch
# could add a key to it. Empty when there is no merge base.
attest_trusted() {
  REPLY="$(git -C "$1" merge-base "$2" HEAD 2>/dev/null || true)"
}

# attest_signers DIR TRUSTED OUT: writes the signers verification trusts
# to the file OUT: CHALK_ATTEST_SIGNERS, else ATTEST_SIGNERS_FILE as
# committed at the commit TRUSTED. Fails when there are none.
attest_signers() {
  if [[ -n ${CHALK_ATTEST_SIGNERS:-} ]]; then
    cat "$CHALK_ATTEST_SIGNERS" > "$3" 2>/dev/null
  else
    [[ -n $2 ]] && git -C "$1" show "$2:$ATTEST_SIGNERS_FILE" > "$3" 2>/dev/null
  fi
}

# attest_verify_one DIR FILE RERUN VAR TRUSTED: checks the record FILE
# against the repository at DIR, trusting the signers committed at TRUSTED
# (attest_signers), and fills VAR with one entry per check: signature,
# subject, tests, cost and, with RERUN 1, rubric and needs. Each value is
# "ok: ..." or "FAIL: ..." (or "skip: ..." when it cannot be checked).
attest_verify_one() {
  local dir="$1" file="$2" rerun="$3" trusted="${5:-}" payload principal sig signers base tree recorded now total sum
  local -n __checks=$4
  __checks=()
  payload="$(mktemp)" sig="$(mktemp)" signers="$(mktemp)"
  if ! attest_payload "$file" > "$payload" 2>/dev/null || ! jq -e . "$payload" >/dev/null 2>&1; then
    __checks["signature"]="FAIL: not a DSSE envelope with a JSON payload"
    rm -f "$payload" "$sig" "$signers"
    return 0
  fi
  principal="$(jq -r '.signatures[0].keyid // "" | split(" ")[0]' "$file")"
  jq -r '.signatures[0].sig // ""' "$file" | openssl base64 -d -A > "$sig" 2>/dev/null || true
  if ! attest_signers "$dir" "$trusted" "$signers"; then
    __checks["signature"]="FAIL: no trusted signers: commit 'chalk attest key' output to $ATTEST_SIGNERS_FILE on the base branch"
  elif attest_pae "$payload" | ssh-keygen -Y verify -f "$signers" \
         -I "$principal" -n "$ATTEST_NAMESPACE" -s "$sig" >/dev/null 2>&1; then
    __checks["signature"]="ok: signed by $principal"
  else
    __checks["signature"]="FAIL: the signature does not verify for '$principal' against the trusted signers"
  fi

  tree="${| attest_tree "$dir"; }"
  recorded="$(jq -r '.subject[0].digest.gitTree // ""' "$payload")"
  if [[ -n $tree && $tree == "$recorded" ]]; then
    __checks["subject"]="ok: the record names this tree ($tree)"
  else
    __checks["subject"]="FAIL: the record names tree ${recorded:-none}, but this branch is ${tree:-unreadable}: the branch changed after it was recorded"
  fi

  base="$(jq -r '.predicate.base.commit // ""' "$payload")"
  if [[ -z $base ]] || ! git -C "$dir" cat-file -e "$base^{commit}" 2>/dev/null; then
    __checks["tests"]="skip: the base commit ${base:-?} is not in this clone (fetch more history)"
  else
    recorded="$(jq -r '.predicate.tests_changed[]?' "$payload")"
    now="$(attest_tests_changed "$dir" "$base")"
    if [[ $recorded != "$now" ]]; then
      __checks["tests"]="FAIL: the record lists other changed test files than the branch has"
    elif [[ -n $now ]]; then
      __checks["tests"]="ok: existing test files changed, for the reviewer: ${now//$'\n'/, }"
    else
      __checks["tests"]="ok: no existing test file changed"
    fi
  fi

  total="$(jq -r '(.predicate.ledger.cost_usd // 0) * 1' "$payload")"
  sum="$(jq -r '[.predicate.ledger.loops[]?.cost_usd // 0] | add // 0' "$payload")"
  if awk -v a="$total" -v b="$sum" 'BEGIN { d = a - b; exit !(d < 0.0001 && d > -0.0001) }'; then
    __checks["cost"]="ok: \$$total over $(jq -r '.predicate.ledger.loops | length' "$payload") recorded call(s)"
  else
    __checks["cost"]="FAIL: the recorded calls add up to \$$sum, not the \$$total recorded"
  fi

  if (( rerun )); then attest_rerun "$dir" "$payload" "$4"; fi
  rm -f "$payload" "$sig" "$signers"
}

# attest_rerun DIR STATEMENT_FILE VAR: runs the rubric, then every saved
# need, in a fresh sandbox with the branch checked out at DIR, as the
# harness did, and adds the rubric and needs checks to VAR. The rubric,
# setup and image are those the record names, not the branch's
# .chalk/config, which the branch itself could have changed; a local image
# whose ID differs from the recorded one is reported.
attest_rerun() {
  local dir="$1" name io need probe failed=0 status=0 image_id note=""
  local -n __rerun=$3
  local -a needs
  local -A got
  local CHALK_TEST_CMD CHALK_SETUP_CMD CHALK_IMAGE
  CHALK_TEST_CMD="$(jq -r '.predicate.rubric.command // ""' "$2")"
  CHALK_SETUP_CMD="$(jq -r '.predicate.rubric.setup // ""' "$2")"
  CHALK_IMAGE="$(jq -r '.predicate.sandbox.image // ""' "$2")"
  if [[ -z $CHALK_TEST_CMD || -z $CHALK_IMAGE ]]; then
    __rerun["rubric"]="FAIL: the record names no rubric command or image to re-run"
    return 0
  fi
  name="${| sandbox_name "attest-verify"; }"
  io="$(mktemp -d)"
  sandbox_ensure_image >/dev/null
  sandbox_start "$name" attest "$io"
  # A CI checkout is often a detached HEAD, which a clone cannot name, so
  # the sandbox clones a branch made for it.
  git -C "$dir" branch -f chalk-attest-verify HEAD
  sandbox_clone "$name" chalk-attest-verify >/dev/null
  git -C "$dir" branch -q -D chalk-attest-verify
  if [[ -n $CHALK_SETUP_CMD ]]; then sandbox_sh "$name" "$CHALK_SETUP_CMD" > "$io/setup.log" 2>&1 || true; fi
  docker exec -w /work/repo "$name" timeout "$CHALK_RUBRIC_TIMEOUT" bash -c "$CHALK_TEST_CMD" > "$io/rubric.log" 2>&1 ||
    status=$?
  image_id="$(docker image inspect -f '{{.Id}}' "$CHALK_IMAGE" 2>/dev/null || true)"
  if [[ $image_id != "$(jq -r '.predicate.sandbox.image_id // ""' "$2")" ]]; then
    note=" (its image ID differs from the recorded one)"
  fi
  if (( status == 0 )); then
    __rerun["rubric"]="ok: the recorded rubric passes in a fresh sandbox on $CHALK_IMAGE$note"
  else
    __rerun["rubric"]="FAIL: the recorded rubric exits $status in a fresh sandbox on $CHALK_IMAGE$note: $(tail -n 3 "$io/rubric.log" | tr '\n' ' ')"
  fi
  evidence_needs "$dir" needs 2>/dev/null
  for need in "${needs[@]}"; do
    probe="${need%%$'\t'*}"
    evidence_probe "$name" "$probe" got
    [[ ${got[outcome]} == passed ]] || failed=$((failed + 1))
  done
  if (( failed )); then
    __rerun["needs"]="FAIL: $failed of ${#needs[@]} saved need(s) fail"
  else
    __rerun["needs"]="ok: ${#needs[@]} saved need(s) hold"
  fi
  sandbox_stop "$name"
  rm -rf "$io"
}

# chalk attest key | verify [--rerun] [--base REF] [TICKET...]
cmd_attest() {
  local sub="${1:-}" rerun=0 root file check failed=0 base="" trusted
  local -a tickets=() files=()
  local -A checks
  [[ $# -eq 0 ]] || shift
  case "$sub" in
    key)
      need ssh-keygen
      info "Add this line to $ATTEST_SIGNERS_FILE and commit it, so that chalk attest verify trusts records this machine signs:"
      printf '%s\n' "${| attest_signer_line; }" ;;
    verify)
      while [ $# -gt 0 ]; do
        case "$1" in
          --rerun) rerun=1 ;;
          --base)
            [[ -n ${2:-} ]] || die "usage: chalk attest verify [--rerun] [--base REF] [TICKET...]"
            base="$2"; shift ;;
          -*) die "usage: chalk attest verify [--rerun] [--base REF] [TICKET...]" ;;
          *) tickets+=("$1") ;;
        esac
        shift
      done
      need git jq openssl ssh-keygen
      root="${| repo_root; }"
      load_config "$root"
      if [[ -z $base ]]; then
        base="origin/$CHALK_BASE_BRANCH"
        git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null || base="$CHALK_BASE_BRANCH"
      fi
      trusted="${| attest_trusted "$root" "$base"; }"
      [[ -n $trusted ]] ||
        die "this branch has no merge base with $base: fetch it with enough history, or name the base branch with --base"
      if (( ${#tickets[@]} )); then
        for file in "${tickets[@]}"; do files+=("$root/$ATTEST_DIR/$file.json"); done
      else
        # The records this branch added or changed: those of tickets merged
        # into the base earlier name trees that are gone, and were checked
        # when they were merged.
        while IFS= read -r file; do
          [[ $file == *.json ]] && files+=("$root/$file")
        done < <(git -C "$root" diff --no-renames --name-only --diff-filter=AM "$trusted" HEAD -- "$ATTEST_DIR")
      fi
      (( ${#files[@]} )) || die "this branch adds no evidence record in $ATTEST_DIR (set CHALK_ATTEST=true before the run)"
      for file in "${files[@]}"; do
        [[ -f $file ]] || die "no evidence record: ${file#"$root/"}"
        attest_verify_one "$root" "$file" "$rerun" checks "$trusted"
        info "${file#"$root/"}:"
        for check in signature subject tests cost rubric needs; do
          [[ -v checks[$check] ]] || continue
          info "  $check: ${checks[$check]}"
          [[ ${checks[$check]} != FAIL:* ]] || failed=1
        done
      done
      (( ! failed )) || die "an evidence record does not hold" ;;
    *) die "usage: chalk attest key | chalk attest verify [--rerun] [--base REF] [TICKET...]" ;;
  esac
}
