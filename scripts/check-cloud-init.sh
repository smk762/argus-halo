#!/usr/bin/env bash
#
# Check what `terraform validate` cannot.
#
# Since #18 the service definitions live in stack/<tier>/ as plain files the
# hosts fetch at boot/update time, and user_data carries only config + the
# argus-update bootstrap. That splits the checks in two:
#
#   the templates (rendered with placeholders, since validate never expands
#   templatefile):
#   1. the rendered document is valid YAML with the write_files we expect,
#      and the embedded argus-update bootstrap is valid bash,
#   2. every ${VAR} the stack's compose files interpolate is defined by the
#      rendered .env + deploy.env -- the files and the templates are edited
#      separately, and an undefined variable becomes an empty string on the
#      host (an empty mount target, an unbound port) with no error anywhere,
#
#   the stack files (checked directly -- what you see is what ships):
#   3. compose files parse as YAML, scripts pass bash -n (and shellcheck if
#      installed), the Caddyfile adapts (`caddy validate`),
#   4. the /api/<service>/* route list agrees with waf.tf's rate-limit
#      expression and the @admin deny exists, actually refuses, and is ordered
#      ahead of the routes, which is the only thing making it fire,
#   5. the frontend's ARGUS_*_URL env values agree with the routed namespaces --
#      the third copy of that list; a stale one sends the browser to the
#      frontend's own catch-all with no error anywhere in this repo -- and
#   6. every pinned image tag answers a registry manifest request -- an
#      unpullable pin aborts `compose up` as a unit and nothing on the host
#      starts (runbook > 521/522). Same shape as preflight.tf: ask, don't
#      guess. Network-dependent, so transport failures warn and skip; a
#      definitive 404 fails.
#
# Checks 2 and 4-5 are the cross-file invariants nothing else in the repo
# enforces.
#
# Needs: terraform, python3 (+pyyaml), bash, curl. Uses `caddy` if present, else
# the caddy Docker image; skips the Caddyfile check with a warning if neither is
# available.

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
    stack_tarball_url     = "https://codeload.github.com/smk762/argus-halo/tar.gz/main"
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
    stack_tarball_url      = "https://codeload.github.com/smk762/argus-halo/tar.gz/main"
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
# Bootstrap-only user_data (#18): config + the fetcher. Anything beyond this
# set belongs in stack/<tier>/, where changing it does not replace the host.
expected = {
    "demo": {"/opt/argus/.env", "/opt/argus/deploy.env", "/opt/argus/argus-update"},
    "core": {"/opt/argus/.env", "/opt/argus/deploy.env", "/opt/argus/argus-update"},
}

for tier, want in expected.items():
    doc = yaml.safe_load(open(os.path.join(work, tier + ".yaml")))
    got = {f["path"] for f in doc["write_files"]}
    if got != want:
        sys.exit(f"error: {tier} write_files is {sorted(got)}, expected exactly "
                 f"{sorted(want)} -- structural files belong in stack/{tier}/, "
                 f"where a change is not a host replacement (#18)")
    for f in doc["write_files"]:
        name = os.path.basename(f["path"])
        out = os.path.join(work, f"{tier}--{name}")
        with open(out, "w") as fh:
            fh.write(f["content"])
    if not doc.get("runcmd"):
        sys.exit(f"error: {tier} cloud-init has no runcmd")
    if not any("argus-update" in " ".join(map(str, cmd)) for cmd in doc["runcmd"]):
        sys.exit(f"error: {tier} runcmd never invokes /opt/argus/argus-update -- "
                 f"the host would boot with no services at all")
    print(f"  {tier}: YAML ok, {len(got)} write_files, {len(doc['runcmd'])} runcmd entries")
PY
# envsubst ships in gettext-base; core's apply.sh renders prometheus.yml with it.
grep -q 'gettext-base' "$repo/modules/core/cloud-init.yaml.tftpl" \
  || die "core cloud-init must install gettext-base -- stack/core/apply.sh needs envsubst"

say "checking shell (stack scripts + rendered argus-update)"
shell_targets=("$repo"/stack/*/*.sh "$work"/demo--argus-update "$work"/core--argus-update)
for s in "${shell_targets[@]}"; do
  [ -e "$s" ] || continue
  bash -n "$s" || die "$(basename "$s") is not valid bash"
done
echo "  bash -n ok (${#shell_targets[@]} scripts)"
if command -v shellcheck >/dev/null; then
  shellcheck -S warning "$repo"/scripts/build-tape.sh "$0" "$repo"/stack/*/*.sh \
    "$work"/demo--argus-update "$work"/core--argus-update || die "shellcheck failed"
  echo "  shellcheck ok"
else
  warn "shellcheck not installed -- skipping lint"
fi

say "checking stack compose files parse and interpolate"
python3 - "$repo" "$work" <<'PY'
import re, sys, yaml

repo, work = sys.argv[1], sys.argv[2]

# Every ${VAR} a compose file (or the prometheus template) interpolates must be
# defined by the env files apply.sh sources: the rendered .env + deploy.env.
# The two sides are edited separately; an undefined variable silently becomes
# an empty string on the host.
for tier in ("core", "demo"):
    defined = set()
    for envfile in (f"{work}/{tier}--.env", f"{work}/{tier}--deploy.env"):
        for line in open(envfile):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                defined.add(line.split("=", 1)[0])
    def interpolated(path):
        # Per line, comments stripped: a ${VAR} mentioned in prose is not a
        # reference compose would expand.
        out = set()
        for line in open(path):
            if line.lstrip().startswith("#"):
                continue
            out |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", line))
        return out

    compose_path = f"{repo}/stack/{tier}/compose.yaml"
    yaml.safe_load(open(compose_path).read())  # an indentation slip fails here, not on the host
    used = interpolated(compose_path)
    if tier == "core":
        used |= interpolated(f"{repo}/stack/{tier}/prometheus.yml.tpl")
    missing = sorted(used - defined)
    if missing:
        sys.exit(f"error: stack/{tier} interpolates {missing}, which the rendered "
                 f".env + deploy.env never define -- on the host these become "
                 f"empty strings with no error anywhere")
    print(f"  {tier}: compose YAML ok, {len(used)} interpolated vars all defined")
PY

say "checking the Caddyfile adapts"
caddyfile="$repo/stack/demo/Caddyfile"
[ -f "$caddyfile" ] || die "no stack/demo/Caddyfile"
if command -v caddy >/dev/null; then
  DOMAIN=argus.example.test caddy validate --config "$caddyfile" --adapter caddyfile >/dev/null 2>&1 \
    || die "caddy validate failed on stack/demo/Caddyfile"
  echo "  Caddyfile: valid"
elif command -v docker >/dev/null; then
  docker run --rm -e DOMAIN=argus.example.test -v "$caddyfile:/etc/caddy/Caddyfile:ro" caddy:2 \
    caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    || die "caddy validate failed on stack/demo/Caddyfile"
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
    sys.exit("error: no `handle_path /prefix/* {` routes found in stack/demo/Caddyfile")

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

say "checking the frontend's ARGUS_*_URL env agrees with the routes"
python3 - "$repo/stack/demo/compose.yaml" "$caddyfile" <<'PY'
import re, sys, yaml

compose = yaml.safe_load(open(sys.argv[1]))
caddyfile = open(sys.argv[2]).read()

routed = {m.group(1) for m in
          re.finditer(r'^\s*handle_path\s+(/\S+?)/\*\s*\{', caddyfile, re.M)}

# The frontend hands these values to the BROWSER, which resolves them against
# the public origin -- so each one must be a namespace Caddy actually routes, or
# every API call it issues falls through to the frontend's own catch-all and
# gets HTML back, with nothing in this repo ever flagging it. Only the frontend
# service is checked: .env's ARGUS_LENS_URL is curator's server-side handoff
# (compose DNS, http://lens:8100), a different value on purpose.
env = compose["services"]["frontend"].get("environment") or []
urls = {}
for entry in env:
    key, _, value = str(entry).partition("=")
    if re.fullmatch(r"ARGUS_[A-Z0-9]+_URL", key):
        urls[key] = value
if not urls:
    sys.exit("error: the frontend service sets no ARGUS_*_URL -- studio 0.1.0+ resolves "
             "its API bases from the environment per request (argus-studio#56)")
stale = {k: v for k, v in urls.items() if v not in routed}
if stale:
    sys.exit(f"error: frontend ARGUS_*_URL values that match no routed namespace: {stale}; "
             f"routed namespaces are {sorted(routed)}. A stale value sends the browser to "
             f"the frontend catch-all -- HTML answers, not the API.")
missing = routed - set(urls.values())
if missing:
    sys.exit(f"error: routed namespaces with no frontend ARGUS_*_URL: {sorted(missing)} -- "
             f"the frontend cannot reach a namespace it is not told about")
print(f"  frontend ARGUS_*_URL values == routed namespaces ({len(urls)})")
PY

say "checking every pinned image tag is pullable"
# Pins live only inside the stack compose files, so a typo'd or unpublished
# tag passes fmt/validate/plan -- and then `docker compose up -d` fails as a
# unit on the host: nothing starts, Caddy never binds, Cloudflare serves
# 521/522 (the repo has the near-miss on record: argus-quarry v0.2.2 looked
# releasable but never published). Ask each registry for the manifest, exactly
# preflight.tf's move. Anonymous pull tokens suffice for public images; a
# transport failure warns and skips so an offline run still passes, a
# definitive 404 fails the build.
images="$(python3 - "$repo/stack/demo/compose.yaml" "$repo/stack/core/compose.yaml" <<'PY'
import sys, yaml
seen = []
for p in sys.argv[1:]:
    doc = yaml.safe_load(open(p))
    for svc in (doc.get("services") or {}).values():
        img = svc.get("image")
        if img and img not in seen:
            seen.append(img)
print("\n".join(seen))
PY
)"
while IFS= read -r image; do
  [ -n "$image" ] || continue
  ref="$image"; case "$ref" in *:*) ;; *) ref="$ref:latest";; esac
  name="${ref%:*}" tag="${ref##*:}"
  case "$name" in
    ghcr.io/*) registry="ghcr.io"; path="${name#ghcr.io/}"
               token_url="https://ghcr.io/token?scope=repository:$path:pull" ;;
    quay.io/*) registry="quay.io"; path="${name#quay.io/}"
               token_url="https://quay.io/v2/auth?service=quay.io&scope=repository:$path:pull" ;;
    */*)       registry="registry-1.docker.io"; path="$name"
               token_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:$path:pull" ;;
    *)         registry="registry-1.docker.io"; path="library/$name"
               token_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:$path:pull" ;;
  esac
  token="$(curl -fsS --max-time 15 "$token_url" 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"
  if [ -z "$token" ]; then
    warn "no anonymous pull token for $image -- skipping pullability check (network?)"
    continue
  fi
  code="$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://$registry/v2/$path/manifests/$tag" || true)"
  case "$code" in
    200) echo "  $image: pullable" ;;
    404) die "$image is NOT pullable (manifest 404). An unpullable pin aborts the whole
       stack at compose up -- nothing on the host starts (runbook > 521/522). Fix
       the tag before applying." ;;
    000|"") warn "no answer from $registry for $image -- skipping pullability check (network?)" ;;
    *)   warn "unexpected HTTP $code from $registry for $image -- not treating as missing" ;;
  esac
done <<< "$images"

say "all cloud-init checks passed"
