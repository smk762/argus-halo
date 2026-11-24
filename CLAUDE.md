# CLAUDE.md — argus-halo

Guidance for AI agents working in this repo. Human-facing usage lives in [README.md](README.md) (the *why*) and [docs/runbook.md](docs/runbook.md) (the *how*); this file is the orientation an agent needs to change things safely.

## What this is

**Infrastructure for the public Argus demo** (not currently deployed; hostname is the required `domain` variable): Terraform (state + remote execution in HCP Terraform, org `dragonhound_argus`, workspace `argus-halo`) for two Hetzner CX23 hosts behind Cloudflare. There is no application code here — the suite services run from pinned GHCR images. `web/` is the static project page at `halo.dragonhound.dev`.

- **demo** (public, disposable): Caddy + the studio frontend + lens, curator, quarry, forge, proof, atlas, all **read-only / replay** (no GPU).
- **core** (private net `10.0.1.0/24`, no public data ports): postgres, qdrant, minio, prometheus, grafana (admin-IP only). Restored on first boot from the **tape** (`tape.tar.zst` on R2).

It consumes argus-studio only as the published `frontend` image; studio's root `compose.yaml` is a dev stack and is deliberately *not* reused (docs/decisions.md).

## Argus suite
<!-- argus-suite: keep this block; argus-ci checks for it -->
This repo is part of the Argus suite. The suite map below lists every sibling and what it owns; check it before
building something a sibling may already do. **On every release, update this repo's row and capabilities in
argus-cortex's SUITE.md** (a PR to argus-cortex in the same release).

@../argus-core/SUITE.md

Not checked out? Read https://github.com/smk762/argus-cortex/blob/dev/SUITE.md

## Must never happen

Each rule names what fails when it is broken. **UNENFORCED** means only this file says so: add a check rather than more prose. `check` is `scripts/check-cloud-init.sh`, `smoke` is `scripts/smoke-demo.py`, `tftest` is `tests/security.tftest.hcl`; all run in CI.

| Never | Enforced by |
|---|---|
| Expose a data port, or SSH/Grafana beyond `admin_ip` | `tftest`; `check` (core publishes on `${PRIVATE_IP}`, demo only through Caddy) |
| Open the origin to the internet unproxied, or weaken zone TLS | `tftest` |
| Relax a service's own gating by moving its pin (proof read-only, forge no training, curator containment, lens read-only, atlas no bakes) | `smoke`; `check` asserts the declared switches. Delete/purge routes are never called: `check` asserts their edge refusal |
| A GPU image (`-train`, `-score`, `-gpu`) or a floating tag | `check` |
| Drop the `/admin`, `@offlimits` or `@delete` refusals, or place them after a route | `check`; `smoke` for `/admin` and `@offlimits` |
| Let the Caddy namespaces, `waf.tf` and the frontend's `ARGUS_*_URL` disagree | `check`; `smoke` reads the rendered page |
| Match a WAF path case-sensitively, or without its `/*` form | `check` |
| Give a service the whole `.env`, or anything but lens the caption key | `check`; `smoke` inspects the containers |
| Mount demo data writable | `check` |
| Interpolate a `${VAR}` the rendered env does not define | `check` |
| Restore a tape or seed over live data | `check` (marker guard); `SEED_FORCE=1` is the operator override |
| Put changeable things in `user_data` (ForceNew: an edit replaces the host and loses its volumes, #18) | Partial: `check` limits `write_files`. A value edit is **UNENFORCED**: #48 |
| Replace core with an expired `tape_dump_url` (presigned, 7 days at most) | **UNENFORCED**: #48 |
| Destroy the R2 tape bucket in passing | `prevent_destroy` in `dns.tf` |
| Commit tfvars or state | `check`, `.gitignore` |
| Print a generated secret | Terraform refuses a non-sensitive output of a sensitive value |
| A private address or server path in `README.md` or `docs/` | `check` |
| Use `halo.dragonhound.dev` as the stack's `domain` (it is the static page) | `tftest` |

## Commands

```bash
make validate          # check-cloud-init + fmt -check + init -backend=false + validate (= CI)
make check-cloud-init  # render templates, YAML/bash/Caddyfile checks, route/waf/env agreement, pin pullability
make test              # terraform test against mocked providers (tests/)
make smoke             # boot the demo tier in Docker and probe its refusals
make fmt               # terraform fmt -recursive
make tape              # build (and with R2_* set, upload) tape.tar.zst — see scripts/build-tape.sh
terraform plan         # remote, in HCP (needs `terraform login`)
```

`terraform` is not necessarily on the dev host's PATH; `check-cloud-init.sh` also needs `python3` + `pyyaml`, and uses `caddy` or its Docker image.

## Conventions & gotchas

- **Advancing `main` is the deploy channel.** Hosts track `stack_ref` (default `main`); `/opt/argus/argus-update` converges a host on it. A pin bump or route edit is a PR to `stack/` against `dev`, and reaches hosts once `main` is fast-forwarded (README > Branches, runbook §4b). Never open a PR against `main`.
- **Adding a service** touches the Caddyfile namespace, the frontend's `ARGUS_*_URL`, its own `environment:` list, the checker's required switches and the smoke test.
- **A new `.env` key** goes Terraform variable → the tier's `templatefile(...)` → the template's `.env` block → the service's `environment:`. A fixed setting belongs on the service alone.
- **`/api/<service>/*` is a passthrough, not a whitelist**, so each service's gating is the public boundary.
- **Qdrant's pin fixes the tape's snapshot minor version** (`make tape` and `restore-tape.sh` both check it).
- `preflight.tf` checks `server_type` against live stock at plan time, through `modules/stock` so tests can substitute the answer.

## CI / release

`.github/workflows/terraform.yml`: fmt, validate, `terraform test`, tflint, `check-cloud-init.sh` and the demo smoke test on every PR and on pushes to `dev`/`main`; remote `plan` on PRs once a `TF_API_TOKEN` secret is set (skipped otherwise). `pages.yml` deploys `web/` on pushes to `dev`. `.github/workflows/suite.yml`: the argus-ci suite-map check (the block above plus this repo's row in SUITE.md). No version tags — a release is `main` fast-forwarded to a `dev` commit that passed CI, and `main` is what the hosts run.
