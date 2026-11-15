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
  `ANTHROPIC_BASE_URL`).
- **Network:** by default the container has outbound network access, so
  an agent misled by something it read could send your code or that
  credential anywhere. `CHALK_EGRESS=allowlist` puts the container on a
  network with no route out and lets it reach only the model provider and
  the hosts you list, through a proxy. That limits where data can go, not
  what an allowed host is sent.
- **The exam:** an agent's change to the files in `CHALK_PROTECTED` (the
  rubric's configuration, the prompts and the CI gates, by default), or
  to the text of its spec, is never committed, and CI reads the rubric
  from the base branch. The CI gate's own file is not protected from a
  person who pushes to the branch: require a code owner's review for it.
- **The A2A server** (`chalk a2a up`, optional): listens on 127.0.0.1
  only and asks for a bearer token on every call. Whoever holds the token
  can start runs, which spend money and execute code in sandboxes, and can
  commit a patch to a detained run's branch, as you can at office hours.
  Treat it as you would a login to your machine.
- **Local services:** the telemetry and lessons database publishes no
  port and is reached only through `docker exec`.
- **Not a defence against a malicious repository:** setup and test commands
  from `.chalk/config` run inside the container. But CI configuration
  (`.github/workflows/`, `.gitlab-ci.yml`) and anything else merged from
  an agent's branch runs wherever your CI runs. Review pull and merge
  requests before merging them.
