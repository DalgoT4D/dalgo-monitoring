#!/usr/bin/env bash
# Export dashboards and alert rules from the OLD Grafana instance so they can be
# committed to this repo and re-provisioned on the new dockerized stack.
#
# Usage:
#   GRAFANA_URL=https://old-grafana.example.com \
#   GRAFANA_TOKEN=glsa_... \
#   ./scripts/export-grafana.sh
#
# Create the token at: <old-grafana>/org/serviceaccounts (give Admin role).
# Output:
#   monitoring-server/grafana/dashboards/*.json
#   monitoring-server/grafana/provisioning/alerting/alert-rules.yaml

set -euo pipefail

: "${GRAFANA_URL:?set GRAFANA_URL}"
: "${GRAFANA_TOKEN:?set GRAFANA_TOKEN}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DASH_DIR="$REPO_ROOT/monitoring-server/grafana/dashboards"
ALERT_DIR="$REPO_ROOT/monitoring-server/grafana/provisioning/alerting"

mkdir -p "$DASH_DIR" "$ALERT_DIR"

auth=(-H "Authorization: Bearer $GRAFANA_TOKEN")

echo "==> Listing dashboards"
uids=$(curl -fsSL "${auth[@]}" "$GRAFANA_URL/api/search?type=dash-db" | jq -r '.[].uid')

for uid in $uids; do
  echo "==> Exporting dashboard $uid"
  payload=$(curl -fsSL "${auth[@]}" "$GRAFANA_URL/api/dashboards/uid/$uid")
  title=$(echo "$payload" | jq -r '.dashboard.title' | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  # Strip server-specific ids so the import is clean.
  echo "$payload" | jq '.dashboard | .id = null' > "$DASH_DIR/${title}-${uid}.json"
done

echo "==> Exporting alert rules"
curl -fsSL "${auth[@]}" "$GRAFANA_URL/api/v1/provisioning/alert-rules/export?format=yaml" \
  > "$ALERT_DIR/alert-rules.yaml"

echo "==> Exporting contact points"
curl -fsSL "${auth[@]}" "$GRAFANA_URL/api/v1/provisioning/contact-points/export?format=yaml" \
  > "$ALERT_DIR/contact-points.yaml"

echo "==> Exporting notification policies"
curl -fsSL "${auth[@]}" "$GRAFANA_URL/api/v1/provisioning/policies/export?format=yaml" \
  > "$ALERT_DIR/policies.yaml"

echo
echo "Done. Review the files under monitoring-server/grafana/ and commit them."
