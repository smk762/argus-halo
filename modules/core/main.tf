resource "hcloud_server" "core" {
  name         = "${var.project}-core"
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = var.ssh_key_ids
  firewall_ids = [hcloud_firewall.core.id]

  network {
    network_id = var.network_id
    ip         = var.private_ip
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    private_ip             = var.private_ip
    postgres_password      = var.postgres_password
    minio_access_key       = var.minio_access_key
    minio_secret_key       = var.minio_secret_key
    tape_dump_url          = var.tape_dump_url
    s3_bucket              = var.s3_bucket
    demo_private_ip        = var.demo_private_ip
    grafana_admin_password = var.grafana_admin_password
    grafana_port           = var.grafana_port
  })

  labels = {
    project = var.project
    tier    = "core"
  }
}

# Hetzner firewalls filter the PUBLIC interface only -- private network traffic
# is never touched. So "SSH only" here means the stores are unreachable from the
# internet by construction, not by a rule we could forget.
resource "hcloud_firewall" "core" {
  name = "${var.project}-core"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip]
  }

  # Grafana. Same trust model as SSH above: exposed on the public interface but
  # reachable only from the admin IP. Everything else Prometheus touches
  # (exporters, the Prometheus UI) stays on the private network -- tunnel in.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = tostring(var.grafana_port)
    source_ips = [var.admin_ip]
  }
}
