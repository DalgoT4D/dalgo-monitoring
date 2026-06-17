#!/usr/bin/env bash
# Create the 3 EC2 alerts (RAM/CPU/disk > 80%) via Grafana API.
# Created with X-Disable-Provenance: true so they're UI-editable, not provisioned.
#
# Usage (run on the monitoring EC2, or anywhere that can reach Grafana):
#   GRAFANA_URL=http://localhost:3000 \
#   GRAFANA_USER=admin \
#   GRAFANA_PASS=... \
#   ./scripts/create-alerts.sh

set -euo pipefail

: "${GRAFANA_URL:=http://localhost:3000}"
: "${GRAFANA_USER:=admin}"
: "${GRAFANA_PASS:?set GRAFANA_PASS}"

auth=(-u "${GRAFANA_USER}:${GRAFANA_PASS}")

echo "==> Looking up Prometheus datasource UID"
DS_UID=$(curl -fsSL "${auth[@]}" "${GRAFANA_URL}/api/datasources/name/Prometheus" | jq -r .uid)
echo "    DS_UID=${DS_UID}"

FOLDER_TITLE="alerts"
echo "==> Looking up / creating folder '${FOLDER_TITLE}'"
FOLDER_UID=$(curl -fsSL "${auth[@]}" "${GRAFANA_URL}/api/folders" \
  | jq -r --arg t "$FOLDER_TITLE" '.[] | select(.title==$t) | .uid' | head -1)

if [ -z "${FOLDER_UID}" ]; then
  echo "    not found, creating..."
  FOLDER_UID=$(curl -fsSL "${auth[@]}" -X POST \
       -H "Content-Type: application/json" \
       -d "{\"title\":\"${FOLDER_TITLE}\"}" \
       "${GRAFANA_URL}/api/folders" | jq -r .uid)
fi
echo "    FOLDER_UID=${FOLDER_UID}"

create_alert() {
  local title="$1" expr="$2" reducer_ref="$3" desc="$4" summary="$5"
  echo "==> Creating alert: ${title}"
  jq -n \
    --arg title "$title" \
    --arg ds "$DS_UID" \
    --arg folder "$FOLDER_UID" \
    --arg expr "$expr" \
    --arg reducer_ref "$reducer_ref" \
    --arg desc "$desc" \
    --arg summary "$summary" \
    '{
      title: $title,
      ruleGroup: "ec2-monitoring",
      folderUID: $folder,
      condition: "C",
      noDataState: "NoData",
      execErrState: "Error",
      for: "0s",
      orgID: 1,
      data: [
        {
          refId: $reducer_ref,
          relativeTimeRange: {from: 60, to: 0},
          datasourceUid: $ds,
          model: {
            datasource: {type: "prometheus", uid: $ds},
            editorMode: "code",
            expr: $expr,
            instant: true,
            intervalMs: 1000,
            maxDataPoints: 43200,
            range: false,
            refId: $reducer_ref
          }
        },
        {
          refId: "B",
          relativeTimeRange: {from: 60, to: 0},
          datasourceUid: "__expr__",
          model: {
            conditions: [{
              evaluator: {params: [], type: "gt"},
              operator: {type: "and"},
              query: {params: ["B"]},
              reducer: {params: [], type: "last"},
              type: "query"
            }],
            datasource: {type: "__expr__", uid: "__expr__"},
            expression: $reducer_ref,
            intervalMs: 1000,
            maxDataPoints: 43200,
            reducer: "last",
            refId: "B",
            type: "reduce"
          }
        },
        {
          refId: "C",
          relativeTimeRange: {from: 60, to: 0},
          datasourceUid: "__expr__",
          model: {
            conditions: [{
              evaluator: {params: [80], type: "gt"},
              operator: {type: "and"},
              query: {params: ["C"]},
              reducer: {params: [], type: "last"},
              type: "query"
            }],
            datasource: {type: "__expr__", uid: "__expr__"},
            expression: "B",
            intervalMs: 1000,
            maxDataPoints: 43200,
            refId: "C",
            type: "threshold"
          }
        }
      ],
      annotations: {
        description: $desc,
        summary: $summary
      },
      labels: {},
      isPaused: false
    }' | curl -fsSL "${auth[@]}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-Disable-Provenance: true" \
        -d @- \
        "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
        | jq -r '"    created uid=\(.uid)"'
}

RAM_EXPR='((node_memory_MemTotal_bytes{instance="dalgo-production-ec2",job="node_exporter"} - node_memory_MemFree_bytes{instance="dalgo-production-ec2",job="node_exporter"} - (node_memory_Cached_bytes{instance="dalgo-production-ec2",job="node_exporter"} + node_memory_Buffers_bytes{instance="dalgo-production-ec2",job="node_exporter"} + node_memory_SReclaimable_bytes{instance="dalgo-production-ec2",job="node_exporter"}) + (node_memory_SwapTotal_bytes{instance="dalgo-production-ec2",job="node_exporter"} - node_memory_SwapFree_bytes{instance="dalgo-production-ec2",job="node_exporter"}) ) / (node_memory_MemTotal_bytes{instance="dalgo-production-ec2",job="node_exporter"} + node_memory_SwapTotal_bytes{instance="dalgo-production-ec2",job="node_exporter"})) * 100'

CPU_EXPR='sum by(instance) (irate(node_cpu_seconds_total{instance="dalgo-production-ec2",job="node_exporter", mode="user"}[5m])) / on(instance) group_left sum by (instance)((irate(node_cpu_seconds_total{instance="dalgo-production-ec2",job="node_exporter"}[5m]))) * 100'

DISK_EXPR='100 - ((node_filesystem_avail_bytes{instance="dalgo-production-ec2",job="node_exporter",mountpoint="/",fstype!="rootfs"} * 100) / node_filesystem_size_bytes{instance="dalgo-production-ec2",job="node_exporter",mountpoint="/",fstype!="rootfs"})'

create_alert "dalgo-production-ec2-ram" "$RAM_EXPR" "memory_used" \
  'The RAM at this moment was {{ index $values "B" }}' \
  'Alerted when RAM usage exceeds 80 percent'

create_alert "dalgo-production-ec2-cpu" "$CPU_EXPR" "cpu_used" \
  'The CPU% at this moment was {{ index $values "B" }}' \
  'Alerted when CPU usage exceeds 80 percent'

create_alert "dalgo-production-ec2-disk-space" "$DISK_EXPR" "disk_used" \
  'The Disk space at this moment was {{ index $values "B" }}' \
  'Alerted when Disk space exceeds 80 percent'

echo
echo "Done. Verify in UI: Alerting -> Alert rules -> folder '${FOLDER_TITLE}'"
echo "All 3 alerts should be created and UI-editable (no lock icon)."
