# The tape

The tape is the recorded pipeline run core restores on first boot: the lineage
DAG (Postgres), the vectors (Qdrant), and the blobs (MinIO), in one
`tape.tar.zst`.

1. Run the real pipeline locally against the sample datasets; cortex records lineage.
2. `make tape` — dumps Postgres, snapshots **every** Qdrant collection, mirrors the
   MinIO bucket, and packs `tape.tar.zst`. Point it at your local stores with
   `SRC_*`, or load a cortex `.env` with `ENV_FILE=path/to/.env make tape` (a bare
   `source` won't survive `make`); see the header of
   [scripts/build-tape.sh](../scripts/build-tape.sh).
3. Upload to the R2 bucket this repo creates. `make tape` does this for you when
   the `R2_*` env is set (and prints a presigned URL); otherwise it stops at the
   local archive and tells you the manual step.
4. Set `tape_dump_url` to that presigned URL. Core restores on first boot via
   `restore-tape.sh` (in [stack/core/](../stack/core/restore-tape.sh)),
   guarded by `/opt/argus/data/.tape-restored` so a re-run never clobbers live data.

**A presigned URL expires — R2 caps them at 7 days.** Core reads `tape_dump_url`
on *every* first boot, so a stale URL means a rebuilt core comes up with empty
stores. The restore fails loudly and names expiry as the likely cause, but it
fails inside cloud-init where nobody is watching. Refresh the URL before any
planned core replace, or publish the tape at a stable address — it is a build
artifact, not a secret, and nothing about it needs to be presigned.

Qdrant snapshots only restore into the **same minor version**, so this is checked
on both sides. `make tape` reads the minor straight out of the qdrant image pin in
[stack/core/compose.yaml](../stack/core/compose.yaml) and refuses to build
against a local Qdrant that doesn't match — nothing to keep in sync by hand. It
also records `qdrant_version` in `MANIFEST`, and `restore-tape.sh` re-checks that
against the Qdrant it actually booted, *before* it touches Postgres. So a pin
moved on one side only is caught at restore time with the stores still untouched,
rather than leaving core half-seeded.

Archive layout — the contract shared by the builder and the restore script:

```
lineage.sql                    pg_dump of the lineage DAG (schema + data)
qdrant/<collection>.snapshot   one Qdrant snapshot per collection
blobs/...                      a mirror of the S3/MinIO bucket
demo/samples|quarry|exports|proof|atlas|dem
                               bind-mount seeds for the demo tier
MANIFEST                       row/collection/blob counts + source Qdrant version
```

`demo/atlas` is a directory of finished jobs (each with `job.json`, previews
and, if you baked one, `fantasy.pmtiles`). `demo/dem` is the DEMs and vector
files `GET /inputs` may name. Both are optional. Point `make tape` at them
with `SRC_ATLAS_JOBS` and `SRC_ATLAS_DEM`. The public host mounts both
read-only, so a seeded job can be browsed and its archive downloaded, and a
new controls job cannot be built there.

Collections are discovered from the live Qdrant, not hardcoded, so whatever
cortex wrote (`image_embeddings`, `tagset_embeddings`, or others) is captured.
Restore is idempotent and safe to re-run by hand — see the [runbook](runbook.md).
