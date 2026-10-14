#!/bin/bash
# =============================================================================
# scripts/deploy-litmuschaos.sh
# Deploys LitmusChaos to EKS via Helm
# LitmusChaos = chaos engineering platform for Kubernetes
# Usage: ./scripts/deploy-litmuschaos.sh
# =============================================================================
set -e

echo "========================================"
echo " Deploy LitmusChaos"
echo "========================================"

# -----------------------------------------------------------------------------
# Step 1: Add LitmusChaos Helm repo
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Add LitmusChaos Helm Repository ==="
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update
echo "LitmusChaos repo added"

# -----------------------------------------------------------------------------
# Step 2: Create litmus namespace
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Create litmus namespace ==="
kubectl create namespace litmus --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# Step 3: Install LitmusChaos
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Install LitmusChaos ==="
helm upgrade --install chaos litmuschaos/litmus \
  --namespace litmus \
  --set portal.frontend.service.type=LoadBalancer \
  --wait --timeout 10m

echo "LitmusChaos installed"

# -----------------------------------------------------------------------------
# Step 4: Wait for pods
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Wait for LitmusChaos pods ==="
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance=chaos \
  -n litmus \
  --timeout=300s

# -----------------------------------------------------------------------------
# Step 5: Final status
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 5: Final Status ==="
kubectl get pods -n litmus
echo ""
kubectl get svc -n litmus

LITMUS_LB=$(kubectl get svc chaos-litmus-frontend-service -n litmus \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo ""
echo "========================================"
echo " LitmusChaos Deployed!"
echo ""
echo " Portal: http://$LITMUS_LB:9091"
echo " Login:  admin / litmus"
echo ""
echo " Pre-built chaos scenarios:"
echo " 1. High Error Rate:"
echo "    kubectl set env deployment/sre-ai-agent ERROR_RATE=0.9 -n sre-ai-agent"
echo ""
echo " 2. High Latency:"
echo "    kubectl set env deployment/sre-ai-agent LATENCY_MS=3000 -n sre-ai-agent"
echo ""
echo " 3. CrashLoopBackOff:"
echo "    kubectl set image deployment/sre-ai-agent sre-ai-agent=bad:image -n sre-ai-agent"
echo ""
echo " 4. Scale to 0 (availability drop):"
echo "    kubectl scale deployment sre-ai-agent --replicas=0 -n sre-ai-agent"
echo ""
echo " Restore all:"
echo "    ./scripts/restore-all.sh"
echo "========================================"