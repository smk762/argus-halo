# Rendered to /opt/argus/prometheus.yml by stack/core/apply.sh (envsubst over
# deploy.env). Scrape targets carry host private IPs, which is exactly why this
# is a template rendered on the host and not user_data: the demo host's private
# IP changing must not force a core rebuild (#18).
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
  - job_name: node
    static_configs:
      - targets: ["${PRIVATE_IP}:9100"]
        labels: { tier: core }
      - targets: ["${DEMO_PRIVATE_IP}:9100"]
        labels: { tier: demo }
  - job_name: postgres
    static_configs:
      - targets: ["postgres-exporter:9187"]
  - job_name: qdrant
    metrics_path: /metrics
    static_configs:
      - targets: ["qdrant:6333"]
  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    static_configs:
      - targets: ["minio:9000"]
