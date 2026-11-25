# argus-halo -- see README and docs/runbook.md.
#
# Terraform is driven directly (init/plan/apply); the only thing worth a target
# is building the tape, which has several moving parts. See scripts/build-tape.sh
# for configuration (source stores, R2 upload) and docs/tape.md.

.PHONY: tape fmt validate test smoke check-cloud-init

# Build tape.tar.zst from the local pipeline stores (and upload to R2 if the
# R2_* env is set). Override sources via SRC_* / CORTEX_* -- see the script header.
tape:
	./scripts/build-tape.sh

# Convenience wrappers around the Terraform CI checks, so `make fmt` / `make
# validate` match what .github/workflows/terraform.yml runs.
fmt:
	terraform fmt -recursive

validate: check-cloud-init
	terraform fmt -check -recursive
	terraform init -backend=false
	terraform validate

# Plan against mocked providers and assert the security properties.
test:
	terraform init -backend=false
	terraform test
	./tests/check_plan_test.sh

# Boot the demo tier locally from its real compose file and probe its refusals.
smoke:
	python3 scripts/smoke-demo.py

# `terraform validate` never expands templatefile(), so it sees none of the
# cloud-init YAML, the bash inside it, or the Caddyfile that routes the public
# entrypoint. This renders them and checks all three -- plus that the Caddy route
# list and waf.tf's rate-limit expression still agree.
check-cloud-init:
	./scripts/check-cloud-init.sh
