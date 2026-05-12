# Agent guidance

This repository is **git-first homelab observability**: Grafana Cloud for UI and storage, **Grafana Alloy** on a Proxmox LXC for ingestion, **Terraform** for Cloud-side resources, dashboard JSON under **`dashboards/`**.

## Read in this order

| Doc | Use |
|-----|-----|
| [README.md](README.md) | Architecture, setup, secrets (direnv `.envrc`), Terraform, Alloy, kiosk (public dashboard), CI |
| [CLAUDE.md](CLAUDE.md) | Query patterns, UIDs, `node_exporter` model, conventions — not duplicate setup |
| [terraform/README.md](terraform/README.md) | State, imports, extending Terraform |
| [CONTRIBUTING.md](CONTRIBUTING.md) | PR expectations |

Cursor loads **[.cursor/rules/read-docs-first.mdc](.cursor/rules/read-docs-first.mdc)** as an always-on reminder.

## Quick facts

- **Logs:** Firewalla Promtail → Alloy `loki.source.api` on **:3100** → Grafana Cloud Loki (`GRAFANA_CLOUD_LOGS_*`).
- **Metrics:** Alloy blackbox + node + HA scrapes → Grafana Cloud Mimir (`GRAFANA_CLOUD_METRICS_*`).
- **Dashboards:** Edit `dashboards/*.json`, then `cd terraform && terraform plan && terraform apply`.
- **Secrets:** Never commit `.envrc`, `alloy/ha_token`, or `terraform/*.tfstate`.

## grafana-assistant CLI (optional)

`grafana-assistant` targets Grafana Cloud with `GRAFANA_SA_TOKEN` / `GRAFANA_AUTH`. Browser `auth` may fail on some stacks; service account tokens work for the Grafana HTTP API and Terraform.
