# Edge rate limit for the two keyed endpoints. In `live` mode /caption/* and
# /scan/* reach lens/curator, and lens captions through a metered upstream (our
# Cerebras key). A public, keyed endpoint is a quota/cost-drain target, so cap it
# per client IP at Cloudflare -- abuse is absorbed at the edge before it ever
# touches the origin or the key. In the default `demo` mode these paths are
# unused, so this is belt-and-suspenders. See README > Environment.
#
# Deliberately NOT covering the other curator routes Caddy now proxies
# (/folders, /thumb, /upload, /export). They are cheap, key-free, and contained
# server-side by ARGUS_CURATOR_SCAN_ROOT -- and /thumb especially is called once
# per tile, so a folder view would trip a 15/min cap on its own. The rule guards
# the metered upstream, which is a different concern from path containment.
#
# Free-plan Cloudflare allows a single rate-limiting rule; keep it to one.
resource "cloudflare_ruleset" "demo_ratelimit" {
  zone_id     = var.cloudflare_zone_id
  name        = "argus-halo edge rate limit"
  description = "Throttle the keyed caption/scan endpoints per client IP."
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [{
    ref         = "caption_scan_ratelimit"
    description = "Cap /caption/* and /scan/* per IP (protects the upstream API key)"
    expression  = "(starts_with(http.request.uri.path, \"/caption/\") or starts_with(http.request.uri.path, \"/scan/\"))"
    action      = "block"
    ratelimit = {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 60
      requests_per_period = 15
      mitigation_timeout  = 60
      requests_to_origin  = true
    }
  }]
}
