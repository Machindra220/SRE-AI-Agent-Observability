AI-Agent-Observability$ cat scripts/deploy-app.sh
#!/bin/bash
# =============================================================================
# scripts/deploy-app.sh
# Build, push, and deploy the FastAPI SRE app to EKS
#
# What it does:
#   1. Creates ECR repository (sre-ai-agent) if not exists
#   2. Builds Docker image from app/Dockerfile
#   3. Pushes to ECR with :latest and :<git-sha> tags
#   4. Deploys to EKS namespace sre-ai-agent:
#        - ConfigMap   (non-secret env vars)
#        - Deployment  (FastAPI app, 2 replicas on app-nodes)
#        - Service     (LoadBalancer — exposes app externally via ALB)
#        - HPA         (auto-scale 2→6 replicas on CPU > 70%)
#   5. Waits for pods to be Ready
#   6. Prints the LoadBalancer URL
#
# App endpoints:
#   GET /api/health    ← liveness probe
#   GET /api/ready     ← readiness probe
#   GET /api/products  ← dummy products
#   GET /api/orders    ← dummy orders
#   GET /api/users     ← dummy users
#   GET /api/slow      ← random 2-5s delay (triggers latency alerts)
#   GET /api/error     ← random 400/500 (triggers error rate alerts)
#
# Namespace:   sre-ai-agent
# ECR repo:    sre-ai-agent
# Dockerfile:  app/Dockerfile
# App port:    8080
#
# Requirements:
#   - complete-infra-up.sh done (cluster, namespaces, ECR pull secret, ALB controller)
#   - Docker running locally
#   - .env file with secrets
#
# Usage:
#   ./scripts/deploy-app.sh
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

# =============================================================================
# Config — matches complete-infra-up.sh
# =============================================================================
AWS_REGION="ap-south-1"
CLUSTER_NAME="sre-ai-agent-cluster"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

APP_ECR_REPO="sre-ai-agent"
APP_ECR="${ECR_REGISTRY}/${APP_ECR_REPO}"
NAMESPACE="sre-ai-agent"
APP_NAME="sre-ai-agent"
APP_PORT=8080          # uvicorn runs on 8080 (main.py line 133)
REPLICAS=2

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Cluster:   $CLUSTER_NAME  |  Region: $AWS_REGION"
log "ECR:       $APP_ECR"
log "Namespace: $NAMESPACE"
log "App port:  $APP_PORT"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =============================================================================
# Step 1 — Create ECR repository
# =============================================================================
step "Step 1 — Creating ECR repository: $APP_ECR_REPO"

aws ecr create-repository \
  --repository-name "$APP_ECR_REPO" \
  --region "$AWS_REGION" \
  2>/dev/null && log "ECR repo created: $APP_ECR_REPO ✓" \
  || warn "ECR repo already exists — skipping"

# =============================================================================
# Step 2 — Build and push Docker image
# =============================================================================
step "Step 2 — Building and pushing Docker image"

# Authenticate Docker to ECR
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "latest")
log "Git SHA: $GIT_SHA"

# Build with app/ as the context — Dockerfile references src/ relative to app/
docker build \
  -t "${APP_ECR}:${GIT_SHA}" \
  -t "${APP_ECR}:latest" \
  "$PROJECT_ROOT/app"

docker push "${APP_ECR}:${GIT_SHA}"
docker push "${APP_ECR}:latest"

log "Image pushed: ${APP_ECR}:${GIT_SHA} ✓"
log "Image pushed: ${APP_ECR}:latest ✓"

# =============================================================================
# Step 3 — Refresh ECR pull secret
# (ECR token expires every 12h — regenerate on each deploy)
# =============================================================================
step "Step 3 — Refreshing ECR pull secret"

ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
kubectl create secret docker-registry ecr-pull-secret \
  --docker-server="$ECR_REGISTRY" \
  --docker-username=AWS \
  --docker-password="$ECR_PASSWORD" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

log "ECR pull secret refreshed ✓"

# =============================================================================
# Step 4 — Deploy to EKS
# =============================================================================
step "Step 4 — Deploying to EKS"

kubectl apply -f - <<EOF
---
# ── ConfigMap — non-secret env vars ─────────────────────────────────────────
apiVersion: v1
kind: ConfigMap
metadata:
  name: sre-ai-agent-config
  namespace: ${NAMESPACE}
data:
  APP_ENV: "production"
  LOG_LEVEL: "INFO"
  PORT: "${APP_PORT}"

---
# ── Deployment ───────────────────────────────────────────────────────────────
# App runs on port 8080 (uvicorn in main.py)
# Health:     GET /api/health  ← liveness
# Readiness:  GET /api/ready   ← readiness
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${APP_NAME}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0        # zero-downtime rolling deploy
  template:
    metadata:
      labels:
        app: ${APP_NAME}
      annotations:
        deploy-time: "$(date -u +%Y%m%dT%H%M%SZ)"
    spec:
      # Run on app-nodes only (not the tainted agent-node)
      nodeSelector:
        role: app
      # Spread 2 replicas across different nodes — HA
      # One node failure does NOT kill all traffic
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: ${APP_NAME}
              topologyKey: kubernetes.io/hostname
      imagePullSecrets:
        - name: ecr-pull-secret
      containers:
        - name: ${APP_NAME}
          image: ${APP_ECR}:${GIT_SHA}
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: ${APP_PORT}
          envFrom:
            - configMapRef:
                name: sre-ai-agent-config
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          # Readiness: /api/ready — stops traffic until pod is truly ready
          readinessProbe:
            httpGet:
              path: /api/ready
              port: ${APP_PORT}
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          # Liveness: /api/health — restarts pod if it becomes unhealthy
          livenessProbe:
            httpGet:
              path: /api/health
              port: ${APP_PORT}
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3

---
# ── Service — LoadBalancer (ALB via AWS Load Balancer Controller) ─────────────
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
spec:
  type: LoadBalancer
  selector:
    app: ${APP_NAME}
  ports:
    - name: http
      port: 80
      targetPort: ${APP_PORT}

---
# ── HPA — auto-scale 2→6 replicas at 70% CPU ────────────────────────────────
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_NAME}-hpa
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP_NAME}
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
EOF

log "Manifests applied ✓"

# =============================================================================
# Step 5 — Wait for rollout
# =============================================================================
step "Step 5 — Waiting for pods to be Ready"

kubectl rollout status deployment/"$APP_NAME" \
  -n "$NAMESPACE" \
  --timeout=180s

log "Deployment rollout complete ✓"

# =============================================================================
# Step 6 — Final status + LB URL
# =============================================================================
step "Step 6 — Status"

echo ""
echo "Pods:"
kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME" \
  -o wide --no-headers | \
  awk '{printf "  %-50s  status=%-12s  node=%s\n", $1, $3, $7}'

echo ""
echo "HPA:"
kubectl get hpa "${APP_NAME}-hpa" -n "$NAMESPACE" --no-headers 2>/dev/null | \
  awk '{printf "  replicas: %s/%s  cpu: %s\n", $6, $7, $5}' || true

echo ""
log "Waiting for LoadBalancer hostname (up to 3 min)..."
APP_LB=""
for i in $(seq 1 18); do
  APP_LB=$(kubectl get svc "$APP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$APP_LB" ]; then
    break
  fi
  sleep 10
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  FastAPI app deployed ✓${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -n "$APP_LB" ]; then
  echo "  App URL:      http://${APP_LB}"
  echo "  Health:       http://${APP_LB}/api/health"
  echo "  Ready:        http://${APP_LB}/api/ready"
  echo "  API Docs:     http://${APP_LB}/docs"
  echo "  Products:     http://${APP_LB}/api/products"
  echo "  Slow (test):  http://${APP_LB}/api/slow"
  echo "  Error (test): http://${APP_LB}/api/error"
else
  warn "LoadBalancer hostname not yet assigned — check in a few minutes:"
  echo "  kubectl get svc ${APP_NAME} -n ${NAMESPACE}"
fi

echo ""
echo "  Image: ${APP_ECR}:${GIT_SHA}"
echo ""
echo "  Next: ./scripts/deploy-agent.sh"
echo ""machindra@DESKTOP-EO7I576:~/SRE-AI-Agent-Observability$