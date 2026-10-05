.PHONY: check lint lint-sandbox test unit test-db docs demo

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

# Serves the docs site at http://127.0.0.1:8000. Needs the pinned tools:
# python3 -m venv .venv && .venv/bin/pip install -r docs/requirements.txt
MKDOCS ?= mkdocs
docs:
	$(MKDOCS) serve

# Records the demo on the docs site and in the README against the test
# fakes, then draws it (docs/assets/demo.*).
demo:
	scripts/demo.sh
	python3 scripts/render-demo.py
