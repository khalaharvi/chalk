#!/usr/bin/env bash
# lib/sandbox.sh: container names and OpenTelemetry flags.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime sandbox

repo_name() { echo "my repo/x"; }

check "sandbox names replace characters docker rejects" \
  test "$(sandbox_name PROJ-1)" = "chalk-sandbox-my-repo-x-PROJ-1"

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
