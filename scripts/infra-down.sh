#!/bin/bash
# =============================================================================
# infra-down.sh
# Purpose: Safely tears down application and AWS infrastructure to stop billing
# Usage:   ./scripts/infra-down.sh
# Order:   K8s resources first → wait for ELB deletion → terraform destroy
# WARNING: This destroys EKS and VPC but PRESERVES ECR repository
# =============================================================================
set -e  # Exit immediately if any command fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"


# Destroying DNS resources first
echo "=== Destroying DNS resources ==="
cd "$PROJECT_ROOT/infrastructure/terraform/dns"
terraform destroy -auto-approve
cd "$PROJECT_ROOT"

echo "========================================"
echo " SRE Demo - Taking Infrastructure Down"
echo "========================================"

# -----------------------------------------------------------------------------
# Step 1: Delete Kubernetes resources
# IMPORTANT: Service must be deleted FIRST
# Deleting the LoadBalancer Service triggers AWS to delete the ELB
# If we run terraform destroy first, the ELB becomes an orphan -
# Terraform can't delete it (Kubernetes created it, not Terraform)
# Orphaned ELBs continue billing and require manual console deletion
# --ignore-not-found prevents errors if resources don't exist
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Removing Kubernetes resources ==="

# Deletes AWS LoadBalancer - most important step
echo "Deleting LoadBalancer service (triggers ELB deletion)..."
kubectl delete -f "$PROJECT_ROOT/kubernetes/service.yaml" --ignore-not-found

# Removes auto-scaler
echo "Deleting HPA..."
kubectl delete -f "$PROJECT_ROOT/kubernetes/hpa.yaml" --ignore-not-found

# Removes application pods
echo "Deleting Deployment..."
kubectl delete -f "$PROJECT_ROOT/kubernetes/deployment.yaml" --ignore-not-found

# Removes configuration
echo "Deleting ConfigMap..."
kubectl delete -f "$PROJECT_ROOT/kubernetes/configmap.yaml" --ignore-not-found

# Removes namespace (deletes everything inside it)
echo "Deleting Namespace..."
kubectl delete -f "$PROJECT_ROOT/kubernetes/namespace.yaml" --ignore-not-found

# -----------------------------------------------------------------------------
# Step 2: Wait for ELB deletion
# AWS takes 30-60 seconds to fully delete the ELB after Service is removed
# Running terraform destroy too early can leave orphaned ELBs
# We verify ELB is gone before proceeding
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Waiting for AWS ELB to be deleted ==="
echo "Waiting 60 seconds for ELB deletion to propagate..."
sleep 60

# Verify no load balancers remain
echo "Verifying ELB is deleted..."
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[*].LoadBalancerName' \
  --output table

# -----------------------------------------------------------------------------
# Step 3: Destroy AWS infrastructure
# -target flag destroys only EKS and VPC, NOT ECR
# ECR is preserved to avoid re-pushing images next session
# This saves the most money - EKS control plane = $73/mo
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Destroying AWS Infrastructure (preserving ECR) ==="
cd "$PROJECT_ROOT/infrastructure/terraform"

# Destroys EKS cluster, node group, and all related resources
terraform destroy \
  -target='module.eks' \
  -target='module.vpc' \
  -auto-approve

echo ""
echo "========================================"
echo " Infrastructure is DOWN"
echo " ECR repository preserved"
echo " Billing stopped for EKS and EC2"
echo "========================================"
