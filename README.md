# argus-halo

Infrastructure for the public [Argus](https://github.com/smk762?tab=repositories&q=argus) demo. Two Hetzner hosts, split public/private, provisioned by Terraform with state in HCP Terraform.

Part of the Argus suite (quarry → curator → lens → forge → proof, over [cortex](https://github.com/smk762/argus-cortex)). *Halation* — the bloom of light around a bright point on film, the halo the lens can't help but throw.

```
                    Cloudflare (proxy, TLS, DNS)
                              │
                    argus.dragonhound.dev
                              │
   ┌──────────────────────────▼──────────────────────────┐
   │  demo          public, disposable          cx23     │
   │  caddy · frontend · curator[server] · lens (replay)  │
   └──────────────────────────┬──────────────────────────┘
                              │  10.0.1.0/24 — private, unrouted
   ┌──────────────────────────▼──────────────────────────┐
   │  core          no public data ports        cx23     │
   │  postgres (lineage) · qdrant (vectors) · minio       │
   │  prometheus · grafana (admin-IP only)                │
   └─────────────────────────────────────────────────────┘
                              ▲
                    R2: seeded tape dump
```

**Cost:** 2 × CX23 @ €5.49/mo = **€10.98/mo**. R2 is inside the 10 GB free tier.

## Quick start

```bash
terraform login                      # HCP Terraform
# set `organization` in versions.tf, create the workspace (CLI-driven)
cp terraform.tfvars.example terraform.tfvars   # or use workspace variables
terraform init
terraform plan
terraform apply
```

Tear down just the public half, leaving the stores up:

```bash
terraform destroy -target=module.demo
```

For the full lifecycle — pre-deploy gates, verification, tape seeding, teardown,
secret rotation, troubleshooting — see the [deploy runbook](docs/runbook.md).

## Decisions

**Why two hosts, when it all fits on one.** It does fit — the tape is ~600 images, under 2 GB of blobs, a few thousand lineage rows, and roughly 2.5 MB of Qdrant vectors. The split is not about capacity or protecting state. It's blast radius: the demo tier exposes curator's `/scan/folder` to the internet, and a compromise there should not land on the database. Postgres, Qdrant and MinIO bind to `10.0.1.10` only. Hetzner firewalls filter the public interface exclusively, so the stores are unreachable from outside by construction rather than by a rule that could be edited wrong.

**Why no GPU.** GPU operations are re-enacted, not simulated. The real pipeline runs once on local hardware; cortex's lineage store captures `source_asset → caption → human_edit → dataset_membership` — that DAG *is* the recording. The demo replays genuine captured output. CPU paths (curator scans, dedup, export) run live, because `argus-curator[server]` never needed a GPU; the `gpu` extra is only for optional detectors and embeddings.

**Why the full suite still fits 2 × CX23.** When quarry, forge and proof join the demo ([#7](https://github.com/smk762/argus-halo/issues/7)) they come in **read-only/replay** — no live training, no live eval — so the footprint stays 2 × CX23 at €10.98/mo and no GPU host is provisioned ([#10](https://github.com/smk762/argus-halo/issues/10)). The deciding weight is proof: its `[score]` stack pulls torch and insightface, several GB of image and a resident-memory tax a CX23 can't absorb alongside the rest. The demo image ships **without** the scorer and serves canned reports instead ([argus-proof#45](https://github.com/smk762/argus-proof/issues/45)). Same posture as *Why no GPU* above — the GPU work is replayed from what the real run recorded, not recomputed on the demo box. Revisit only if live `/forge run` or live `/proof` eval becomes a demo requirement, and that's a re-scope, not a resize.

**Why no volume.** The tape is a build artifact with a long build time, not precious data — expensive to regenerate (GPU hours) but fully reproducible. Durability lives in the R2 dump, not in a block device. Adding `hcloud_volume` + `prevent_destroy` for 2 GB on a 40 GB disk would be theatre. Revisit if the tape outgrows the root disk.

**Why not the OVH dedicated box.** A spare RISE-1 (Xeon-E 2386G, 64 GB ECC) was available at zero marginal cost and is far better hardware. Rejected on two counts: the workload cannot use 64 GB — Postgres holds metadata, Qdrant holds ~2.5 MB, MinIO is disk-bound — and more importantly, infrastructure pinned to a specific box nobody else owns can't be reproduced by a stranger. `git clone && terraform apply` is the point.

**Why Cloudflare proxied.** Hides the origin address, terminates edge TLS, absorbs probes. Set the zone SSL mode to **Full (strict)** — Caddy holds a real certificate at the origin.

**Why our own compose, not argus-studio's.** [argus-studio](https://github.com/smk762/argus-studio) already ships suite compose orchestration — but it's a single-host *developer* stack: `up --build` from sibling checkouts, profiles, a GPU override, source bind-mounts. This demo is deployment-shaped and different in kind: two hosts with a public/private split, pinned published images (no build context), Caddy terminating real TLS at the origin, and the core stores (postgres/qdrant/minio) bound to the private network — none of which studio's dev compose models. So the demo keeps a small, purpose-built compose per tier and consumes studio only as the published `frontend` image. The suite images it references are tracked in [#2](https://github.com/smk762/argus-halo/issues/2).

## Security

Curator's `/scan/folder`, `/scan/folder/stream` and `/export` take caller-supplied paths. Until [argus-curator#3](https://github.com/smk762/argus-curator/issues/3) they bypassed the `_resolve_within()` containment that `/folders`, `/thumb` and `/upload` apply — a path-traversal and information-disclosure surface on a public host, made worse by `--cors` reflecting any origin. **Fixed in argus-curator v0.2.0**: those endpoints now resolve `folder`/`dest` under `ARGUS_CURATOR_SCAN_ROOT` (and an export root), `move` is gated behind `--allow-move`, and `--cors` no longer reflects arbitrary origins. The demo pins `argus-curator:0.2.0` so it runs the enforced build — this was the deploy gate in [argus-halo#1](https://github.com/smk762/argus-halo/issues/1), now closed.

Defence in depth still sits around it, none sufficient alone:

- `ARGUS_CURATOR_SCAN_ROOT` points at `/srv/argus/samples`, mounted read-only into the container.
- The demo tier holds no database; the stores are private-network only.
- The two keyed/backed endpoints (`/caption/*`, `/scan/*`) are rate-limited at the Cloudflare edge (`waf.tf`, 15 req/min per IP) so a public client can't drain the metered captioning key. In the default `demo` UI mode these paths aren't even exercised — see [Environment](#environment).

These are containment, not authorization — the server-side enforcement is what actually closes the hole. A read-only mount limits the blast radius of a filesystem read, it doesn't prevent one, and `NEXT_PUBLIC_CURATOR_UI_MODE=demo` is a frontend flag anyone can bypass with curl.

Secrets are generated by `random_password` and passed to hosts via cloud-init. They land in Terraform state — which is why state is in HCP Terraform (encrypted, access-controlled) and why `*.tfvars` is gitignored.

## Monitoring

Prometheus and Grafana run on **core**, next to the stores — no extra host, so the €10.98/mo is unchanged. Prometheus scrapes both tiers over the private network:

- **hosts** — `node_exporter` on core and demo (`10.0.1.10:9100`, `10.0.1.20:9100`)
- **stores** — Postgres (`postgres_exporter`), Qdrant (`/metrics`), MinIO (`/minio/v2/metrics/cluster`, served token-free on the private net)

Only Grafana is exposed, and only to `admin_ip` — the same trust model as SSH, by a firewall rule rather than by construction, because it's an admin UI and not a data store. Prometheus and every exporter stay private; tunnel in to reach the Prometheus UI.

```bash
terraform output -raw grafana_password         # admin password (user: admin)
open "$(terraform output -raw grafana_url)"     # http://<core ip>:3000, from your admin IP
ssh -L 9090:10.0.1.10:9090 root@<core ip>       # then Prometheus at http://localhost:9090
```

Grafana ships with the Prometheus datasource auto-provisioned; add dashboards to taste.

## Environment

Config reaches the containers by one path on **both** tiers: Terraform renders a
single `/opt/argus/.env` per host (from HCP workspace variables, `random_password`
resources, and derived values), cloud-init writes it `0600`, and every service
that needs config loads it with Compose `env_file`. No per-service inline secrets,
one file to reason about per host. To add a key: declare the Terraform variable,
thread it into that tier's `templatefile(...)`, and add the line to the `.env`
block. Where each value comes from:

- **Sensitive / operator-supplied** → a **Sensitive** HCP workspace variable.
- **Generated** → a `random_password` resource (never printed, never committed).
- **Static** → a `default` in code, or a literal in the template.

### core — `/opt/argus/.env`

| Key | Consumer | Source | Default | Sensitive |
|---|---|---|---|---|
| `POSTGRES_USER` | postgres | code | `argus` | no |
| `POSTGRES_PASSWORD` | postgres, postgres-exporter | `random_password` | generated | **yes** |
| `POSTGRES_DB` | postgres | code | `argus` | no |
| `MINIO_ROOT_USER` | minio | `minio_access_key` | `argus` | no |
| `MINIO_ROOT_PASSWORD` | minio | `random_password` | generated | **yes** |
| `MINIO_PROMETHEUS_AUTH_TYPE` | minio | code | `public` | no |
| `DATA_SOURCE_NAME` | postgres-exporter | derived (embeds pw) | — | **yes** |
| `GF_SERVER_HTTP_PORT` | grafana | `grafana_port` | `3000` | no |
| `GF_SECURITY_ADMIN_PASSWORD` | grafana | `random_password` | generated | **yes** |
| `GF_USERS_ALLOW_SIGN_UP` | grafana | code | `false` | no |
| `GF_AUTH_ANONYMOUS_ENABLED` | grafana | code | `false` | no |

### demo — `/opt/argus/.env`

| Key | Consumer | Source | Default | Sensitive |
|---|---|---|---|---|
| `ARGUS_CURATOR_SCAN_ROOT` | curator | `curator_scan_root` | `/srv/argus/samples` | no |
| `ARGUS_CURATOR_EXPORT_ROOT` | curator | `curator_export_root` | `""` → `/export` refused | no |
| `ARGUS_LENS_URL` | curator | code | `http://lens:8100` | no |
| `ARGUS_BACKEND` | lens | code | `openai-compat` | no |
| `ARGUS_OPENAI_COMPAT_BASE_URL` | lens | `lens_caption_base_url` | `https://api.cerebras.ai/v1` | no |
| `ARGUS_OPENAI_COMPAT_MODEL` | lens | `lens_caption_model` | `gemma-4-31b` | no |
| `ARGUS_OPENAI_COMPAT_API_KEY` | lens | `lens_caption_api_key` (**HCP**) | `""` → **required to caption** | **yes** |
| `CORTEX_PG_URL` | *reserved* | core output | derived | **yes** |
| `CORTEX_QDRANT_URL` | *reserved* | core output | derived | no |
| `CORTEX_S3_ENDPOINT` | *reserved* | core output | derived | no |
| `CORTEX_S3_BUCKET` | *reserved* | core output | `argus-tape` | no |
| `CORTEX_S3_ACCESS_KEY` | *reserved* | `minio_access_key` | `argus` | no |
| `CORTEX_S3_SECRET_KEY` | *reserved* | `random_password` | generated | **yes** |
| `CORTEX_S3_REGION` | *reserved* | code | `us-east-1` | no |

**Two honest caveats, both tracked:**

- **`CORTEX_*` is reserved, not yet consumed.** The pinned `argus-lens 0.4.0` and
  `argus-curator 0.2.0` images read *none* of the `CORTEX_*` variables — so the
  core store tier is provisioned but idle from the app tier's point of view. It's
  wired now so a lineage-replay backend drops in without re-plumbing
  ([argus-lens#45](https://github.com/smk762/argus-lens/issues/45)).
- **lens captions via a live endpoint, not replay.** There's no GPU here and no
  replay backend yet, so lens is pointed at an OpenAI-compatible vision model
  (Cerebras `gemma-4-31b`, the only image-capable model there). Set
  `lens_caption_api_key` in HCP or lens returns `401` on every caption. This is
  the interim until [argus-lens#45](https://github.com/smk762/argus-lens/issues/45).

### frontend (argus-studio) — build-time, **not** in `.env`

studio's `NEXT_PUBLIC_*` are inlined into the client bundle **at build time**, so
they cannot be set from the demo host's `.env` — the `frontend` service carries no
runtime `environment:` on purpose. A published image must be built for its origin
(a footgun for a public image), so the demo tracks making studio runtime-
configurable / same-origin — it already sits behind Caddy on one origin —
in [argus-studio#56](https://github.com/smk762/argus-studio/issues/56). The build
args that matter when publishing (see [#2](https://github.com/smk762/argus-halo/issues/2)):

| Build arg | Purpose | Demo value |
|---|---|---|
| `NEXT_PUBLIC_API_URL` | lens API, from the browser | `https://argus.dragonhound.dev` (or same-origin) |
| `NEXT_PUBLIC_CURATOR_URL` | curator API, from the browser | same |
| `NEXT_PUBLIC_CURATOR_UI_MODE` | `demo` (bundled sample) or `live` | `demo` |

## The tape

The tape is the recorded pipeline run core restores on first boot: the lineage
DAG (Postgres), the vectors (Qdrant), and the blobs (MinIO), in one
`tape.tar.zst`.

1. Run the real pipeline locally against the sample datasets; cortex records lineage.
2. `make tape` — dumps Postgres, snapshots **every** Qdrant collection, mirrors the
   MinIO bucket, and packs `tape.tar.zst`. Point it at your local stores with
   `SRC_*`, or load a cortex `.env` with `ENV_FILE=path/to/.env make tape` (a bare
   `source` won't survive `make`); see the header of
   [scripts/build-tape.sh](scripts/build-tape.sh).
3. Upload to the R2 bucket this repo creates. `make tape` does this for you when
   the `R2_*` env is set (and prints a presigned URL); otherwise it stops at the
   local archive and tells you the manual step.
4. Set `tape_dump_url` to that presigned URL. Core restores on first boot via
   `restore-tape.sh` (in [core's cloud-init](modules/core/cloud-init.yaml.tftpl)),
   guarded by `/opt/argus/data/.tape-restored` so a re-run never clobbers live data.

Archive layout — the contract shared by the builder and the restore script:

```
lineage.sql                    pg_dump of the lineage DAG (schema + data)
qdrant/<collection>.snapshot   one Qdrant snapshot per collection
blobs/...                      a mirror of the S3/MinIO bucket
MANIFEST                       row/collection/blob counts, for a sanity check
```

Collections are discovered from the live Qdrant, not hardcoded, so whatever
cortex wrote (`image_embeddings`, `tagset_embeddings`, or others) is captured.
Restore is idempotent and safe to re-run by hand — see the runbook.

## Known gaps

- The frontend image (`argus-studio`) isn't published to GHCR yet, so the demo can't fully boot until it is ([#2](https://github.com/smk762/argus-halo/issues/2)), and its URLs are baked at build time until it's made runtime-configurable ([argus-studio#56](https://github.com/smk762/argus-studio/issues/56)). `curator` and `lens` are pinned to released tags.
- **No replay backend yet.** lens can't serve recorded captions from the lineage store, so it calls a live vision endpoint (Cerebras) instead, and the `CORTEX_*` store contract is provisioned but unused ([argus-lens#45](https://github.com/smk762/argus-lens/issues/45)). See [Environment](#environment).
- CI runs `fmt -check` + `validate` on every push and PR. Remote `plan` is wired but stays skipped until a `TF_API_TOKEN` repository secret is set — see `.github/workflows/terraform.yml`.

## License

MIT — see [LICENSE](LICENSE).
