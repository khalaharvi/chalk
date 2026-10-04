.PHONY: check lint lint-sandbox test unit test-db

check: lint test

lint:
	shellcheck -x -s bash bin/chalk lib/core/*.sh lib/*.sh share/sandbox/scripts/*.sh \
	  scripts/*.sh tests/e2e.sh tests/unit/*.sh tests/fakes/*
	scripts/lint-conventions.sh

# Parses the sandbox scripts with the sandbox's oldest supported bash (5.2).
# CI runs this on ubuntu-latest, whose /usr/bin/bash is 5.2.
SANDBOX_BASH ?= /usr/bin/bash
lint-sandbox:
	scripts/check-sandbox-syntax.sh $(SANDBOX_BASH)

test: unit
	bash tests/e2e.sh

unit:
	@for test in tests/unit/*_test.sh; do bash "$$test" || exit 1; done

# Same test, but SQL runs against a real Postgres (with pg_trgm) at
# FAKE_PG_URL, e.g. postgresql://chalk:chalk@127.0.0.1:5432/chalk
test-db:
	@test -n "$$FAKE_PG_URL" || { echo "set FAKE_PG_URL"; exit 1; }
	bash tests/e2e.sh
