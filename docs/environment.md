# Environment

Terraform renders one `/opt/argus/.env` per host (from HCP workspace variables,
`random_password` resources and derived values) and cloud-init writes it `0600`.
A second file, `/opt/argus/deploy.env`, carries deploy knobs (`TAPE_DUMP_URL`,
addresses, the tracked stack ref). `stack/<tier>/apply.sh` sources both for
compose's `${VAR}` interpolation.

Each service then lists the keys it needs in its own `environment:` block. No
container receives the whole file, so the caption key reaches only lens, and
Grafana holds no store credential
([#15](https://github.com/smk762/argus-halo/issues/15)).
`scripts/check-cloud-init.sh` fails the build if a service goes back to
`env_file`, or if a second service names the caption key.

To add a key: declare the Terraform variable, thread it into that tier's
`templatefile(...)`, add it to the template's `.env` block, and list it on the
service. A changed `.env` value is a `user_data` change and replaces the host;
a fixed setting belongs on the service instead. Where each value comes from:

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

A few flags are set on the service in `stack/demo/compose.yaml` rather than in
this file. They are fixed demo posture, not secrets, and a change to `.env`
is a `user_data` change, which replaces the host. They ride `argus-update`:

| Key | Service | Value | Why it is not in `.env` |
|---|---|---|---|
| `ARGUS_REFINE` | lens | `off` | lens 0.10 refines with local Ollama unless this is off |
| `QUARRY_ALLOW_FETCH` | quarry | `0` | the archive slice fetch is quarry 0.3's one write route |
| `ATLAS_ALLOW_BAKE` | atlas | empty | empty is off; `POST /bake` stays 403 |
| `ATLAS_ALLOW_OSM` | atlas | empty | empty is off; the host is not an Overpass proxy |
| `ATLAS_JOBS_DIR` / `ATLAS_DEM_DIR` | atlas | image defaults | mount targets; both `:ro` |

`CORTEX_*` is reserved: nothing running here consumes it yet, so no container
receives it. The core stores are provisioned and seeded ahead of lens's
lineage-replay backend ([argus-lens#45](https://github.com/smk762/argus-lens/issues/45)).
Until then lens captions through an OpenAI-compatible vision endpoint; set
`lens_caption_api_key` in HCP or captions return `401`.

Fixed posture (`LENS_READ_ONLY`, `ARGUS_PROOF_READ_ONLY`, `QUARRY_ALLOW_FETCH`
and the rest) is set on each service in
[stack/demo/compose.yaml](../stack/demo/compose.yaml), where the checker asserts it.

### frontend (argus-studio)

The image resolves `ARGUS_*` from its environment per request, so one published
image deploys to any origin. The smoke test reads the rendered page and fails if
a URL did not take effect.

| Variable | Purpose | Demo value |
|---|---|---|
| `ARGUS_LENS_URL` … `ARGUS_ATLAS_URL` | API bases, as the browser sees them | `/api/<service>` |
| `ARGUS_CURATOR_UI_MODE` | `demo` (bundled sample) or `live` | `demo` |
| `ARGUS_FORGE_UI_MODE`, `ARGUS_PROOF_UI_MODE` | same, per page | `live` (both services are read-only) |
