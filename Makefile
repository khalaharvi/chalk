.PHONY: check lint test unit test-db

check: lint test

lint:
	shellcheck -x -s bash bin/chalk lib/core/*.sh lib/*.sh share/sandbox/scripts/*.sh \
	  scripts/*.sh tests/e2e.sh tests/unit/*.sh tests/fakes/*

test: unit
	bash tests/e2e.sh

unit:
	@for test in tests/unit/*_test.sh; do bash "$$test" || exit 1; done

# Same test, but SQL runs against a real Postgres (with pg_trgm) at
# FAKE_PG_URL, e.g. postgresql://chalk:chalk@127.0.0.1:5432/chalk
test-db:
	@test -n "$$FAKE_PG_URL" || { echo "set FAKE_PG_URL"; exit 1; }
	bash tests/e2e.sh
