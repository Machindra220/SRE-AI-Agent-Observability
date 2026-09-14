#!/bin/bash
# =============================================================================
# scripts/deploy-agent.sh
# Automates Phase 21 manual steps:
#   1. Create agent ECR repo (if not exists)
#   2. Build and push agent Docker image
#   3. Deploy pgvector to EKS
#   4. Deploy agent to EKS
#   5. Initialize pgvector schema
#   6. Index runbooks into pgvector
# Usage: ./scripts/deploy-agent.sh
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/load-secrets.sh"

AWS_REGION="us-east-1"
AWS_ACCOUNT="502274764708"
AGENT_ECR="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/sre-ai-agent-llm"
CLUSTER_NAME="sre-ai-agent-dev-eks-cluster"

echo "========================================"
echo " SRE AI Agent — Deploy Agent to EKS"
echo "========================================"

# -----------------------------------------------------------------------------
# Step 1: Create ECR repo for agent (skip if exists)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Create Agent ECR Repository ==="
aws ecr create-repository \
  --repository-name sre-ai-agent-llm \
  --region $AWS_REGION 2>/dev/null || echo "ECR repo already exists — skipping"

# -----------------------------------------------------------------------------
# Step 2: Build and push agent Docker image
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Build and Push Agent Docker Image ==="
cd "$PROJECT_ROOT"

aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

GIT_SHA=$(git rev-parse --short HEAD)
docker build -t ${AGENT_ECR}:${GIT_SHA} -t ${AGENT_ECR}:latest \
  -f agent/Dockerfile .

docker push ${AGENT_ECR}:${GIT_SHA}
docker push ${AGENT_ECR}:latest
echo "Agent image pushed: ${AGENT_ECR}:latest"

# -----------------------------------------------------------------------------
# Step 3: Create agent Kubernetes secret with Gemini API key
# NOTE: agent-secret.yaml is gitignored — created dynamically here
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Create Agent Kubernetes Secret ==="

# Load Gemini key from .env
GEMINI_KEY=$(grep GEMINI_API_KEY "$PROJECT_ROOT/.env" | cut -d'=' -f2)

kubectl create secret generic sre-ai-agent-llm-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_KEY" \
  --from-literal=PGPASSWORD="sre_pass" \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret created/updated"

# -----------------------------------------------------------------------------
# Step 4: Deploy pgvector to EKS
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Deploy pgvector to EKS ==="
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/pgvector-service.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=pgvector \
  -n sre-ai-agent-llm \
  --timeout=120s

echo "pgvector is Ready"

# -----------------------------------------------------------------------------
# Step 5: Deploy agent to EKS
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 5: Deploy Agent to EKS ==="
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-namespace.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-configmap.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-deployment.yaml"
kubectl apply -f "$PROJECT_ROOT/kubernetes/agent-service.yaml"

kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent-llm \
  -n sre-ai-agent-llm \
  --timeout=180s

echo "Agent is Ready"

# -----------------------------------------------------------------------------
# Step 6: Initialize pgvector schema
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 6: Initialize pgvector schema ==="

PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm -l app=pgvector -o name | head -1)

kubectl exec -n sre-ai-agent-llm $PGVECTOR_POD \
  -- psql -U sre_user -d sre_agent << 'SQLEOF'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS runbook_chunks (
  id SERIAL PRIMARY KEY,
  source TEXT NOT NULL,
  content TEXT NOT NULL,
  embedding vector(384),
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
  ON runbook_chunks
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 10);
SQLEOF

echo "pgvector schema initialized"

# -----------------------------------------------------------------------------
# Step 7: Index runbooks via port-forward
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 7: Index Runbooks into pgvector ==="

# Kill any existing port-forward
pkill -f "port-forward.*5433" 2>/dev/null || true
sleep 2

# Start port-forward
kubectl port-forward -n sre-ai-agent-llm \
  $PGVECTOR_POD 5433:5432 &
PF_PID=$!
sleep 5

# Run indexer
cd "$PROJECT_ROOT"
PGHOST=localhost PGPORT=5433 PGDATABASE=sre_agent \
  PGUSER=sre_user PGPASSWORD=sre_pass \
  python -m rag.indexer

# Kill port-forward
kill $PF_PID 2>/dev/null || true

echo "Runbooks indexed!"

# -----------------------------------------------------------------------------
# Step 8: Final status
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 8: Final Status ==="
kubectl get pods -n sre-ai-agent-llm
echo ""
echo "--- Agent Service (LoadBalancer URL) ---"
kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm

echo ""
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo "========================================"
echo " Agent deployed successfully!"
echo ""
echo " Agent URL: http://$AGENT_LB"
echo " Health:    http://$AGENT_LB/agent/health"
echo " API Docs:  http://$AGENT_LB/docs"
echo " History:   http://$AGENT_LB/agent/history"
echo ""
echo " Next: Configure Datadog webhook:"
echo " URL: http://$AGENT_LB/agent/triage"
echo "========================================"