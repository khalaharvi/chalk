# Default Chalk sandbox. For non-Node stacks, build your own image FROM this
# one (or any image with bash, git, coreutils and the `claude` CLI on PATH)
# and set CHALK_IMAGE in .chalk/config.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates jq ripgrep \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

WORKDIR /work
