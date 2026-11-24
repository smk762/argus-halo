# Monitoring

Prometheus and Grafana run on **core**, next to the stores — no extra host, so the €10.98/mo is unchanged. Prometheus scrapes both tiers over the private network:

- **hosts** — `node_exporter` on core and demo (port 9100 on each private address)
- **stores** — Postgres (`postgres_exporter`), Qdrant (`/metrics`), MinIO (`/minio/v2/metrics/cluster`, served token-free on the private net)

Only Grafana is exposed, and only to `admin_ip` — the same trust model as SSH, by a firewall rule rather than by construction, because it's an admin UI and not a data store. Prometheus and every exporter stay private; tunnel in to reach the Prometheus UI.

```bash
terraform output -raw grafana_password         # admin password (user: admin)
open "$(terraform output -raw grafana_url)"     # http://<core ip>:3000, from your admin IP
ssh -L "9090:$(terraform output -raw core_private_ip):9090" root@<core ip>       # then Prometheus at http://localhost:9090
```

Grafana ships with the Prometheus datasource auto-provisioned; add dashboards to taste.
