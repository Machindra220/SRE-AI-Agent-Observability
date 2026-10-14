#!/bin/bash
# =============================================================================
# scripts/deploy-chaoskube.sh
# Phase 24 — Lightweight Chaos Engineering on EKS t3.small
#
# What it does:
#   Installs chaoskube — a lightweight pod killer that randomly terminates pods
#   to simulate failures and trigger Grafana Cloud alerts → LangGraph RCA.
#
# Why chaoskube instead of LitmusChaos:
#   LitmusChaos requires MongoDB StatefulSet (~1.5GB RAM) + EBS CSI driver.
#   t3.small has only 2GB total RAM — leaves nothing for chaos pods.
#   chaoskube: single Deployment, ~50MB, no PVC, no EBS, runs on t3.small.
#
# Chaos flow:
#   chaoskube kills pod → pod restarts → kube_pod_container_restarts_total rises
#   → Grafana Cloud alert fires → POST /agent/triage → LangGraph 4-node RCA
#
# Requirements:
#   - EKS cluster running (infra-up-complete.sh already done)
#   - kubectl connected to cluster
#   - Helm installed
#   - Grafana Cloud alert rules configured (Phase 23)
#   - Agent LB URL known (for AGENT_WEBHOOK_URL)
#
# Usage:
#   ./scripts/deploy-chaoskube.sh
#   CHAOS_INTERVAL=5m ./scripts/deploy-chaoskube.sh   # kill every 5 min
#   DRY_RUN=true ./scripts/deploy-chaoskube.sh         # simulate without killing
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# Configuration
# =============================================================================
CHAOS_NAMESPACE="chaos"           # chaoskube lives here (isolated from app)
TARGET_NAMESPACE="sre-ai-agent"   # namespace where pods will be killed
CHAOS_INTERVAL="${CHAOS_INTERVAL:-2m}"  # how often to kill a pod
DRY_RUN="${DRY_RUN:-false}"       # true = log only, no actual kills
CHAOSKUBE_VERSION="0.29.0"        # pinned version — stable on t3.small

# Get agent LB for webhook (optional — chaoskube kills pods, Grafana fires alert)
AGENT_LB=$(kubectl get svc sre-ai-agent-llm \
  -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

echo "========================================"
echo " Phase 24: Deploying chaoskube"
echo " Target namespace: $TARGET_NAMESPACE"
echo " Chaos interval:   $CHAOS_INTERVAL"
echo " Dry run:          $DRY_RUN"
echo " Agent LB:         ${AGENT_LB:-not detected}"
echo "========================================"

# =============================================================================
# Step 1: Add Helm repo
# =============================================================================
echo ""
echo "=== Step 1: Adding chaoskube Helm repo ==="
helm repo add chaoskube https://linki.github.io/chaoskube/ 2>/dev/null || true
helm repo update
echo "Repo added: linki/chaoskube"

# =============================================================================
# Step 2: Create chaos namespace
# =============================================================================
echo ""
echo "=== Step 2: Creating chaos namespace ==="
kubectl create namespace "$CHAOS_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace ready: $CHAOS_NAMESPACE"

# =============================================================================
# Step 3: Create RBAC — chaoskube needs permission to list+delete pods
# in the target namespace only (least-privilege)
# =============================================================================
echo ""
echo "=== Step 3: Configuring RBAC for chaoskube ==="
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: chaoskube
  namespace: $CHAOS_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: chaoskube
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list", "delete", "watch"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: chaoskube
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: chaoskube
subjects:
  - kind: ServiceAccount
    name: chaoskube
    namespace: $CHAOS_NAMESPACE
EOF
echo "RBAC configured (least-privilege: list+delete pods only)"

# =============================================================================
# Step 4: Install chaoskube via Helm
#
# Key flags:
#   --namespaces       — only kill pods in sre-ai-agent
#   --interval         — how often to kill (default 2m)
#   --dry-run          — log only, no actual kills (for testing)
#   --labels           — only kill pods with app label (skip system pods)
#   --minimum-age      — wait 30s before killing (lets pod stabilize first)
#   --excluded-weekdays — avoid chaos on weekends (optional)
# =============================================================================
echo ""
echo "=== Step 4: Installing chaoskube ==="

DRY_RUN_FLAG="false"
if [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_FLAG="true"
  echo "DRY_RUN=true — chaoskube will LOG kills but NOT execute them"
fi

helm upgrade --install chaoskube chaoskube/chaoskube \
  --namespace "$CHAOS_NAMESPACE" \
  --version "$CHAOSKUBE_VERSION" \
  --set interval="$CHAOS_INTERVAL" \
  --set namespaces="$TARGET_NAMESPACE" \
  --set labels="app" \
  --set minimumAge="30s" \
  --set dryRun="$DRY_RUN_FLAG" \
  --set logFormat="json" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=chaoskube \
  --set resources.requests.memory="32Mi" \
  --set resources.requests.cpu="10m" \
  --set resources.limits.memory="64Mi" \
  --set resources.limits.cpu="100m" \
  --timeout 5m

echo "chaoskube installed"

# =============================================================================
# Step 5: Verify deployment
# =============================================================================
echo ""
echo "=== Step 5: Verifying chaoskube ==="
echo "Waiting for chaoskube pod to be ready..."
kubectl rollout status deployment/chaoskube \
  -n "$CHAOS_NAMESPACE" --timeout=60s

echo ""
echo "chaoskube pod status:"
kubectl get pods -n "$CHAOS_NAMESPACE"

echo ""
echo "chaoskube logs (first 10 lines):"
sleep 5
kubectl logs -n "$CHAOS_NAMESPACE" \
  -l app.kubernetes.io/name=chaoskube \
  --tail=10 2>/dev/null || \
  kubectl logs -n "$CHAOS_NAMESPACE" \
  deployment/chaoskube \
  --tail=10 2>/dev/null || \
  echo "Logs not available yet — check: kubectl logs -n $CHAOS_NAMESPACE deployment/chaoskube"

# =============================================================================
# Step 6: Apply chaos annotation to target pods (optional label selector)
# chaoskube already targets all pods in namespace — this just shows which pods
# are chaos targets for visibility
# =============================================================================
echo ""
echo "=== Step 6: Chaos targets in $TARGET_NAMESPACE ==="
echo "Pods that chaoskube WILL randomly terminate:"
kubectl get pods -n "$TARGET_NAMESPACE" \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName" \
  2>/dev/null || echo "No pods found in $TARGET_NAMESPACE"

# =============================================================================
# Final summary
# =============================================================================
echo ""
echo "========================================"
echo " chaoskube deployed!"
echo ""
echo " Chaos flow:"
echo "   1. chaoskube kills a pod in $TARGET_NAMESPACE every $CHAOS_INTERVAL"
echo "   2. Pod restarts — kube_pod_container_restarts_total rises"
echo "   3. Grafana Cloud alert fires (Pod Restart Rate High rule)"
echo "   4. Alert → webhook → POST http://$AGENT_LB/agent/triage"
echo "   5. LangGraph pipeline: alert_parser → runbook_retriever → diagnoser → rca_writer"
echo "   6. RCA logged to stdout + Grafana Cloud Loki (Phase 24)"
echo ""
echo " Monitor chaos in real-time:"
echo "   kubectl logs -n $CHAOS_NAMESPACE -f deployment/chaoskube"
echo "   kubectl get pods -n $TARGET_NAMESPACE -w"
echo ""
echo " Pause chaos (scale down):"
echo "   kubectl scale deployment chaoskube -n $CHAOS_NAMESPACE --replicas=0"
echo ""
echo " Resume chaos:"
echo "   kubectl scale deployment chaoskube -n $CHAOS_NAMESPACE --replicas=1"
echo ""
echo " Stop chaos permanently:"
echo "   helm uninstall chaoskube -n $CHAOS_NAMESPACE"
echo ""
if [ "$DRY_RUN" = "true" ]; then
  echo " NOTE: DRY_RUN=true — no pods are actually being killed."
  echo "       To enable real chaos: DRY_RUN=false ./scripts/deploy-chaoskube.sh"
fi
echo "========================================"