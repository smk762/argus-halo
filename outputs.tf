output "demo_url" {
  description = "Public entrypoint."
  value       = "https://${var.domain}"
}

output "demo_ipv4" {
  description = "Demo tier public address. SSH here to debug the app tier."
  value       = module.demo.public_ipv4
}

output "core_ipv4" {
  description = "Core tier public address. SSH only; no data ports are exposed."
  value       = module.core.public_ipv4
}

output "core_private_ip" {
  description = "Core's address on the private network. Where the stores actually listen."
  value       = local.core_private_ip
}

output "tape_bucket" {
  description = "R2 bucket holding the seeded lineage dump."
  value       = cloudflare_r2_bucket.tape.name
}

output "ssh_core" {
  value = "ssh root@${module.core.public_ipv4}"
}

output "ssh_demo" {
  value = "ssh root@${module.demo.public_ipv4}"
}
