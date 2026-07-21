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
- **Curator scan-root containment** — shipped in argus-curator v0.2.0, which the
  demo pins. `/scan/folder`, `/scan/folder/stream` and `/export` resolve under
  `ARGUS_CURATOR_SCAN_ROOT` server-side; argus-halo#1 is closed.
- **Cloudflare SSL mode** — pinned to Full (strict) by `cloudflare_zone_setting`
  in `dns.tf`.

What's left:

- [ ] **The frontend image exists.** `curator` and `lens` are pinned to released
      tags, but `frontend` is still `ghcr.io/smk762/argus-studio:latest` and that
      tag is **not published yet** ([#2](https://github.com/smk762/argus-halo/issues/2)).
      Until it is, the demo host boots into an image-pull error for that one
      service and the public entrypoint 502s. This is the deploy gate.
- [ ] Workspace variables are set with real values (Execution Mode = Remote),
      including `lens_caption_api_key` as **Sensitive** (a Cerebras key). Without
      it lens returns `401` on every caption.
- [ ] The Cloudflare token carries **Zone Settings:Edit** as well as DNS and R2 —
      the SSL-mode resource needs it, and a token minted before that resource
      existed won't have it.
- [ ] `terraform plan` output has been reviewed and matches expectations.

**Public exposure — keep the crowd on `demo` mode.** The published `argus-studio`
image should be built in `demo` UI mode (studio's default): the frontend serves a
bundled sample and makes **no** live calls to lens/curator, so the metered
captioning key is untouched. Only `live` mode drives real scans/captions, which
(a) meters against the Cerebras key and (b) exposes `/scan/*` publicly — reserve
it for your own walkthroughs or a tiny curated set until replay lands
([argus-lens#45](https://github.com/smk762/argus-lens/issues/45)). Either way a
Cloudflare rate-limit rule (`waf.tf`) caps `/caption/*` and `/scan/*` at 15
req/min per IP so a single client can't drain the key. `demo`/`live` is baked at
studio build time — see README > Environment.

---

## 3. Deploy

```bash
terraform init          # if not already initialized this session
terraform plan          # review: runs remotely in HCP
terraform apply         # type 'yes' at the prompt
```

Expected resource graph on a clean apply (13 resources):

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
3. Re-apply, or re-run the restore on core:

```bash
ssh root@$(terraform output -raw core_ipv4) '/opt/argus/restore-tape.sh'
```

`restore-tape.sh` seeds all three stores — Postgres, then Qdrant (uploads each
`qdrant/*.snapshot`, which recreates the collection), then MinIO (mirrors
`blobs/` into the bucket). It's idempotent: it no-ops once
`/opt/argus/data/.tape-restored` exists. Delete that marker to force a re-seed.

> **The presigned URL expires — R2 caps them at 7 days.** Core reads
> `tape_dump_url` on *every* first boot, so a rebuilt core with a stale URL comes
> up with empty stores. The restore says so explicitly in
> `/var/log/cloud-init-output.log`, but it fails inside cloud-init where nobody is
> watching. **Before any planned core replace** (including
> `-replace=random_password.postgres`, which recreates the host), re-run `make
> tape` and refresh the variable. For a demo you rebuild often, publish the tape
> at a stable address instead — it's a build artifact, not a secret.

`make tape` refuses to build against a local Qdrant whose *minor* version differs
from the pinned image core restores on: snapshots don't cross minors, so that
combination would pack and upload cleanly and then fail at first boot. Override
with `TAPE_QDRANT_MINOR` only if you've moved the pin on both sides.

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
terraform destroy -target=module.demo -target=module.core \
  -target=cloudflare_dns_record.demo -target=cloudflare_ruleset.demo_ratelimit

# Really delete the bucket -- remove the lifecycle block in dns.tf first, then:
terraform destroy
```

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
**will be recreated**. For `postgres`/`minio` that means core is rebuilt and
re-restores the tape — so confirm `tape_dump_url` hasn't expired first (§5), or
you rotate a password and lose the seed data in the same apply.

For the Hetzner/Cloudflare API tokens, rotate at the provider and update the
workspace variable.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `plan`: organization not found | org name typo in `versions.tf` | match `dragonhound_argus`, re-init |
| `plan`: `server_type … cannot be built in location …` | plan retired, or out of stock in that location | the error lists what IS available there — set `server_type` (or `location`) to one of them |
| Demo returns 502 | app container down or image missing (`argus-studio:latest` is unpublished — #2) | `docker compose ps`/`logs` on demo; confirm GHCR tags |
| `apply`: Cloudflare 403 on the zone setting | token predates `cloudflare_zone_setting`, lacks Zone Settings:Edit | add the permission to the token, update the workspace variable |
| Redirect loop / TLS handshake errors | zone drifted off Full (strict) | re-`apply` — `cloudflare_zone_setting.ssl` puts it back |
| Can reach a store port publicly | firewall/binding regression | check compose binds `10.0.1.x:PORT`, not `0.0.0.0` |
| Restore didn't run | marker present or no URL | remove `.tape-restored`, set `tape_dump_url` |
| Core rebuilt with empty stores | presigned `tape_dump_url` expired (R2 max 7d) | `make tape`, set the fresh URL, re-run `/opt/argus/restore-tape.sh` — see §5 |
| `make tape` aborts on a version mismatch | local Qdrant minor ≠ the pinned restore minor | match your local Qdrant; snapshots don't cross minors |
| A curator call 404s from the browser | endpoint not in the Caddy route list | add the prefix to the `@curator` matcher in the demo cloud-init |
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
