# Security model

The demo host is on the internet and assumed to be probed. These are the
controls, in the order a request meets them, and what checks each one.

| Layer | Control | Checked by |
|---|---|---|
| Cloudflare | Proxied record hides the origin; zone TLS is Full (strict) | `terraform test` |
| Cloudflare | 15 req/min per IP on captioning, scanning and upload | `terraform test`, `check-cloud-init.sh` |
| Hetzner firewall | demo: 80/443 open, SSH from `admin_ip`. core: SSH and Grafana from `admin_ip`, no data ports | `terraform test` |
| Variable validation | `admin_ip` must be a CIDR of /8 or longer, so `0.0.0.0/0` fails the plan | `terraform test` |
| Caddy | `/admin`, writes, outbound fetches, GPU work and `DELETE` refused before any route; body caps | `check-cloud-init.sh`, smoke test |
| Service | Each service's read-only switches and path containment | smoke test, `check-cloud-init.sh` |
| Container | Data mounted `:ro`; only Caddy publishes a port; each service holds only its own config | `check-cloud-init.sh`, smoke test |
| Network | Stores bind to the private interface of a second host | compose, runbook section 4 |

## The proxy is a passthrough

Caddy routes `/api/<service>/*` to each backend and strips the prefix, so every
endpoint a service exposes is reachable, including ones a future image adds.
Per-endpoint routing was tried and collided across services
([#8](https://github.com/smk762/argus-halo/issues/8)). The consequence is that
**moving an image pin is a security change**: a release that relaxes its own
gating would widen the public surface with no diff here.

`scripts/smoke-demo.py` is the control for that. It boots the tier from the real
compose file, Caddyfile and pins, then checks that:

- forge refuses training, proof refuses evaluation and writes, atlas refuses
  bakes and OSM fetches, and quarry refuses archive fetches, at the edge and
  again behind it;
- curator rejects absolute, relative and traversal paths on `/scan/folder`,
  `/folders`, `/thumb` and `/image`; refuses `/export` with no export root; and
  refuses `mode=move`;
- case changes, doubled slashes, `..` segments and percent-encoding do not slip
  past the edge refusals;
- lens and curator refuse cross-site writes;
- only lens holds the caption key.

It runs in CI on every pull request. Routes that remove things (curator purge
and delete, atlas purge, any `DELETE`) are **not** called, because a regression
would make the probe destructive. Their edge refusal is asserted statically by
`check-cloud-init.sh`.

## Known limits

- `ARGUS_CURATOR_UI_MODE=demo` is a frontend flag. It is not a boundary.
- Cloudflare matches raw paths while Caddy normalises them first, so
  `/api/lens//caption` is routed but not rate-limited unless URL normalisation
  is enabled on the zone. The plan allows a single rate-limit rule.
- `/api/curator/folders` and `/thumb` are not rate-limited: a folder view fires
  `thumb` once per tile.
- Generated secrets are in Terraform state, which is why state lives in HCP
  Terraform and `*.tfvars` is gitignored. They also reach the hosts in
  `user_data`, readable through the Hetzner metadata service from the host.
- Containment limits what a caller can reach. There is no authentication on the
  public API.
