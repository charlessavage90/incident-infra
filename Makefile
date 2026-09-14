.PHONY: fmt fmt-check validate lint test check dormant active

fmt:
	@bash scripts/check.sh fmt

fmt-check:
	@bash scripts/check.sh fmt-check

validate:
	@bash scripts/check.sh validate

lint:
	@bash scripts/check.sh lint

test:
	@bash scripts/check.sh test

check:
	@bash scripts/check.sh check

dormant:
	@bash scripts/check.sh dormant

active:
	@bash scripts/check.sh active
