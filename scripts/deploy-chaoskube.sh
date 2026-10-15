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
#   - EKS cluster running (complete-infra-up.sh already done)
#   - kubectl connected to cluster
#   - Helm installed
#   - Grafana Cloud alert rules configured
#   - Agent deployed (deploy-agent.sh already done)
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
CHAOSKUBE_VERSION="0.6.0"        # chart 0.6.0 = app 0.39.0 (latest stable)

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
# Scope update to this repo only — avoids GitHub timeouts from other repos
helm repo update chaoskube
echo "Repo ready: chaoskube"

# =============================================================================
# Step 2: Create chaos namespace
# =============================================================================
echo ""
echo "=== Step 2: Creating chaos namespace ==="
kubectl create namespace "$CHAOS_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace ready: $CHAOS_NAMESPACE"

# =============================================================================
# Step 3: Install chaoskube via Helm
#
# Key flags:
#   namespaces   — only kill pods in sre-ai-agent
#   interval     — how often to kill (default 2m)
#   dryRun       — log only, no actual kills (for testing)
#   minimumAge   — wait 30s before killing (lets pod stabilize first)
#
# NOTE: Do NOT set --set labels — it acts as a label selector and will filter
#       out pods that don't have an exact label match, causing zero kills.
#       Let chaoskube target all pods in the namespace.
#
# NOTE: Do NOT pre-create the ServiceAccount with kubectl — Helm must own it
#       to avoid ownership conflicts on re-runs (missing helm annotations).
# =============================================================================
echo ""
echo "=== Step 3: Installing chaoskube ==="

DRY_RUN_FLAG="false"
if [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_FLAG="true"
  echo "DRY_RUN=true — chaoskube will LOG kills but NOT execute them"
fi

# Build helm args — chaoskube 0.6.0 passes all chaoskube flags under chaoskube.args.*
# no-dry-run is a boolean flag: set it to "" to enable real kills, omit for dry-run
HELM_ARGS=(
  --namespace "$CHAOS_NAMESPACE"
  --version "$CHAOSKUBE_VERSION"
  --set chaoskube.args.interval="$CHAOS_INTERVAL"
  --set chaoskube.args.namespaces="$TARGET_NAMESPACE"
  --set chaoskube.args.minimum-age="30s"
  --set chaoskube.args.kinds="!DaemonSet"
  --set resources.requests.memory="32Mi"
  --set resources.requests.cpu="10m"
  --set resources.limits.memory="64Mi"
  --set resources.limits.cpu="100m"
  --timeout 5m
)

# Enable real kills only when not dry-run (flag presence = enabled, absence = dry-run)
if [ "$DRY_RUN_FLAG" = "false" ]; then
  HELM_ARGS+=(--set chaoskube.args.no-dry-run="")
fi

helm upgrade --install chaoskube chaoskube/chaoskube "${HELM_ARGS[@]}"

echo "chaoskube installed ✓"

# =============================================================================
# Step 4: Verify deployment
# =============================================================================
echo ""
echo "=== Step 4: Verifying chaoskube ==="
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
# Step 5: Show chaos targets
# =============================================================================
echo ""
echo "=== Step 5: Chaos targets in $TARGET_NAMESPACE ==="
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
echo "   4. Alert → webhook → POST http://${AGENT_LB:-<agent-lb>}/agent/triage"
echo "   5. LangGraph pipeline: alert_parser → runbook_retriever → diagnoser → rca_writer"
echo "   6. RCA logged to stdout + Grafana Cloud Loki"
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