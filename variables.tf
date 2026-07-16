variable "project" {
  description = "Name prefix applied to every resource."
  type        = string
  default     = "argus-halo"
}

# --- credentials -------------------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write), from Console > Security > API tokens."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare token with Zone:DNS:Edit and Workers R2 Storage:Edit on dragonhound.dev."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (dashboard sidebar, or Overview > API)."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID for dragonhound.dev (Overview > API section, bottom right)."
  type        = string
}

# --- access ------------------------------------------------------------------

variable "ssh_public_key" {
  description = "Public key installed on both hosts. Paste the key itself, not a path."
  type        = string
}

variable "admin_ip" {
  description = "Your source address in CIDR form, e.g. 203.0.113.9/32. SSH is restricted to this."
  type        = string
}

# --- placement ---------------------------------------------------------------

variable "domain" {
  description = "Public hostname for the demo tier."
  type        = string
  default     = "argus.dragonhound.dev"
}

variable "location" {
  description = "Hetzner location. fsn1/nbg1 = Germany, hel1 = Finland."
  type        = string
  default     = "fsn1"
}

variable "network_zone" {
  description = "Hetzner network zone. Must contain var.location."
  type        = string
  default     = "eu-central"
}

variable "server_type" {
  description = "Hetzner server type. cx23 = 2 vCPU / 4 GB, EUR 5.49/mo as of 2026-06-15."
  type        = string
  default     = "cx23"
}

variable "image" {
  description = "Base image for both tiers."
  type        = string
  default     = "ubuntu-24.04"
}

# --- application -------------------------------------------------------------

variable "tape_dump_url" {
  description = <<-EOT
    Presigned URL of the seeded lineage dump, restored into core on first boot.
    Leave empty to start with empty stores. See README > The tape.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}
