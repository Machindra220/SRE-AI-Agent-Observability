#!/bin/bash
# =============================================================================
# infra-up.sh
# Purpose: Provisions AWS infrastructure and deploys the application to EKS
# Usage:   ./scripts/infra-up.sh
# =============================================================================
set -e  # Exit immediately if any command fails

# Load all secrets automatically
source "$(dirname "$0")/load-secrets.sh"

AWS_REGION="us-east-1"
CLUSTER_NAME="sre-ai-agent-dev-eks-cluster"
ECR_URL="502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-dev-ecr-api"

# Get absolute paths regardless of where script is run from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo " SRE AI Agent - Infrastructure Up"
echo "========================================"

# -----------------------------------------------------------------------------
# Step 1: Terraform Apply
# Creates VPC, EKS cluster, ECR repo, and node group on AWS
# Takes 15-20 minutes on first run
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Provisioning AWS Infrastructure (Terraform) ==="
cd "$PROJECT_ROOT/infrastructure/terraform/eks"
terraform init -upgrade
terraform apply -auto-approve
cd "$PROJECT_ROOT"

# -----------------------------------------------------------------------------
# Step 2: Update kubeconfig
# Adds the new EKS cluster credentials to ~/.kube/config
# Required before any kubectl commands can work
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Connecting kubectl to EKS cluster ==="
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# -----------------------------------------------------------------------------
# Step 3: Wait for node to be Ready
# EKS node takes a few minutes to join the cluster after creation
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Waiting for EKS node to be Ready ==="
kubectl wait --for=condition=Ready nodes \
  --all \
  --timeout=300s

echo "--- Node status ---"
kubectl get nodes

# -----------------------------------------------------------------------------
# Step 4: Build and push Docker image to ECR
# Builds the FastAPI app image and pushes to ECR with git SHA + latest tags
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Build and push Docker image to ECR ==="

# Authenticate Docker to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin \
  502274764708.dkr.ecr.us-east-1.amazonaws.com

# Build and push
cd "$PROJECT_ROOT/app"
GIT_SHA=$(git rev-parse --short HEAD)
docker build -t ${ECR_URL}:${GIT_SHA} -t ${ECR_URL}:latest .
docker push ${ECR_URL}:${GIT_SHA}
docker push ${ECR_URL}:latest
cd "$PROJECT_ROOT"

echo "Image pushed: ${ECR_URL}:${GIT_SHA}"

# -----------------------------------------------------------------------------
# Step 5: Apply Kubernetes manifests
# Order matters: namespace → configmap → deployment → service → hpa
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 5: Deploying application to Kubernetes ==="
cd "$PROJECT_ROOT/kubernetes"

# Creates the sre-ai-agent namespace
kubectl apply -f namespace.yaml

# Creates environment configuration
kubectl apply -f configmap.yaml

# Deploys the FastAPI application pods
kubectl apply -f deployment.yaml

# Creates AWS LoadBalancer to expose app externally
kubectl apply -f service.yaml

# Enables auto-scaling based on CPU utilization
kubectl apply -f hpa.yaml

cd "$PROJECT_ROOT"

# -----------------------------------------------------------------------------
# Step 6: Wait for app pod to be Ready
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 6: Waiting for application pod to be Ready ==="
kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent \
  -n sre-ai-agent \
  --timeout=120s

# -----------------------------------------------------------------------------
# Step 7: Install Datadog Agent via Helm
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 7: Installing Datadog Agent ==="

# Add Helm repo
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Create Datadog secret in sre-ai-agent namespace
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace sre-ai-agent \
  --dry-run=client -o yaml | kubectl apply -f -

# Install Datadog via Helm
helm upgrade --install datadog-agent datadog/datadog \
  --namespace sre-ai-agent \
  --values "$PROJECT_ROOT/infrastructure/helm/datadog/values.yaml" \
  --wait \
  --timeout 5m

echo "=== Datadog Agent installed ==="

# -----------------------------------------------------------------------------
# Step 8: Show final status
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 8: Final Status ==="
echo ""
echo "--- Nodes ---"
kubectl get nodes

echo ""
echo "--- Pods (sre-ai-agent namespace) ---"
kubectl get pods -n sre-ai-agent

echo ""
echo "--- Service (LoadBalancer URL) ---"
kubectl get svc sre-ai-agent -n sre-ai-agent

echo ""
echo "--- HPA ---"
kubectl get hpa -n sre-ai-agent

echo ""
echo "========================================"
echo " Infrastructure is UP"
echo " Application deployed to EKS"
echo " Datadog Agent installed"
echo ""
echo " Wait 2-3 mins for LoadBalancer EXTERNAL-IP"
echo " Run: kubectl get svc sre-ai-agent -n sre-ai-agent"
echo ""
echo " Cost reminder: run infra-down.sh when done!"
echo "========================================"