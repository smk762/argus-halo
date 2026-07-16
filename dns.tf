# Cloudflare v5 renamed this from `cloudflare_record` and `value` -> `content`.
# ttl is required; ttl = 1 means "automatic" and is mandatory when proxied.
resource "cloudflare_dns_record" "demo" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "A"
  content = module.demo.public_ipv4
  ttl     = 1
  proxied = true
  comment = "argus-halo demo tier"
}

# Durable home for the tape. Core is disposable; this is not.
# Free tier covers 10 GB and the tape is ~2 GB.
resource "cloudflare_r2_bucket" "tape" {
  account_id = var.cloudflare_account_id
  name       = "${var.project}-tape"
  location   = "EEUR"
}
