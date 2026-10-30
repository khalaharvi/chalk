# Evidence records

With `CHALK_ATTEST=true`, a finished branch carries a signed record of how
its work was checked, committed as `.chalk/evidence/<TICKET>.json` just
before the branch is pushed. The pull or merge request names it, and CI
checks it with `chalk attest verify`.

A record proves which key signed it, and what the harness saw while it
ran the work. It does not prove that the change is correct: tests that
pass can still miss what they do not test. Read it as evidence for the
reviewer, not as a verdict.

## Set it up

1. On the machine that runs Chalk, print the line that lets CI trust its
   key:

    ```sh
    chalk attest key
    ```

    The key is Chalk's own ed25519 key, made in its state directory the
    first time; set `CHALK_ATTEST_KEY` to use another. It never enters a
    sandbox.

2. Commit that line to `.chalk/allowed_signers` on your base branch, one
   line per machine that runs Chalk.
3. Set `CHALK_ATTEST=true` in `.chalk/config`.
4. In CI, check out the pull request's **head** commit rather than a merge
   commit, with enough history to reach its merge base, and run:

    ```sh
    chalk attest verify --rerun --base "origin/$BASE_BRANCH"
    ```

    where `$BASE_BRANCH` is the branch the request targets (in GitHub
    Actions, `$GITHUB_BASE_REF`). Verify checks the records the branch
    added since its merge base with it, and trusts the signers committed
    there, never the branch's own copy of `.chalk/allowed_signers`: whoever
    pushes the branch could add a key to that. Without `--base`, the base
    is `origin/CHALK_BASE_BRANCH`, a setting the branch can change, so name
    it in CI.

It needs `git`, `jq`, `openssl` and `ssh-keygen` (OpenSSH 8.1 or newer).
`--rerun` also needs Docker, to run the rubric and the saved needs in a
fresh sandbox.

## What verify checks

| Check | Passes when |
| :-- | :-- |
| `signature` | The record's DSSE signature verifies for the principal it names against `.chalk/allowed_signers` as committed at the branch's merge base (or against `CHALK_ATTEST_SIGNERS`, set outside the repository). |
| `subject` | The record names this branch's git tree, not counting `.chalk/evidence/`. Any commit after the record fails this. |
| `tests` | The existing test files the branch changed, deleted or renamed are those the record lists. They are printed for the reviewer: an agent that edits a test until it passes is what this check is for. |
| `cost` | The recorded calls add up to the recorded total. |
| `rubric` | With `--rerun`: the rubric command the record names passes in a fresh sandbox on the image it names, after the setup command it names. The branch's `.chalk/config` is not used, since the branch could change it. When the local image's ID differs from the recorded one, the check says so. |
| `needs` | With `--rerun`: every need saved in `.chalk/needs` passes in that sandbox. |

Verify exits non-zero when any check fails.

## The format

The record is a [DSSE](https://github.com/secure-systems-lab/dsse)
envelope, `payloadType` `application/vnd.in-toto+json`, signed with
`ssh-keygen -Y sign` in the namespace `chalk-attestation`. Its
`signatures[].keyid` is the principal, then the key's SHA256 fingerprint.
Its payload is an [in-toto](https://in-toto.io) Statement v1:

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [{ "name": "chalk/PROJ-123", "digest": { "gitTree": "…" } }],
  "predicateType": "https://github.com/khalaharvi/chalk/blob/main/docs/reference/attestation.md",
  "predicate": {
    "version": 0,
    "ticket": "PROJ-123",
    "created": "2026-10-30T12:00:00Z",
    "base": { "branch": "main", "commit": "…", "tree": "…" },
    "harness": { "chalk": "0.8.0", "prompts": "…", "fp_rules": "shadow", "decider": "off" },
    "sandbox": { "image": "chalk-sandbox:local", "image_id": "sha256:…", "needs": [] },
    "rubric": { "command": "npm test", "setup": "npm ci" },
    "review": { "ran": true, "summary": "…" },
    "tests_changed": [],
    "ledger": {
      "loops": [{ "run_id": "…", "loop": 1, "kind": "continue", "rubric_exit": 0, "tests_hash": null,
                  "first_error": null, "tree_id": "…", "verdict": null, "fp_rules": "shadow",
                  "model": "…", "prompts": "…", "cost_usd": 0.41, "budget_usd": 1.0 }],
      "lessons": [],
      "cost_usd": 0.41
    }
  }
}
```

`ledger` is what the harness recorded in its database for the ticket:
every agent call but lesson distillation, and every detention with its
probe and evidence (see [Saved needs](../guide/running/failures.md#saved-needs)).
`version` changes when a field changes meaning.

When the record cannot be made, because `ssh-keygen` is missing, the
database did not answer, or the branch has no merge base with
`CHALK_BASE_BRANCH`, the branch is submitted without it, with a warning.
