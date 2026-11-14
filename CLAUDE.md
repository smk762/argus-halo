# CLAUDE.md — argus-halo

Guidance for AI agents working in this repo. Human-facing usage lives in [README.md](README.md) (the *why*) and [docs/runbook.md](docs/runbook.md) (the *how*); this file is the orientation an agent needs to change things safely.

## What this is

**Infrastructure for the public Argus demo** at `argus.dragonhound.dev`: Terraform (state + remote execution in HCP Terraform, org `dragonhound_argus`, workspace `argus-halo`) for two Hetzner CX23 hosts behind Cloudflare. There is no application code here — the suite services run from pinned GHCR images.

- **demo** (public, disposable): Caddy + the studio frontend + lens, curator, quarry, forge, proof, all **read-only / replay** (no GPU).
- **core** (private net `10.0.1.0/24`, no public data ports): postgres, qdrant, minio, prometheus, grafana (admin-IP only). Restored on first boot from the **tape** (`tape.tar.zst` on R2).

It consumes argus-studio only as the published `frontend` image; studio's root `compose.yaml` is a dev stack and is deliberately *not* reused (README > Decisions).

## Layout

- Root `*.tf` — `main.tf` (network, firewalls, the two modules), `dns.tf` (records, zone SSL mode, the R2 bucket with `prevent_destroy`), `waf.tf` (the single free-plan rate-limit rule), `preflight.tf` (checks `server_type` against live Hetzner stock at plan time), `variables.tf` / `outputs.tf` / `versions.tf` / `providers.tf`.
- `modules/{core,demo}/` — one `hcloud_server` each; `cloud-init.yaml.tftpl` renders **only config** (`/opt/argus/.env`, `deploy.env`) plus the `argus-update` fetcher.
- `stack/{core,demo}/` — the service definitions the hosts fetch at boot and on `argus-update`: `compose.yaml` (**image pins live here**), `apply.sh`, the demo `Caddyfile`, `prometheus.yml.tpl`, restore scripts.
- `scripts/check-cloud-init.sh` — the checks `terraform validate` can't do; `scripts/build-tape.sh` — `make tape`.

## Commands

```bash
make validate          # check-cloud-init + fmt -check + init -backend=false + validate (= CI)
make check-cloud-init  # render templates, YAML/bash/Caddyfile checks, route/waf/env agreement, pin pullability
make fmt               # terraform fmt -recursive
make tape              # build (and with R2_* set, upload) tape.tar.zst — see scripts/build-tape.sh
terraform plan         # remote, in HCP (needs `terraform login`)
```

`terraform` is not necessarily on the dev host's PATH; `check-cloud-init.sh` also needs `python3` + `pyyaml`, and uses `caddy` or its Docker image.

## Conventions & gotchas

- **Merging to `main` is the deploy channel.** Hosts track `stack_ref` (default `main`); `ssh root@<host> /opt/argus/argus-update` converges a host on whatever is merged. A pin bump or Caddy route edit is a PR to `stack/`, not a Terraform change (runbook §4b).
- **Don't put changeable things in `user_data`.** `hcloud_server.user_data` is ForceNew: editing the cloud-init templates (secrets, `.env`/`deploy.env` values, `stack_ref`, the bootstrap) **replaces the host**, losing `caddy_data`/the origin cert or core's volumes (#18). Structural files belong in `stack/`.
- **Three lists must agree** and only `check-cloud-init.sh` enforces it: the Caddy `/api/<service>/*` namespaces, `waf.tf`'s rate-limit expression, and the frontend's `ARGUS_*_URL` values in `stack/demo/compose.yaml`. Adding a service touches all three, plus `ARGUS_*` for the frontend goes in its inline `environment:` block — **never** `.env`, which holds the caption key and store credentials.
- **Every `${VAR}` a stack compose file interpolates must be defined** by the rendered `.env` + `deploy.env`; an undefined one becomes an empty string on the host silently. New keys: Terraform variable → the tier's `templatefile(...)` → the template's `.env` block.
- **`/api/<service>/*` is a passthrough, not a whitelist.** Each service's own gating is the public boundary: proof `ARGUS_PROOF_READ_ONLY=1`, forge read-only by default, curator scan-root containment + empty export root + no `move`. When a suite pin moves, re-run the probes in README > Security / runbook §2 — a relaxed release widens the public surface with no diff here.
- **Pin, don't float.** Suite images are exact versions; the checker asks the registry that each tag exists, because one unpullable pin aborts `compose up` for the whole tier. Qdrant's pin also fixes the tape's snapshot minor version (`make tape` and `restore-tape.sh` both check it).
- **The tape URL is presigned and expires in ≤7 days**; a core rebuild with a stale `tape_dump_url` boots with empty stores. Refresh it before any planned core replace.
- Secrets come from `random_password` or Sensitive HCP workspace variables and land in remote state; `*.tfvars` is gitignored — never commit one, never print a generated secret.

## CI / release

`.github/workflows/terraform.yml`: `fmt -check`, `init -backend=false`, `validate`, and `check-cloud-init.sh` on every push/PR; remote `plan` on PRs once a `TF_API_TOKEN` secret is set (skipped otherwise). No releases — `main` is what the hosts run.
