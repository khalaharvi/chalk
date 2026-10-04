.PHONY: check lint test test-db

check: lint test

lint:
	shellcheck -s bash bin/chalk lib/core/*.sh lib/*.sh share/sandbox/scripts/*.sh \
	  scripts/*.sh tests/e2e.sh tests/fakes/*

test:
	bash tests/e2e.sh

# Same test, but SQL runs against a real Postgres (with pg_trgm) at
# FAKE_PG_URL, e.g. postgresql://chalk:chalk@127.0.0.1:5432/chalk
test-db:
	@test -n "$$FAKE_PG_URL" || { echo "set FAKE_PG_URL"; exit 1; }
	bash tests/e2e.sh
