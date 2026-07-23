variable "project" { type = string }
variable "location" { type = string }
variable "server_type" { type = string }
variable "image" { type = string }
variable "network_id" { type = string }
variable "admin_ip" { type = string }
variable "private_ip" { type = string }
variable "domain" { type = string }

variable "ssh_key_ids" {
  type = list(string)
}

# --- cortex contract, handed down from modules/core --------------------------

variable "cortex_pg_url" {
  type      = string
  sensitive = true
}

variable "cortex_qdrant_url" { type = string }
variable "cortex_s3_endpoint" { type = string }
variable "cortex_s3_bucket" { type = string }
variable "minio_access_key" { type = string }

variable "minio_secret_key" {
  type      = string
  sensitive = true
}

# The demo host restores the same tape core does, but reads only its demo/ subtree
# (quarry/forge/proof/samples seed) via restore-seed.sh. Empty => tiers start
# empty. See variables.tf (root) for the full contract and README > The tape.
variable "tape_dump_url" {
  type      = string
  default   = ""
  sensitive = true
}

variable "curator_scan_root" {
  description = <<-EOT
    Sandbox directory curator is allowed to scan. See README > Security.
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
