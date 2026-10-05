# Security

Chalk runs coding agents that execute commands, so its isolation matters.

## Report a vulnerability

If you find a way for an agent to reach outside its sandbox, read host
credentials, or push without going through a pull or merge request,
report it privately with the **Report a vulnerability** button on the
repository's
[Security tab](https://github.com/khalaharvi/chalk/security). Do not open
a public issue with the details.

Include:

- the Chalk version (`chalk --version`) and your Docker runtime;
- what an agent could do that it should not, and how you got there;
- the smallest spec or setup that reproduces it.

If the button is missing, open an issue that asks for a private contact
and contains no details. Fixes go into the latest release.

## What Chalk does and does not protect

- **The sandbox:** the agent works in a container on a clone of the
  repository. The host repository is mounted read-only, and only a git
  bundle of commits comes out.
- **Credentials:** the container holds no GitHub or GitLab credentials.
  It does hold the model credentials you export (`ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_AUTH_TOKEN`, and
  `ANTHROPIC_BASE_URL`), and it has outbound network access.
- **Local services:** the telemetry and lessons database publishes no
  port and is reached only through `docker exec`.
- **Not a defence against a malicious repository:** setup and test commands
  from `.chalk/config` run inside the container. But CI configuration
  (`.github/workflows/`, `.gitlab-ci.yml`) and anything else merged from
  an agent's branch runs wherever your CI runs. Review pull and merge
  requests before merging them.
