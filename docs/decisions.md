# Design decisions

Why the infrastructure is shaped this way. For the overview see the [README](../README.md).

## Why two hosts, when it all fits on one

It does fit — the tape is ~600 images, under 2 GB of blobs, a few thousand lineage rows, and roughly 2.5 MB of Qdrant vectors. The split is not about capacity or protecting state. It's blast radius: the demo tier exposes curator's `/scan/folder` to the internet, and a compromise there should not land on the database. Postgres, Qdrant and MinIO bind to core's private address only. Hetzner firewalls filter the public interface exclusively, so the stores are unreachable from outside by construction rather than by a rule that could be edited wrong.

## Why no GPU

GPU operations are re-enacted, not simulated. The real pipeline runs once on local hardware; cortex's lineage store captures `source_asset → caption → human_edit → dataset_membership` — that DAG *is* the recording. The demo replays genuine captured output. CPU paths (curator scans, dedup, export) run live, because `argus-curator[server]` never needed a GPU; the `gpu` extra is only for optional detectors and embeddings.

## Why the full suite still fits 2 × CX23

Quarry, forge, proof and atlas join the demo in **read-only/replay** — no live training, no live eval and no live bake — so the footprint stays 2 × CX23 at about €12/mo (€5.49 each plus €0.50 per IPv4, excluding VAT) and no GPU host is provisioned ([#10](https://github.com/smk762/argus-halo/issues/10)). The deciding weight is still proof: its `[score]` stack pulls torch and insightface, several GB of image and a resident-memory tax a CX23 can't absorb alongside the rest. The demo image ships **without** the scorer and serves canned reports instead ([argus-proof#45](https://github.com/smk762/argus-proof/issues/45)). Atlas is the GDAL image (about 190 MB compressed, no torch); `POST /bake` stays 403. Same posture as *Why no GPU* above — the GPU work is replayed from what the real run recorded, not recomputed on the demo box. Revisit only if live `/forge run`, live `/proof` eval, or live `/atlas` bake becomes a demo requirement, and that's a re-scope, not a resize.

## Why no volume

The tape is a build artifact with a long build time, not precious data — expensive to regenerate (GPU hours) but fully reproducible. Durability lives in the R2 dump, not in a block device. Adding `hcloud_volume` + `prevent_destroy` for 2 GB on a 40 GB disk would be theatre. `prevent_destroy` sits on the R2 bucket instead (`dns.tf`), which is where durability actually lives — a plain `terraform destroy` refuses rather than taking the one artifact that costs GPU hours to regenerate. Revisit if the tape outgrows the root disk.

## Why not the OVH dedicated box

A spare RISE-1 (Xeon-E 2386G, 64 GB ECC) was available at zero marginal cost and is far better hardware. Rejected on two counts: the workload cannot use 64 GB — Postgres holds metadata, Qdrant holds ~2.5 MB, MinIO is disk-bound — and more importantly, infrastructure pinned to a specific box nobody else owns can't be reproduced by a stranger. `git clone && terraform apply` is the point.

## Why Cloudflare proxied

Hides the origin address, terminates edge TLS, absorbs probes. The zone's SSL mode is pinned to **Full (strict)** in `dns.tf` — Caddy holds a real certificate at the origin, and anything less either talks plaintext to an origin that redirects to HTTPS (Flexible, an infinite loop) or skips validating the certificate it asked us to install. It's Terraform's to hold, not a checklist item.

## Why our own compose, not argus-studio's

[argus-studio](https://github.com/smk762/argus-studio) already ships suite compose orchestration — but it's a single-host *developer* stack: `up --build` from sibling checkouts, profiles, a GPU override, source bind-mounts. This demo is deployment-shaped and different in kind: two hosts with a public/private split, pinned published images (no build context), Caddy terminating real TLS at the origin, and the core stores (postgres/qdrant/minio) bound to the private network — none of which studio's dev compose models. So the demo keeps a small, purpose-built compose per tier and consumes studio only as the published `frontend` image. The suite images it references are tracked in [#2](https://github.com/smk762/argus-halo/issues/2).

## Why the service definitions are fetched, not baked into `user_data`

`hcloud_server.user_data` is ForceNew, so anything living there can only change by replacing the host — and the things that change most (image pins, Caddy routes, monitoring configs) were exactly what lived there. That inverted the pins' own rationale: the Grafana pin protects a version-bound data volume, and bumping it destroyed that volume ([#18](https://github.com/smk762/argus-halo/issues/18)). Now `user_data` carries only config (`.env`, `deploy.env`) and a tiny fetcher (`argus-update`); the structural files live in [`stack/`](../stack/) and are fetched at boot and on demand from the tracked ref (`stack_ref`, default `main`). A pin bump is a merge to `dev`, a fast-forward of `main` (see [Branches](../README.md#branches)), plus `ssh <host> /opt/argus/argus-update` — volumes, certificates and the host's IP survive. The trade: advancing `main` **is** the deploy channel, and first boot depends on GitHub being reachable. See runbook §4b.

## Why Silo instead of MinIO

MinIO's community edition went source-only in October 2025, then into maintenance, and its repository was archived in April 2026; the images this repo pinned no longer pull. Nothing about the tape needs a different store, so the stack moved to [Silo](https://github.com/pgsty/silo), an AGPL fork that keeps the S3 API, `MINIO_*` environment, health and metrics paths. The service is still called `minio` in compose because clients and scrape targets address it by that name. The trade is trusting a small third-party maintainer, which is acceptable for a private-network store whose contents can be rebuilt from R2.
