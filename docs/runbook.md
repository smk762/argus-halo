# Deploy runbook

Operational guide for standing up, verifying, seeding, and tearing down the
argus-halo demo. For *why* the infrastructure is shaped this way, see the
[README](../README.md); this document is the *how*.

State and runs live in HCP Terraform (org `dragonhound_argus`, workspace
`argus-halo`, CLI-driven, remote execution). You trigger runs from your machine
or CI; the plan/apply itself executes on HCP's runners using the workspace
variables.

---

## 0. Prerequisites

**Tools** (local):

- `terraform` >= 1.9 (repo is pinned/tested on 1.15.8)
- `git`, `curl`, an SSH client
- For `make tape` (§5 only): `pg_dump`, `jq`, `tar`, `zstd`, and Docker — the
  script runs the MinIO client from its image so there's no `mc` to install
- Optional: `tofu` — the config validates on OpenTofu too

**Accounts & tokens:**

| What | Where | Used as |
|---|---|---|
| HCP Terraform login | `terraform login` | CLI → HCP auth (`~/.terraform.d/credentials.tfrc.json`) |
| Hetzner API token (Read & Write) | Console → Security → API tokens | `hcloud_token` |
| Cloudflare API token | Zone:DNS:Edit + Zone Settings:Edit + Workers R2 Storage:Edit on dragonhound.dev | `cloudflare_api_token` |
| Cloudflare account ID | Dashboard sidebar | `cloudflare_account_id` |
| Cloudflare zone ID | dragonhound.dev → Overview → API | `cloudflare_zone_id` |
| SSH public key | your keypair (`ssh-keygen -t ed25519`) | `ssh_public_key` |
| Your source IP | `curl -s ifconfig.me` then append `/32` | `admin_ip` |
| Captioning API key | [Cerebras Cloud](https://cloud.cerebras.ai/) → API keys | `lens_caption_api_key` |

---

## 1. One-time setup

Already done for the existing workspace; repeat only when bootstrapping a fresh
environment.

```bash
terraform login          # paste the token from app.terraform.io
terraform init           # creates/attaches the argus-halo workspace
```

Then in the HCP UI, workspace `argus-halo` → **Variables**, add the inputs above
as **Terraform variables**. Mark `hcloud_token`, `cloudflare_api_token` and
`lens_caption_api_key` **Sensitive**. Confirm **Settings → General → Execution
Mode = Remote**.

Everything else (`server_type`, `location`, `domain`, `image`, `network_zone`,
and the `lens_caption_*` endpoint/model) has a working default; override only if
you need to. `lens_caption_api_key` has no default — without it lens returns
`401` on every caption (see README > Environment).

---

## 2. Pre-deploy checklist

Do not `apply` until all of these are true. Several items that used to live here
are now enforced by code and need no human:

- `server_type` — `plan` checks it against live Hetzner stock and names the
  working alternatives (`preflight.tf`).
- **Curator containment** — shipped in argus-curator v0.2.0; the demo pins v0.2.1
  and verified against that tag (#19, re-probed from 0.2.0 and byte-identical on
  all six checks): scan/folders/thumb/upload resolve under
  `ARGUS_CURATOR_SCAN_ROOT`, `mode=move` is `403`, and `/export` — governed by the
  *separate* `ARGUS_CURATOR_EXPORT_ROOT`, left **empty** here — refuses outright.
  argus-halo#1 is closed. Re-verify when the curator pin moves: `/api/curator/*`
  is a passthrough, so this is the public boundary (README > Security).
- **Cloudflare SSL mode** — pinned to Full (strict) by `cloudflare_zone_setting`
  in `dns.tf`. Note this is a *zone-wide* setting: it applies to every hostname on
  dragonhound.dev, not just this demo's.
- **No live GPU work is reachable** — `POST /api/proof/run/stream` and
  `POST /api/forge/run` both return `403` on the pinned images, verified through
  the proxy. proof needs `ARGUS_PROOF_READ_ONLY=1` (set in `.env`); forge refuses
  by default and would need `ARGUS_FORGE_READONLY=0` to enable, which we never set.
- **Every image tag is pullable** — `scripts/check-cloud-init.sh` (CI, every PR)
  asks each registry for every pinned manifest in both rendered compose files;
  a 404 fails the build. All services are pinned — `frontend` was the last
  ([#2](https://github.com/smk762/argus-halo/issues/2)), which closed the old
  deploy gate. The failure mode the check prevents is total: `docker compose
  up -d` fails as a unit on an unpullable image, so it does not degrade to one
  broken service — **nothing on the demo host starts**, Caddy never binds
  :80/:443, and Cloudflare serves 521/522 rather than a 502.

What's left:

- [ ] **`tape_dump_url` is fresh** if you are seeding (§5). Any apply that changes
      cloud-init or a `random_password` recreates the host(s), and core re-runs
      the restore on first boot against whatever URL is in the workspace. R2
      presigns expire after 7 days.
- [ ] Workspace variables are set with real values (Execution Mode = Remote),
      including `lens_caption_api_key` as **Sensitive** (a Cerebras key). Without
      it lens returns `401` on every caption.
- [ ] The Cloudflare token carries **Zone Settings:Edit** as well as DNS and R2 —
      the SSL-mode resource needs it, and a token minted before that resource
      existed won't have it.
- [ ] `terraform plan` output has been reviewed and matches expectations.

**Public exposure — keep the crowd on `demo` mode.** The compose sets
`ARGUS_CURATOR_UI_MODE=demo` on the frontend (also studio's default): it serves a
bundled sample and makes **no** live calls to lens/curator, so the metered
captioning key is untouched. Only `live` mode drives real scans/captions, which
(a) meters against the Cerebras key and (b) drives real scans — reserve it for
your own walkthroughs or a tiny curated set until replay lands
([argus-lens#45](https://github.com/smk762/argus-lens/issues/45)).

**The UI mode does not control reachability.** Caddy routes `/api/lens/*` and
`/api/curator/*` to the backends regardless of how studio was built; `demo` mode
only means the *bundled frontend* doesn't call them. Anyone with curl reaches them
either way, so the real controls are the ones in the config: a Cloudflare
rate-limit rule (`waf.tf`) caps `/api/lens/caption`, `/api/curator/scan` and
`/api/curator/upload` at 15 req/min per IP, Caddy caps request bodies at 32 MB,
curator confines paths to `ARGUS_CURATOR_SCAN_ROOT`, and an empty
`ARGUS_CURATOR_EXPORT_ROOT` makes `/export` refuse. `folders` and `thumb` are
deliberately uncapped — a folder view fires thumb once per tile and would trip the
limit on its own. Note the namespace is a passthrough, so a service's *whole* API
is reachable under its prefix — see README > Security. `demo`/`live` is runtime
config on the frontend service since studio 0.1.0 (argus-studio#56) — see
README > Environment.

---

## 3. Deploy

```bash
terraform init          # if not already initialized this session
terraform plan          # review: runs remotely in HCP
terraform apply         # type 'yes' at the prompt
```

Expected resource graph on a clean apply (14 resources):

The demo host now runs seven containers — `caddy`, `frontend`, `lens`, `curator`,
`quarry`, `forge`, `proof` — plus `node-exporter`. Core is unchanged.

- `hcloud_ssh_key.admin`
- `hcloud_network.argus` + `hcloud_network_subnet.argus`
- `random_password.postgres`, `random_password.minio`, `random_password.grafana`
- `module.core`: `hcloud_server.core` + `hcloud_firewall.core`
- `module.demo`: `hcloud_server.demo` + `hcloud_firewall.demo`
- `cloudflare_dns_record.demo`, `cloudflare_zone_setting.ssl`,
  `cloudflare_r2_bucket.tape`, `cloudflare_ruleset.demo_ratelimit`

Grab the outputs:

```bash
terraform output           # demo_url, demo_ipv4, core_ipv4, core_private_ip, tape_bucket
terraform output -raw ssh_demo   # ssh root@<demo ip>
terraform output -raw ssh_core   # ssh root@<core ip>
```

cloud-init runs on first boot: installs Docker, writes `/opt/argus/compose.yaml`,
and brings the stack up. Allow a few minutes after `apply` returns.

---

## 4. Post-deploy verification

**Cloud-init finished (both hosts):**

```bash
ssh root@$(terraform output -raw demo_ipv4) 'cloud-init status --wait; docker compose -f /opt/argus/compose.yaml ps'
ssh root@$(terraform output -raw core_ipv4) 'cloud-init status --wait; docker compose -f /opt/argus/compose.yaml ps'
```

All containers should be `running`/`healthy` (postgres has a healthcheck).

**Public entrypoint serves over TLS:**

```bash
curl -fsSI "$(terraform output -raw demo_url)" | head -n 1     # expect 200/3xx
```

**The stores are NOT reachable from the internet** (this is the whole point of
the split — expect these to hang/refuse):

```bash
DEMO=$(terraform output -raw demo_ipv4)
for p in 5432 6333 9000; do nc -vz -w3 "$DEMO" "$p" 2>&1; done   # all should fail
```

**The stores ARE reachable across the private network** (run from demo):

```bash
ssh root@$(terraform output -raw demo_ipv4) \
  'for p in 5432 6333 9000; do nc -vz -w3 10.0.1.10 $p; done'    # all should connect
```

**SSH is locked to your IP** — from any other address, port 22 should time out.

**Monitoring is up.** Grafana answers from your admin IP; Prometheus targets are healthy:

```bash
curl -fsSI "$(terraform output -raw grafana_url)" | head -n 1        # expect 200/302
terraform output -raw grafana_password                              # login: admin / <this>

# Prometheus stays private — tunnel, then check every target is "up":
CORE=$(terraform output -raw core_ipv4)
ssh -fN -L 9090:10.0.1.10:9090 root@"$CORE"
curl -fsS localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
```

Expect the `node` (core + demo), `postgres`, `qdrant`, and `minio` jobs all `up`.

---

## 5. Seed the tape (optional)

Skip for an empty-store demo. To seed from a recorded pipeline run:

1. With the pipeline's local stores up, build and upload in one step:

   ```bash
   R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... make tape
   ```

   That dumps Postgres, snapshots every Qdrant collection, mirrors the MinIO
   bucket, packs `tape.tar.zst`, uploads it to the bucket from `terraform output
   -raw tape_bucket`, and prints a presigned URL. Point it at non-default local
   stores with `SRC_*`, or load a cortex `.env` with `ENV_FILE=...` — a bare
   `source` won't survive `make` (see [scripts/build-tape.sh](../scripts/build-tape.sh)).
   Omit the `R2_*` vars to build the archive only and upload by hand.
2. Set that presigned URL as the `tape_dump_url` workspace variable.
3. Re-apply (which recreates core and restores on first boot), or re-run the
   restore in place. The URL is baked into the on-host script at plan time, so
   pass a fresh one explicitly rather than expecting the script to pick up the
   workspace variable:

```bash
ssh root@$(terraform output -raw core_ipv4) \
  "TAPE_DUMP_URL='<the presigned url>' /opt/argus/restore-tape.sh"
```

`restore-tape.sh` seeds all three stores — Postgres, then Qdrant (uploads each
`qdrant/*.snapshot`, which recreates the collection), then MinIO (mirrors
`blobs/` into the bucket). It's idempotent: it no-ops once
`/opt/argus/data/.tape-restored` exists. Delete that marker to force a re-seed.

The **demo host** has its own counterpart, `restore-seed.sh`: it reads the same
tape's `demo/` subtree, drops each tier onto its bind-mount source
(`/srv/argus/<tier>`), and makes the trees world-readable (`a+rX` — quarry
0.2.3+ reads its `:ro` pool as uid 10001). It runs before `compose up` on first
boot and no-ops once `/srv/argus/.seed-restored` exists; to refresh the demo
tiers in place, delete that marker and re-run with a fresh URL:

```bash
ssh root@$(terraform output -raw demo_ipv4) \
  "rm -f /srv/argus/.seed-restored && TAPE_DUMP_URL='<the presigned url>' /opt/argus/restore-seed.sh"
```

Re-seed through the script rather than untarring by hand: a hand-copied pool
keeps whatever restrictive modes the tape carries, and quarry then 500s on
every read through its read-only mount.

> **The presigned URL expires — R2 caps them at 7 days.** Core reads
> `tape_dump_url` on *every* first boot, so a rebuilt core with a stale URL comes
> up with empty stores. The restore distinguishes a stale URL (HTTP 401/403) from
> a transport failure and says which in `/var/log/cloud-init-output.log`, but it
> fails inside cloud-init where nobody is watching. **Before any planned core
> replace** — a `random_password` rotation, a cloud-init edit, a `server_type`
> change — re-run `make tape` and refresh the variable. For a demo you rebuild
> often, publish the tape at a stable address instead: it's a build artifact, not
> a secret, and nothing about it needs to be presigned.

**Qdrant minors are checked on both sides.** A snapshot only restores into a
matching minor, so `make tape` refuses to build against a local Qdrant whose minor
differs from the image core restores on — it reads that minor straight from
`modules/core/cloud-init.yaml.tftpl`, so there's nothing to keep in sync by hand.
The builder also records `qdrant_version` in `MANIFEST`, and `restore-tape.sh`
re-checks it against the Qdrant it actually booted, *before* touching Postgres —
so a pin moved on only one side is caught at restore time with the stores still
untouched, rather than half-seeded. `TAPE_QDRANT_MINOR` overrides the build-side
check only; the restore-side one always runs.

---

## 6. Teardown

**Tear down just the public tier**, leaving the stores (and their data) up:

```bash
terraform destroy -target=module.demo
```

**Full teardown** — destroys both hosts, network, DNS record:

```bash
terraform destroy
```

This **will refuse** while `cloudflare_r2_bucket.tape` carries `prevent_destroy`,
which is deliberate: the bucket holds the one artifact that costs GPU hours to
regenerate, and it should not go away as a side effect of tearing down two
disposable VMs. Two options:

```bash
# Keep the tape (usual case) -- destroy everything else.
# -exclude is the inverse of -target, so this needs no list to keep in step with
# the resource graph; it destroys all 13 other resources.
terraform destroy -exclude=cloudflare_r2_bucket.tape

# Really delete the bucket -- empty it first (R2, like S3, refuses to delete a
# bucket that still holds objects), then remove the lifecycle block in dns.tf:
mc rm "r2/$(terraform output -raw tape_bucket)/tape.tar.zst"
terraform destroy
```

(`-exclude` needs Terraform >= 1.12; on older versions, spell out `-target` for
every resource in the §3 list except the bucket.)

Data on the hosts is **not** backed by a volume by design — durability lives in
the R2 tape, not the block device. A full destroy is data loss for anything not
in the tape.

---

## 7. Rotate secrets

`postgres`, `minio` and `grafana` credentials are generated by `random_password`
and stored in HCP state. To rotate:

```bash
terraform apply -replace=random_password.postgres
terraform apply -replace=random_password.minio
terraform apply -replace=random_password.grafana   # then: terraform output -raw grafana_password
```

This regenerates the secret and re-templates cloud-init; the affected host(s)
**will be recreated** (`user_data` forces replacement). Which hosts:

| Rotating | Rebuilds | Why |
|---|---|---|
| `random_password.postgres` | **core and demo** | demo's `.env` carries `CORTEX_PG_URL`, which embeds the password |
| `random_password.minio` | **core and demo** | demo's `.env` carries `CORTEX_S3_SECRET_KEY` |
| `random_password.grafana` | core only | Grafana runs on core alone |

So a postgres/minio rotation is a **public outage**, not just a core rebuild: the
demo host gets a new IPv4 (the DNS record updates), and its `caddy_data` volume
goes with it, so Caddy re-issues its certificate on the way back up. Core also
re-restores the tape — confirm `tape_dump_url` hasn't expired first (§5), or you
rotate a password and lose the seed data in the same apply.

For the Hetzner/Cloudflare API tokens, rotate at the provider and update the
workspace variable.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `plan`: organization not found | org name typo in `versions.tf` | match `dragonhound_argus`, re-init |
| `plan`: `server_type … cannot be built in location …` | plan retired, or out of stock in that location | the error lists what IS available there — set `server_type` (or `location`) to one of them |
| Demo returns 502 | a backend container is down but Caddy is up | `docker compose ps`/`logs` on demo |
| Demo returns 521/522, nothing listening | one image failed to pull, so `compose up` aborted the whole stack | `docker compose ps -a` on demo will be empty; confirm every image in the compose is pullable — the six GHCR pins (#2) **and** the Docker Hub ones (`caddy:2`, `node-exporter`), whose pull failure aborts identically. `check-cloud-init.sh` asserts all of them per PR |
| `413` on an upload | body exceeds the 32 MB cap in the demo Caddyfile | raise `max_size` in the `/api/curator/*` block, or split the upload |
| `apply`: Cloudflare 403 on the zone setting | token predates `cloudflare_zone_setting`, lacks Zone Settings:Edit | add the permission to the token, update the workspace variable |
| Redirect loop / TLS handshake errors | zone drifted off Full (strict) | re-`apply` — `cloudflare_zone_setting.ssl` puts it back |
| Can reach a store port publicly | firewall/binding regression | check compose binds `10.0.1.x:PORT`, not `0.0.0.0` |
| Restore didn't run | marker present or no URL | remove `.tape-restored`, set `tape_dump_url` |
| Core rebuilt with empty stores | presigned `tape_dump_url` expired (R2 max 7d) | `make tape`, then `TAPE_DUMP_URL='<new url>' /opt/argus/restore-tape.sh` on core — and set the workspace variable too, or the next rebuild repeats it. See §5 |
| Restore says "transport failure", not expiry | network/DNS/TLS, not the URL | retry; the script already retries 3× before giving up |
| Restore refuses on a Qdrant version mismatch | tape built against a different Qdrant minor than core runs | rebuild the tape against core's Qdrant, or move the pin in `modules/core/cloud-init.yaml.tftpl` (build-tape.sh reads its minor from there) |
| `make tape` aborts on a version mismatch | local Qdrant minor ≠ the pinned restore minor | match your local Qdrant; snapshots don't cross minors |
| A backend call 404s from the browser | frontend called the bare path instead of the `/api/<service>/…` namespace | fix the frontend's base URL (argus-studio#56 made it runtime-configurable); the proxy no longer needs a per-endpoint route |
| A whole service 404s | its `handle_path /api/<svc>/*` block is missing | add the block in the demo cloud-init, and the service to compose — see #8. Note this replaces the demo host |
| SSH/Grafana time out from your machine | your ISP rotated your IP; `admin_ip` no longer matches | see *Recover access after an IP change* below |

Inspect a host's first-boot log:

```bash
ssh root@<ip> 'cat /var/log/cloud-init-output.log'
```

### Recover access after an IP change

`admin_ip` gates SSH (both hosts) and Grafana (core) at the Hetzner firewall.
If your ISP hands you a new address you'll simply time out. You are **not**
locked out of fixing it — `apply` drives the Hetzner API from HCP's runners, not
over SSH, so your current IP is irrelevant to running it.

1. Get the new address: `curl -s ifconfig.me`.
2. HCP UI → workspace `argus-halo` → **Variables** → set `admin_ip` to
   `<new-ip>/32`.
3. **Start a new run** (or `terraform apply` locally).

This is an **in-place firewall update** — `source_ips` only. `admin_ip` is not
part of cloud-init, so nothing is rebuilt and there is no data loss; access
returns within seconds. Only the two `hcloud_firewall` resources should show as
changed in the plan.
