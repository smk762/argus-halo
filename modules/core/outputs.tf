# These are cortex's contract, verbatim. modules/demo feeds them straight into
# CORTEX_PG_URL / CORTEX_QDRANT_URL / CORTEX_S3_ENDPOINT. If cortex's store layer
# ever grows a fourth backend, it shows up here first.

output "cortex_pg_url" {
  value     = "postgresql://argus:${var.postgres_password}@${var.private_ip}:5432/argus"
  sensitive = true
}

output "cortex_qdrant_url" {
  value = "http://${var.private_ip}:6333"
}

output "cortex_s3_endpoint" {
  value = "http://${var.private_ip}:9000"
}

output "cortex_s3_bucket" {
  value = var.s3_bucket
}

output "minio_access_key" {
  value = var.minio_access_key
}

output "public_ipv4" {
  value = hcloud_server.core.ipv4_address
}
