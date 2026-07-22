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
# In-container paths for the three read-only/replay services. Each is bind-
# mounted read-only from /srv/argus/<tier> on the host, which the tape seeds (#9).
# They are container-side paths, not host paths -- changing one changes what the
# service is told, so it must match the mount in cloud-init.

variable "quarry_home" {
  description = "Provenance pool quarry serves from (QUARRY_HOME). Read-only; the gallery API is all GETs."
  type        = string
  default     = "/srv/argus/quarry"
}

variable "forge_export_root" {
  description = "Curated export root forge renders training configs from. Read-only; live training is refused by default."
  type        = string
  default     = "/srv/argus/exports"
}

variable "proof_reports_dir" {
  description = "Precomputed EvalReports proof replays. Read-only; live GPU eval is disabled via ARGUS_PROOF_READ_ONLY."
  type        = string
  default     = "/srv/argus/proof/reports"
}

variable "proof_exports_dir" {
  description = "Export tree proof resolves report images against."
  type        = string
  default     = "/srv/argus/proof/exports"
}

variable "proof_runs_dir" {
  description = "Run directory proof reads. Never written to in replay mode."
  type        = string
  default     = "/srv/argus/proof/runs"
}

# --- lens captioning backend -------------------------------------------------
# lens 0.4.0 has no lineage-replay backend (argus-lens#45) and there is no GPU
# here, so captions come from an OpenAI-compatible vision endpoint.

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
