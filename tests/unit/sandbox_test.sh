#!/usr/bin/env bash
# lib/sandbox.sh: container names, OpenTelemetry flags and egress rules.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime sandbox

repo_name() { REPLY="my repo/x"; }

check "sandbox names replace characters docker rejects" \
  test "${| sandbox_name PROJ-1; }" = "chalk-sandbox-my-repo-x-PROJ-1"

declare -a args
CHALK_OTEL_ENDPOINT="" CHALK_OTEL_PROTOCOL=grpc CHALK_OTEL_SIGNALS=traces
sandbox_otel_args args PROJ-1
check "no telemetry flags without an endpoint" test "${#args[@]}" -eq 0

has() { local flag; for flag in "${args[@]}"; do [[ $flag == "$1" ]] && return 0; done; return 1; }

for endpoint in http://localhost:4317 http://127.0.0.1:4317; do
  CHALK_OTEL_ENDPOINT="$endpoint"
  sandbox_otel_args args PROJ-1
  check "a loopback endpoint ($endpoint) is rewritten to the host" \
    has "OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4317"
done

CHALK_OTEL_ENDPOINT=https://otel.example.com:4317
sandbox_otel_args args PROJ-1
check "a remote endpoint is left alone" has "OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com:4317"
check "resource attributes carry a safe repository name and the ticket" \
  has "OTEL_RESOURCE_ATTRIBUTES=chalk.repo=my_repo_x,chalk.ticket=PROJ-1"

CHALK_OTEL_SIGNALS=metrics,logs
sandbox_otel_args args PROJ-1
check "a requested signal gets an upper-case exporter flag (metrics)" has OTEL_METRICS_EXPORTER=otlp
check "a requested signal gets an upper-case exporter flag (logs)" has OTEL_LOGS_EXPORTER=otlp
check "signals that were not requested get no flag" eval '! has OTEL_TRACES_EXPORTER=otlp'

# What an allowlisted sandbox's proxy forwards to.
declare -a hosts
unset ANTHROPIC_BASE_URL
CHALK_EGRESS_ALLOW=""
sandbox_egress_hosts hosts
check "an allowlisted sandbox reaches the API and the token host, and nothing else" \
  test "${hosts[*]}" = "api.anthropic.com platform.claude.com"
CHALK_EGRESS_ALLOW="registry.npmjs.org .pythonhosted.org"
sandbox_egress_hosts hosts
check "CHALK_EGRESS_ALLOW adds its hosts" \
  test "${hosts[*]}" = "api.anthropic.com platform.claude.com registry.npmjs.org .pythonhosted.org"
ANTHROPIC_BASE_URL="https://user:secret@gateway.example.com:8443/v1/anthropic"
CHALK_EGRESS_ALLOW=""
sandbox_egress_hosts hosts
check "a gateway in ANTHROPIC_BASE_URL takes the API's place, as host and port without credentials or path" \
  test "${hosts[0]}" = "gateway.example.com:8443"
unset ANTHROPIC_BASE_URL

CHALK_EGRESS=open
declare -a flags=(stale)
sandbox_egress_start chalk-sandbox-x flags
check "with CHALK_EGRESS=open no proxy is started and the sandbox gets no network flags" test "${#flags[@]}" -eq 0
