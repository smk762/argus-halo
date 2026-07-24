locals {
  # Fixed private addresses so cloud-init can template connection strings
  # without a second apply.
  core_private_ip = "10.0.1.10"
  demo_private_ip = "10.0.1.20"

  # The repo tarball each host's argus-update fetches its stack/<tier>/ from
  # (#18). Service definitions, pins, routes and restore scripts live there,
  # not in user_data -- so a pin bump is a merge plus an in-place update.
  # codeload takes a bare ref: a branch, a tag, or a commit SHA all work.
  stack_tarball_url = "https://codeload.github.com/${var.stack_repo}/tar.gz/${var.stack_ref}"
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.project}-admin"
  public_key = var.ssh_public_key
}

resource "hcloud_network" "argus" {
  name     = var.project
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "argus" {
  network_id   = hcloud_network.argus.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = "10.0.1.0/24"
}

# Generated here, never committed, never printed. Both tiers read them from
# state via module outputs.
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "minio" {
  length  = 40
  special = false
}

# Grafana admin login. Default admin/admin is never acceptable on a box whose
# dashboard is reachable from the admin IP.
resource "random_password" "grafana" {
  length  = 24
  special = false
}

module "core" {
  source = "./modules/core"

  project     = var.project
  location    = var.location
  server_type = var.server_type
  image       = var.image
  ssh_key_ids = [hcloud_ssh_key.admin.id]
  network_id  = hcloud_network.argus.id
  private_ip  = local.core_private_ip
  admin_ip    = var.admin_ip

  postgres_password = random_password.postgres.result
  minio_secret_key  = random_password.minio.result
  tape_dump_url     = var.tape_dump_url
  stack_tarball_url = local.stack_tarball_url

  # Monitoring: Prometheus/Grafana live here; Prometheus also scrapes the demo
  # tier's node_exporter over the private network.
  grafana_admin_password = random_password.grafana.result
  demo_private_ip        = local.demo_private_ip

  # The server's network block fails if the subnet isn't up yet. The preflight
  # gate (preflight.tf) already fails the whole plan before anything is created,
  # so naming it here is ordering clarity, not the gate itself.
  depends_on = [hcloud_network_subnet.argus, data.hcloud_location.target]
}

module "demo" {
  source = "./modules/demo"

  project     = var.project
  location    = var.location
  server_type = var.server_type
  image       = var.image
  ssh_key_ids = [hcloud_ssh_key.admin.id]
  network_id  = hcloud_network.argus.id
  private_ip  = local.demo_private_ip
  admin_ip    = var.admin_ip
  domain      = var.domain

  # The whole point of the split: cortex's contract, handed over as outputs.
  # Reserved: lens/curator 0.x don't consume CORTEX_* yet (argus-lens#45).
  cortex_pg_url      = module.core.cortex_pg_url
  cortex_qdrant_url  = module.core.cortex_qdrant_url
  cortex_s3_endpoint = module.core.cortex_s3_endpoint
  cortex_s3_bucket   = module.core.cortex_s3_bucket
  minio_access_key   = module.core.minio_access_key
  minio_secret_key   = random_password.minio.result
  stack_tarball_url  = local.stack_tarball_url

  # Same tape core restores, but the demo host reads only its demo/ subtree to
  # seed the quarry/forge/proof/samples mounts (#9). One URL to rotate.
  tape_dump_url = var.tape_dump_url

  # Captioning backend (interim, until lens replay lands -- argus-lens#45).
  lens_caption_api_key  = var.lens_caption_api_key
  lens_caption_base_url = var.lens_caption_base_url
  lens_caption_model    = var.lens_caption_model

  depends_on = [hcloud_network_subnet.argus, data.hcloud_location.target]
}
