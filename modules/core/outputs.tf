# These are cortex's contract, verbatim. modules/demo feeds them straight into
# CORTEX_PG_URL / CORTEX_QDRANT_URL / CORTEX_S3_ENDPOINT. If cortex's store layer
# ever grows a fourth backend, it shows up here first.

output "cortex_pg_url" {
  description = "Lineage store DSN on the private network."
  value       = "postgresql://argus:${var.postgres_password}@${var.private_ip}:5432/argus"
  sensitive   = true
}

output "cortex_qdrant_url" {
  description = "Vector store URL on the private network."
  value       = "http://${var.private_ip}:6333"
}

output "cortex_s3_endpoint" {
  description = "Blob store endpoint on the private network."
  value       = "http://${var.private_ip}:9000"
}

output "cortex_s3_bucket" {
  description = "Blob store bucket."
  value       = var.s3_bucket
}

output "minio_access_key" {
  description = "MinIO root user."
  value       = var.minio_access_key
}

output "public_ipv4" {
  description = "Public IPv4 address."
  value       = hcloud_server.core.ipv4_address
}

output "grafana_endpoint" {
  description = "Grafana URL, reachable from the admin IP (or via SSH tunnel to core)."
  value       = "http://${hcloud_server.core.ipv4_address}:${var.grafana_port}"
}

output "open_ports" {
  description = "Ports open on the public interface. Asserted by tests/security.tftest.hcl."
  value       = [for r in hcloud_firewall.core.rule : r.port if r.direction == "in"]
}

output "allowed_sources" {
  description = "Every source CIDR any public port accepts."
  sensitive   = true
  value       = flatten([for r in hcloud_firewall.core.rule : r.source_ips])
}
