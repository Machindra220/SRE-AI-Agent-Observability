#!/bin/bash
# =============================================================================
# scripts/infra-up-complete.sh
# ONE COMMAND — deploys complete SRE AI Agent Observability Platform
#
# What it deploys:
#   1.  AWS EKS + VPC + ECR (Terraform)
#   2.  App Docker image → ECR → EKS
#   3.  Datadog Agent (Helm) — secret created BEFORE Helm install
#   4.  DNS Route53 (Terraform) — auto-detects ELB
#   5.  Agent Docker image → ECR → EKS (agent_nodes)
#   6.  pgvector → EKS + schema init + runbook indexing
#   7.  Prometheus + Grafana (Helm) — monitoring namespace
#   8.  LitmusChaos (Helm) — litmus namespace
#
# Usage:
#   ./scripts/infra-up-complete.sh
#
# Requirements:
#   - AWS CLI configured
#   - Docker Desktop running
#   - .env file with GEMINI_API_KEY
#   - Git Bash (Windows) or bash (Linux/Mac)
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
echo "=== Step 3: Waiting for ALL nodes to be Ready ==="
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo "--- Node status ---"
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
# Create agent ECR repo if not exists
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
# Secret MUST be created before Helm install
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 8: Install Datadog Agent ==="

# Add Helm repo
helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true
helm repo update

# Create secret FIRST before Helm install
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace sre-ai-agent \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Datadog secret created"

# Install Datadog via Helm
helm upgrade --install datadog-agent datadog/datadog \
  --namespace sre-ai-agent \
  --values "$PROJECT_ROOT/infrastructure/helm/datadog/values.yaml" \
  --timeout 10m

# Wait for Datadog pods separately (more reliable than --wait)
echo "Waiting for Datadog pods..."
sleep 30
kubectl wait --for=condition=Ready pod \
  -l app=datadog-agent \
  -n sre-ai-agent \
  --timeout=300s 2>/dev/null || true

kubectl get pods -n sre-ai-agent
echo "Datadog agent installed"

# ─────────────────────────────────────────────────────────────────────────────
# PART 5: DNS
# Auto-detects app ELB and updates Route53
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 9: Update DNS (Route53) ==="

# Wait for app LB to be ready
echo "Waiting for app LoadBalancer..."
sleep 30
APP_LB=""
for i in {1..10}; do
  APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$APP_LB" ]; then
    break
  fi
  echo "Waiting for LB... attempt $i/10"
  sleep 15
done

if [ -n "$APP_LB" ]; then
  # Auto-update elb_hostname in variables.tf
  sed -i "s|default = \".*\.elb\.amazonaws\.com\"|default = \"$APP_LB\"|" \
    "$PROJECT_ROOT/infrastructure/terraform/dns/variables.tf"
  echo "Updated ELB hostname: $APP_LB"

  cd "$PROJECT_ROOT/infrastructure/terraform/dns"
  terraform init -upgrade 2>/dev/null || true
  terraform apply -auto-approve
  cd "$PROJECT_ROOT"
  echo "DNS updated — sre.machindra.online → $APP_LB"
else
  echo "WARNING: Could not detect app LB — update DNS manually"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PART 6: DEPLOY PGVECTOR + AGENT TO EKS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 10: Deploy pgvector to EKS ==="
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-namespace.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-service.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=pgvector -n sre-ai-agent-llm --timeout=120s
echo "pgvector ready"

echo ""
echo "=== Step 11: Deploy Agent to EKS ==="

# Create agent secret dynamically (not stored in git)
GEMINI_KEY=$(grep GEMINI_API_KEY "$PROJECT_ROOT/.env" | cut -d'=' -f2)
kubectl create secret generic sre-ai-agent-llm-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_KEY" \
  --from-literal=PGPASSWORD="sre_pass" \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -

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

# Kill any existing port-forward on 5433
pkill -f "port-forward.*5433" 2>/dev/null || true
sleep 2

# Start port-forward
kubectl port-forward -n sre-ai-agent-llm $PGVECTOR_POD 5433:5432 &
PF_PID=$!
sleep 8

# Run indexer
cd "$PROJECT_ROOT"
PGHOST=localhost PGPORT=5433 PGDATABASE=sre_agent \
  PGUSER=sre_user PGPASSWORD=sre_pass \
  python -m rag.indexer

# Kill port-forward
kill $PF_PID 2>/dev/null || true
echo "Runbooks indexed!"

# ─────────────────────────────────────────────────────────────────────────────
# PART 7: PROMETHEUS + GRAFANA ON EKS
# Uses t3.medium node group — ensure agent_nodes is t3.medium or add 3rd node
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 14: Deploy Prometheus + Grafana ==="

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Install Prometheus
helm upgrade --install prometheus \
  prometheus-community/prometheus \
  --namespace monitoring \
  --set server.service.type=LoadBalancer \
  --set server.persistentVolume.enabled=false \
  --set alertmanager.enabled=false \
  --set prometheus-node-exporter.tolerations[0].key=workload \
  --set prometheus-node-exporter.tolerations[0].operator=Exists \
  --set prometheus-node-exporter.tolerations[0].effect=NoSchedule \
  --timeout 10m 2>/dev/null || echo "Prometheus install failed — likely insufficient resources, run on larger nodes"

# Get Prometheus internal URL
PROM_INTERNAL="http://prometheus-server.monitoring.svc.cluster.local"

# Install Grafana with Prometheus datasource pre-configured
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --set service.type=LoadBalancer \
  --set adminPassword=admin \
  --set datasources."datasources\.yaml".apiVersion=1 \
  --set datasources."datasources\.yaml".datasources[0].name=Prometheus \
  --set datasources."datasources\.yaml".datasources[0].type=prometheus \
  --set datasources."datasources\.yaml".datasources[0].url=$PROM_INTERNAL \
  --set datasources."datasources\.yaml".datasources[0].isDefault=true \
  --timeout 10m 2>/dev/null || echo "Grafana install failed — likely insufficient resources, run on larger nodes"

echo "Monitoring deployed (check pods: kubectl get pods -n monitoring)"

# ─────────────────────────────────────────────────────────────────────────────
# PART 8: LITMUSCHAOS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Step 15: Deploy LitmusChaos ==="

helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/ 2>/dev/null || true
helm repo update

kubectl create namespace litmus --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install chaos litmuschaos/litmus \
  --namespace litmus \
  --set portal.frontend.service.type=LoadBalancer \
  --timeout 10m 2>/dev/null || echo "LitmusChaos install failed — likely insufficient resources"

echo "LitmusChaos deployed (check pods: kubectl get pods -n litmus)"

# ─────────────────────────────────────────────────────────────────────────────
# FINAL STATUS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Final Status ==="
echo ""
echo "--- All Pods ---"
kubectl get pods -n sre-ai-agent
echo ""
kubectl get pods -n sre-ai-agent-llm
echo ""
kubectl get pods -n monitoring 2>/dev/null || true
echo ""
kubectl get pods -n litmus 2>/dev/null || true

echo ""
echo "--- All Services ---"
kubectl get svc -n sre-ai-agent | grep LoadBalancer
kubectl get svc -n sre-ai-agent-llm | grep LoadBalancer
kubectl get svc -n monitoring 2>/dev/null | grep LoadBalancer || true
kubectl get svc -n litmus 2>/dev/null | grep LoadBalancer || true

# Get all URLs
APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
GRAFANA_LB=$(kubectl get svc grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "not deployed")
PROM_LB=$(kubectl get svc prometheus-server -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "not deployed")
LITMUS_LB=$(kubectl get svc chaos-litmus-frontend-service -n litmus \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "not deployed")

echo ""
echo "========================================"
echo " ALL SERVICES DEPLOYED!"
echo ""
echo " App:         http://sre.machindra.online/api/health"
echo " App LB:      http://$APP_LB/api/health"
echo " Agent:       http://$AGENT_LB/agent/health"
echo " Agent Docs:  http://$AGENT_LB/docs"
echo " Prometheus:  http://$PROM_LB"
echo " Grafana:     http://$GRAFANA_LB (admin/admin)"
echo " LitmusChaos: http://$LITMUS_LB:9091 (admin/litmus)"
echo ""
echo " NEXT STEPS:"
echo " 1. Update Datadog webhook URL:"
echo "    http://$AGENT_LB/agent/triage"
echo " 2. Import Grafana dashboard:"
echo "    monitoring/grafana/sre-ai-agent-dashboard.json"
echo " 3. Test end-to-end:"
echo "    curl -X POST http://$AGENT_LB/agent/triage ..."
echo "========================================"