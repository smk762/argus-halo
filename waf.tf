# Edge rate limit for the endpoints worth metering. In `live` mode
# /api/lens/caption and /api/curator/scan reach lens/curator, and lens captions
# through a metered upstream (our Cerebras key). A public, keyed endpoint is a
# quota/cost-drain target, so cap it per client IP at Cloudflare -- abuse is
# absorbed at the edge before it ever touches the origin or the key. In the
# default `demo` mode these paths are unused, so this is belt-and-suspenders.
#
# /api/curator/upload is in scope too: it is the one unauthenticated WRITE curator
# exposes, and the cap (3 per 10 s, about 18/min) is above any real use of it.
# Scan-root containment bounds where an upload lands, not how often it arrives,
# so containment is not a substitute for a cap. Body size is capped separately, in the demo Caddyfile.
#
# Deliberately NOT covered: /api/curator/folders and /api/curator/thumb (a folder
# view fires thumb once per tile, so this cap would trip on a single
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
# proof has landed (#8) and the question is settled: POST /api/proof/run/stream
# is 403'd by ARGUS_PROOF_READ_ONLY=1, so it is deliberately NOT metered here --
# there is no upstream cost or write behind it to protect. Atlas is the same
# shape: POST /api/atlas/bake and /osm are 403, and /controls fails at mkdir
# on the read-only jobs mount before gdalwarp, so it is not the metered path.
# The single free-plan rule stays on the caption key and the curator write.
#
# Known gap, tracked: this rule matches literal paths, but Caddy normalises
# `//`, `/./` and `/../` before routing, so /api/lens//caption reaches lens as
# /caption while matching none of the strings below. lower() closes the
# case-folding version of this; the structural version needs Cloudflare URL
# normalization enabled on the zone (Rules > Settings) to be closed here.
#
# Free-plan Cloudflare allows a single rate-limiting rule, and only 10 s for its
# period and block (the provider's plan-time dry run refuses anything else).
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
      period              = 10
      requests_per_period = 3
      mitigation_timeout  = 10
      requests_to_origin  = true
    }
  }]
}
