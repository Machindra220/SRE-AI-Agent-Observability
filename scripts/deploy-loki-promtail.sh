#!/bin/bash
# =============================================================================
# scripts/deploy-loki-promtail.sh
# Phase 24 — Ship EKS pod logs to Grafana Cloud Loki via Promtail
#
# What it does:
#   Deploys Promtail as a DaemonSet on all EKS nodes.
#   Scrapes logs from: sre-ai-agent, sre-ai-agent-llm, chaos, monitoring.
#   Ships logs to Grafana Cloud Loki with Kubernetes metadata labels.
#
# Log labels added to every log line:
#   {namespace, pod, container, app, node}
#
# After deployment — query logs in Grafana Cloud:
#   {namespace="sre-ai-agent"}               — all app logs
#   {app="sre-ai-agent"}                     — app pod logs only
#   {namespace="chaos"}                      — chaoskube kill events
#   {namespace="sre-ai-agent-llm"}           — LangGraph RCA logs
#
# Requirements:
#   - EKS cluster running and kubectl connected
#   - Grafana Cloud stack: scarletcanary2090 (ap-south-1 region)
#   - .env file with:
#       LOKI_USER_ID=1800194          ← Loki datasource User field
#       GRAFANA_CLOUD_API_KEY=<token> ← same token used for Prometheus remote_write
#
# Usage (credentials auto-loaded from .env):
#   ./scripts/deploy-loki-promtail.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env if not already loaded
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -o allexport
  source "$PROJECT_ROOT/.env"
  set +o allexport
fi

# =============================================================================
# Validate required credentials
# =============================================================================
if [ -z "${LOKI_USER_ID:-}" ]; then
  echo "ERROR: LOKI_USER_ID not set."
  echo "  Add to your .env file:"
  echo "    LOKI_USER_ID=1800194"
  echo "  (numeric User field from grafanacloud-scarletcanary2090-logs datasource settings)"
  exit 1
fi

# Support both GRAFANA_CLOUD_API_KEY (used in .env) and GRAFANA_CLOUD_API_TOKEN
GRAFANA_CLOUD_API_TOKEN="${GRAFANA_CLOUD_API_TOKEN:-${GRAFANA_CLOUD_API_KEY:-}}"

if [ -z "${GRAFANA_CLOUD_API_TOKEN:-}" ]; then
  echo "ERROR: Grafana Cloud API key not set."
  echo "  Add to your .env file:"
  echo "    GRAFANA_CLOUD_API_KEY=<your-token>"
  echo "  (same token used for Prometheus remote_write in Phase 23)"
  exit 1
fi

# =============================================================================
# Grafana Cloud Loki endpoint — ap-south-1 (scarletcanary2090 stack)
# =============================================================================
LOKI_URL="https://logs-prod-028.grafana.net/loki/api/v1/push"

echo "========================================"
echo " Phase 24: Deploying Promtail → Grafana Cloud Loki"
echo " Loki URL:     $LOKI_URL"
echo " Loki User ID: $LOKI_USER_ID"
echo " Scraping:     sre-ai-agent, sre-ai-agent-llm, chaos, monitoring"
echo "========================================"

# =============================================================================
# Step 1: Add Grafana Helm repo
# =============================================================================
echo ""
echo "=== Step 1: Adding Grafana Helm repo ==="
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
echo "Repo ready: grafana/promtail"

# =============================================================================
# Step 2: Create Promtail secret for Loki credentials
# =============================================================================
echo ""
echo "=== Step 2: Creating Loki credentials secret ==="
kubectl create namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic promtail-loki-secret \
  --from-literal=loki-user-id="$LOKI_USER_ID" \
  --from-literal=loki-token="$GRAFANA_CLOUD_API_TOKEN" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret created: promtail-loki-secret in monitoring namespace"

# =============================================================================
# Step 3: Install Promtail via Helm
# Credentials injected via --set (not from values.yaml — avoids secrets in git)
# =============================================================================
echo ""
echo "=== Step 3: Installing Promtail DaemonSet ==="

VALUES_FILE="$PROJECT_ROOT/infrastructure/helm/promtail/values.yaml"
if [ ! -f "$VALUES_FILE" ]; then
  echo "ERROR: values file not found: $VALUES_FILE"
  echo "  Expected at: infrastructure/helm/promtail/values.yaml"
  exit 1
fi

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  -f "$VALUES_FILE" \
  --set "config.clients[0].url=$LOKI_URL" \
  --set "config.clients[0].basic_auth.username=$LOKI_USER_ID" \
  --set "config.clients[0].basic_auth.password=$GRAFANA_CLOUD_API_TOKEN" \
  --timeout 5m

echo "Promtail DaemonSet installed"

# =============================================================================
# Step 4: Verify DaemonSet — one pod per node
# =============================================================================
echo ""
echo "=== Step 4: Verifying Promtail DaemonSet ==="
echo "Waiting 30s for pods to start..."
sleep 30

kubectl rollout status daemonset/promtail -n monitoring --timeout=120s || {
  echo "WARNING: Promtail rollout not complete — checking pod status..."
  kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
}

echo ""
echo "Promtail pods (should be one per node):"
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail \
  -o wide --no-headers | \
  awk '{printf "  Pod: %-50s Node: %s\n", $1, $7}'

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
POD_COUNT=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=promtail --no-headers 2>/dev/null | wc -l)
echo ""
echo "Nodes: $NODE_COUNT  |  Promtail pods: $POD_COUNT"
if [ "$POD_COUNT" -eq "$NODE_COUNT" ]; then
  echo "✓ One Promtail pod per node — DaemonSet healthy"
else
  echo "WARNING: Pod count ($POD_COUNT) != node count ($NODE_COUNT)"
  echo "  Check: kubectl describe daemonset promtail -n monitoring"
fi

# =============================================================================
# Step 5: Verify logs reaching Grafana Cloud
# Check Promtail logs for successful push
# =============================================================================
echo ""
echo "=== Step 5: Checking Promtail → Loki connectivity ==="
sleep 10

echo "Recent Promtail logs (looking for successful push):"
kubectl logs -n monitoring \
  -l app.kubernetes.io/name=promtail \
  --tail=20 2>/dev/null | grep -E "level|error|push|sent|batch" || \
  kubectl logs -n monitoring \
  daemonset/promtail \
  --tail=20 2>/dev/null || \
  echo "Logs not available yet — check: kubectl logs -n monitoring daemonset/promtail"

# =============================================================================
# Final summary
# =============================================================================
echo ""
echo "========================================"
echo " Promtail → Grafana Cloud Loki deployed!"
echo ""
echo " Query logs in Grafana Cloud Explore:"
echo "   Data source: Loki (grafanacloud-scarletcanary2090-logs)"
echo ""
echo "   All app logs:"
echo "     {namespace=\"sre-ai-agent\"}"
echo ""
echo "   Chaos kill events:"
echo "     {namespace=\"chaos\"}"
echo ""
echo "   LangGraph RCA output:"
echo "     {namespace=\"sre-ai-agent-llm\"}"
echo ""
echo "   Error logs across all namespaces:"
echo "     {namespace=~\"sre-ai-agent.*\"} |= \"ERROR\""
echo ""
echo "   Pod restart events (during chaos):"
echo "     {namespace=\"sre-ai-agent\"} |= \"restart\""
echo ""
echo " Check Promtail status:"
echo "   kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail"
echo "   kubectl logs -n monitoring daemonset/promtail --tail=50"
echo ""
echo " NEXT: Import Grafana Cloud chaos dashboard"
echo "   monitoring/grafana/grafana-chaos-dashboard.json"
echo "========================================"