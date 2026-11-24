output "public_ipv4" {
  description = "Public IPv4 address."
  value       = hcloud_server.demo.ipv4_address
}

output "private_ip" {
  description = "Address on the private network."
  value       = var.private_ip
}

output "open_ports" {
  description = "Ports open on the public interface. Asserted by tests/security.tftest.hcl."
  value       = [for r in hcloud_firewall.demo.rule : r.port if r.direction == "in"]
}

output "ssh_sources" {
  description = "Source CIDRs SSH accepts."
  value       = flatten([for r in hcloud_firewall.demo.rule : r.source_ips if r.port == "22"])
}
