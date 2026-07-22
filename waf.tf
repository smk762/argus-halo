# Edge rate limit for the endpoints worth metering. In `live` mode
# /api/lens/caption and /api/curator/scan reach lens/curator, and lens captions
# through a metered upstream (our Cerebras key). A public, keyed endpoint is a
# quota/cost-drain target, so cap it per client IP at Cloudflare -- abuse is
# absorbed at the edge before it ever touches the origin or the key. In the
# default `demo` mode these paths are unused, so this is belt-and-suspenders.
#
# /api/curator/upload is in scope too: it is the one unauthenticated WRITE curator
# exposes, and 15/min is far above any real use of it. Scan-root containment
# bounds where an upload lands, not how often it arrives, so containment is not a
# substitute for a cap. Body size is capped separately, in the demo Caddyfile.
#
# Deliberately NOT covered: /api/curator/folders and /api/curator/thumb (a folder
# view fires thumb once per tile, so a 15/min cap would trip on a single
# legitimate page load), and /api/curator/export (curator refuses it outright
# here -- ARGUS_CURATOR_EXPORT_ROOT is empty -- so there is no upstream cost to
# protect; whether it should be routed at all is #19).
#
# Paths are the EDGE paths, i.e. before Caddy's handle_path strips the
# `/api/<service>` prefix -- Cloudflare only ever sees the un-stripped form.
# They are checked against the demo Caddyfile's routes by
# scripts/check-cloud-init.sh. lower() is load-bearing: Caddy matches paths
# case-insensitively but the Rules language does not, so without it a request to
# /API/LENS/CAPTION/x routes to lens and skips this rule entirely.
#
# When proof lands (#8), decide explicitly whether POST /api/proof/run/stream
# belongs here or is provably 403'd by ARGUS_PROOF_READ_ONLY -- not neither.
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
    description = "Cap lens caption + curator scan/upload per IP (metered upstream + the one write endpoint)"
    expression  = "(lower(http.request.uri.path) in {\"/api/lens/caption\" \"/api/curator/scan\" \"/api/curator/upload\"} or starts_with(lower(http.request.uri.path), \"/api/lens/caption/\") or starts_with(lower(http.request.uri.path), \"/api/curator/scan/\") or starts_with(lower(http.request.uri.path), \"/api/curator/upload/\"))"
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
