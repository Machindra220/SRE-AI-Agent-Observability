#!/bin/bash
# =============================================================================
# scripts/infra-down.sh
# Teardown — mirrors infra-up-complete.sh in REVERSE order
#
# Destroys:
#   1. Helm releases (kube-prometheus-stack, aws-load-balancer-controller)
#   2. EBS CSI addon
#   3. Kubernetes secrets (monitoring, sre-ai-agent, sre-ai-agent-llm)
#   4. Namespaces (sre-ai-agent, sre-ai-agent-llm, monitoring, chaos)
#   5. IRSA service accounts (ALB + EBS CSI)
#   6. EKS node groups (agent-nodes, app-nodes)
#   7. EKS cluster
#   8. IAM policy (AWSLoadBalancerControllerIAMPolicy-<cluster>)
#
# Usage:
#   ./scripts/infra-down.sh
#   ./scripts/infra-down.sh --force      # skip confirmation prompt
#
# WARNING: This is IRREVERSIBLE. All data (pgvector, logs, secrets) will be lost.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step() {
  echo -e "\n${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN} $*${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
}

# ── Same infra config as infra-up-complete.sh ───────────────────────────────
AWS_REGION="ap-south-1"
CLUSTER_NAME="sre-ai-agent-cluster"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || { err "Could not resolve AWS account ID — check aws credentials"; exit 1; }

POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# =============================================================================
# Confirmation guard
# =============================================================================
echo -e "${RED}"
echo "  ██████╗ ███████╗███████╗████████╗██████╗  ██████╗ ██╗   ██╗"
echo "  ██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗╚██╗ ██╔╝"
echo "  ██║  ██║█████╗  ███████╗   ██║   ██████╔╝██║   ██║ ╚████╔╝ "
echo "  ██║  ██║██╔══╝  ╚════██║   ██║   ██╔══██╗██║   ██║  ╚██╔╝  "
echo "  ██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╔╝   ██║   "
echo "  ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝    ╚═╝  "
echo -e "${NC}"
echo -e "${RED}  This will permanently delete:${NC}"
echo -e "    • EKS cluster:    ${YELLOW}$CLUSTER_NAME${NC}"
echo -e "    • Region:         ${YELLOW}$AWS_REGION${NC}"
echo -e "    • AWS account:    ${YELLOW}$AWS_ACCOUNT_ID${NC}"
echo -e "    • All namespaces, secrets, PVCs, load balancers"
echo -e "    • Node groups: agent-nodes, app-nodes"
echo -e "    • IAM policy: $POLICY_NAME"
echo ""

if [ "$FORCE" = false ]; then
  read -r -p "  Type the cluster name to confirm deletion [${CLUSTER_NAME}]: " CONFIRM
  if [ "$CONFIRM" != "$CLUSTER_NAME" ]; then
    echo ""
    warn "Confirmation mismatch — aborting. Nothing was deleted."
    exit 0
  fi
fi

# Ensure kubeconfig points to this cluster
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" &>/dev/null \
  || warn "Could not update kubeconfig — cluster may already be gone; continuing teardown"

echo ""
log "Starting teardown of $CLUSTER_NAME  (reverse of infra-up-complete.sh)"

# =============================================================================
# Step 1 — Uninstall kube-prometheus-stack
# (Must go first — it owns ServiceMonitors, PrometheusRules, and PVCs)
# =============================================================================
step "Step 1 — Uninstalling kube-prometheus-stack"

if helm status kube-prometheus-stack -n monitoring &>/dev/null; then
  helm uninstall kube-prometheus-stack --namespace monitoring --timeout 5m
  log "kube-prometheus-stack uninstalled ✓"
else
  warn "kube-prometheus-stack not found — skipping"
fi

# Delete any leftover CRDs (they survive helm uninstall by design)
for CRD in \
  alertmanagerconfigs.monitoring.coreos.com \
  alertmanagers.monitoring.coreos.com \
  podmonitors.monitoring.coreos.com \
  probes.monitoring.coreos.com \
  prometheusagents.monitoring.coreos.com \
  prometheuses.monitoring.coreos.com \
  prometheusrules.monitoring.coreos.com \
  scrapeconfigs.monitoring.coreos.com \
  servicemonitors.monitoring.coreos.com \
  thanosrulers.monitoring.coreos.com; do
  kubectl delete crd "$CRD" --ignore-not-found=true
done
log "Prometheus CRDs removed ✓"

# =============================================================================
# Step 2 — Uninstall AWS Load Balancer Controller
# (Before deleting namespaces — controller manages ALB/NLB resources)
# =============================================================================
step "Step 2 — Uninstalling AWS Load Balancer Controller"

if helm status aws-load-balancer-controller -n kube-system &>/dev/null; then
  helm uninstall aws-load-balancer-controller --namespace kube-system --timeout 5m
  log "AWS Load Balancer Controller uninstalled ✓"
else
  warn "AWS Load Balancer Controller not found — skipping"
fi

# Wait for any ALBs/NLBs provisioned by the controller to be deprovisioned
log "Waiting 30s for AWS load balancers to deprovision..."
sleep 30

# =============================================================================
# Step 3 — Remove EBS CSI addon
# (Before node groups — CSI driver needs nodes to gracefully terminate)
# =============================================================================
step "Step 3 — Removing EBS CSI Driver addon"

if aws eks describe-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --region "$AWS_REGION" &>/dev/null; then
  aws eks delete-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --region "$AWS_REGION"
  log "EBS CSI addon deletion initiated ✓"
  # Wait for addon to be fully removed
  log "Waiting for EBS CSI addon removal..."
  aws eks wait addon-deleted \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --region "$AWS_REGION" 2>/dev/null || true
else
  warn "EBS CSI addon not found — skipping"
fi

# =============================================================================
# Step 4 — Delete Kubernetes secrets
# =============================================================================
step "Step 4 — Deleting Kubernetes secrets"

# monitoring
for SECRET in grafana-cloud-secret; do
  kubectl delete secret "$SECRET" -n monitoring --ignore-not-found=true
  log "Deleted secret: monitoring/$SECRET ✓"
done

# sre-ai-agent-llm
for SECRET in gemini-api-secret ecr-pull-secret; do
  kubectl delete secret "$SECRET" -n sre-ai-agent-llm --ignore-not-found=true
  log "Deleted secret: sre-ai-agent-llm/$SECRET ✓"
done

# sre-ai-agent
for SECRET in ecr-pull-secret; do
  kubectl delete secret "$SECRET" -n sre-ai-agent --ignore-not-found=true
  log "Deleted secret: sre-ai-agent/$SECRET ✓"
done

# =============================================================================
# Step 5 — Delete namespaces
# (This deletes ALL resources inside: deployments, services, PVCs, configmaps)
# =============================================================================
step "Step 5 — Deleting namespaces"

for NS in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
  if kubectl get namespace "$NS" &>/dev/null; then
    kubectl delete namespace "$NS" --timeout=120s
    log "Namespace deleted: $NS ✓"
  else
    warn "Namespace '$NS' not found — skipping"
  fi
done

# =============================================================================
# Step 6 — Delete IRSA service accounts
# =============================================================================
step "Step 6 — Deleting IRSA service accounts"

eksctl delete iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --name aws-load-balancer-controller \
  --namespace kube-system \
  --region "$AWS_REGION" \
  2>/dev/null && log "ALB IRSA deleted ✓" || warn "ALB IRSA not found — skipping"

eksctl delete iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --region "$AWS_REGION" \
  2>/dev/null && log "EBS CSI IRSA deleted ✓" || warn "EBS CSI IRSA not found — skipping"

# =============================================================================
# Step 7 — Delete node groups
# (agent-nodes first — tainted nodes, easier to drain; then app-nodes)
# =============================================================================
step "Step 7 — Deleting node groups"

for NG in agent-nodes app-nodes; do
  if eksctl get nodegroup \
    --cluster "$CLUSTER_NAME" \
    --name "$NG" \
    --region "$AWS_REGION" &>/dev/null; then
    log "Deleting node group: $NG (this may take 3–5 min)..."
    eksctl delete nodegroup \
      --cluster "$CLUSTER_NAME" \
      --name "$NG" \
      --region "$AWS_REGION" \
      --wait
    log "Node group deleted: $NG ✓"
  else
    warn "Node group '$NG' not found — skipping"
  fi
done

# =============================================================================
# Step 8 — Delete EKS cluster
# =============================================================================
step "Step 8 — Deleting EKS cluster: $CLUSTER_NAME"

if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
  log "Deleting cluster (this may take 10–15 min)..."
  eksctl delete cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --wait
  log "EKS cluster deleted ✓"
else
  warn "Cluster '$CLUSTER_NAME' not found — skipping"
fi

# =============================================================================
# Step 9 — Delete IAM policy
# (Last — policy is no longer needed after all role attachments are gone)
# =============================================================================
step "Step 9 — Deleting IAM policy"

if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  # Detach from all entities first
  ATTACHED_ROLES=$(aws iam list-entities-for-policy \
    --policy-arn "$POLICY_ARN" \
    --entity-filter Role \
    --query 'PolicyRoles[].RoleName' \
    --output text 2>/dev/null || echo "")

  for ROLE in $ATTACHED_ROLES; do
    aws iam detach-role-policy \
      --role-name "$ROLE" \
      --policy-arn "$POLICY_ARN" \
      2>/dev/null && log "Detached policy from role: $ROLE ✓" || true
  done

  aws iam delete-policy --policy-arn "$POLICY_ARN"
  log "IAM policy deleted: $POLICY_NAME ✓"
else
  warn "IAM policy not found — skipping"
fi

# =============================================================================
# Done
# =============================================================================
step "Teardown complete ✓"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  All resources for '$CLUSTER_NAME' removed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Resources cleaned up:"
echo "    ✓ Helm:          kube-prometheus-stack, aws-load-balancer-controller"
echo "    ✓ Addon:         aws-ebs-csi-driver"
echo "    ✓ Namespaces:    sre-ai-agent, sre-ai-agent-llm, monitoring, chaos"
echo "    ✓ IRSA:          ALB controller, EBS CSI"
echo "    ✓ Node groups:   agent-nodes, app-nodes"
echo "    ✓ EKS cluster:   $CLUSTER_NAME"
echo "    ✓ IAM policy:    $POLICY_NAME"
echo ""
echo "  ECR images are NOT deleted — remove manually if needed:"
echo "    aws ecr list-images --repository-name sre-ai-agent --region $AWS_REGION"
echo ""
echo "  Your .env secrets are NOT deleted — they are local files only."
echo ""