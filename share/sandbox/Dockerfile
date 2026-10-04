# Default Chalk sandbox. For non-Node stacks, build your own image FROM this
# one (or any image with bash 5.2 or newer, git, coreutils and the `claude`
# CLI on PATH) and set CHALK_IMAGE in .chalk/config. Debian 12, used here,
# ships bash 5.2.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates jq ripgrep \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

WORKDIR /work
