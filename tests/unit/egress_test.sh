#!/usr/bin/env bash
# share/sandbox/egress-proxy.js: the real proxy, run with this machine's
# node against a server on localhost. Skipped where there is no node; the
# sandbox image always has one.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"

if ! command -v node >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "ok   egress proxy: skipped, needs node and curl"
  exit 0
fi

# free_port: prints a TCP port nothing listens on.
free_port() {
  node -e 'const s = require("net").createServer().listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); })'
}
target_port="$(free_port)"
proxy_port="$(free_port)"

node -e 'require("http").createServer((q, s) => s.end("hello from the target\n")).listen(Number(process.argv[1]), "127.0.0.1")' \
  "$target_port" &
target=$!
CHALK_EGRESS_HOSTS="localhost:$target_port .allowed.test other.test" CHALK_EGRESS_PORT="$proxy_port" \
  node "$CHALK_HOME/share/sandbox/egress-proxy.js" > "$tmp/proxy.log" 2>&1 &
proxy=$!
trap 'kill "$target" "$proxy" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in {1..50}; do
  if grep -q listening "$tmp/proxy.log" && curl -s -o /dev/null "http://127.0.0.1:$target_port/"; then break; fi
  sleep 0.1
done

# through ARGS...: curl by way of the proxy, ignoring any proxy this
# machine's own environment names.
through() {
  env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u ALL_PROXY -u NO_PROXY -u no_proxy \
    curl -s --max-time 10 --proxy "http://127.0.0.1:$proxy_port" "$@"
}

check "an allowed host and port is forwarded" \
  test "$(through "http://localhost:$target_port/")" = "hello from the target"
check "an allowed host and port is tunnelled with CONNECT" \
  test "$(through --proxytunnel "http://localhost:$target_port/")" = "hello from the target"
check "a host that is not on the list is refused with 403" \
  test "$(through -o /dev/null -w '%{http_code}' "http://evil.example.com/")" = 403
check "the refusal says what to change" \
  grep -q 'evil.example.com is not on this sandbox.s allowlist.*CHALK_EGRESS_ALLOW' <<<"$(through "http://evil.example.com/")"
check "an HTTPS tunnel to a host that is not on the list is refused" \
  test "$(through -o /dev/null -w '%{http_connect}' "https://evil.example.com/" || true)" = 403
check "an allowed host on another port is refused" \
  test "$(through -o /dev/null -w '%{http_code}' "http://localhost:1/")" = 403
check "a rule without a port allows 80 and 443 only" \
  test "$(through -o /dev/null -w '%{http_code}' "http://other.test:8080/")" = 403
check "an address is not allowed because a name for it is" \
  test "$(through -o /dev/null -w '%{http_code}' "http://127.0.0.1:$target_port/")" = 403
check "a name that only ends like an allowed one is refused" \
  test "$(through -o /dev/null -w '%{http_code}' "http://notallowed.test/")" = 403
# These two are allowed, so the proxy tries them and fails to resolve the
# name: 502, not 403.
check "a leading-dot rule allows the domain itself" \
  test "$(through -o /dev/null -w '%{http_code}' "http://allowed.test/")" = 502
check "a leading-dot rule allows names under the domain, whatever their case" \
  test "$(through -o /dev/null -w '%{http_code}' "http://Deep.Sub.ALLOWED.test/")" = 502
check "a request that is not a proxy request gets no page" \
  test "$(env -u HTTP_PROXY -u http_proxy -u NO_PROXY -u no_proxy curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/")" = 400
check "every decision is logged as allow or deny with the destination" \
  sh -c "grep -q ' allow localhost:$target_port\$' '$tmp/proxy.log' && grep -q ' deny evil.example.com:443\$' '$tmp/proxy.log' &&
    grep -q ' deny evil.example.com:80\$' '$tmp/proxy.log'"
