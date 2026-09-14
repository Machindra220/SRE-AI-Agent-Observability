#!/bin/bash
# =============================================================================
# scripts/infra-up-eks.sh
# Complete automation — Phase 21+22
# Provisions ALL infrastructure and deploys ALL services:
#   1. AWS EKS + VPC + ECR (Terraform)
#   2. App Docker image → ECR → EKS
#   3. Datadog Agent (Helm)
#   4. DNS Route53 (Terraform)
#   5. Agent Docker image → ECR → EKS
#   6. pgvector → EKS + schema + runbook indexing
#   7. Prometheus + Grafana (Helm)
#   8. LitmusChaos (Helm)
# Usage: ./scripts/infra-up-eks.sh
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load all secrets from AWS Secrets Manager
source "$SCRIPT_DIR/load-secrets.sh"

AWS_REGION="us-east-1"
AWS_ACCOUNT="502274764708"
CLUSTER_NAME="sre-ai-agent-dev-eks-cluster"
APP_ECR="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/sre-ai-agent-dev-ecr-api"
AGENT_ECR="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/sre-ai-agent-llm"

echo "========================================"
echo " SRE AI Agent — Full Infrastructure Up"
echo "========================================"

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: AWS INFRASTRUCTURE
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 1: Provisioning AWS Infrastructure (Terraform) ==="
cd "$PROJECT_ROOT/infrastructure/terraform/eks"
terraform init -upgrade
terraform apply -auto-approve
cd "$PROJECT_ROOT"

echo ""
echo "=== Step 2: Connecting kubectl to EKS ==="
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

echo ""
echo "=== Step 3: Waiting for nodes to be Ready ==="
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes --show-labels | grep workload

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: BUILD AND PUSH DOCKER IMAGES
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 4: ECR Login ==="
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

echo ""
echo "=== Step 5: Build and Push App Image ==="
GIT_SHA=$(git rev-parse --short HEAD)
cd "$PROJECT_ROOT/app"
docker build -t ${APP_ECR}:${GIT_SHA} -t ${APP_ECR}:latest .
docker push ${APP_ECR}:${GIT_SHA}
docker push ${APP_ECR}:latest
cd "$PROJECT_ROOT"
echo "App image pushed: ${APP_ECR}:latest"

echo ""
echo "=== Step 6: Build and Push Agent Image ==="
# Create ECR repo if not exists
aws ecr create-repository \
  --repository-name sre-ai-agent-llm \
  --region $AWS_REGION 2>/dev/null || true

docker build -t ${AGENT_ECR}:${GIT_SHA} -t ${AGENT_ECR}:latest \
  -f agent/Dockerfile .
docker push ${AGENT_ECR}:${GIT_SHA}
docker push ${AGENT_ECR}:latest
echo "Agent image pushed: ${AGENT_ECR}:latest"

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: DEPLOY APP TO EKS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 7: Deploy App to Kubernetes ==="
kubectl apply -f "$PROJECT_ROOT/kubernetes/namespace.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/configmap.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/service.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/hpa.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent -n sre-ai-agent --timeout=120s
echo "App deployed"

# ─────────────────────────────────────────────────────────────────────────────
# PART 4: INSTALL DATADOG AGENT
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 8: Install Datadog Agent ==="
helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true
helm repo update

kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace sre-ai-agent \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install datadog-agent datadog/datadog \
  --namespace sre-ai-agent \
  --values "$PROJECT_ROOT/infrastructure/helm/datadog/values.yaml" \
  --wait --timeout 5m
echo "Datadog agent installed"

# ─────────────────────────────────────────────────────────────────────────────
# PART 5: DNS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 9: Update DNS (Route53) ==="

# Auto-detect new ELB hostname
APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -n "$APP_LB" ]; then
  # Update variables.tf with new ELB hostname
  sed -i "s|default = \".*\.elb\.amazonaws\.com\"|default = \"$APP_LB\"|" \
    "$PROJECT_ROOT/infrastructure/terraform/dns/variables.tf"
  echo "Updated ELB hostname: $APP_LB"

  cd "$PROJECT_ROOT/infrastructure/terraform/dns"
  terraform apply -auto-approve
  cd "$PROJECT_ROOT"
  echo "DNS updated"
else
  echo "WARNING: Could not detect app LB hostname — update DNS manually"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PART 6: DEPLOY AGENT + PGVECTOR
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 10: Deploy pgvector to EKS ==="
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-service.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=pgvector -n sre-ai-agent-llm --timeout=120s
echo "pgvector ready"

echo ""
echo "=== Step 11: Deploy Agent to EKS ==="

# Create agent secret dynamically (not committed to git)
GEMINI_KEY=$(grep GEMINI_API_KEY "$PROJECT_ROOT/.env" | cut -d'=' -f2)
kubectl create secret generic sre-ai-agent-llm-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_KEY" \
  --from-literal=PGPASSWORD="sre_pass" \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-namespace.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-configmap.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-service.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent-llm -n sre-ai-agent-llm --timeout=180s
echo "Agent ready"

echo ""
echo "=== Step 12: Initialize pgvector schema ==="
PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm -l app=pgvector -o name | head -1)

kubectl exec -n sre-ai-agent-llm $PGVECTOR_POD \
  -- psql -U sre_user -d sre_agent -c "
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE TABLE IF NOT EXISTS runbook_chunks (
      id SERIAL PRIMARY KEY,
      source TEXT NOT NULL,
      content TEXT NOT NULL,
      embedding vector(384),
      created_at TIMESTAMP DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
      ON runbook_chunks USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 10);
  "
echo "Schema initialized"

echo ""
echo "=== Step 13: Index Runbooks ==="
pkill -f "port-forward.*5433" 2>/dev/null || true
sleep 2

kubectl port-forward -n sre-ai-agent-llm $PGVECTOR_POD 5433:5432 &
PF_PID=$!
sleep 5

cd "$PROJECT_ROOT"
PGHOST=localhost PGPORT=5433 PGDATABASE=sre_agent \
  PGUSER=sre_user PGPASSWORD=sre_pass \
  python -m rag.indexer

kill $PF_PID 2>/dev/null || true
echo "Runbooks indexed!"

# ─────────────────────────────────────────────────────────────────────────────
# PART 7: MONITORING STACK
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 14: Deploy Prometheus + Grafana ==="
bash "$SCRIPT_DIR/deploy-monitoring.sh"

# ─────────────────────────────────────────────────────────────────────────────
# PART 8: LITMUSCHAOS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 15: Deploy LitmusChaos ==="
bash "$SCRIPT_DIR/deploy-litmuschaos.sh"

# ─────────────────────────────────────────────────────────────────────────────
# FINAL STATUS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Final Status ==="
kubectl get nodes
echo ""
kubectl get pods -n sre-ai-agent
echo ""
kubectl get pods -n sre-ai-agent-llm
echo ""
kubectl get pods -n monitoring
echo ""
kubectl get pods -n litmus

APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
GRAFANA_LB=$(kubectl get svc grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
PROM_LB=$(kubectl get svc prometheus-server -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
LITMUS_LB=$(kubectl get svc chaos-litmus-frontend-service -n litmus \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo ""
echo "========================================"
echo " ALL SERVICES DEPLOYED SUCCESSFULLY!"
echo ""
echo " App:         http://sre.machindra.online/api/health"
echo " App LB:      http://$APP_LB"
echo " Agent:       http://$AGENT_LB/agent/health"
echo " Agent Docs:  http://$AGENT_LB/docs"
echo " Prometheus:  http://$PROM_LB"
echo " Grafana:     http://$GRAFANA_LB (admin/admin)"
echo " LitmusChaos: http://$LITMUS_LB:9091 (admin/litmus)"
echo ""
echo " Next steps:"
echo " 1. Configure Datadog webhook:"
echo "    URL: http://$AGENT_LB/agent/triage"
echo " 2. Add @webhook-sre-ai-agent-triage to monitors"
echo " 3. Import Grafana dashboard from monitoring/grafana/"
echo "========================================"