# Deployment Runbook — SRE AI Agent Observability Platform

> Follow this document step by step to deploy the complete project.
> Estimated time: 45-60 minutes for full deployment.
> Repo: https://github.com/Machindra220/SRE-AI-Agent-Observability

---

## Table of Contents

1. [Pre-flight Checklist](#1-pre-flight-checklist)
2. [Session Startup](#2-session-startup)
3. [Deploy Complete Infrastructure](#3-deploy-complete-infrastructure)
4. [Verify All Services](#4-verify-all-services)
5. [Post-Deploy Configuration](#5-post-deploy-configuration)
6. [Test End-to-End](#6-test-end-to-end)
7. [Demo Flow](#7-demo-flow)
8. [Teardown](#8-teardown)
9. [Debug Commands](#9-debug-commands)
10. [Common Issues and Fixes](#10-common-issues-and-fixes)

---

## 1. Pre-flight Checklist

Before starting — verify everything is ready:

```bash
# Open Git Bash in project folder
cd ~/Downloads/AI_Observability_project/SRE-AI-Agent-Observability

# Check tools
git --version          # should show 2.x
aws --version          # should show 2.x
kubectl version --client  # should show v1.32
terraform --version    # should show v1.x
helm version           # should show v4.x
python --version       # should show 3.12.x
docker --version       # should show 28.x

# Check Docker Desktop is running
docker ps              # should not error

# Check AWS connected
aws sts get-caller-identity
# Should show: 502274764708, terraform-local-user
```

✅ All green → proceed to Step 2
❌ Any errors → see [Debug Commands](#9-debug-commands)

---

## 2. Session Startup

```bash
# 1. Open Docker Desktop on Windows — wait for green status

# 2. Open Git Bash
cd ~/Downloads/AI_Observability_project/SRE-AI-Agent-Observability

# 3. Activate Python venv
source .venv/Scripts/activate
# Prompt should show: ((.venv))

# 4. Fix python3 alias (required for Git Bash on Windows)
alias python3='python'

# 5. Load AWS secrets
source scripts/load-secrets.sh
# Should show: DD_API_KEY loaded, DD_APP_KEY loaded, AWS keys loaded

# 6. Verify keys loaded
echo "DD_API_KEY: ${DD_API_KEY:0:8}..."
echo "Agent ready to deploy"
```

---

## 3. Deploy Complete Infrastructure

### Option A — One Command (Recommended)

```bash
./scripts/infra-up-complete.sh
```

**Timeline:**
```
0-20 min  → Terraform creates EKS + VPC + ECR
20-22 min → kubectl connects to EKS
22-25 min → Docker builds and pushes app + agent images
25-27 min → K8s manifests deployed
27-32 min → Datadog agent installed via Helm
32-35 min → DNS Route53 updated
35-40 min → pgvector + agent deployed
40-42 min → Runbooks indexed (14 chunks)
42-47 min → Prometheus + Grafana (needs t3.medium)
47-52 min → LitmusChaos (needs t3.medium)
```

### Option B — Step by Step (if script fails midway)

**Step 1 — Terraform EKS**
```bash
cd infrastructure/terraform/eks
terraform init
terraform apply -auto-approve
cd ../../..
```

**Step 2 — Connect kubectl**
```bash
aws eks update-kubeconfig \
  --name sre-ai-agent-dev-eks-cluster \
  --region us-east-1

kubectl get nodes
# Wait until nodes show Ready
```

**Step 3 — Build and push images**
```bash
# ECR login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  502274764708.dkr.ecr.us-east-1.amazonaws.com

# App image
APP_ECR="502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-dev-ecr-api"
docker build -t ${APP_ECR}:latest ./app
docker push ${APP_ECR}:latest

# Agent image
AGENT_ECR="502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-llm"
aws ecr create-repository --repository-name sre-ai-agent-llm \
  --region us-east-1 2>/dev/null || true
docker build -t ${AGENT_ECR}:latest -f agent/Dockerfile .
docker push ${AGENT_ECR}:latest
```

**Step 4 — Deploy app**
```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/hpa.yaml

kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent -n sre-ai-agent --timeout=120s
```

**Step 5 — Install Datadog (secret FIRST)**
```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Create secret BEFORE helm install
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace sre-ai-agent \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install datadog-agent datadog/datadog \
  --namespace sre-ai-agent \
  --values infrastructure/helm/datadog/values.yaml \
  --timeout 10m
```

**Step 6 — Update DNS**
```bash
# Get app LoadBalancer URL
APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "App LB: $APP_LB"

# Update variables.tf with new LB
sed -i "s|default = \".*\.elb\.amazonaws\.com\"|default = \"$APP_LB\"|" \
  infrastructure/terraform/dns/variables.tf

# Apply DNS
cd infrastructure/terraform/dns
terraform init
terraform apply -auto-approve
cd ../../..
```

**Step 7 — Deploy pgvector + agent**
```bash
kubectl apply -f kubernetes/agent-namespace.yaml
kubectl apply -f kubernetes/pgvector-deployment.yaml
kubectl apply -f kubernetes/pgvector-service.yaml

kubectl wait --for=condition=Ready pod \
  -l app=pgvector -n sre-ai-agent-llm --timeout=120s

# Create agent secret
GEMINI_KEY=$(grep GEMINI_API_KEY .env | cut -d'=' -f2)
kubectl create secret generic sre-ai-agent-llm-secret \
  --from-literal=GEMINI_API_KEY="$GEMINI_KEY" \
  --from-literal=PGPASSWORD="sre_pass" \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f kubernetes/agent-configmap.yaml
kubectl apply -f kubernetes/agent-deployment.yaml
kubectl apply -f kubernetes/agent-service.yaml

kubectl wait --for=condition=Ready pod \
  -l app=sre-ai-agent-llm -n sre-ai-agent-llm --timeout=180s
```

**Step 8 — Initialize pgvector schema**
```bash
PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm \
  -l app=pgvector -o name | head -1)

kubectl exec -n sre-ai-agent-llm $PGVECTOR_POD \
  -- psql -U sre_user -d sre_agent -c "
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE TABLE IF NOT EXISTS runbook_chunks (
      id SERIAL PRIMARY KEY,
      source TEXT NOT NULL,
      content TEXT NOT NULL,
      embedding vector(384),
      created_at TIMESTAMP DEFAULT NOW()
    );"
```

**Step 9 — Index runbooks**
```bash
PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm \
  -l app=pgvector -o name | head -1)

# Kill any existing port-forward
pkill -f "port-forward.*5433" 2>/dev/null || true
sleep 2

kubectl port-forward -n sre-ai-agent-llm $PGVECTOR_POD 5433:5432 &
sleep 8

PGHOST=localhost PGPORT=5433 PGDATABASE=sre_agent \
  PGUSER=sre_user PGPASSWORD=sre_pass \
  python -m rag.indexer

pkill -f "port-forward.*5433" 2>/dev/null || true
```

**Step 10 — Deploy Prometheus + Grafana (needs t3.medium nodes)**
```bash
bash scripts/deploy-monitoring.sh
```

**Step 11 — Deploy LitmusChaos (needs t3.medium nodes)**
```bash
bash scripts/deploy-litmuschaos.sh
```

---

## 4. Verify All Services

Run this after deployment to confirm everything is working:

```bash
echo "=== Nodes ==="
kubectl get nodes --show-labels | grep workload

echo "=== App pods ==="
kubectl get pods -n sre-ai-agent

echo "=== Agent pods ==="
kubectl get pods -n sre-ai-agent-llm

echo "=== Monitoring pods ==="
kubectl get pods -n monitoring 2>/dev/null || echo "Not deployed"

echo "=== LitmusChaos pods ==="
kubectl get pods -n litmus 2>/dev/null || echo "Not deployed"

echo "=== All LoadBalancer URLs ==="
kubectl get svc -n sre-ai-agent | grep LoadBalancer
kubectl get svc -n sre-ai-agent-llm | grep LoadBalancer
kubectl get svc -n monitoring 2>/dev/null | grep LoadBalancer || true
kubectl get svc -n litmus 2>/dev/null | grep LoadBalancer || true

echo "=== Agent health ==="
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$AGENT_LB/agent/health

echo "=== App health ==="
curl -s http://sre.machindra.online/api/health
```

---

## 5. Post-Deploy Configuration

### Update Datadog Webhook

Every new deployment creates a new agent LoadBalancer URL.
Must update Datadog webhook each time:

```bash
# Get new agent LB URL
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Update Datadog webhook to: http://$AGENT_LB/agent/triage"
```

1. Go to `https://app.datadoghq.com/integrations/webhooks`
2. Find `sre-ai-agent-triage` → Edit
3. Update URL with new agent LB hostname
4. Save → Test notification

### Import Grafana Dashboard (first time only)

1. Go to `http://<GRAFANA_LB>` (admin/admin)
2. Connections → Data sources → Add → Prometheus
3. URL: `http://prometheus-server.monitoring.svc.cluster.local`
4. Save & test
5. Dashboards → Import → Upload `monitoring/grafana/sre-ai-agent-dashboard.json`

---

## 6. Test End-to-End

```bash
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test 1 — Pod restart (best result: 95% confidence)
curl -s -X POST http://$AGENT_LB/agent/triage \
  -H "Content-Type: application/json" \
  -d '{"alert_name":"Pod Restart Rate High","severity":"P2","service":"sre-ai-agent","message":"Pod restarted 5 times, OOMKilled"}' \
  | python -m json.tool | grep -E "confidence|runbook_used|incident_id"

# Test 2 — High error rate
curl -s -X POST http://$AGENT_LB/agent/triage \
  -H "Content-Type: application/json" \
  -d '{"alert_name":"High Error Rate","severity":"P2","service":"sre-ai-agent","message":"12% of requests returning 500 errors"}' \
  | python -m json.tool | grep -E "confidence|runbook_used|incident_id"

# Check history
curl -s http://$AGENT_LB/agent/history | python -m json.tool

# Open HTML report in browser
echo "Open: http://$AGENT_LB/docs"
```

### Inject Chaos for Demo

```bash
# Inject high error rate
kubectl set env deployment/sre-ai-agent ERROR_RATE=0.9 -n sre-ai-agent
echo "Chaos injected — wait 2-3 min for Datadog monitor to fire"

# Restore after demo
kubectl set env deployment/sre-ai-agent ERROR_RATE=0 -n sre-ai-agent
echo "Restored"
```

---

## 7. Demo Flow

### Browser Tabs to Pre-Open

```
Tab 1: GitHub README     → github.com/Machindra220/SRE-AI-Agent-Observability
Tab 2: AWS EKS Console   → console.aws.amazon.com → EKS → Workloads
Tab 3: Datadog Infra     → app.datadoghq.com → Infrastructure → Kubernetes
Tab 4: Datadog Monitors  → app.datadoghq.com → Monitors
Tab 5: Agent Docs        → http://<AGENT_LB>/docs
Tab 6: Agent History     → http://<AGENT_LB>/agent/history
Tab 7: Grafana Dashboard → http://<GRAFANA_LB>
Tab 8: AWS CloudShell    → console.aws.amazon.com → CloudShell
```

### Demo Script (15 min)

```
1. Architecture (2 min)
   Show GitHub README → ARCHITECTURE.md
   "22 phases, 2 repos, production-grade AIOps"

2. Infrastructure (1 min)
   AWS Console → EKS → Workloads
   "2 dedicated node groups — app and AI agent isolated"

3. Datadog (2 min)
   Infrastructure → Kubernetes → show pods
   APM → sre-ai-agent service
   "Full observability already flowing"

4. Inject chaos (1 min)
   kubectl set env deployment/sre-ai-agent ERROR_RATE=0.9 -n sre-ai-agent
   "I just broke production"

5. Monitor fires (1 min)
   Show Datadog monitor going red
   "Datadog detected it — firing webhook to AI agent"

6. RCA generated (2 min)
   curl http://$AGENT_LB/agent/history
   Open HTML report → show confidence badge
   "Agent diagnosed it automatically — no human involved"

7. Grafana AI quality (1 min)
   Show dashboard → context_recall 100%
   "We monitor AI quality just like API quality"

8. Restore (30 sec)
   kubectl set env deployment/sre-ai-agent ERROR_RATE=0 -n sre-ai-agent

9. Summary (2 min)
   "Alert to RCA in under 10 seconds
    Zero human involvement
    95% confidence on OOMKilled
    100% RAG accuracy"
```

---

## 8. Teardown

```bash
./scripts/infra-down.sh
```

If script gets stuck on namespace deletion:

```bash
# Force delete all namespaces
kubectl delete namespace sre-ai-agent --force --grace-period=0 2>/dev/null || true
kubectl delete namespace sre-ai-agent-llm --force --grace-period=0 2>/dev/null || true
kubectl delete namespace monitoring --force --grace-period=0 2>/dev/null || true
kubectl delete namespace litmus --force --grace-period=0 2>/dev/null || true

# Wait for LBs to delete
sleep 60

# Destroy terraform directly
cd infrastructure/terraform/eks
terraform destroy -target='module.eks' -target='module.vpc' -auto-approve
```

---

## 9. Debug Commands

### AWS / Infrastructure

```bash
# Verify AWS identity
aws sts get-caller-identity

# List EKS clusters
aws eks list-clusters --region us-east-1

# Check node groups
aws eks list-nodegroups \
  --cluster-name sre-ai-agent-dev-eks-cluster \
  --region us-east-1

# Check node group status
aws eks describe-nodegroup \
  --cluster-name sre-ai-agent-dev-eks-cluster \
  --nodegroup-name <nodegroup-name> \
  --region us-east-1 \
  --query 'nodegroup.{status:status,health:health}'

# Check remaining ELBs (run before terraform destroy)
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[*].{Name:LoadBalancerName,State:State.Code}' \
  --output table
```

### Kubernetes

```bash
# Get all pods across all namespaces
kubectl get pods -A

# Get all services with external IPs
kubectl get svc -A | grep LoadBalancer

# Check node resources
kubectl describe nodes | grep -A5 "Allocated resources"

# Check node labels
kubectl get nodes --show-labels | grep workload

# Get events (useful for debugging pending pods)
kubectl get events -n sre-ai-agent --sort-by='.lastTimestamp'
kubectl get events -n sre-ai-agent-llm --sort-by='.lastTimestamp'

# Describe a stuck pod
kubectl describe pod <pod-name> -n <namespace>

# Force delete stuck namespace
kubectl delete namespace <name> --force --grace-period=0
```

### Datadog Agent

```bash
# Check Datadog pods
kubectl get pods -n sre-ai-agent | grep datadog

# Check Datadog logs
kubectl logs -n sre-ai-agent \
  -l app=datadog-agent --tail=30

# Check cluster agent logs
kubectl logs -n sre-ai-agent \
  -l app=datadog-cluster-agent --tail=30

# Verify Datadog secret exists
kubectl get secret datadog-secret -n sre-ai-agent

# Recreate Datadog secret if missing
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace sre-ai-agent \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Datadog after secret fix
kubectl rollout restart deployment/datadog-agent-cluster-agent -n sre-ai-agent
kubectl rollout restart daemonset/datadog-agent -n sre-ai-agent
```

### AI Agent

```bash
# Get agent LB URL
kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm

# Check agent logs
kubectl logs -n sre-ai-agent-llm \
  $(kubectl get pod -n sre-ai-agent-llm \
  -l app=sre-ai-agent-llm -o name) --tail=30

# Check pgvector logs
kubectl logs -n sre-ai-agent-llm \
  $(kubectl get pod -n sre-ai-agent-llm \
  -l app=pgvector -o name) --tail=20

# Check runbook chunks count
PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm \
  -l app=pgvector -o name | head -1)
kubectl exec -n sre-ai-agent-llm $PGVECTOR_POD \
  -- psql -U sre_user -d sre_agent \
  -c "SELECT source, COUNT(*) FROM runbook_chunks GROUP BY source;"

# Re-index runbooks if chunks missing
PGVECTOR_POD=$(kubectl get pod -n sre-ai-agent-llm \
  -l app=pgvector -o name | head -1)
pkill -f "port-forward.*5433" 2>/dev/null || true
kubectl port-forward -n sre-ai-agent-llm $PGVECTOR_POD 5433:5432 &
sleep 8
PGHOST=localhost PGPORT=5433 PGDATABASE=sre_agent \
  PGUSER=sre_user PGPASSWORD=sre_pass python -m rag.indexer
pkill -f "port-forward.*5433" 2>/dev/null || true

# Test agent triage
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$AGENT_LB/agent/health
```

### Secrets / Environment

```bash
# Check secrets loaded
echo "DD_API_KEY: ${DD_API_KEY:0:8}..."
echo "DD_APP_KEY: ${DD_APP_KEY:0:8}..."

# Reload secrets
source scripts/load-secrets.sh

# Fix python3 on Windows Git Bash
alias python3='python'

# Verify Gemini key in .env
grep GEMINI_API_KEY .env | cut -c1-30
```

### Docker

```bash
# Check Docker running
docker ps

# Check ECR repos
aws ecr describe-repositories --region us-east-1 \
  --query 'repositories[*].repositoryName'

# Check images in ECR
aws ecr list-images \
  --repository-name sre-ai-agent-dev-ecr-api \
  --region us-east-1
```

---

## 10. Common Issues and Fixes

| Issue | Symptom | Fix |
|---|---|---|
| Docker not running | `docker.sock` error in script | Start Docker Desktop, wait for green |
| DD secret missing | `cluster-agent` CrashLoopBackOff | Recreate secret, rollout restart |
| python3 not found | `load-secrets.sh` fails silently | `alias python3='python'` |
| Namespace stuck | Terminal stuck at "namespace deleted" | `kubectl delete namespace --force --grace-period=0` |
| Port 5433 in use | `bind: address already in use` | `pkill -f "port-forward.*5433"` |
| t3.small insufficient | Pods Pending in monitoring/litmus | Upgrade to t3.medium in eks.tf |
| ECR push fails | `no basic auth credentials` | Re-run ECR login command |
| Gemini rate limit | `confidence: 0.0` | Wait for midnight Pacific reset |
| DNS not resolving | `curl sre.machindra.online` fails | Update BigRock NS if hosted zone recreated |
| terraform stuck | Waiting for resource deletion | Force delete K8s resources, run destroy manually |
| Node group failed | `CREATE_FAILED` in AWS | Check instance type — t3.medium not free tier |

---

*GitHub: https://github.com/Machindra220/SRE-AI-Agent-Observability*
*Last updated: September 2026*