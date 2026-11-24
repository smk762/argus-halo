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

variable "ssh_key_ids" {
  description = "Hetzner SSH key ids installed on the host."
  type        = list(string)
}

variable "private_ip" {
  description = "Fixed address on the private network. The stores bind here and nowhere else."
  type        = string
}

variable "postgres_password" {
  description = "Postgres password."
  type        = string
  sensitive   = true
}

variable "minio_access_key" {
  description = "MinIO root user."
  type        = string
  default     = "argus"
}

variable "minio_secret_key" {
  description = "MinIO root password."
  type        = string
  sensitive   = true
}

variable "s3_bucket" {
  description = "Bucket the tape restores into."
  type        = string
  default     = "argus-tape"
}

variable "tape_dump_url" {
  description = "Presigned tape URL; empty starts the host unseeded."
  type        = string
  default     = ""
  sensitive   = true
}

# --- monitoring --------------------------------------------------------------

variable "demo_private_ip" {
  description = "Demo tier's private address. Prometheus scrapes its node_exporter here."
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  sensitive   = true
}

variable "grafana_port" {
  description = "Port Grafana listens on. Opened on the public interface to admin_ip only."
  type        = number
  default     = 3000
}

variable "stack_tarball_url" {
  description = <<-EOT
    Tarball URL of the repo ref this host tracks; argus-update fetches it and
    applies stack/core/ from it (#18). Structural changes (pins, monitoring)
    reach the host by merging and re-running argus-update, not by replacing
    the server.
  EOT
  type        = string
}
