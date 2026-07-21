# Edge rate limit for the endpoints worth metering. In `live` mode /caption and
# /scan reach lens/curator, and lens captions through a metered upstream (our
# Cerebras key). A public, keyed endpoint is a quota/cost-drain target, so cap it
# per client IP at Cloudflare -- abuse is absorbed at the edge before it ever
# touches the origin or the key. In the default `demo` mode these paths are
# unused, so this is belt-and-suspenders. See README > Environment.
#
# /upload is in scope too: it is the one unauthenticated WRITE curator exposes,
# and 15/min is far above any real use of it. Scan-root containment bounds where
# an upload lands, not how often it arrives, so containment is not a substitute
# for a cap. The body size is capped separately, in the demo Caddyfile.
#
# Deliberately NOT covered: /folders and /thumb (a folder view fires /thumb once
# per tile, so a 15/min cap would trip on a single legitimate page load), and
# /export (curator refuses it outright here -- ARGUS_CURATOR_EXPORT_ROOT is
# empty -- so there is no upstream cost to protect).
#
# The path list mirrors the @lens/@curator matchers in the demo cloud-init and
# must be kept in step with them. lower() is load-bearing: Caddy matches paths
# case-insensitively but the Rules language does not, so without it a request to
# /CAPTION/x routes to lens and skips this rule entirely.
#
# Free-plan Cloudflare allows a single rate-limiting rule; keep it to one.
resource "cloudflare_ruleset" "demo_ratelimit" {
  zone_id     = var.cloudflare_zone_id
  name        = "argus-halo edge rate limit"
  description = "Throttle the keyed caption/scan endpoints per client IP."
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [{
    ref         = "caption_scan_upload_ratelimit"
    description = "Cap /caption, /scan and /upload per IP (metered upstream + the one write endpoint)"
    expression  = "(lower(http.request.uri.path) in {\"/caption\" \"/scan\" \"/upload\"} or starts_with(lower(http.request.uri.path), \"/caption/\") or starts_with(lower(http.request.uri.path), \"/scan/\") or starts_with(lower(http.request.uri.path), \"/upload/\"))"
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
