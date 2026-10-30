# Design: Evidence-carrying pull requests

Status: APPROVED by the maintainer on 2026-10-30 (Thesis 4 of the paper, one PR; SSH signing chosen)
Mode: Builder
Paper: [docs/paper/main.tex](../paper/main.tex), Section 7
Reference: [docs/reference/attestation.md](../reference/attestation.md)
Stacked on: [evidence-lessons.md](evidence-lessons.md)

## Problem Statement

Agent-authored pull requests carry human-readable traces at best. Copilot
adds a commit trailer that links to session logs; Cursor attaches videos
and logs. Both are produced in the agent's own environment, and neither is
bound to the tree that is merged. A reviewer cannot tell from the request
whether the tests the agent claims to have run were run, by whom, on
which tree, or whether the agent edited the tests to make them pass. Chalk
already holds that evidence in its ledger. It never leaves the machine.

## What Makes This Cool

- **The harness signs, not the agent.** The record is built from what
  the harness recorded and signed with a key that never enters a sandbox.
- **It is bound to the exact tree.** Any later commit fails verification.
- **It shows test edits.** Existing test files the branch changed or
  deleted are listed, the failure mode reward-hacking studies document,
  and verification recomputes the list.
- **It can be re-run.** `--rerun` runs the rubric and the saved needs in a
  fresh sandbox in CI. That checks the evidence; the agent's run itself is
  never replayed.

## Constraints

- No new dependency beyond OpenSSH's `ssh-keygen -Y`, which git already
  uses for SSH-signed commits and which CI runners and macOS ship.
  Base64 goes through `openssl`, which Chalk already needs.
- Opt-in (`CHALK_ATTEST=false` by default): a record is a new file in
  every request, and what it holds leaves the machine with the branch
  (PRIVACY.md).
- Optional services never block. Without `ssh-keygen`, the database or a
  merge base, the branch is submitted without a record, with a warning.

## Premises

1. **The record is a standard.** It is an in-toto Statement v1 in a DSSE
   envelope, with a predicate type documented at
   `docs/reference/attestation.md` and a `version` field.
2. **The subject is the tree without `.chalk/evidence/`.** That lets the
   record be committed to the branch it describes, and records of other
   tickets merged earlier do not matter.
3. **Signers are trusted per repository.** `.chalk/allowed_signers` is
   committed on the base branch; `CHALK_ATTEST_SIGNERS` overrides it.
4. **Report, don't judge, test edits.** Changing an existing test can be
   right. The record lists such changes for the reviewer; verification
   fails only when the list no longer matches the branch.

## Recommended Approach

- `lib/attest.sh`:
  - `attest_key`, `attest_principal` and `attest_signer_line`;
  - `attest_tree` (the subject) and `attest_tests_changed`;
  - `attest_pae` and `attest_sign` (DSSE);
  - `attest_statement`;
  - `attest_record`, called by `run_graduate` before the push;
  - `attest_verify_one` and `attest_rerun`;
  - `cmd_attest key|verify`.
- `db_attest_ledger`: the ticket's calls, lessons and total cost.
- The request body gains an "Evidence:" line.
- `chalk doctor` checks for `ssh-keygen` when `CHALK_ATTEST=true`.

## Not in scope

- Keyless signing and a transparency log (Sigstore). It would send an
  identity to a public log, against "nothing leaves the machine unless you
  send it".
- A forge-side check that blocks merges without a record. The
  verification command is ready for CI; wiring it into the shipped
  templates is a follow-up.
- Re-checking the review verdict. It is recorded, not re-run, since a
  model's review is not reproducible.

## Failure modes

| Failure | Effect |
|---|---|
| `ssh-keygen` missing at submit | No record; warning; request opened as before |
| Database down at submit | No record; warning |
| A commit after the record | `subject` fails |
| CI checks out a merge commit | `subject` fails; the reference page says to check out the head |
| Shallow CI clone | `tests` is skipped, saying to fetch more history |
| Payload edited | `signature` fails, and usually `cost` too |
