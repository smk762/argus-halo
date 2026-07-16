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
