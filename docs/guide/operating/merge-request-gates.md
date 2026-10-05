# Pull and merge request gates

The rubric already passed in the sandbox, but the sandbox is where the
agent worked. The gates check the work again where the agent never was,
and the approval rule records that a person reviewed it.

`chalk init` adds `.github/workflows/chalk.yml` on GitHub or
`.gitlab/chalk.gitlab-ci.yml` on GitLab. On pull or merge requests from
`chalk/*` and `tutoring/*` branches, it runs:

| Job | GitHub | GitLab | What it checks |
| :-- | :-- | :-- | :-- |
| Spec | `chalk / spec` | `chalk:spec` | `specs/<TICKET>.md` has no unfinished checkpoints, and `CLAUDE.md` and `.chalk/textbook.md` exist |
| Rubric | `chalk / rubric` | `chalk:rubric` | `CHALK_SETUP_CMD` and `CHALK_TEST_CMD` from `.chalk/config`, run in CI |
| Audit | `chalk / audit` | `chalk:audit` | Optional: writes a row to a central audit table when both gates pass |

The ticket is read from the branch name, so a branch must carry a key
like `PROJ-123`.

## GitHub

- In a branch protection rule (or ruleset) for the base branch, make
  `chalk / spec` and `chalk / rubric` required status checks, and require
  an approving review.
- Set the repository variable `CHALK_CI_IMAGE` to an image with your
  toolchain. The rubric job runs in it; the default is `node:22`.
- For the audit trail, add the secret `CHALK_AUDIT_DB_URL`.

## GitLab

- Turn on merge request approval rules.
- The jobs use the built-in `test` and `.post` stages; if you define your
  own `stages:`, keep `test`.
- `CHALK_CI_IMAGE` is a variable in the included file (default `node:22`);
  override it for your toolchain.
- For the audit trail, add `CHALK_AUDIT_DB_URL` as a masked CI/CD
  variable.

## The audit table

`CHALK_AUDIT_DB_URL` is a Postgres connection URL for a database your
organisation keeps. Apply the table once:

```sh
psql "$CHALK_AUDIT_DB_URL" -f share/ci-audit-schema.sql
```

Each pull or merge request whose gates pass adds a row with the project,
ticket, request number, commit and pipeline, with status `gates_passed`.
Together with the local `runs` and `lessons` tables, it is the evidence
trail described in the [compliance note](../configuring/permissions.md#compliance-note).

The gates show that the checks passed; the approval shows that a person
reviewed the diff. Neither replaces the other.
