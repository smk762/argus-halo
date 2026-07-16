output "public_ipv4" {
  value = hcloud_server.demo.ipv4_address
}

output "private_ip" {
  value = var.private_ip
}
