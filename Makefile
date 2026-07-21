# argus-halo -- see README and docs/runbook.md.
#
# Terraform is driven directly (init/plan/apply); the only thing worth a target
# is building the tape, which has several moving parts. See scripts/build-tape.sh
# for configuration (source stores, R2 upload) and README > The tape.

.PHONY: tape fmt validate

# Build tape.tar.zst from the local pipeline stores (and upload to R2 if the
# R2_* env is set). Override sources via SRC_* / CORTEX_* -- see the script header.
tape:
	./scripts/build-tape.sh

# Convenience wrappers around the Terraform CI checks, so `make fmt` / `make
# validate` match what .github/workflows/terraform.yml runs.
fmt:
	terraform fmt -recursive

validate:
	terraform fmt -check -recursive
	terraform validate
