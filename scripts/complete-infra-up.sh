#!/bin/bash
# =============================================================================
# scripts/complete-infra-up.sh
# Bootstrap full EKS infrastructure for SRE-AI-Agent-Observability
#
# Idempotent — safe to re-run. Every step checks if resources already exist.
#
# Secrets loaded from .env:
#   GEMINI_API_KEY
#   GRAFANA_CLOUD_API_KEY
#   GRAFANA_CLOUD_REMOTE_WRITE_URL
#   GRAFANA_CLOUD_USERNAME
#   LOKI_USER_ID
#
# Usage:    ./scripts/complete-infra-up.sh
# Teardown: ./scripts/infra-down.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Colour helpers ─────────────────────────────────────────────────────────
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
# Infrastructure config — hardcoded (not secrets)
# =============================================================================
AWS_REGION="ap-south-1"
CLUSTER_NAME="sre-ai-agent-cluster"
EKS_VERSION="1.32"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

APP_NODE_TYPE="t3.small"
APP_NODE_COUNT=3
AGENT_NODE_TYPE="t3.small"
AGENT_NODE_COUNT=1

INSTALL_DATADOG=false
INSTALL_LITMUSCHAOS=false

# Pinned chart versions — avoids GitHub download timeouts on helm repo update
ALB_CHART_VERSION="1.11.0"
PROM_CHART_VERSION="92.7.0"

# =============================================================================
# Load secrets from .env
# =============================================================================
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -o allexport
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  set +o allexport
  log ".env loaded ✓"
else
  warn ".env not found — secrets must be exported manually"
fi

: "${GEMINI_API_KEY:?ERROR: GEMINI_API_KEY not set}"
: "${GRAFANA_CLOUD_API_KEY:?ERROR: GRAFANA_CLOUD_API_KEY not set}"
: "${GRAFANA_CLOUD_REMOTE_WRITE_URL:?ERROR: GRAFANA_CLOUD_REMOTE_WRITE_URL not set}"
: "${GRAFANA_CLOUD_USERNAME:?ERROR: GRAFANA_CLOUD_USERNAME not set}"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Cluster:      $CLUSTER_NAME  |  $AWS_REGION"
log "Account:      $AWS_ACCOUNT_ID"
log "ECR:          $ECR_REGISTRY"
log "App nodes:    ${APP_NODE_COUNT}× $APP_NODE_TYPE"
log "Agent nodes:  ${AGENT_NODE_COUNT}× $AGENT_NODE_TYPE (taint: workload=ai-agent:NoSchedule)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =============================================================================
# Step 1 — EKS cluster
# =============================================================================
step "Step 1 — EKS cluster"

if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
  warn "Cluster '$CLUSTER_NAME' already exists — skipping"
else
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --version "$EKS_VERSION" \
    --without-nodegroup \
    --with-oidc
  log "EKS cluster created ✓"
fi

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
log "kubeconfig updated ✓"

# =============================================================================
# Step 2 — Node groups
# =============================================================================
step "Step 2 — Node groups"

# app-nodes — no taint
if eksctl get nodegroup --cluster "$CLUSTER_NAME" --name app-nodes --region "$AWS_REGION" &>/dev/null; then
  warn "app-nodes already exists — skipping"
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

# agent-nodes — taint via config file (--node-taints flag removed in eksctl 0.180+)
if eksctl get nodegroup --cluster "$CLUSTER_NAME" --name agent-nodes --region "$AWS_REGION" &>/dev/null; then
  warn "agent-nodes already exists — skipping"
else
  cat <<EOF | eksctl create nodegroup -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
managedNodeGroups:
  - name: agent-nodes
    instanceType: ${AGENT_NODE_TYPE}
    desiredCapacity: ${AGENT_NODE_COUNT}
    minSize: 1
    maxSize: 2
    labels:
      role: agent
    taints:
      - key: workload
        value: ai-agent
        effect: NoSchedule
    tags:
      Project: sre-ai-agent
EOF
  log "agent-nodes created (${AGENT_NODE_COUNT}× $AGENT_NODE_TYPE, taint: workload=ai-agent:NoSchedule) ✓"
fi

log "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo ""
kubectl get nodes -L role
log "All nodes Ready ✓"

# =============================================================================
# Step 3 — AWS Load Balancer Controller
# =============================================================================
step "Step 3 — AWS Load Balancer Controller"

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

# Add repo only; skip global helm repo update to avoid GitHub download timeouts
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks 2>/dev/null || true

VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

# Check if already installed at this version
ALB_INSTALLED=$(helm list -n kube-system -q | grep "^aws-load-balancer-controller$" || true)
if [ -n "$ALB_INSTALLED" ]; then
  warn "aws-load-balancer-controller already installed — upgrading in place"
fi

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "$ALB_CHART_VERSION" \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --timeout 5m

kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  -n kube-system \
  --timeout=120s

log "AWS Load Balancer Controller v${ALB_CHART_VERSION} installed ✓"

# =============================================================================
# Step 4 — EBS CSI Driver
# =============================================================================
step "Step 4 — EBS CSI Driver"

# Build trust policy directly — avoids eksctl CloudFormation ghost-state bug
# where eksctl silently skips if SA exists in K8s but CFN stack is gone (or vice versa)
OIDC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.identity.oidc.issuer' \
  --output text | sed 's|https://||')

EBS_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
EBS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EBS_ROLE_NAME}"

if aws iam get-role --role-name "$EBS_ROLE_NAME" &>/dev/null; then
  warn "IAM role $EBS_ROLE_NAME already exists — skipping"
else
  cat > /tmp/ebs-trust-policy.json <<TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ID}:aud": "sts.amazonaws.com",
          "${OIDC_ID}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }
  ]
}
TRUSTEOF

  aws iam create-role \
    --role-name "$EBS_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ebs-trust-policy.json
  aws iam attach-role-policy \
    --role-name "$EBS_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
  log "IAM role $EBS_ROLE_NAME created ✓"
fi

# Create SA with IRSA annotation (idempotent)
if kubectl get sa ebs-csi-controller-sa -n kube-system &>/dev/null; then
  # Ensure annotation is set (may be missing if SA was created without it)
  kubectl annotate serviceaccount ebs-csi-controller-sa \
    -n kube-system \
    eks.amazonaws.com/role-arn="$EBS_ROLE_ARN" \
    --overwrite
  warn "ebs-csi-controller-sa already exists — annotation updated"
else
  kubectl create serviceaccount ebs-csi-controller-sa -n kube-system
  kubectl annotate serviceaccount ebs-csi-controller-sa \
    -n kube-system \
    eks.amazonaws.com/role-arn="$EBS_ROLE_ARN"
  log "ebs-csi-controller-sa created with IRSA annotation ✓"
fi

# Handle CREATE_FAILED by deleting and recreating
ADDON_STATUS=$(aws eks describe-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --region "$AWS_REGION" \
  --query 'addon.status' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$ADDON_STATUS" = "ACTIVE" ]; then
  warn "EBS CSI addon already ACTIVE — skipping"
elif [ "$ADDON_STATUS" = "CREATE_FAILED" ]; then
  warn "EBS CSI addon in CREATE_FAILED state — deleting and recreating"
  aws eks delete-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --region "$AWS_REGION"
  sleep 10
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --service-account-role-arn "$EBS_ROLE_ARN" \
    --region "$AWS_REGION"
  log "EBS CSI addon recreated ✓"
else
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --service-account-role-arn "$EBS_ROLE_ARN" \
    --region "$AWS_REGION"
  log "EBS CSI addon created ✓"
fi

log "Waiting for EBS CSI addon to become ACTIVE..."
aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --region "$AWS_REGION"
log "EBS CSI Driver ACTIVE ✓"

kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  2>/dev/null || warn "gp2 already default or not found — continuing"

log "EBS CSI Driver ready ✓"

# =============================================================================
# Step 5 — Namespaces
# =============================================================================
step "Step 5 — Namespaces"

for NS in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  log "Namespace ready: $NS ✓"
done

# =============================================================================
# Step 6 — ECR pull secrets
# =============================================================================
step "Step 6 — ECR pull secrets"

ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")

for NS in sre-ai-agent sre-ai-agent-llm; do
  kubectl create secret docker-registry ecr-pull-secret \
    --docker-server="$ECR_REGISTRY" \
    --docker-username=AWS \
    --docker-password="$ECR_PASSWORD" \
    --namespace "$NS" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "ECR pull secret → $NS ✓"
done

# =============================================================================
# Step 7 — Kubernetes secrets from .env
# =============================================================================
step "Step 7 — Kubernetes secrets"

kubectl create secret generic gemini-api-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_API_KEY" \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -
log "gemini-api-secret → sre-ai-agent-llm ✓"

kubectl create secret generic grafana-cloud-secret \
  --from-literal=api-key="$GRAFANA_CLOUD_API_KEY" \
  --from-literal=prometheus-user="$GRAFANA_CLOUD_USERNAME" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -
log "grafana-cloud-secret → monitoring ✓"

# =============================================================================
# Step 8 — kube-prometheus-stack
# =============================================================================
step "Step 8 — kube-prometheus-stack"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
# Update only the prometheus-community repo — avoids GitHub download timeouts
helm repo update prometheus-community 2>/dev/null || true

cat > /tmp/kube-prometheus-values.yaml <<EOF
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
      - url: "${GRAFANA_CLOUD_REMOTE_WRITE_URL}"
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
    serviceMonitorNamespaceSelector: {}
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

# --version pins to cached chart, no --wait (avoids HTTP/2 hang)
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f /tmp/kube-prometheus-values.yaml \
  --version "$PROM_CHART_VERSION" \
  --timeout 10m

# Poll pods instead of --wait
log "Waiting for Prometheus operator..."
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus-operator \
  -n monitoring --timeout=180s

log "Waiting for Prometheus..."
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n monitoring --timeout=300s

log "kube-prometheus-stack v${PROM_CHART_VERSION} installed ✓"

# =============================================================================
# Step 9 — ServiceMonitor + PrometheusRules
# =============================================================================
step "Step 9 — ServiceMonitor + PrometheusRules"

kubectl apply -f - <<'EOF'
---
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
---
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
  warn "INSTALL_LITMUSCHAOS=true — not implemented (use deploy-chaoskube.sh)"
else
  log "INSTALL_LITMUSCHAOS=false — skipped (chaoskube used instead) ✓"
fi

# =============================================================================
# Infrastructure summary
# =============================================================================
step "Infrastructure ready ✓"

echo ""
log "Cluster:  $CLUSTER_NAME  |  $AWS_REGION"
echo ""
kubectl get nodes -L role --no-headers | \
  awk '{printf "  %-52s  status=%-8s  role=%s\n", $1, $2, $NF}'
echo ""
for NS in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
  STATUS=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "missing")
  printf "  namespace/%-28s %s\n" "$NS" "$STATUS"
done
echo ""

# =============================================================================
# Deploy all components serially
# Each deploy script is idempotent — safe to re-run
# =============================================================================
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Running deploy scripts..."
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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
  if ! bash "$DEPLOY"; then
    echo ""
    echo -e "${RED}[ERROR]${NC} Deploy failed: $SCRIPT_NAME"
    echo ""
    echo "  Fix the issue above then re-run:"
    echo "    bash $DEPLOY"
    echo ""
    echo "  Remaining scripts to run after fix:"
    FOUND=false
    for R in "${DEPLOY_SCRIPTS[@]}"; do
      [ "$R" = "$DEPLOY" ] && FOUND=true
      [ "$FOUND" = true ] && echo "    bash $R"
    done
    exit 1
  fi

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
  awk '{printf "  %-52s  status=%-8s  role=%s\n", $1, $2, $NF}'
echo ""
echo "  Pods:"
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
echo "  ⚠️  Set Grafana Cloud contact point webhook to:"
echo "      http://${AGENT_LB}/agent/triage"
echo ""
echo "  Chaos flow:"
echo "    chaoskube kills pod every 2m → Prometheus alert →"
echo "    webhook → LangGraph agent RCA → Loki logs"
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Run ./scripts/infra-down.sh when done to avoid AWS costs"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"