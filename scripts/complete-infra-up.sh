#!/bin/bash
# =============================================================================
# scripts/infra-up-complete.sh
# Phase 22 — Bootstrap full EKS infrastructure for SRE-AI-Agent-Observability
#
# Infrastructure config is hardcoded here (not in .env).
# Only secrets are loaded from .env:
#   GEMINI_API_KEY
#   GRAFANA_CLOUD_API_KEY
#   GRAFANA_CLOUD_PROMETHEUS_URL
#   GRAFANA_CLOUD_USERNAME
#   LOKI_USER_ID
#
# Usage:
#   ./scripts/infra-up-complete.sh
#
# Teardown:
#   ./scripts/infra-down.sh
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
# Infrastructure config — hardcoded (these are not secrets)
# =============================================================================
AWS_REGION="ap-south-1"
CLUSTER_NAME="sre-ai-agent-cluster"
EKS_VERSION="1.32"

# ECR registry is derived from AWS account — no need to hardcode
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Node group config
APP_NODE_TYPE="t3.small"
APP_NODE_COUNT=3
AGENT_NODE_TYPE="t3.small"
AGENT_NODE_COUNT=1

# Feature flags (disabled — chaoskube replaces LitmusChaos in Phase 24)
INSTALL_DATADOG=false
INSTALL_LITMUSCHAOS=false

# =============================================================================
# Load secrets from .env (only secrets — not infra config)
# =============================================================================
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -o allexport
  source "$PROJECT_ROOT/.env"
  set +o allexport
  log ".env loaded (secrets)"
else
  warn ".env not found — secrets must be exported manually before running"
fi

# Fail fast if secrets are missing
: "${GEMINI_API_KEY:?ERROR: GEMINI_API_KEY not set. Add to .env}"
: "${GRAFANA_CLOUD_API_KEY:?ERROR: GRAFANA_CLOUD_API_KEY not set. Add to .env}"
: "${GRAFANA_CLOUD_PROMETHEUS_URL:?ERROR: GRAFANA_CLOUD_PROMETHEUS_URL not set. Add to .env}"
: "${GRAFANA_CLOUD_USERNAME:?ERROR: GRAFANA_CLOUD_USERNAME not set. Add to .env}"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Cluster:       $CLUSTER_NAME"
log "Region:        $AWS_REGION"
log "Account:       $AWS_ACCOUNT_ID"
log "ECR registry:  $ECR_REGISTRY"
log "App nodes:     ${APP_NODE_COUNT}× $APP_NODE_TYPE (no taint)"
log "Agent nodes:   ${AGENT_NODE_COUNT}× $AGENT_NODE_TYPE (taint: workload=ai-agent:NoSchedule)"
log "Datadog:       $INSTALL_DATADOG"
log "LitmusChaos:   $INSTALL_LITMUSCHAOS"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =============================================================================
# Step 1 — Create EKS cluster
# =============================================================================
step "Step 1 — Creating EKS cluster: $CLUSTER_NAME"

if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
  warn "Cluster '$CLUSTER_NAME' already exists — skipping creation"
else
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --version "$EKS_VERSION" \
    --without-nodegroup \
    --with-oidc
  log "EKS cluster created ✓"
fi

aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"
log "kubeconfig updated ✓"

# =============================================================================
# Step 2 — Create node groups
# =============================================================================
step "Step 2 — Creating node groups"

# app-nodes: 3× t3.small, no taint — runs FastAPI, pgvector, Prometheus, chaoskube
if eksctl get nodegroup --cluster "$CLUSTER_NAME" --name app-nodes --region "$AWS_REGION" &>/dev/null; then
  warn "Node group 'app-nodes' already exists — skipping"
else
  eksctl create nodegroup \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --name app-nodes \
    --node-type "$APP_NODE_TYPE" \
    --nodes "$APP_NODE_COUNT" \
    --nodes-min 2 \
    --nodes-max 4 \
    --node-labels "role=app" \
    --asg-access \
    --managed
  log "app-nodes created (${APP_NODE_COUNT}× $APP_NODE_TYPE) ✓"
fi

# agent-nodes: 1× t3.small, taint workload=ai-agent:NoSchedule — LangGraph only
if eksctl get nodegroup --cluster "$CLUSTER_NAME" --name agent-nodes --region "$AWS_REGION" &>/dev/null; then
  warn "Node group 'agent-nodes' already exists — skipping"
else
  eksctl create nodegroup \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --name agent-nodes \
    --node-type "$AGENT_NODE_TYPE" \
    --nodes "$AGENT_NODE_COUNT" \
    --nodes-min 1 \
    --nodes-max 2 \
    --node-labels "role=agent" \
    --node-taints "workload=ai-agent:NoSchedule" \
    --asg-access \
    --managed
  log "agent-nodes created (${AGENT_NODE_COUNT}× $AGENT_NODE_TYPE, tainted) ✓"
fi

log "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo ""
kubectl get nodes -L role -o wide
log "All nodes Ready ✓"

# =============================================================================
# Step 3 — Install AWS Load Balancer Controller
# =============================================================================
step "Step 3 — Installing AWS Load Balancer Controller"

POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  warn "IAM policy '$POLICY_NAME' already exists — skipping"
else
  curl -sSL \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json \
    -o /tmp/alb-iam-policy.json
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document file:///tmp/alb-iam-policy.json
  log "IAM policy created ✓"
fi

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn "$POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve 2>/dev/null || warn "ALB IRSA already exists — continuing"

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version 1.11.0 \  
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --timeout 5m \
  --wait

log "AWS Load Balancer Controller installed ✓"

# =============================================================================
# Step 4 — Install EBS CSI Driver (needed for pgvector PVC)
# =============================================================================
step "Step 4 — Installing EBS CSI Driver"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --override-existing-serviceaccounts \
  --approve 2>/dev/null || warn "EBS CSI IRSA already exists — continuing"

EBS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa-Role1"

aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "$EBS_ROLE_ARN" \
  --region "$AWS_REGION" 2>/dev/null || warn "EBS CSI addon already exists — continuing"

# Patch gp2 to be the default StorageClass
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  2>/dev/null || warn "gp2 patch skipped (may already be default)"

log "EBS CSI Driver installed ✓"

# =============================================================================
# Step 5 — Create namespaces
# =============================================================================
step "Step 5 — Creating namespaces"

for NS in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  log "Namespace ready: $NS"
done

# =============================================================================
# Step 6 — ECR pull secrets
# =============================================================================
step "Step 6 — Creating ECR pull secrets"

ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")

for NS in sre-ai-agent sre-ai-agent-llm; do
  kubectl create secret docker-registry ecr-pull-secret \
    --docker-server="$ECR_REGISTRY" \
    --docker-username=AWS \
    --docker-password="$ECR_PASSWORD" \
    --namespace "$NS" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "ECR pull secret → namespace: $NS ✓"
done

# =============================================================================
# Step 7 — Secrets (from .env)
# =============================================================================
step "Step 7 — Creating Kubernetes secrets from .env"

# GEMINI_API_KEY → sre-ai-agent-llm
kubectl create secret generic gemini-api-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_API_KEY" \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -
log "gemini-api-secret → sre-ai-agent-llm ✓"

# Grafana Cloud credentials → monitoring
kubectl create secret generic grafana-cloud-secret \
  --from-literal=api-key="$GRAFANA_CLOUD_API_KEY" \
  --from-literal=prometheus-user="$GRAFANA_CLOUD_USERNAME" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -
log "grafana-cloud-secret → monitoring ✓"

# =============================================================================
# Step 8 — Install kube-prometheus-stack
# =============================================================================
step "Step 8 — Installing kube-prometheus-stack"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

cat > /tmp/kube-prometheus-values.yaml << EOF
prometheus:
  prometheusSpec:
    retention: 2h
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
    remoteWrite:
      - url: "${GRAFANA_CLOUD_PROMETHEUS_URL}"
        basicAuth:
          username:
            name: grafana-cloud-secret
            key: prometheus-user
          password:
            name: grafana-cloud-secret
            key: api-key
        writeRelabelConfigs:
          - sourceLabels: [__name__]
            regex: 'kube_pod_container_restarts_total|http_requests_total|http_request_duration_seconds.*|up|kube_pod_status_phase'
            action: keep
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorNamespaceSelector:
      matchNames:
        - sre-ai-agent
        - sre-ai-agent-llm
        - monitoring
        - chaos

grafana:
  enabled: true
  adminPassword: "admin"
  resources:
    requests:
      cpu: 100m
      memory: 128Mi

alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
EOF

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f /tmp/kube-prometheus-values.yaml \
  --timeout 10m \
  --wait

log "kube-prometheus-stack installed ✓"

# =============================================================================
# Step 9 — ServiceMonitor + PrometheusRules for sre-ai-agent
# =============================================================================
step "Step 9 — Applying ServiceMonitor and PrometheusRules"

kubectl apply -f - << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: sre-ai-agent-monitor
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - sre-ai-agent
  selector:
    matchLabels:
      app: sre-ai-agent
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
EOF

kubectl apply -f - << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: sre-ai-agent-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: sre-ai-agent
      interval: 30s
      rules:
        - alert: PodRestartRateHigh
          expr: rate(kube_pod_container_restarts_total{namespace="sre-ai-agent"}[2m]) > 0.1
          for: 1m
          labels:
            severity: warning
            namespace: sre-ai-agent
          annotations:
            summary: "Pod restart rate high in sre-ai-agent"
            description: "Pod {{ $labels.pod }} restarting > 0.1/s"

        - alert: HighErrorRate
          expr: |
            rate(http_requests_total{namespace="sre-ai-agent",status=~"5.."}[5m])
            / rate(http_requests_total{namespace="sre-ai-agent"}[5m]) > 0.05
          for: 2m
          labels:
            severity: warning
            namespace: sre-ai-agent
          annotations:
            summary: "HTTP error rate > 5%"
            description: "Error rate {{ $value | humanizePercentage }}"

        - alert: HighP99Latency
          expr: |
            histogram_quantile(0.99,
              rate(http_request_duration_seconds_bucket{namespace="sre-ai-agent"}[5m])
            ) > 1.0
          for: 2m
          labels:
            severity: warning
            namespace: sre-ai-agent
          annotations:
            summary: "p99 latency > 1s"
            description: "p99 = {{ $value | humanizeDuration }}"
EOF

log "ServiceMonitor + PrometheusRules applied ✓"

# =============================================================================
# Step 10 — Feature flags
# =============================================================================
step "Step 10 — Feature flags"

if [ "$INSTALL_DATADOG" = "true" ]; then
  warn "INSTALL_DATADOG=true — not implemented (not used in this project)"
else
  log "INSTALL_DATADOG=false — skipped ✓"
fi

if [ "$INSTALL_LITMUSCHAOS" = "true" ]; then
  warn "INSTALL_LITMUSCHAOS=true — not implemented (use deploy-chaoskube.sh instead)"
else
  log "INSTALL_LITMUSCHAOS=false — skipped (chaoskube used in Phase 24) ✓"
fi

# =============================================================================
# Summary
# =============================================================================
step "Infrastructure ready ✓"

echo ""
log "Cluster:  $CLUSTER_NAME  |  Region: $AWS_REGION"
echo ""
log "Nodes:"
kubectl get nodes -L role --no-headers | \
  awk '{printf "  %-50s  status=%-8s  role=%s\n", $1, $2, $NF}'
echo ""
log "Namespaces:"
for NS in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
  STATUS=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "missing")
  printf "  %-28s %s\n" "$NS" "$STATUS"
done
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Infrastructure ready — running deploy scripts"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
 
# =============================================================================
# Auto-deploy — runs all 5 deploy scripts serially
# Each script is idempotent — safe to re-run if one fails
# =============================================================================
 
DEPLOY_SCRIPTS=(
  "$SCRIPT_DIR/deploy-pgvector.sh"
  "$SCRIPT_DIR/deploy-app.sh"
  "$SCRIPT_DIR/deploy-agent.sh"
  "$SCRIPT_DIR/deploy-chaoskube.sh"
  "$SCRIPT_DIR/deploy-loki-promtail.sh"
)
 
TOTAL=${#DEPLOY_SCRIPTS[@]}
CURRENT=0
 
for DEPLOY in "${DEPLOY_SCRIPTS[@]}"; do
  CURRENT=$((CURRENT + 1))
  SCRIPT_NAME=$(basename "$DEPLOY")
 
  step "Deploy $CURRENT/$TOTAL — $SCRIPT_NAME"
 
  if [ ! -f "$DEPLOY" ]; then
    err "Script not found: $DEPLOY — aborting"
  fi
 
  chmod +x "$DEPLOY"
  bash "$DEPLOY" || {
    echo ""
    err "Deploy script failed: $SCRIPT_NAME"
    echo ""
    echo "  Fix the issue above and re-run from this step:"
    echo "    bash $DEPLOY"
    echo ""
    echo "  Or re-run remaining scripts manually:"
    for REMAINING in "${DEPLOY_SCRIPTS[@]}"; do
      if [ "$REMAINING" = "$DEPLOY" ] || [ "$REMAINING" \> "$DEPLOY" ]; then
        echo "    bash $REMAINING"
      fi
    done
    exit 1
  }
 
  log "$SCRIPT_NAME completed ✓"
done
 
# =============================================================================
# Full stack summary
# =============================================================================
step "Full stack deployed ✓"
 
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Everything is UP  🚀${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
 
echo "  Cluster:  $CLUSTER_NAME  |  $AWS_REGION"
echo ""
 
echo "  Nodes:"
kubectl get nodes -L role --no-headers | \
  awk '{printf "  %-50s  status=%-8s  role=%s\n", $1, $2, $NF}'
echo ""
 
echo "  Pods (all namespaces):"
for NS in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
  kubectl get pods -n "$NS" --no-headers 2>/dev/null | \
    awk -v ns="$NS" '{printf "  [%-20s]  %-45s  %s\n", ns, $1, $3}' || true
done
echo ""
 
APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
 
echo "  URLs:"
echo "    App health:    http://${APP_LB}/api/health"
echo "    App docs:      http://${APP_LB}/docs"
echo "    Agent health:  http://${AGENT_LB}/agent/health"
echo "    Agent triage:  http://${AGENT_LB}/agent/triage   ← Grafana webhook"
echo ""
echo "  ⚠️  Update Grafana Cloud webhook URL to:"
echo "     http://${AGENT_LB}/agent/triage"
echo ""
echo "  Chaos flow active:"
echo "    chaoskube kills pod every 2m → Prometheus alert →"
echo "    webhook → LangGraph RCA → Loki logs"
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Run infra-down.sh when done to avoid AWS costs"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
 