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

# Caddy holds a real certificate at the origin, so the zone must be on Full
# (strict) -- anything less and the edge either talks plaintext to an origin that
# redirects to HTTPS (Flexible => infinite redirect loop) or skips validating the
# origin certificate it asked us to install. This used to be a manual checklist
# item repeated in four places; a setting Terraform can hold is not a runbook step.
#
# Needs `Zone Settings:Edit` on the API token, on top of DNS and R2.
#
# Scope note: this is a ZONE setting, so it applies to every hostname on
# dragonhound.dev, not just ours. That is correct for a zone whose origins all
# hold real certificates, and wrong the moment one doesn't -- an origin without a
# valid cert starts returning 526 instead of degrading. If the zone ever hosts an
# origin that can't be given a certificate, this resource is the thing to
# reconsider, not the thing to work around in the dashboard (an `apply` puts it
# back).
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "strict"
}

# Durable home for the tape. Core is disposable; this is not.
# Free tier covers 10 GB and the tape is ~2 GB.
#
# prevent_destroy makes that claim enforceable rather than aspirational: a plain
# `terraform destroy` refuses instead of taking the one artifact that costs GPU
# hours to regenerate. To tear the bucket down deliberately, delete this lifecycle
# block (or the resource) and apply -- see docs/runbook.md > Teardown.
#
# It blocks REPLACEMENT too, not just destruction, and `name`/`account_id` are
# both RequiresReplace in the provider. So changing var.project (or the account)
# turns the whole plan into "Instance cannot be destroyed" -- not just this
# resource, and -target can't route around it. That is the intended trade (the
# bucket outliving a rename is the point), but it means renaming the project is a
# deliberate two-step: drop this block, apply, rename, put it back.
#
# Note also that prevent_destroy guards the BUCKET, not the object. `make tape`
# overwrites tape.tar.zst in place on every run; if the tape ever becomes
# genuinely irreplaceable, that wants object versioning or a dated key, which is
# a different mechanism from this one.
resource "cloudflare_r2_bucket" "tape" {
  account_id = var.cloudflare_account_id
  name       = "${var.project}-tape"
  location   = "EEUR"

  lifecycle {
    prevent_destroy = true
  }
}
