#!/bin/bash
# =============================================================================
# scripts/deploy-monitoring.sh
# Deploys Prometheus + Grafana to EKS via Helm
# Also configures Grafana with Prometheus data source automatically
# Usage: ./scripts/deploy-monitoring.sh
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo " Deploy Monitoring Stack (Prometheus + Grafana)"
echo "========================================"

# -----------------------------------------------------------------------------
# Step 1: Add Helm repos
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Add Helm Repositories ==="
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
echo "Helm repos updated"

# -----------------------------------------------------------------------------
# Step 2: Create monitoring namespace
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Create monitoring namespace ==="
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# Step 3: Install Prometheus
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Install Prometheus ==="
helm upgrade --install prometheus \
  prometheus-community/prometheus \
  --namespace monitoring \
  --set server.service.type=LoadBalancer \
  --set server.persistentVolume.enabled=false \
  --set alertmanager.enabled=false \
  --wait --timeout 5m

echo "Prometheus installed"

# -----------------------------------------------------------------------------
# Step 4: Install Grafana
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Install Grafana ==="

# Get Prometheus service URL for auto-datasource
PROM_URL="http://prometheus-server.monitoring.svc.cluster.local"

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --set service.type=LoadBalancer \
  --set adminPassword=admin \
  --set datasources."datasources\.yaml".apiVersion=1 \
  --set datasources."datasources\.yaml".datasources[0].name=Prometheus \
  --set datasources."datasources\.yaml".datasources[0].type=prometheus \
  --set datasources."datasources\.yaml".datasources[0].url=$PROM_URL \
  --set datasources."datasources\.yaml".datasources[0].isDefault=true \
  --wait --timeout 5m

echo "Grafana installed with Prometheus datasource pre-configured"

# -----------------------------------------------------------------------------
# Step 5: Import AI Quality Dashboard
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 5: Import AI Quality Dashboard ==="

# Wait for Grafana LB
sleep 30
GRAFANA_LB=$(kubectl get svc grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

if [ "$GRAFANA_LB" != "pending" ]; then
  # Import dashboard via Grafana API
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -u admin:admin \
    "http://$GRAFANA_LB/api/dashboards/import" \
    -d "{
      \"dashboard\": $(cat $PROJECT_ROOT/monitoring/grafana/sre-ai-agent-dashboard.json),
      \"overwrite\": true,
      \"folderId\": 0
    }" | python3 -m json.tool 2>/dev/null || echo "Dashboard import — open Grafana UI to import manually"
fi

# -----------------------------------------------------------------------------
# Step 6: Final status
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 6: Final Status ==="
kubectl get pods -n monitoring
echo ""
kubectl get svc -n monitoring

PROM_LB=$(kubectl get svc prometheus-server -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
GRAFANA_LB=$(kubectl get svc grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo ""
echo "========================================"
echo " Monitoring Stack Deployed!"
echo ""
echo " Prometheus: http://$PROM_LB"
echo " Grafana:    http://$GRAFANA_LB"
echo "             Login: admin / admin"
echo ""
echo " Prometheus datasource pre-configured in Grafana"
echo " Import dashboard from:"
echo " monitoring/grafana/sre-ai-agent-dashboard.json"
echo "========================================"