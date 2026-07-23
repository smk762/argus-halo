#!/usr/bin/env bash
#
# Check what `terraform validate` cannot.
#
# validate never expands templatefile(), so everything that matters most in this
# repo -- the cloud-init YAML, the bash embedded in it, and the Caddyfile that
# routes the public entrypoint -- is invisible to CI. A mis-indented write_files
# block or a bad Caddy matcher passes green and is first observed as a host that
# doesn't boot, recoverable only by changing user_data again, i.e. by replacing
# the server. That is an expensive way to find a typo.
#
# So: render both templates with placeholder values, then assert
#   1. the rendered document is valid YAML with the write_files we expect,
#   2. every embedded script is syntactically valid bash (and shellcheck-clean,
#      if shellcheck is installed),
#   3. the Caddyfile adapts (`caddy validate`), and
#   4. the /api/<service>/* route list agrees with waf.tf's rate-limit expression
#      -- the one cross-file invariant nothing else in the repo enforces -- and
#      the @admin deny exists, actually refuses, and is ordered ahead of the
#      routes, which is the only thing making it fire.
#
# Needs: terraform, python3 (+pyyaml), bash. Uses `caddy` if present, else the
# caddy Docker image; skips check 3 with a warning if neither is available.

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v terraform >/dev/null || die "missing dependency: terraform"
command -v python3   >/dev/null || die "missing dependency: python3"
python3 -c 'import yaml' 2>/dev/null || die "python3 needs pyyaml (pip install pyyaml)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Placeholder values only -- this checks SHAPE, not content. They just have to be
# the right type and non-empty, so the rendered document is representative.
cat > "$work/render.tf" <<EOF
output "demo" {
  value = templatefile("$repo/modules/demo/cloud-init.yaml.tftpl", {
    domain                = "argus.example.test"
    cortex_pg_url         = "postgresql://argus:pw@10.0.1.10:5432/argus"
    cortex_qdrant_url     = "http://10.0.1.10:6333"
    cortex_s3_endpoint    = "http://10.0.1.10:9000"
    cortex_s3_bucket      = "argus-tape"
    minio_access_key      = "argus"
    minio_secret_key      = "placeholder"
    curator_scan_root     = "/srv/argus/samples"
    curator_export_root   = ""
    tape_dump_url         = "https://example.test/tape.tar.zst"
    quarry_home           = "/srv/argus/quarry"
    forge_export_root     = "/srv/argus/exports"
    proof_home            = "/srv/argus/proof"
    lens_caption_base_url = "https://api.cerebras.ai/v1"
    lens_caption_model    = "gemma-4-31b"
    lens_caption_api_key  = "placeholder"
  })
}

output "core" {
  value = templatefile("$repo/modules/core/cloud-init.yaml.tftpl", {
    private_ip             = "10.0.1.10"
    postgres_password      = "placeholder"
    minio_access_key       = "argus"
    minio_secret_key       = "placeholder"
    tape_dump_url          = "https://example.test/tape.tar.zst"
    s3_bucket              = "argus-tape"
    demo_private_ip        = "10.0.1.20"
    grafana_admin_password = "placeholder"
    grafana_port           = 3000
  })
}
EOF

say "rendering both cloud-init templates"
(
  cd "$work"
  terraform init -backend=false >/dev/null
  terraform apply -auto-approve >/dev/null
  terraform output -raw demo > demo.yaml
  terraform output -raw core > core.yaml
)

say "parsing rendered YAML and extracting embedded files"
python3 - "$work" <<'PY'
import sys, os, yaml

work = sys.argv[1]
expected = {
    "demo": {"/opt/argus/.env", "/opt/argus/Caddyfile", "/opt/argus/compose.yaml",
             "/opt/argus/restore-seed.sh"},
    "core": {"/opt/argus/.env", "/opt/argus/compose.yaml", "/opt/argus/prometheus.yml",
             "/opt/argus/grafana/provisioning/datasources/prometheus.yml",
             "/opt/argus/restore-tape.sh"},
}

for tier, want in expected.items():
    doc = yaml.safe_load(open(os.path.join(work, tier + ".yaml")))
    got = {f["path"] for f in doc["write_files"]}
    missing = want - got
    if missing:
        sys.exit(f"error: {tier} cloud-init lost write_files: {sorted(missing)}")
    # compose.yaml is itself YAML -- parse it, so an indentation slip in the
    # embedded document fails here rather than on the host.
    for f in doc["write_files"]:
        name = os.path.basename(f["path"])
        if name.endswith((".yaml", ".yml")):
            yaml.safe_load(f["content"])
        out = os.path.join(work, f"{tier}--{name}")
        with open(out, "w") as fh:
            fh.write(f["content"])
    if not doc.get("runcmd"):
        sys.exit(f"error: {tier} cloud-init has no runcmd")
    print(f"  {tier}: YAML ok, {len(got)} write_files, {len(doc['runcmd'])} runcmd entries")
PY

say "checking embedded shell"
# Both restore scripts: core's restore-tape.sh and the demo host's restore-seed.sh.
for s in "$work"/*restore-*.sh; do
  [ -e "$s" ] || continue
  bash -n "$s" || die "rendered $(basename "$s") is not valid bash"
  echo "  $(basename "$s"): bash -n ok"
done
if command -v shellcheck >/dev/null; then
  shellcheck -S warning "$repo/scripts/build-tape.sh" "$0" || die "shellcheck failed"
  echo "  scripts/*.sh: shellcheck ok"
else
  warn "shellcheck not installed -- skipping lint of scripts/*.sh"
fi

say "checking the Caddyfile adapts"
caddyfile="$work/demo--Caddyfile"
[ -f "$caddyfile" ] || die "no Caddyfile in the rendered demo cloud-init"
if command -v caddy >/dev/null; then
  caddy validate --config "$caddyfile" --adapter caddyfile >/dev/null 2>&1 \
    || die "caddy validate failed on the rendered Caddyfile"
  echo "  Caddyfile: valid"
elif command -v docker >/dev/null; then
  docker run --rm -v "$caddyfile:/etc/caddy/Caddyfile:ro" caddy:2 \
    caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    || die "caddy validate failed on the rendered Caddyfile"
  echo "  Caddyfile: valid (via docker)"
else
  warn "neither caddy nor docker available -- skipping Caddyfile validation"
fi

say "checking the route list agrees with waf.tf"
python3 - "$caddyfile" "$repo/waf.tf" <<'PY'
import re, sys

caddyfile, waf = (open(p).read() for p in sys.argv[1:3])

# Each backend is mounted under its own /api/<service>/* namespace, stripped by
# handle_path. Collect the namespaces; everything else falls through to the
# frontend by design.
routed = {m.group(1) for m in
          re.finditer(r'^\s*handle_path\s+(/\S+?)/\*\s*\{', caddyfile, re.M)}
if not routed:
    sys.exit("error: no `handle_path /prefix/* {` routes found in the rendered Caddyfile")

bad = sorted(p for p in routed if not re.fullmatch(r'/api/[a-z][a-z0-9-]*', p))
if bad:
    sys.exit(f"error: routes must be namespaced as /api/<service>; found {bad}. "
             f"Bare endpoint names collide across services -- see issue #8.")

# The namespaces are passthroughs, so every service's /admin subtree must be
# denied -- otherwise an image that ships an admin endpoint (lens already has
# POST /admin/unload) exposes it publicly on the next pull, with no diff here.
# One wildcard pair covers every namespace, present and future, and still does
# not catch /administrator; anchor the search so a comment cannot stand in for
# the real matcher.
m = re.search(r'^\s*@admin\s+path\s+([^\n]+)', caddyfile, re.M)
admin_paths = set(m.group(1).split()) if m else set()
want_admin = {"/api/*/admin", "/api/*/admin/*"}
if not want_admin <= admin_paths:
    sys.exit(f"error: @admin must deny the wildcard pair {sorted(want_admin)}; it covers "
             f"every /api/<svc> namespace, present and future, without catching "
             f"/administrator. Found: {sorted(admin_paths)}")

# Listing the paths is not refusing them. The block has to exist, answer with a
# 4xx, and not proxy -- otherwise the matcher above is decoration.
hm = re.search(r'handle\s+@admin\s*\{(.*?)\n\s*\}', caddyfile, re.S)
if not hm:
    sys.exit("error: no `handle @admin { ... }` block -- the @admin matcher denies nothing")
if "reverse_proxy" in hm.group(1) or not re.search(r'respond\b[^\n]*\s4\d\d\b', hm.group(1)):
    sys.exit(f"error: `handle @admin` must respond a 4xx and must not reverse_proxy, "
             f"else admin paths are served rather than denied. Found: {hm.group(1).strip()!r}")

# ...and it only fires if it comes FIRST. Caddy evaluates handle/handle_path in
# source order and the first match wins, so a deny sitting after a route is dead
# code: /api/lens/admin/unload would match /api/lens/* and proxy straight through.
first_route = re.search(r'^\s*handle_path\s', caddyfile, re.M)
if first_route and caddyfile.index("@admin") > first_route.start():
    sys.exit("error: the @admin deny must appear BEFORE the handle_path routes -- Caddy "
             "matches handle blocks in source order, so a deny placed after a route "
             "never fires and every /api/<svc>/admin is proxied through")

# A namespace added with a bare `handle` or an inline reverse_proxy would neither
# strip its prefix nor land in `routed`, so it would silently escape both the
# admin deny above and the waf agreement check below.
strays = re.findall(r'^\s*(?:handle|reverse_proxy)\s+(/api/\S+)', caddyfile, re.M)
if strays:
    sys.exit(f"error: /api routes must be spelled `handle_path /api/<svc>/* {{...}}`, not "
             f"bare handle or inline reverse_proxy: {sorted(set(strays))}")

# Anything waf.tf rate-limits must actually be a route, and must be lowercased
# there -- Caddy matches paths case-insensitively and the Rules language does not,
# so a rule written against the raw path is bypassed by changing a letter's case.
# Anchor on the attribute itself: splitting on the first "expression" substring
# picked up any comment that happened to use the word.
em = re.search(r'^\s*expression\s*=\s*"(.*)"\s*$', waf, re.M)
if not em:
    sys.exit("error: could not find the `expression = \"...\"` attribute in waf.tf")
expr = em.group(1).replace('\\"', '"')

in_set = re.search(r"in\s*\{([^}]*)\}", expr)
limited = set(re.findall(r'"([^"]+)"', in_set.group(1))) if in_set else set()
prefixes = set(re.findall(
    r'starts_with\(lower\(http\.request\.uri\.path\),\s*"([^"]+)"\)', expr))

if not limited:
    sys.exit("error: could not parse the exact-path set out of the waf.tf expression")
if "lower(http.request.uri.path)" not in expr:
    sys.exit("error: waf.tf must match on lower(http.request.uri.path) -- Caddy's "
             "path matching is case-insensitive, so a raw-path rule is bypassable")

# waf.tf sees EDGE paths -- handle_path strips the prefix only after Cloudflare
# has already matched -- so every rate-limited path must sit under a routed
# namespace, or the rule guards nothing.
orphans = sorted(p for p in limited
                 if not any(p.startswith(ns + "/") for ns in routed))
if orphans:
    sys.exit(f"error: waf.tf rate-limits paths under no routed namespace: {orphans}; "
             f"routed namespaces are {sorted(routed)}")

# Each rate-limited path needs BOTH forms: an exact match on /api/curator/scan
# alone leaves /api/curator/scan/folder uncapped.
want = {p.rstrip("/") + "/" for p in limited}
if prefixes != want:
    sys.exit(f"error: waf.tf exact-match and prefix-match sets disagree; "
             f"exact={sorted(limited)} implies prefixes {sorted(want)}, "
             f"found {sorted(prefixes)}")

print(f"  routed namespaces: {sorted(routed)}")
print(f"  rate-limited:      {sorted(limited)} (+ subtrees, lowercased)")
PY

say "all cloud-init checks passed"
