#!/bin/bash
# =============================================================================
# scripts/deploy-agent.sh
# Build, push, and deploy the LangGraph SRE agent to EKS
#
# Steps:
#   1. Create agent ECR repo (if not exists)
#   2. Build and push agent Docker image
#   3. Create agent Kubernetes secret (Gemini API key)
#   4. Deploy agent to EKS (namespace, configmap, deployment, service)
#   5. Initialize pgvector schema
#   6. Index runbooks into pgvector
#
# NOTE: pgvector is deployed by deploy-pgvector.sh (runs before this)
#
# Usage: ./scripts/deploy-agent.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() {
  echo -e "\n${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN} $*${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
}

# Load .env secrets
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -o allexport
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  set +o allexport
fi

AWS_REGION="ap-south-1"
CLUSTER_NAME="sre-ai-agent-cluster"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
AGENT_ECR="${ECR_REGISTRY}/sre-ai-agent-llm"
NAMESPACE="sre-ai-agent-llm"

: "${GEMINI_API_KEY:?ERROR: GEMINI_API_KEY not set in .env}"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Cluster:   $CLUSTER_NAME  |  Region: $AWS_REGION"
log "ECR:       $AGENT_ECR"
log "Namespace: $NAMESPACE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# -----------------------------------------------------------------------------
# Step 1: Create ECR repo
# -----------------------------------------------------------------------------
step "Step 1 — Create Agent ECR Repository"

aws ecr create-repository \
  --repository-name sre-ai-agent-llm \
  --region "$AWS_REGION" \
  2>/dev/null && log "ECR repo created: sre-ai-agent-llm ✓" \
  || warn "ECR repo already exists — skipping"

# -----------------------------------------------------------------------------
# Step 2: Build and push agent Docker image
# -----------------------------------------------------------------------------
step "Step 2 — Build and Push Agent Docker Image"

# Authenticate Docker to ECR (use full ECR_REGISTRY, not bare AWS_ACCOUNT_ID)
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "latest")
log "Git SHA: $GIT_SHA"

# Agent Dockerfile copies from agent/, rag/, docs/runbooks/, vector-db/
# so project root must be the build context
docker build \
  -t "${AGENT_ECR}:${GIT_SHA}" \
  -t "${AGENT_ECR}:latest" \
  -f "$PROJECT_ROOT/agent/Dockerfile" \
  "$PROJECT_ROOT"

docker push "${AGENT_ECR}:${GIT_SHA}"
docker push "${AGENT_ECR}:latest"
log "Agent image pushed: ${AGENT_ECR}:${GIT_SHA} ✓"
log "Agent image pushed: ${AGENT_ECR}:latest ✓"

# -----------------------------------------------------------------------------
# Step 3: Create agent Kubernetes secret
# -----------------------------------------------------------------------------
step "Step 3 — Create Agent Kubernetes Secret"

kubectl create secret generic sre-ai-agent-llm-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_API_KEY" \
  --from-literal=PGPASSWORD="sre_pass" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

log "sre-ai-agent-llm-secret created/updated ✓"

# Refresh ECR pull secret (token expires every 12h)
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
kubectl create secret docker-registry ecr-pull-secret \
  --docker-server="$ECR_REGISTRY" \
  --docker-username=AWS \
  --docker-password="$ECR_PASSWORD" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
log "ECR pull secret refreshed ✓"

# -----------------------------------------------------------------------------
# Step 4: Deploy agent to EKS
# (Namespace already exists from complete-infra-up.sh)
# (pgvector already deployed from deploy-pgvector.sh)
# -----------------------------------------------------------------------------
step "Step 4 — Deploy Agent to EKS"

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: sre-ai-agent-llm-config
  namespace: ${NAMESPACE}
data:
  PGHOST: "pgvector.sre-ai-agent-llm.svc.cluster.local"
  PGPORT: "5432"
  PGDATABASE: "sre_agent"
  PGUSER: "sre_user"
  APP_ENV: "production"
  LOG_LEVEL: "INFO"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sre-ai-agent-llm
  namespace: ${NAMESPACE}
  labels:
    app: sre-ai-agent-llm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sre-ai-agent-llm
  template:
    metadata:
      labels:
        app: sre-ai-agent-llm
      annotations:
        deploy-time: "$(date -u +%Y%m%dT%H%M%SZ)"
    spec:
      nodeSelector:
        role: agent
      tolerations:
        - key: workload
          value: ai-agent
          effect: NoSchedule
      imagePullSecrets:
        - name: ecr-pull-secret
      containers:
        - name: sre-ai-agent-llm
          image: ${AGENT_ECR}:${GIT_SHA}
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8001
          envFrom:
            - configMapRef:
                name: sre-ai-agent-llm-config
          env:
            - name: GEMINI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: sre-ai-agent-llm-secret
                  key: GEMINI_API_KEY
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: sre-ai-agent-llm-secret
                  key: PGPASSWORD
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /agent/health
              port: 8001
            initialDelaySeconds: 15
            periodSeconds: 5
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /agent/health
              port: 8001
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: sre-ai-agent-llm
  namespace: ${NAMESPACE}
  labels:
    app: sre-ai-agent-llm
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
spec:
  type: LoadBalancer
  selector:
    app: sre-ai-agent-llm
  ports:
    - name: http
      port: 80
      targetPort: 8001
EOF

log "Agent manifests applied ✓"

# -----------------------------------------------------------------------------
# Step 5: Wait for agent pod
# -----------------------------------------------------------------------------
step "Step 5 — Waiting for Agent Pod"

kubectl rollout status deployment/sre-ai-agent-llm \
  -n "$NAMESPACE" \
  --timeout=180s

log "Agent deployment rollout complete ✓"

# -----------------------------------------------------------------------------
# Step 6: Initialize pgvector schema
# -----------------------------------------------------------------------------
step "Step 6 — Initialize pgvector schema"

PGVECTOR_POD=$(kubectl get pod -n "$NAMESPACE" -l app=pgvector -o name | head -1)

if [ -z "$PGVECTOR_POD" ]; then
  err "pgvector pod not found in $NAMESPACE — run deploy-pgvector.sh first"
fi

# Use separate -c calls — heredoc piped through kubectl exec is unreliable
kubectl exec -n "$NAMESPACE" "$PGVECTOR_POD" -- \
  psql -U sre_user -d sre_agent -c "CREATE EXTENSION IF NOT EXISTS vector;"

kubectl exec -n "$NAMESPACE" "$PGVECTOR_POD" -- \
  psql -U sre_user -d sre_agent -c "
CREATE TABLE IF NOT EXISTS runbook_chunks (
  id SERIAL PRIMARY KEY,
  source TEXT NOT NULL,
  content TEXT NOT NULL,
  embedding vector(384),
  created_at TIMESTAMP DEFAULT NOW()
);"

kubectl exec -n "$NAMESPACE" "$PGVECTOR_POD" -- \
  psql -U sre_user -d sre_agent -c "
CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
  ON runbook_chunks
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 10);"

# Verify table exists
kubectl exec -n "$NAMESPACE" "$PGVECTOR_POD" -- \
  psql -U sre_user -d sre_agent -c "\dt runbook_chunks" | grep -q runbook_chunks \
  && log "pgvector schema initialized ✓" \
  || err "runbook_chunks table not found after schema init — aborting"

# -----------------------------------------------------------------------------
# Step 7: Index runbooks via Kubernetes Job
# Runs inside the cluster using the agent image (no local Python deps needed)
# -----------------------------------------------------------------------------
step "Step 7 — Index Runbooks into pgvector"

# Delete previous job if exists (jobs are immutable)
kubectl delete job rag-indexer -n "$NAMESPACE" --ignore-not-found=true

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: rag-indexer
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        role: agent
      tolerations:
        - key: workload
          value: ai-agent
          effect: NoSchedule
      imagePullSecrets:
        - name: ecr-pull-secret
      containers:
        - name: indexer
          image: ${AGENT_ECR}:${GIT_SHA}
          command: ["python3", "-m", "rag.indexer"]
          env:
            - name: PGHOST
              value: pgvector.sre-ai-agent-llm.svc.cluster.local
            - name: PGPORT
              value: "5432"
            - name: PGDATABASE
              value: sre_agent
            - name: PGUSER
              value: sre_user
            - name: PGPASSWORD
              value: sre_pass
EOF

log "Waiting for indexer job to complete..."
kubectl wait --for=condition=Complete job/rag-indexer \
  -n "$NAMESPACE" --timeout=300s

kubectl logs job/rag-indexer -n "$NAMESPACE"
log "Runbooks indexed ✓"

# -----------------------------------------------------------------------------
# Step 8: Final status
# -----------------------------------------------------------------------------
step "Step 8 — Status"

echo ""
echo "Pods:"
kubectl get pods -n "$NAMESPACE" -o wide --no-headers | \
  awk '{printf "  %-50s  status=%-12s  node=%s\n", $1, $3, $7}'

echo ""
log "Waiting for LoadBalancer hostname (up to 3 min)..."
AGENT_LB=""
for i in $(seq 1 18); do
  AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  [ -n "$AGENT_LB" ] && break
  sleep 10
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Agent deployed ✓${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Agent URL:  http://${AGENT_LB:-pending}"
echo "  Health:     http://${AGENT_LB:-pending}/agent/health"
echo "  API Docs:   http://${AGENT_LB:-pending}/docs"
echo "  History:    http://${AGENT_LB:-pending}/agent/history"
echo "  Triage:     http://${AGENT_LB:-pending}/agent/triage  ← Grafana webhook"
echo ""
echo "  Image: ${AGENT_ECR}:${GIT_SHA}"
echo ""
echo "  Next: ./scripts/deploy-chaoskube.sh"
echo ""