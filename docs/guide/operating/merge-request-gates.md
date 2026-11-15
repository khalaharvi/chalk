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
| Rubric | `chalk / rubric` | `chalk:rubric` | `CHALK_SETUP_CMD` and `CHALK_TEST_CMD` from the base branch's `.chalk/config`, run in CI |
| Audit | `chalk / audit` | `chalk:audit` | Optional: writes a row to a central audit table when both gates pass |

The ticket is read from the branch name, so a branch must carry a key
like `PROJ-123`.

## What an agent may not change

A check is only worth something if the work it checks cannot rewrite it.
Chalk guards that in three places, none of which asks a model:

- **In the run.** The files and directories in `CHALK_PROTECTED` are the
  exam: by default `.chalk` (the rubric's configuration, the textbook and
  any prompts you ejected) and the CI configuration
  (`.github/workflows`, `.gitlab-ci.yml`, `.gitlab/chalk.gitlab-ci.yml`).
  A loop that changes one of them, or changes the spec in any way but
  ticking a checkpoint, is not committed, even when the rubric passes. The
  agent is told which file to put back, and a run that keeps doing it goes
  to [detention](../running/failures.md). Add whatever else defines "done"
  in your repository, such as a directory of acceptance tests. To change a
  protected file, commit the change yourself; `CHALK_PROTECTED=none`
  protects nothing.
- **In CI.** The rubric job reads `CHALK_SETUP_CMD` and `CHALK_TEST_CMD`
  from the base branch, not from the pull or merge request. A request that
  edits `.chalk/config` therefore still has to pass the rubric you
  merged. To change the rubric, merge the change to the base branch first.
- **On the request.** With `CHALK_TEST_GUARD=true`, the harness compares
  the branch with its base and lists every test file that was deleted, or
  given a skip marker or fewer assertion lines. The list goes to the
  reviewing agent, which must account for each entry, and into the
  request's description. It counts lines, so it is a list of places to
  look: it can flag a test that was only reorganised, and it cannot see a
  test rewritten to assert something weaker in the same number of lines.

One gap is yours to close on the forge. The gate's own file
(`.github/workflows/chalk.yml` or `.gitlab/chalk.gitlab-ci.yml`) is part
of the request it gates, so someone who pushes to a Chalk branch by hand
could rewrite it. Make a code owner's review required for the CI
configuration and `.chalk/`: a `CODEOWNERS` entry with "Require review
from Code Owners" on GitHub, or Code Owner approval on a protected branch
on GitLab.

## The rubric's image

The rubric job runs in the image named by `CHALK_CI_IMAGE`, `node:22`
unless you set it. On any other stack, set it before the first pull or
merge request, or every one fails the rubric gate with an error like
`go: not found`. The image must:

- Come from a registry CI can pull from. The sandbox image Chalk runs
  locally is not there unless you push it.
- Have your toolchain, and whatever `CHALK_SETUP_CMD` does not install.
- On GitLab, have git: the job fetches the target branch to read the
  rubric from it, and stops with "CHALK_CI_IMAGE needs git" without it. On
  GitHub the workflow checks the base branch out itself.
- Have bash and sed. The job runs `CHALK_SETUP_CMD` and `CHALK_TEST_CMD`
  with `bash -c`, as the sandbox does, so a rubric that relies on bash
  passes or fails the same way in both. Debian and Ubuntu based images
  have bash; Alpine images do not, and the job stops with
  "CHALK_CI_IMAGE needs bash".

[Use your own stack](../configuring/your-stack.md#the-ci-image) covers
choosing the image, with examples.

## GitHub

- In a branch protection rule (or ruleset) for the base branch, make
  `chalk / spec` and `chalk / rubric` required status checks, and require
  an approving review.
- For a stack other than Node, set the repository variable
  `CHALK_CI_IMAGE`, for example
  `gh variable set CHALK_CI_IMAGE --body golang:1.23-bookworm`.
- For the audit trail, add the secret `CHALK_AUDIT_DB_URL`.

## GitLab

- Turn on merge request approval rules.
- The jobs use the built-in `test` and `.post` stages; if you define your
  own `stages:`, keep `test`.
- For a stack other than Node, change `CHALK_CI_IMAGE` under `variables:`
  in `.gitlab/chalk.gitlab-ci.yml`, or set a CI/CD variable of the same
  name, which takes precedence.
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
