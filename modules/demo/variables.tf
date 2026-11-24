variable "project" {
  description = "Name prefix applied to every resource."
  type        = string
}

variable "location" {
  description = "Hetzner location."
  type        = string
}

variable "server_type" {
  description = "Hetzner server type."
  type        = string
}

variable "image" {
  description = "Base OS image."
  type        = string
}

variable "network_id" {
  description = "Private network to attach to."
  type        = string
}

variable "admin_ip" {
  description = "CIDR allowed to reach SSH."
  type        = string
}

variable "private_ip" {
  description = "Fixed address on the private network."
  type        = string
}

variable "domain" {
  description = "Public hostname Caddy serves."
  type        = string
}

variable "ssh_key_ids" {
  description = "Hetzner SSH key ids installed on the host."
  type        = list(string)
}

# --- cortex contract, handed down from modules/core --------------------------

variable "cortex_pg_url" {
  description = "Lineage store DSN, from the core module."
  type        = string
  sensitive   = true
}

variable "cortex_qdrant_url" {
  description = "Vector store URL, from the core module."
  type        = string
}

variable "cortex_s3_endpoint" {
  description = "Blob store endpoint, from the core module."
  type        = string
}

variable "cortex_s3_bucket" {
  description = "Blob store bucket, from the core module."
  type        = string
}

variable "minio_access_key" {
  description = "MinIO root user."
  type        = string
}

variable "minio_secret_key" {
  description = "MinIO root password."
  type        = string
  sensitive   = true
}

# The demo host restores the same tape core does, but reads only its demo/ subtree
# (quarry/forge/proof/samples seed) via restore-seed.sh. Empty => tiers start
# empty. See variables.tf (root) for the full contract and docs/tape.md.
variable "tape_dump_url" {
  description = "Presigned tape URL; empty starts the host unseeded."
  type        = string
  default     = ""
  sensitive   = true
}

variable "curator_scan_root" {
  description = <<-EOT
    Sandbox directory curator is allowed to scan. See docs/security.md.
    This is a containment measure, not authorization -- curator must enforce it
    server-side. A UI mode flag is not a boundary.
  EOT
  type        = string
  default     = "/srv/argus/samples"
}

variable "curator_export_root" {
  description = <<-EOT
    Root that curator /export destinations resolve under. Left empty on the
    public host so /export refuses outright (read-only demo).
  EOT
  type        = string
  default     = ""
}

# --- full-suite tiers (#7) ---------------------------------------------------
# In-container paths for the three read-only/replay services, bind-mounted from
# /srv/argus/<tier> on the host, which the tape seeds (#9). All three are
# mounted :ro -- quarry only since the 0.2.3 pin, the first published release
# whose store opens a read-only QUARRY_HOME (argus-quarry#5; the rollback rule
# lives at the pin in cloud-init.yaml.tftpl). These are container-side paths
# only: each one is what the service is told AND the mount target, so the two
# cannot drift.

variable "quarry_home" {
  description = "Provenance pool quarry serves from (QUARRY_HOME). Mounted read-only since the 0.2.3 pin (argus-quarry#5); the public API is all GETs."
  type        = string
  default     = "/srv/argus/quarry"
}

variable "forge_export_root" {
  description = "Curated export root forge renders training configs from. Read-only; live training is refused by default."
  type        = string
  default     = "/srv/argus/exports"
}

# One root, not three dirs: proof's reports/exports/runs are fixed subdirectories
# of it, so the mount and the three ARGUS_PROOF_*_DIR values are derived from a
# single value and cannot point somewhere nothing is mounted.
variable "proof_home" {
  description = "Root proof replays from; reports/, exports/ and runs/ live under it. Mounted read-only -- live GPU eval is disabled via ARGUS_PROOF_READ_ONLY."
  type        = string
  default     = "/srv/argus/proof"
}

# --- lens captioning backend -------------------------------------------------
# lens 0.5.0 ships the lineage-replay backend (argus-lens#45) but it is not
# enabled (ARGUS_BACKEND=openai-compat) and there is no GPU here, so captions
# come from an OpenAI-compatible vision endpoint.

variable "lens_caption_base_url" {
  description = "OpenAI-compatible endpoint lens captions through. Default: Cerebras."
  type        = string
  default     = "https://api.cerebras.ai/v1"
}

variable "lens_caption_model" {
  description = "Vision-capable model id at the endpoint. Cerebras: gemma-4-31b."
  type        = string
  default     = "gemma-4-31b"
}

variable "lens_caption_api_key" {
  description = "API key for the captioning endpoint (e.g. Cerebras). Set in HCP."
  type        = string
  default     = ""
  sensitive   = true
}

variable "stack_tarball_url" {
  description = <<-EOT
    Tarball URL of the repo ref this host tracks; argus-update fetches it and
    applies stack/demo/ from it (#18). Structural changes (pins, routes)
    reach the host by merging and re-running argus-update, not by replacing
    the server.
  EOT
  type        = string
}
