#!/bin/bash
# =============================================================================
# scripts/deploy-pgvector.sh
# Deploy pgvector (PostgreSQL + pgvector extension) to EKS
#
# What it creates:
#   - PersistentVolumeClaim  (EBS volume via gp2 StorageClass)
#   - Deployment             (ankane/pgvector image)
#   - Service                (ClusterIP — internal only, not exposed externally)
#   - Initializes schema:    vector extension + runbook_chunks table + index
#
# Namespace: sre-ai-agent-llm
# Internal DNS: pgvector.sre-ai-agent-llm.svc.cluster.local:5432
#
# Requirements:
#   - EKS cluster running (complete-infra-up.sh done)
#   - EBS CSI Driver installed (done in Step 4 of infra-up)
#   - Namespace sre-ai-agent-llm exists (done in Step 5 of infra-up)
#
# Usage:
#   ./scripts/deploy-pgvector.sh
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

NAMESPACE="sre-ai-agent-llm"
PG_USER="sre_user"
PG_PASSWORD="sre_pass"
PG_DB="sre_agent"

echo ""
log "Deploying pgvector → namespace: $NAMESPACE"

# =============================================================================
# Step 1 — Apply pgvector manifests (PVC + Deployment + Service)
# =============================================================================
step "Step 1 — Applying pgvector manifests"

kubectl apply -f - <<EOF
---
# ── PersistentVolumeClaim ────────────────────────────────────────────────────
# EBS volume backed by gp2 StorageClass (set as default in infra-up Step 4)
# 5Gi is enough for runbook embeddings (384-dim vectors, ~1000 chunks)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pgvector-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp2
  resources:
    requests:
      storage: 5Gi

---
# ── Deployment ───────────────────────────────────────────────────────────────
# ankane/pgvector = official pgvector image (PostgreSQL + vector extension)
# Single replica — pgvector is used for RAG retrieval, not high-write workload
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgvector
  namespace: ${NAMESPACE}
  labels:
    app: pgvector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgvector
  template:
    metadata:
      labels:
        app: pgvector
    spec:
      # Run on app-nodes (not the tainted agent-node)
      nodeSelector:
        role: app
      containers:
        - name: pgvector
          image: ankane/pgvector:latest
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: "${PG_USER}"
            - name: POSTGRES_PASSWORD
              value: "${PG_PASSWORD}"
            - name: POSTGRES_DB
              value: "${PG_DB}"
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: pgvector-storage
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "${PG_USER}", "-d", "${PG_DB}"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "${PG_USER}", "-d", "${PG_DB}"]
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: pgvector-storage
          persistentVolumeClaim:
            claimName: pgvector-pvc

---
# ── Service ──────────────────────────────────────────────────────────────────
# ClusterIP only — pgvector is internal; only the LangGraph agent talks to it
# DNS: pgvector.sre-ai-agent-llm.svc.cluster.local:5432
apiVersion: v1
kind: Service
metadata:
  name: pgvector
  namespace: ${NAMESPACE}
  labels:
    app: pgvector
spec:
  type: ClusterIP
  selector:
    app: pgvector
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
EOF

log "pgvector manifests applied ✓"

# =============================================================================
# Step 2 — Wait for pgvector pod to be Ready
# =============================================================================
step "Step 2 — Waiting for pgvector pod"

kubectl wait --for=condition=Ready pod \
  -l app=pgvector \
  -n "$NAMESPACE" \
  --timeout=120s

log "pgvector pod is Ready ✓"

# =============================================================================
# Step 3 — Initialize schema
# Creates: vector extension, runbook_chunks table, ivfflat index
# =============================================================================
step "Step 3 — Initializing pgvector schema"

PGVECTOR_POD=$(kubectl get pod -n "$NAMESPACE" -l app=pgvector -o name | head -1)

kubectl exec -n "$NAMESPACE" "$PGVECTOR_POD" \
  -- psql -U "$PG_USER" -d "$PG_DB" << 'SQLEOF'
-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Runbook chunks table
-- embedding: 384-dim (all-MiniLM-L6-v2 model used in rag/indexer.py)
CREATE TABLE IF NOT EXISTS runbook_chunks (
  id          SERIAL PRIMARY KEY,
  source      TEXT NOT NULL,        -- runbook filename
  content     TEXT NOT NULL,        -- chunk text
  embedding   vector(384),          -- 384-dim embedding
  created_at  TIMESTAMP DEFAULT NOW()
);

-- IVFFlat index for approximate nearest-neighbour search
-- lists=10 is appropriate for < 10,000 vectors (our runbook size)
CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
  ON runbook_chunks
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 10);

-- Verify
SELECT 'pgvector extension: ' || extversion AS status
  FROM pg_extension WHERE extname = 'vector';
SELECT 'runbook_chunks table ready' AS status;
SQLEOF

log "Schema initialized ✓"

# =============================================================================
# Step 4 — Final status
# =============================================================================
step "Step 4 — Status"

echo ""
kubectl get pod,pvc,svc -n "$NAMESPACE" -l app=pgvector

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  pgvector deployed ✓${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Internal DNS:  pgvector.${NAMESPACE}.svc.cluster.local:5432"
echo "  Database:      ${PG_DB}"
echo "  User:          ${PG_USER}"
echo "  Password:      ${PG_PASSWORD}"
echo ""
echo "  Next: ./scripts/deploy-app.sh"
echo ""