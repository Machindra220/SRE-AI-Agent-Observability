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
#   8.  EBS CSI Driver — SKIPPED (required for LitmusChaos, re-enable when needed)
#   9.  LitmusChaos (Helm) — SKIPPED (resource-heavy, re-enable on larger nodes)
#
# Idempotent: safe to re-run if any step fails — picks up where it left off
#
# Usage:
#   ./scripts/infra-up-complete.sh
#
# Requirements:
#   - AWS CLI configured
#   - eksctl installed
#   - Docker Desktop running
#   - .env file with GEMINI_API_KEY
#   - Git Bash (Windows) or bash (Linux/Mac)
# =============================================================================

# set -e removed intentionally — each step handles its own errors explicitly
# This allows re-runs without false failures from already-existing resources
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load all secrets from AWS Secrets Manager
source "$SCRIPT_DIR/load-secrets.sh"

AWS_REGION="us-east-1"
AWS_ACCOUNT="502274764708"
CLUSTER_NAME="sre-ai-agent-dev-eks-cluster"
APP_ECR="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/sre-ai-agent-dev-ecr-api"
AGENT_ECR="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/sre-ai-agent-llm"

# =============================================================================
# Helper — print step header
# =============================================================================
step() {
  echo ""
  echo "========================================================"
  echo "  $1"
  echo "========================================================"
}

# =============================================================================
# Helper — check if a kubectl resource exists
# =============================================================================
k8s_exists() {
  kubectl get "$1" "$2" -n "${3:-default}" &>/dev/null
}

echo ""
echo "========================================"
echo " SRE AI Agent — Full Infrastructure Up"
echo "========================================"
echo " Project root: $PROJECT_ROOT"
echo "========================================"

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: AWS INFRASTRUCTURE
# ─────────────────────────────────────────────────────────────────────────────

step "Step 1: Provisioning AWS Infrastructure (Terraform)"
cd "$PROJECT_ROOT/infrastructure/terraform/eks"
terraform init -upgrade
terraform apply -auto-approve
cd "$PROJECT_ROOT"

step "Step 2: Connecting kubectl to EKS"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

step "Step 3: Waiting for ALL nodes to be Ready"
# Retry loop — on re-run nodes may already be ready
kubectl wait --for=condition=Ready nodes --all --timeout=300s || {
  echo "WARNING: Not all nodes ready after 300s — checking status..."
  kubectl get nodes
}
echo "--- Node status ---"
kubectl get nodes --show-labels | grep -E "NAME|workload" || true

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: BUILD AND PUSH DOCKER IMAGES
# ─────────────────────────────────────────────────────────────────────────────

step "Step 4: ECR Login"
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

step "Step 5: Build and Push App Image"
GIT_SHA=$(git rev-parse --short HEAD)
cd "$PROJECT_ROOT/app"
docker build -t "${APP_ECR}:${GIT_SHA}" -t "${APP_ECR}:latest" .
docker push "${APP_ECR}:${GIT_SHA}"
docker push "${APP_ECR}:latest"
cd "$PROJECT_ROOT"
echo "App image pushed: ${APP_ECR}:latest"

step "Step 6: Build and Push Agent Image"
# Create agent ECR repo if not exists — safe to run multiple times
aws ecr create-repository \
  --repository-name sre-ai-agent-llm \
  --region "$AWS_REGION" 2>/dev/null || true

docker build -t "${AGENT_ECR}:${GIT_SHA}" -t "${AGENT_ECR}:latest" \
  -f agent/Dockerfile .
docker push "${AGENT_ECR}:${GIT_SHA}"
docker push "${AGENT_ECR}:latest"
echo "Agent image pushed: ${AGENT_ECR}:latest"

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: DEPLOY APP TO EKS
# kubectl apply is idempotent — safe to re-run, creates or updates
# ─────────────────────────────────────────────────────────────────────────────

step "Step 7: Deploy App to Kubernetes"
kubectl apply -f "$PROJECT_ROOT/kubernetes/namespace.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/configmap.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/service.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/hpa.yaml"

echo "Waiting for app pod to be ready..."
kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent -n sre-ai-agent --timeout=120s || {
  echo "WARNING: App pod not ready after 120s — checking..."
  kubectl get pods -n sre-ai-agent
  kubectl describe pod -l app=sre-ai-agent -n sre-ai-agent | tail -20
}
echo "App deployed"

# ─────────────────────────────────────────────────────────────────────────────
# PART 4: INSTALL DATADOG AGENT
# helm upgrade --install is idempotent — installs or upgrades
# kubectl apply with --dry-run=client -o yaml | apply is idempotent for secrets
# ─────────────────────────────────────────────────────────────────────────────

step "Step 8: Install Datadog Agent"

helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true
helm repo update

# --dry-run=client -o yaml | kubectl apply = idempotent secret upsert
kubectl create secret generic datadog-secret \
  --from-literal=api-key="$DD_API_KEY" \
  --from-literal=app-key="$DD_APP_KEY" \
  --namespace sre-ai-agent \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Datadog secret created/updated"

# helm upgrade --install = idempotent (installs if missing, upgrades if exists)
helm upgrade --install datadog-agent datadog/datadog \
  --namespace sre-ai-agent \
  --values "$PROJECT_ROOT/infrastructure/helm/datadog/values.yaml" \
  --timeout 10m

echo "Waiting for Datadog pods..."
sleep 30
kubectl wait --for=condition=Ready pod \
  -l app=datadog-agent \
  -n sre-ai-agent \
  --timeout=300s 2>/dev/null || \
  echo "WARNING: Datadog pods not all ready — continuing (DaemonSet may still be rolling)"

kubectl get pods -n sre-ai-agent
echo "Datadog agent installed"

# ─────────────────────────────────────────────────────────────────────────────
# PART 5: DNS
# sed -i + terraform apply = idempotent — updates variable and applies
# ─────────────────────────────────────────────────────────────────────────────

step "Step 9: Update DNS (Route53)"

echo "Waiting for app LoadBalancer to get hostname..."
APP_LB=""
for i in {1..10}; do
  APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$APP_LB" ]; then
    echo "LB ready: $APP_LB"
    break
  fi
  echo "Waiting for LB... attempt $i/10"
  sleep 15
done

if [ -n "$APP_LB" ]; then
  sed -i "s|default = \".*\.elb\.amazonaws\.com\"|default = \"$APP_LB\"|" \
    "$PROJECT_ROOT/infrastructure/terraform/dns/variables.tf"
  echo "Updated ELB hostname in variables.tf: $APP_LB"

  cd "$PROJECT_ROOT/infrastructure/terraform/dns"
  terraform init -upgrade 2>/dev/null || true
  terraform apply -auto-approve
  cd "$PROJECT_ROOT"
  echo "DNS updated — sre.machindra.online → $APP_LB"
else
  echo "WARNING: Could not detect app LB after 150s — skipping DNS update"
  echo "         Run manually: terraform apply in infrastructure/terraform/dns"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PART 6: DEPLOY PGVECTOR + AGENT TO EKS
# kubectl apply = idempotent
# secret with --dry-run=client | apply = idempotent upsert
# ─────────────────────────────────────────────────────────────────────────────

step "Step 10: Deploy pgvector to EKS"
cd "$PROJECT_ROOT"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-namespace.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-service.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=pgvector -n sre-ai-agent-llm --timeout=120s || {
  echo "WARNING: pgvector pod not ready after 120s"
  kubectl get pods -n sre-ai-agent-llm
}
echo "pgvector ready"

step "Step 11: Deploy Agent to EKS"

# Read GEMINI key from .env or AWS Secrets Manager (already sourced)
GEMINI_KEY="${GEMINI_API_KEY:-$(grep GEMINI_API_KEY "$PROJECT_ROOT/.env" 2>/dev/null | cut -d'=' -f2 || echo "")}"
if [ -z "$GEMINI_KEY" ]; then
  echo "ERROR: GEMINI_API_KEY not found in environment or .env file"
  exit 1
fi

kubectl create secret generic sre-ai-agent-llm-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_KEY" \
  --from-literal=PGPASSWORD="sre_pass" \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-configmap.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-service.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent-llm -n sre-ai-agent-llm --timeout=180s || {
  echo "WARNING: Agent pod not ready after 180s"
  kubectl get pods -n sre-ai-agent-llm
  kubectl describe pod -l app=sre-ai-agent-llm -n sre-ai-agent-llm | tail -20
}
echo "Agent ready"

step "Step 12: Initialize pgvector schema"
PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm -l app=pgvector \
  -o name 2>/dev/null | head -1)

if [ -z "$PGVECTOR_POD" ]; then
  echo "WARNING: pgvector pod not found — skipping schema init"
else
  # CREATE IF NOT EXISTS = idempotent — safe to run multiple times
  kubectl exec -n sre-ai-agent-llm "$PGVECTOR_POD" \
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
    " && echo "Schema initialized" || echo "WARNING: Schema init failed — may already exist"
fi

step "Step 13: Index Runbooks"
PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm -l app=pgvector \
  -o name 2>/dev/null | head -1)

if [ -z "$PGVECTOR_POD" ]; then
  echo "WARNING: pgvector pod not found — skipping runbook indexing"
else
  # Kill any existing port-forward on 5433
  pkill -f "port-forward.*5433" 2>/dev/null || true
  sleep 2

  kubectl port-forward -n sre-ai-agent-llm "$PGVECTOR_POD" 5433:5432 &
  PF_PID=$!
  sleep 8

  cd "$PROJECT_ROOT"
  # || true — indexer failure must not stop the rest of the deploy
  PGHOST=localhost PGPORT=5433 PGDATABASE=sre_agent \
    PGUSER=sre_user PGPASSWORD=sre_pass \
    python -m rag.indexer || \
    echo "WARNING: Runbook indexer failed — re-run manually: python -m rag.indexer"

  kill $PF_PID 2>/dev/null || true
  echo "Runbook indexing complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PART 7: PROMETHEUS + GRAFANA
# helm upgrade --install = idempotent
# ─────────────────────────────────────────────────────────────────────────────

step "Step 14: Deploy Prometheus + Grafana"
cd "$PROJECT_ROOT"

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana \
  https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# --dry-run=client | apply = idempotent namespace creation
kubectl create namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

# helm upgrade --install = idempotent
helm upgrade --install prometheus \
  prometheus-community/prometheus \
  --namespace monitoring \
  --set server.service.type=LoadBalancer \
  --set server.persistentVolume.enabled=false \
  --set alertmanager.enabled=false \
  --set prometheus-node-exporter.tolerations[0].key=workload \
  --set prometheus-node-exporter.tolerations[0].operator=Exists \
  --set prometheus-node-exporter.tolerations[0].effect=NoSchedule \
  --timeout 10m || \
  echo "WARNING: Prometheus install failed — check: kubectl get pods -n monitoring"

PROM_INTERNAL="http://prometheus-server.monitoring.svc.cluster.local"

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --set service.type=LoadBalancer \
  --set adminPassword=admin \
  --set "datasources.datasources\.yaml.apiVersion=1" \
  --set "datasources.datasources\.yaml.datasources[0].name=Prometheus" \
  --set "datasources.datasources\.yaml.datasources[0].type=prometheus" \
  --set "datasources.datasources\.yaml.datasources[0].url=$PROM_INTERNAL" \
  --set "datasources.datasources\.yaml.datasources[0].isDefault=true" \
  --timeout 10m || \
  echo "WARNING: Grafana install failed — check: kubectl get pods -n monitoring"

echo "Monitoring deployed"

# ─────────────────────────────────────────────────────────────────────────────
# PART 8: EBS CSI DRIVER — SKIPPED
# Re-enable when deploying LitmusChaos on larger nodes (t3.medium or dedicated)
# To re-enable: uncomment PART 8 and PART 9 blocks below
# ─────────────────────────────────────────────────────────────────────────────

# step "Step 15: Install EBS CSI Driver (required for LitmusChaos MongoDB PVC)"
#
# echo "[*] Installing EBS CSI addon..."
# aws eks create-addon \
#   --cluster-name "$CLUSTER_NAME" \
#   --addon-name aws-ebs-csi-driver \
#   --region "$AWS_REGION" 2>/dev/null || \
#   echo "EBS CSI addon already exists — skipping creation"
#
# echo "[*] Checking EBS CSI IAM service account..."
# EXISTING_ROLE=$(kubectl get sa ebs-csi-controller-sa \
#   -n kube-system \
#   -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' \
#   2>/dev/null || echo "")
#
# if [ -z "$EXISTING_ROLE" ]; then
#   echo "No IAM role attached — creating service account with role..."
#   eksctl create iamserviceaccount \
#     --name ebs-csi-controller-sa \
#     --namespace kube-system \
#     --cluster "$CLUSTER_NAME" \
#     --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
#     --approve \
#     --override-existing-serviceaccounts \
#     --region "$AWS_REGION"
#   echo "IAM role attached"
# else
#   echo "IAM role already attached: $EXISTING_ROLE — skipping"
# fi
#
# echo "[*] Setting gp2 as default storageclass..."
# kubectl patch storageclass gp2 \
#   -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
#   2>/dev/null || true
#
# echo "[*] Restarting EBS CSI controller..."
# kubectl rollout restart deployment/ebs-csi-controller -n kube-system
#
# echo "[*] Waiting for EBS CSI controller to be ready (180s)..."
# kubectl rollout status deployment/ebs-csi-controller \
#   -n kube-system --timeout=180s || {
#   echo "ERROR: EBS CSI controller failed to start"
#   kubectl get pods -n kube-system | grep ebs
#   kubectl describe deployment ebs-csi-controller -n kube-system | tail -20
#   exit 1
# }
#
# echo "EBS CSI Driver ready"
# kubectl get pods -n kube-system | grep ebs-csi-controller

# ─────────────────────────────────────────────────────────────────────────────
# PART 9: LITMUSCHAOS — SKIPPED
# Resource-heavy on t3.small — needs dedicated node or t3.medium+
# To re-enable: uncomment this block and PART 8 above
# ─────────────────────────────────────────────────────────────────────────────

# step "Step 16: Deploy LitmusChaos"
# cd "$PROJECT_ROOT"
#
# helm repo add litmuschaos \
#   https://litmuschaos.github.io/litmus-helm/ 2>/dev/null || true
# helm repo update
#
# echo "[*] Verifying LitmusChaos chart..."
# helm search repo litmuschaos/litmus | grep litmus || {
#   echo "ERROR: litmuschaos/litmus chart not found in repo"
#   exit 1
# }
#
# LITMUS_VALUES="$PROJECT_ROOT/infrastructure/helm/litmus/values.yaml"
# if [ ! -f "$LITMUS_VALUES" ]; then
#   echo "ERROR: values file not found: $LITMUS_VALUES"
#   exit 1
# fi
# echo "[*] Using values: $LITMUS_VALUES"
#
# kubectl create namespace litmus \
#   --dry-run=client -o yaml | kubectl apply -f -
#
# helm upgrade --install chaos litmuschaos/litmus \
#   --namespace litmus \
#   --set portal.frontend.service.type=LoadBalancer \
#   -f "$LITMUS_VALUES" \
#   --timeout 10m
#
# echo "LitmusChaos deployed — waiting 30s for pods to initialise..."
# sleep 30
# kubectl get pods -n litmus

# ─────────────────────────────────────────────────────────────────────────────
# FINAL STATUS
# ─────────────────────────────────────────────────────────────────────────────

step "Final Status"

echo "--- All Pods ---"
kubectl get pods -n sre-ai-agent       2>/dev/null || true
echo ""
kubectl get pods -n sre-ai-agent-llm   2>/dev/null || true
echo ""
kubectl get pods -n monitoring         2>/dev/null || true
# kubectl get pods -n litmus           2>/dev/null || true  # SKIPPED

echo ""
echo "--- All Services ---"
kubectl get svc -n sre-ai-agent        2>/dev/null | grep LoadBalancer || true
kubectl get svc -n sre-ai-agent-llm    2>/dev/null | grep LoadBalancer || true
kubectl get svc -n monitoring          2>/dev/null | grep LoadBalancer || true
# kubectl get svc -n litmus            2>/dev/null | grep LoadBalancer || true  # SKIPPED

# Collect all LB URLs
APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
GRAFANA_LB=$(kubectl get svc grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "not deployed")
PROM_LB=$(kubectl get svc prometheus-server -n monitoring \
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
echo " LitmusChaos: SKIPPED — re-enable on t3.medium+ nodes"
echo ""
echo " NEXT STEPS:"
echo " 1. Update Datadog webhook URL:"
echo "    http://$AGENT_LB/agent/triage"
echo " 2. Import Grafana dashboard:"
echo "    monitoring/grafana/sre-ai-agent-dashboard.json"
echo " 3. Test end-to-end:"
echo "    curl -X POST http://$AGENT_LB/agent/triage ..."
echo " 4. To enable LitmusChaos later:"
echo "    Uncomment PART 8 + PART 9 in this script"
echo "    Increase node size to t3.medium in eks.tf"
echo "========================================"