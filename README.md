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

**Why no volume.** The tape is a build artifact with a long build time, not precious data — expensive to regenerate (GPU hours) but fully reproducible. Durability lives in the R2 dump, not in a block device. Adding `hcloud_volume` + `prevent_destroy` for 2 GB on a 40 GB disk would be theatre. Revisit if the tape outgrows the root disk.

**Why not the OVH dedicated box.** A spare RISE-1 (Xeon-E 2386G, 64 GB ECC) was available at zero marginal cost and is far better hardware. Rejected on two counts: the workload cannot use 64 GB — Postgres holds metadata, Qdrant holds ~2.5 MB, MinIO is disk-bound — and more importantly, infrastructure pinned to a specific box nobody else owns can't be reproduced by a stranger. `git clone && terraform apply` is the point.

**Why Cloudflare proxied.** Hides the origin address, terminates edge TLS, absorbs probes. Set the zone SSL mode to **Full (strict)** — Caddy holds a real certificate at the origin.

**Why our own compose, not argus-studio's.** [argus-studio](https://github.com/smk762/argus-studio) already ships suite compose orchestration — but it's a single-host *developer* stack: `up --build` from sibling checkouts, profiles, a GPU override, source bind-mounts. This demo is deployment-shaped and different in kind: two hosts with a public/private split, pinned published images (no build context), Caddy terminating real TLS at the origin, and the core stores (postgres/qdrant/minio) bound to the private network — none of which studio's dev compose models. So the demo keeps a small, purpose-built compose per tier and consumes studio only as the published `frontend` image. The suite images it references are tracked in [#2](https://github.com/smk762/argus-halo/issues/2).

## Security

Curator's `/scan/folder`, `/scan/folder/stream` and `/export` take caller-supplied paths. Until [argus-curator#3](https://github.com/smk762/argus-curator/issues/3) they bypassed the `_resolve_within()` containment that `/folders`, `/thumb` and `/upload` apply — a path-traversal and information-disclosure surface on a public host, made worse by `--cors` reflecting any origin. **Fixed in argus-curator v0.2.0**: those endpoints now resolve `folder`/`dest` under `ARGUS_CURATOR_SCAN_ROOT` (and an export root), `move` is gated behind `--allow-move`, and `--cors` no longer reflects arbitrary origins. The demo pins `argus-curator:0.2.0` so it runs the enforced build — this was the deploy gate in [argus-halo#1](https://github.com/smk762/argus-halo/issues/1), now closed.

Defence in depth still sits around it, none sufficient alone:

- `ARGUS_CURATOR_SCAN_ROOT` points at `/srv/argus/samples`, mounted read-only into the container.
- The demo tier holds no database; the stores are private-network only.

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

## The tape

Not yet automated. Current shape:

1. Run the real pipeline locally against the six sample datasets; cortex records lineage.
2. `pg_dump` the lineage schema, snapshot Qdrant, sync MinIO blobs; `tar --zstd` into `tape.tar.zst`.
3. Upload to the R2 bucket this repo creates.
4. Set `tape_dump_url` to a presigned URL; core restores on first boot, guarded by `/opt/argus/data/.tape-restored`.

Steps 2–4 want a `make tape` target. Qdrant snapshot and MinIO restore aren't wired into `restore-tape.sh` yet — only Postgres is.

## Known gaps

- `server_type = "cx23"` — Hetzner renamed the plan line in June 2026 and the API needs auth to enumerate. If `plan` rejects it, check the Console for the exact identifier.
- The frontend image (`argus-studio`) isn't published to GHCR yet, so the demo can't fully boot until it is ([#2](https://github.com/smk762/argus-halo/issues/2)). `curator` and `lens` are pinned to released tags.
- CI runs `fmt -check` + `validate` on every push and PR. Remote `plan` is wired but stays skipped until a `TF_API_TOKEN` repository secret is set — see `.github/workflows/terraform.yml`.

## License

MIT — see [LICENSE](LICENSE).
