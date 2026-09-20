#!/bin/bash
# =============================================================================
# infra-down.sh
# Purpose: Safely tears down ALL application services and AWS infrastructure
# Usage:   ./scripts/infra-down.sh
# Order:   Helm uninstall → Delete K8s LB services →
#          wait for ELB deletion → terraform destroy
# NOTE:    EBS CSI + LitmusChaos steps SKIPPED (litmus not deployed)
# WARNING: Destroys EKS and VPC but PRESERVES ECR and DNS hosted zone
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

AWS_REGION="us-east-1"
CLUSTER_NAME="sre-ai-agent-dev-eks-cluster"

echo "========================================"
echo " SRE AI Agent - Taking Infrastructure Down"
echo "========================================"

# NOTE: DNS terraform is NOT destroyed
# NS records at BigRock stay the same — just update elb_hostname next deploy

# -----------------------------------------------------------------------------
# Step 1: Uninstall Helm releases FIRST
# Helm manages finalizers — deleting namespace directly before uninstall
# leaves orphaned resources and ELBs that block terraform destroy
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Uninstalling Helm releases ==="

helm uninstall datadog-agent --namespace sre-ai-agent 2>/dev/null || \
  echo "datadog-agent not found, skipping"

helm uninstall prometheus --namespace monitoring 2>/dev/null || \
  echo "prometheus not found, skipping"

helm uninstall grafana --namespace monitoring 2>/dev/null || \
  echo "grafana not found, skipping"

# helm uninstall chaos --namespace litmus 2>/dev/null || \
#   echo "chaos (LitmusChaos) not found, skipping"   # SKIPPED — litmus not deployed

echo "Helm releases uninstalled"

# -----------------------------------------------------------------------------
# Step 2: Delete LitmusChaos PVCs — SKIPPED (litmus not deployed)
# Re-enable when LitmusChaos is active — PVCs block terraform VPC deletion
# -----------------------------------------------------------------------------
# echo ""
# echo "=== Step 2: Deleting LitmusChaos PVCs (releases EBS volumes) ==="
#
# kubectl delete pvc --all -n litmus 2>/dev/null || true
# echo "Waiting 20s for EBS volumes to detach..."
# sleep 20
#
# REMAINING=$(kubectl get pvc -n litmus 2>/dev/null | grep -v NAME | wc -l)
# if [ "$REMAINING" -gt 0 ]; then
#   echo "WARNING: $REMAINING PVCs still pending deletion — forcing..."
#   kubectl get pvc -n litmus -o name 2>/dev/null | \
#     xargs -I {} kubectl patch {} -n litmus \
#     -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
# fi
# echo "PVCs deleted"

# -----------------------------------------------------------------------------
# Step 3: Delete ALL LoadBalancer services
# This triggers AWS to delete ELBs before terraform destroy
# Orphaned ELBs continue billing and BLOCK VPC deletion
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Deleting all LoadBalancer services ==="

kubectl delete svc sre-ai-agent \
  -n sre-ai-agent --ignore-not-found
echo "App LB deleted"

kubectl delete svc sre-ai-agent-llm \
  -n sre-ai-agent-llm --ignore-not-found
echo "Agent LB deleted"

kubectl delete svc prometheus-server \
  -n monitoring --ignore-not-found 2>/dev/null || true
kubectl delete svc grafana \
  -n monitoring --ignore-not-found 2>/dev/null || true
echo "Monitoring LBs deleted"

# kubectl delete svc chaos-litmus-frontend-service \
#   -n litmus --ignore-not-found 2>/dev/null || true  # SKIPPED — litmus not deployed
# echo "LitmusChaos LB deleted"

# -----------------------------------------------------------------------------
# Step 4: Delete remaining Kubernetes resources
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Removing Kubernetes resources ==="

# App namespace
kubectl delete -f "$PROJECT_ROOT/kubernetes/hpa.yaml" \
  --ignore-not-found 2>/dev/null || true
kubectl delete -f "$PROJECT_ROOT/kubernetes/deployment.yaml" \
  --ignore-not-found 2>/dev/null || true
kubectl delete -f "$PROJECT_ROOT/kubernetes/configmap.yaml" \
  --ignore-not-found 2>/dev/null || true
kubectl delete -f "$PROJECT_ROOT/kubernetes/namespace.yaml" \
  --ignore-not-found 2>/dev/null || true

# Agent namespace
kubectl delete namespace sre-ai-agent-llm --ignore-not-found 2>/dev/null || true

# Monitoring namespace
kubectl delete namespace monitoring --ignore-not-found 2>/dev/null || true

# Litmus namespace — SKIPPED (litmus not deployed)
# kubectl delete namespace litmus --ignore-not-found 2>/dev/null || true

echo "All K8s resources deleted"

# -----------------------------------------------------------------------------
# Step 5: Remove EBS CSI Driver — SKIPPED (not installed, litmus not deployed)
# Re-enable when LitmusChaos is active — must run before terraform destroy
# -----------------------------------------------------------------------------
# echo ""
# echo "=== Step 5: Removing EBS CSI Driver ==="
#
# aws eks delete-addon \
#   --cluster-name "$CLUSTER_NAME" \
#   --addon-name aws-ebs-csi-driver \
#   --region "$AWS_REGION" 2>/dev/null || \
#   echo "EBS CSI addon not found, skipping"
#
# echo "Waiting 20s for addon deletion..."
# sleep 20
#
# eksctl delete iamserviceaccount \
#   --name ebs-csi-controller-sa \
#   --namespace kube-system \
#   --cluster "$CLUSTER_NAME" \
#   --region "$AWS_REGION" 2>/dev/null || \
#   echo "EBS CSI IAM service account not found, skipping"
#
# echo "EBS CSI Driver removed"

# -----------------------------------------------------------------------------
# Step 6: Wait for ELB deletion
# AWS takes 30-60 seconds to fully delete ELBs after service deletion
# Terraform destroy will fail if ELBs still hold VPC/subnet references
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 6: Waiting for AWS ELBs to be deleted (60s) ==="
sleep 60

# Verify no load balancers remain
echo "Verifying ELBs deleted..."
REMAINING_LBS=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[*].LoadBalancerName' \
  --output text 2>/dev/null || echo "")

if [ -n "$REMAINING_LBS" ]; then
  echo "WARNING: These ELBs still exist — may cause terraform destroy to fail:"
  echo "$REMAINING_LBS"
  echo "Waiting additional 30s..."
  sleep 30
else
  echo "All ELBs deleted — safe to proceed"
fi

# -----------------------------------------------------------------------------
# Step 7: Destroy AWS Infrastructure
# Destroys EKS + VPC but PRESERVES ECR (avoid re-pushing images next session)
# PRESERVES DNS hosted zone (no BigRock NS update needed next deploy)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 7: Destroying AWS Infrastructure ==="
cd "$PROJECT_ROOT/infrastructure/terraform/eks"

terraform destroy \
  -target='module.eks' \
  -target='module.vpc' \
  -auto-approve

echo ""
echo "========================================"
echo " Infrastructure is DOWN"
echo ""
echo " PRESERVED:"
echo "  ECR        — images still available for next deploy"
echo "  DNS        — no BigRock NS update needed"
echo "  .env       — secrets intact"
echo ""
echo " DESTROYED:"
echo "  EKS cluster + nodes"
echo "  VPC + subnets"
echo "  ELBs"
echo ""
echo " SKIPPED (re-enable when LitmusChaos active):"
echo "  EBS volumes cleanup"
echo "  EBS CSI addon + IAM role"
echo "  LitmusChaos namespace + PVCs"
echo ""
echo " Billing stopped for EKS and EC2"
echo "========================================"