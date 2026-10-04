# Security

Chalk runs coding agents that execute commands, so its isolation matters.
If you find a way for an agent to reach outside its sandbox, read host
credentials, or push without going through a merge request, please report
it privately through GitHub's "Report a vulnerability" button on this
repository instead of opening a public issue.

## What Chalk does and does not protect

- The agent works in a container on a clone of the repository. The host
  repository is mounted read-only and only a git bundle of commits comes out.
- The container holds no GitLab credentials. It does hold the Claude
  credentials you export, and it has outbound network access.
- The telemetry database and the optional memory server listen on the local
  machine only.
- Chalk is not a defence against a malicious repository. Setup and test
  commands from `.chalk/config` run inside the container, but
  `.gitlab-ci.yml` and anything else merged from an agent's branch run
  wherever your CI runs. Review merge requests.
