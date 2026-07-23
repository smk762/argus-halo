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
  description = "Cloudflare token with Zone:DNS:Edit, Zone Settings:Edit (for the SSL-mode resource) and Workers R2 Storage:Edit on dragonhound.dev."
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

  # Ask the question at plan time, like preflight.tf does for server_type. A bare
  # address (203.0.113.9) otherwise passes plan and fails at apply on two firewall
  # resources, in the Hetzner API's words rather than ours. cidrhost() rejects any
  # value that is not a valid CIDR, so can() turns that into a clean plan error.
  validation {
    condition     = can(cidrhost(var.admin_ip, 0))
    error_message = "admin_ip must be in CIDR form, e.g. 203.0.113.9/32 (a bare address is not accepted)."
  }

  # CIDR form alone is not the interesting question -- 0.0.0.0/0 is a perfectly
  # valid CIDR. This value is the source_ips on SSH for both tiers and on
  # Grafana, so an over-broad prefix opens exactly what it is meant to close,
  # with a green plan. Guard the dangerous case, not just the cosmetic one.
  # The first condition already reports a non-CIDR, so skip it here rather than
  # emit two errors for one typo.
  validation {
    condition     = !can(cidrhost(var.admin_ip, 0)) || try(tonumber(regex("[0-9]+$", var.admin_ip)) >= 8, false)
    error_message = "admin_ip is too broad: give a specific address or small network (prefix /8 or longer), not 0.0.0.0/0 or ::/0 -- that would open SSH and Grafana to the entire internet."
  }
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
  description = <<-EOT
    Hetzner server type for both tiers. cx23 is the smallest of the
    cost-optimized shared-x86 line Hetzner introduced in October 2025.
    Checked against live per-location stock at plan time -- a retired or
    sold-out identifier fails the plan and lists what IS available in
    var.location, so there is nothing to look up by hand. See preflight.tf.
  EOT
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

    R2 caps presigned URLs at 7 days, and core reads this on EVERY first boot --
    so refresh it before any apply that recreates core (a password rotation, a
    cloud-init change, a server_type change), or the rebuild comes up with empty
    stores. `make tape` prints a fresh one.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# --- lens captioning ---------------------------------------------------------

variable "lens_caption_api_key" {
  description = <<-EOT
    API key for the OpenAI-compatible endpoint lens captions through (default
    Cerebras). Required for lens to caption; set as a Sensitive workspace
    variable. Interim until argus-lens#45 (lineage replay) removes the need for
    a live model. See README > Environment.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "lens_caption_base_url" {
  description = "OpenAI-compatible endpoint lens captions through. Default: Cerebras."
  type        = string
  default     = "https://api.cerebras.ai/v1"
}

variable "lens_caption_model" {
  description = "Vision-capable model id at lens_caption_base_url. Cerebras: gemma-4-31b."
  type        = string
  default     = "gemma-4-31b"
}

variable "stack_repo" {
  description = "GitHub repo (owner/name) each host fetches its stack/<tier>/ from (#18)."
  type        = string
  default     = "smk762/argus-halo"
}

variable "stack_ref" {
  description = <<-EOT
    Git ref of stack_repo the hosts track: a branch, tag, or commit SHA.
    `main` means a host converges on the current default branch every time
    argus-update runs (boot included) -- merging to main IS the deploy
    channel. Pin a SHA or tag here only if you want plan-time control back,
    accepting that changing it then replaces the hosts again (it lives in
    deploy.env, which is user_data).
  EOT
  type        = string
  default     = "main"
}
