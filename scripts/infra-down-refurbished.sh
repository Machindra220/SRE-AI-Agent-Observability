#!/bin/bash
# =============================================================================
# infra-down.sh
# Purpose: Safely tears down ALL application services and AWS infrastructure
# Usage:   ./scripts/infra-down.sh
# Order:   Delete K8s LB services → wait for ELB deletion → terraform destroy
# WARNING: Destroys EKS and VPC but PRESERVES ECR and DNS hosted zone
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo " SRE AI Agent - Taking Infrastructure Down"
echo "========================================"

# NOTE: DNS terraform is NOT destroyed
# NS records at BigRock stay the same — just update elb_hostname next deploy

# -----------------------------------------------------------------------------
# Step 1: Delete ALL LoadBalancer services first
# This triggers AWS to delete ELBs before terraform destroy
# Orphaned ELBs continue billing and can't be deleted by terraform
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Deleting all LoadBalancer services ==="

# App service
kubectl delete svc sre-ai-agent -n sre-ai-agent --ignore-not-found
echo "App LB deleted"

# Agent service
kubectl delete svc sre-ai-agent-llm -n sre-ai-agent-llm --ignore-not-found
echo "Agent LB deleted"

# Monitoring services
kubectl delete svc prometheus-server -n monitoring --ignore-not-found 2>/dev/null || true
kubectl delete svc grafana -n monitoring --ignore-not-found 2>/dev/null || true
echo "Monitoring LBs deleted"

# LitmusChaos service
kubectl delete svc chaos-litmus-frontend-service -n litmus --ignore-not-found 2>/dev/null || true
echo "LitmusChaos LB deleted"

# -----------------------------------------------------------------------------
# Step 2: Delete remaining K8s resources
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Removing Kubernetes resources ==="

# App namespace
kubectl delete -f "$PROJECT_ROOT/kubernetes/hpa.yaml" --ignore-not-found
kubectl delete -f "$PROJECT_ROOT/kubernetes/deployment.yaml" --ignore-not-found
kubectl delete -f "$PROJECT_ROOT/kubernetes/configmap.yaml" --ignore-not-found
kubectl delete -f "$PROJECT_ROOT/kubernetes/namespace.yaml" --ignore-not-found

# Agent namespace
kubectl delete namespace sre-ai-agent-llm --ignore-not-found

# Monitoring namespace
kubectl delete namespace monitoring --ignore-not-found 2>/dev/null || true

# Litmus namespace
kubectl delete namespace litmus --ignore-not-found 2>/dev/null || true

echo "All K8s resources deleted"

# -----------------------------------------------------------------------------
# Step 3: Wait for ELB deletion
# AWS takes 30-60 seconds to fully delete ELBs
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Waiting for AWS ELBs to be deleted (60s) ==="
sleep 60

# Verify no load balancers remain
echo "Verifying ELBs deleted..."
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[*].LoadBalancerName' \
  --output table 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 4: Destroy AWS Infrastructure
# Destroys EKS + VPC but PRESERVES ECR (avoid re-pushing images next session)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Destroying AWS Infrastructure ==="
cd "$PROJECT_ROOT/infrastructure/terraform/eks"

terraform destroy \
  -target='module.eks' \
  -target='module.vpc' \
  -auto-approve

echo ""
echo "========================================"
echo " Infrastructure is DOWN"
echo " ECR preserved — images still available"
echo " DNS preserved — no BigRock update needed"
echo " Billing stopped for EKS and EC2"
echo "========================================"