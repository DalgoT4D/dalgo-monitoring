# Dalgo monitoring

Dockerized monitoring stack for Dalgo. Two independent deployables:

| Directory             | Runs on                  | What it does                                                                 |
|-----------------------|--------------------------|------------------------------------------------------------------------------|
| `monitoring-server/`  | new monitoring EC2       | Prometheus + Grafana + postgres_exporter (scrapes prod RDS remotely)         |
| `prod-targets/`       | the prod Dalgo EC2       | node_exporter + process_exporter + celery_exporter                            |

Each directory has its own `docker-compose.yml` and `.env.example`. Clone the repo on each host, copy `.env.example` → `.env`, fill it in, and `docker compose up -d`.

What we monitor:
- Prod EC2 — hardware/OS metrics (node_exporter), per-process metrics (process_exporter), Celery tasks (celery_exporter)
- Prod RDS — postgres server metrics (postgres_exporter, run from the monitoring server)
- Dalgo Django app — `/prometheus/metrics` on `api.dalgo.org` (django-prometheus)

Public-facing TLS + reverse proxy is handled by the existing **`tech4dev-internal` ALB** in `vpc-060665f96234a5997`, not by a container in this stack. Grafana itself speaks plain HTTP on port 3000; the ALB terminates TLS at `https://monitoring.projecttech4dev.org/`.

---

## Monitoring server setup

### AWS-side prereqs (one-time)

Everything below assumes the new monitoring EC2 lives in **`vpc-060665f96234a5997`** (same VPC as the ALB and the prod EC2). Private subnet works; you'll need a NAT gateway for the EC2's outbound (docker pull, Google OAuth, SMTP, scraping `api.dalgo.org`).

1. **Target group** — HTTP, port 3000, healthcheck path `/api/health`, VPC `vpc-060665f96234a5997`. Register the new monitoring EC2 (target type: instance).
2. **Listener rule** on `tech4dev-internal:443` — host header `monitoring.projecttech4dev.org` → forward to that target group. Priority lower than the existing vaultwarden rule is fine (any free integer).
3. **DNS** — `monitoring.projecttech4dev.org` → CNAME (or Route53 ALIAS) → `tech4dev-internal-567714633.ap-south-1.elb.amazonaws.com`. No cert work needed — the ALB's wildcard `*.projecttech4dev.org` cert covers it.
4. **Security groups** — create one for the monitoring EC2 (e.g. `dalgo-monitoring-sg`) and wire it up:

   | On this resource                | Direction | Port              | Source/Dest                | Why                                  |
   |---------------------------------|-----------|-------------------|----------------------------|--------------------------------------|
   | monitoring EC2                  | inbound   | 3000              | ALB SG `sg-048da56c0332d295a` | ALB → Grafana                      |
   | monitoring EC2                  | outbound  | all               | 0.0.0.0/0 (default)        | docker pull, OAuth, SMTP, scrapes    |
   | prod EC2 (`dalgo-production-arm`) | inbound | 9100, 9256, 9808 | `dalgo-monitoring-sg`      | Prometheus scrapes node/process/celery |
   | prod RDS                        | inbound   | 5432              | `dalgo-monitoring-sg`      | postgres_exporter connects           |
   | metadata RDS                    | inbound   | 5432              | `dalgo-monitoring-sg`      | Grafana stores users/dashboards      |

5. **IAM** — attach the managed policy `AmazonSSMManagedInstanceCore` to the EC2's role so you can shell in via SSM Session Manager (no bastion or public SSH needed).

### Bring up the stack

Prereqs on the EC2: Docker + Docker Compose plugin installed.

```bash
git clone <this-repo>
cd dalgo-monitoring/monitoring-server
cp .env.example .env
# edit .env — see the variable notes inside
docker compose up -d
docker compose logs -f grafana
```

Once the ALB's target shows healthy, Grafana is reachable at `https://monitoring.projecttech4dev.org/`. First login uses the admin credentials from `.env`; after that, log in via Google.

### Google OAuth (Grafana)

1. In Google Cloud Console → APIs & Services → Credentials → **Create OAuth client ID** (type: Web application).
2. Authorized redirect URI: `https://monitoring.projecttech4dev.org/login/google`
3. Copy the client ID and secret into `.env` as `GF_AUTH_GOOGLE_CLIENT_ID` / `GF_AUTH_GOOGLE_CLIENT_SECRET`.
4. Restart Grafana: `docker compose up -d grafana`.

Only `@projecttech4dev.org` accounts can sign in (enforced by `GF_AUTH_GOOGLE_ALLOWED_DOMAINS` + `GF_AUTH_GOOGLE_HOSTED_DOMAIN`). New users land as **Viewer** (read-only); promote to Editor/Admin manually in the UI.

### Postgres exporter — RDS read-only user

Create a minimal-permission user on the prod RDS and put its DSN in `DATA_SOURCE_NAME`:

```sql
CREATE USER monitor WITH PASSWORD '...';
GRANT pg_monitor TO monitor;
```

### Grafana metadata DB

Grafana uses an existing external Postgres (not SQLite) for its metadata. On that RDS, create the database and user once:

```sql
CREATE DATABASE grafana;
CREATE USER grafana WITH PASSWORD '...';
GRANT ALL PRIVILEGES ON DATABASE grafana TO grafana;
\c grafana
GRANT ALL ON SCHEMA public TO grafana;
```

Then fill the `GF_DATABASE_*` variables in `.env`. Grafana auto-creates its schema on first boot.

### Dashboards and alerts (provisioning)

- Dashboard JSONs live in `monitoring-server/grafana/dashboards/` and are auto-loaded by Grafana via `provisioning/dashboards/dashboards.yml`.
- Alert rules live in `monitoring-server/grafana/provisioning/alerting/alert-rules.yaml`.
- Contact points (email destinations) are managed via the Grafana UI — not provisioned via file.
- `allowUiUpdates: true` is set, so dashboard edits in the UI persist to the metadata DB — but they will be **overwritten** by the JSON file on reload. Treat the files as the source of truth; commit changes.

To pull existing dashboards + alerts from the **old** Grafana into the repo, see `scripts/export-grafana.sh`.

---

## Prod targets setup

Prereqs on the prod EC2:
- Docker + Docker Compose plugin installed
- Stop the old systemd `node_exporter` service before starting the container (port 9100 conflict): `sudo systemctl disable --now node_exporter`
- Same for `process_exporter` if it's running under systemd
- SG inbound: 9100, 9256, 9808 **only** from `dalgo-monitoring-sg` (the new monitoring EC2's SG)

```bash
git clone <this-repo>
cd dalgo-monitoring/prod-targets
cp .env.example .env
# set CELERY_BROKER_URL to whatever the Django app uses
docker compose up -d
```

Verify locally on the prod EC2:
```bash
curl localhost:9100/metrics | head
curl localhost:9256/metrics | head
curl localhost:9808/metrics | head
```

---

## Migration from the old "everything-machine"

1. Do the AWS-side prereqs above (target group, listener rule, DNS, SGs).
2. Stand up the new monitoring server with empty Prometheus + fresh Grafana.
3. On a machine that can reach the old Grafana, run the export script:
   ```bash
   GRAFANA_URL=https://<old-grafana> \
   GRAFANA_TOKEN=<service-account-token> \
   ./scripts/export-grafana.sh
   ```
   Review the diff, commit the dashboards + alert files.
4. Pull on the new monitoring server and restart Grafana: `docker compose up -d grafana`.
5. Recreate the email contact point in the new Grafana UI (Alerting → Contact points). Re-route the imported alert rules to it.
6. Roll out `prod-targets/` on the prod EC2 (stop the old systemd exporters first).
7. Confirm Prometheus targets are green: in Grafana → Connections → Data sources → Prometheus → Test, then SSM into the EC2 and `curl localhost:9090/api/v1/targets | jq` for the full list.
8. Once dashboards look right, decommission the old "everything-machine" VM.

Metric history from the old Prometheus is **not** migrated — the previous setup had 30d retention, so anything older than that is already gone. If you do want the history, rsync `/var/lib/prometheus/` from the old VM into the new `prometheus_data` volume before first boot.

---

## Pinned versions

| Component          | Image                                          |
|--------------------|------------------------------------------------|
| Prometheus         | `prom/prometheus:v3.1.0`                       |
| Grafana            | `grafana/grafana:11.4.0`                       |
| postgres_exporter  | `prometheuscommunity/postgres-exporter:v0.17.1`|
| node_exporter      | `prom/node-exporter:v1.8.2`                    |
| process_exporter   | `ncabatoff/process-exporter:0.8.7`             |
| celery_exporter    | `ghcr.io/danihodovic/celery-exporter:0.12.2`   |
| cAdvisor           | `gcr.io/cadvisor/cadvisor:v0.49.1`             |
