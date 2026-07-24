resource "hcloud_server" "demo" {
  name         = "${var.project}-demo"
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = var.ssh_key_ids
  firewall_ids = [hcloud_firewall.demo.id]

  network {
    network_id = var.network_id
    ip         = var.private_ip
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    domain                = var.domain
    cortex_pg_url         = var.cortex_pg_url
    cortex_qdrant_url     = var.cortex_qdrant_url
    cortex_s3_endpoint    = var.cortex_s3_endpoint
    cortex_s3_bucket      = var.cortex_s3_bucket
    minio_access_key      = var.minio_access_key
    minio_secret_key      = var.minio_secret_key
    curator_scan_root     = var.curator_scan_root
    curator_export_root   = var.curator_export_root
    tape_dump_url         = var.tape_dump_url
    quarry_home           = var.quarry_home
    forge_export_root     = var.forge_export_root
    proof_home            = var.proof_home
    lens_caption_base_url = var.lens_caption_base_url
    lens_caption_model    = var.lens_caption_model
    lens_caption_api_key  = var.lens_caption_api_key
    stack_tarball_url     = var.stack_tarball_url
  })

  labels = {
    project = var.project
    tier    = "demo"
  }
}

# This box is the one on the internet. Assume it will be probed.
resource "hcloud_firewall" "demo" {
  name = "${var.project}-demo"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}
