# How to Start Guide — SRE AI Agent Observability Platform

> Complete deployment guide from zero to fully running platform.
> Covers: AWS infra, EKS, Datadog, LitmusChaos, local containers,
> AI agent, pgvector, Prometheus, Grafana.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [WSL Environment Setup](#2-wsl-environment-setup)
3. [AWS Infrastructure — Terraform](#3-aws-infrastructure--terraform)
4. [Deploy App to EKS](#4-deploy-app-to-eks)
5. [Deploy Datadog Agent](#5-deploy-datadog-agent)
6. [Deploy Datadog as Code (Terraform)](#6-deploy-datadog-as-code-terraform)
7. [Deploy LitmusChaos](#7-deploy-litmuschaos)
8. [Start Local Docker Containers](#8-start-local-docker-containers)
9. [Start AI Agent](#9-start-ai-agent)
10. [Connect to Each Service](#10-connect-to-each-service)
11. [Grafana — Connect Prometheus + Import Dashboard](#11-grafana--connect-prometheus--import-dashboard)
12. [Run AI Evals](#12-run-ai-evals)
13. [Full Session Startup Checklist](#13-full-session-startup-checklist)
14. [Teardown / Shutdown](#14-teardown--shutdown)

---

## 1. Prerequisites

### Windows + WSL2 Setup

| Tool | Purpose | Install |
|---|---|---|
| WSL2 Ubuntu | Linux environment | Windows features |
| Rancher Desktop | Docker engine | [rancherdesktop.io](https://rancherdesktop.io) |
| VSCode | Editor | [code.visualstudio.com](https://code.visualstudio.com) |
| AWS CLI | AWS access | `sudo apt install awscli` |
| kubectl | K8s control | `sudo apt install kubectl` |
| Helm | K8s packages | `sudo apt install helm` |
| Terraform | IaC | `sudo apt install terraform` |

### WSL Memory Config (one-time)

On Windows, create/edit `C:\Users\Machindra\.wslconfig`:

```ini
[wsl2]
memory=6GB
processors=4
swap=4GB
```

Then restart WSL:
```powershell
wsl --shutdown
```

### WSL DNS Fix (if DNS fails after restart)

```bash
sudo unlink /etc/resolv.conf

sudo tee /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

sudo tee /etc/wsl.conf << 'EOF'
[network]
generateResolvConf = false
EOF
```

### Python Setup (one-time)

```bash
# Install Python 3.12 (3.14 breaks psycopg2)
sudo apt update
sudo apt install -y python3.12 python3.12-venv python3.12-dev

# Create venv in project
cd ~/SRE-AI-Agent-Observability
python3.12 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r agent/requirements.txt
```

### Clone the repo (one-time)

```bash
git clone https://github.com/Machindra220/SRE-AI-Agent-Observability.git
cd ~/SRE-AI-Agent-Observability
```

---

## 2. WSL Environment Setup

### Load secrets from AWS Secrets Manager

```bash
cd ~/SRE-AI-Agent-Observability

# Load all secrets (DD_API_KEY, DD_APP_KEY, AWS keys)
source scripts/load-secrets.sh

# Verify keys loaded
echo "DD_API_KEY: ${DD_API_KEY:0:8}..."
echo "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:8}..."
```

### Create .env file (one-time, for AI agent)

```bash
cat > .env << 'EOF'
# Gemini API — get free key from https://aistudio.google.com/apikey
GEMINI_API_KEY=your-gemini-api-key-here

# PostgreSQL (pgvector Docker container)
PGHOST=localhost
PGPORT=5432
PGDATABASE=sre_agent
PGUSER=sre_user
PGPASSWORD=sre_pass
EOF
```

### Load .env for current session

```bash
export $(cat .env | grep -v '^#' | xargs)
```

---

## 3. AWS Infrastructure — Terraform

> **One-time setup.** Skip if EKS cluster already exists.
> Takes ~15-20 minutes to provision.

### Step 1 — Configure AWS credentials

```bash
aws configure
# AWS Access Key ID: [your key]
# AWS Secret Access Key: [your secret]
# Default region: us-east-1
# Default output format: json

# Verify
aws sts get-caller-identity
```

### Step 2 — Provision EKS + VPC + ECR

```bash
cd ~/SRE-AI-Agent-Observability/infrastructure/terraform/eks

# Initialize Terraform
terraform init

# Preview what will be created
terraform plan

# Create infrastructure (~15 min)
terraform apply -auto-approve
```

**Resources created:**
- VPC with public subnets
- EKS cluster (`sre-ai-agent-dev-eks-cluster`, K8s 1.32, t3.small)
- ECR repository (`sre-ai-agent-dev-ecr-api`)
- IAM roles and node groups

### Step 3 — Connect kubectl to EKS

```bash
aws eks update-kubeconfig \
  --name sre-ai-agent-dev-eks-cluster \
  --region us-east-1

# Verify connection
kubectl get nodes
kubectl get pods -A
```

### Step 4 — Provision DNS (Route53)

```bash
cd ~/SRE-AI-Agent-Observability/infrastructure/terraform/dns

terraform init
terraform plan
terraform apply -auto-approve

# Verify
aws route53 list-hosted-zones
```

---

## 4. Deploy App to EKS

### Option A — Manual kubectl deploy

```bash
cd ~/SRE-AI-Agent-Observability

# Create namespace
kubectl apply -f kubernetes/namespace.yaml

# Deploy all manifests
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/hpa.yaml

# Verify pods are running
kubectl get pods -n sre-ai-agent
kubectl get svc -n sre-ai-agent

# Get LoadBalancer URL
kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### Option B — Use infra-up.sh automation script

```bash
cd ~/SRE-AI-Agent-Observability

# Full infra + deploy in one command
./scripts/infra-up.sh
```

**What infra-up.sh does:**
1. Loads secrets from AWS Secrets Manager
2. Runs `terraform apply` for EKS
3. Configures kubectl
4. Builds Docker image and pushes to ECR
5. Deploys Kubernetes manifests
6. Waits for pods to be ready
7. Installs Datadog agent via Helm

### Build and push Docker image manually

```bash
# Get ECR login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS \
  --password-stdin 502274764708.dkr.ecr.us-east-1.amazonaws.com

ECR_URL="502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-dev-ecr-api"

# Build and push
docker build -t sre-ai-agent:latest ./app
docker tag sre-ai-agent:latest $ECR_URL:latest
docker push $ECR_URL:latest

# Trigger rolling update
kubectl rollout restart deployment/sre-ai-agent -n sre-ai-agent
kubectl rollout status deployment/sre-ai-agent -n sre-ai-agent
```

### Verify app is running

```bash
# Get LoadBalancer URL
LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "App URL: http://$LB"

# Test endpoints
curl http://$LB/api/health
curl http://$LB/api/normal
```

---

## 5. Deploy Datadog Agent

### Step 1 — Add Datadog Helm repo

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

### Step 2 — Create Datadog secret in K8s

```bash
kubectl create secret generic datadog-secret \
  --from-literal api-key=$DD_API_KEY \
  --from-literal app-key=$DD_APP_KEY \
  -n sre-ai-agent
```

### Step 3 — Install Datadog agent via Helm

```bash
helm install datadog-agent datadog/datadog \
  -f infrastructure/helm/datadog/values.yaml \
  -n sre-ai-agent

# Verify agent pods are running
kubectl get pods -n sre-ai-agent | grep datadog

# Check agent status
kubectl exec -it \
  $(kubectl get pod -n sre-ai-agent -l app=datadog-agent -o name | head -1) \
  -n sre-ai-agent -- agent status
```

### Step 4 — Verify in Datadog UI

Open [app.datadoghq.com](https://app.datadoghq.com):
- Infrastructure → Kubernetes → should show cluster
- APM → Services → should show `sre-ai-agent`

### Upgrade Datadog agent (if values.yaml changed)

```bash
helm upgrade datadog-agent datadog/datadog \
  -f infrastructure/helm/datadog/values.yaml \
  -n sre-ai-agent
```

---

## 6. Deploy Datadog as Code (Terraform)

> Creates monitors, SLOs, and dashboards in Datadog via Terraform.

```bash
cd ~/SRE-AI-Agent-Observability/infrastructure/terraform/datadog

# Initialize
terraform init

# Preview
terraform plan

# Apply (creates 5 monitors, 2 SLOs, 1 dashboard)
terraform apply -auto-approve

# Verify output
terraform output
```

**Resources created:**
- 5 Datadog monitors (P1 Availability, P2 Error Rate, P2 Pod Restart, P2 SLO Burn Rate, P3 Latency)
- 2 SLOs (Availability 99%, Latency p99 < 2s)
- 1 Golden Signals dashboard

---

## 7. Deploy LitmusChaos

> For chaos engineering — inject failures to test monitors and agent.

### Step 1 — Install LitmusChaos

```bash
# Add LitmusChaos Helm repo
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update

# Create namespace
kubectl create namespace litmus

# Install LitmusChaos
helm install chaos litmuschaos/litmus \
  --namespace litmus \
  --set portal.frontend.service.type=NodePort

# Verify
kubectl get pods -n litmus
```

### Step 2 — Access LitmusChaos portal

```bash
# Get portal URL
kubectl get svc -n litmus | grep frontend

# Port forward if needed
kubectl port-forward svc/chaos-litmus-frontend-service \
  9091:9091 -n litmus &

# Open: http://localhost:9091
# Default credentials: admin / litmus
```

### Step 3 — Run chaos scenarios manually (without LitmusChaos)

```bash
# Chaos 1: High Error Rate
kubectl set env deployment/sre-ai-agent \
  ERROR_RATE=0.8 -n sre-ai-agent

# Chaos 2: High Latency
kubectl set env deployment/sre-ai-agent \
  LATENCY_MS=3000 -n sre-ai-agent

# Chaos 3: CrashLoopBackOff
kubectl set image deployment/sre-ai-agent \
  sre-ai-agent=bad-image:notexist -n sre-ai-agent

# Chaos 4: Scale to 0 (availability drop)
kubectl scale deployment sre-ai-agent \
  --replicas=0 -n sre-ai-agent

# Restore all
./scripts/restore-all.sh
```

---

## 8. Start Local Docker Containers

> Start Rancher Desktop on Windows first, then run these in WSL.

### Check Rancher Desktop is running

```bash
docker --version
docker ps
```

### pgvector (PostgreSQL + vector extension)

```bash
# First time — create container
docker run -d \
  --name pgvector \
  -e POSTGRES_DB=sre_agent \
  -e POSTGRES_USER=sre_user \
  -e POSTGRES_PASSWORD=sre_pass \
  -p 5432:5432 \
  pgvector/pgvector:pg17

# Subsequent sessions — just start existing container
docker start pgvector

# Verify running
docker ps | grep pgvector
```

### Prometheus (AI eval metrics)

```bash
cd ~/SRE-AI-Agent-Observability

# First time — create container
docker run -d \
  --name sre-prometheus \
  -p 9093:9090 \
  -v $(pwd)/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml \
  prom/prometheus:latest

# Subsequent sessions
docker start sre-prometheus

# Verify
docker ps | grep sre-prometheus
```

### Grafana (AI quality dashboard)

```bash
# First time — create container
docker run -d \
  --name sre-grafana \
  -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  grafana/grafana:latest

# Subsequent sessions — use existing Grafana on port 3000
# (skip if already running)
docker start sre-grafana

# Verify
docker ps | grep grafana
```

### Metrics server (serves metrics.prom to Prometheus)

```bash
# Create the metrics server script (one-time)
cat > /tmp/metrics_server.py << 'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

METRICS_FILE = Path("/home/machindra/SRE-AI-Agent-Observability/evals/metrics.prom")

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not METRICS_FILE.exists():
            self.send_response(404)
            self.end_headers()
            return
        content = METRICS_FILE.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, format, *args):
        pass

print("Metrics server running on port 9092...")
HTTPServer(("0.0.0.0", 9092), MetricsHandler).serve_forever()
EOF

# Start metrics server (every session)
nohup python3 /tmp/metrics_server.py > /tmp/metrics_server.log 2>&1 &
echo "Metrics server PID: $!"

# Verify
curl -I http://localhost:9092/metrics.prom 2>&1 | grep content-type
```

### All containers status check

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected output:
```
NAMES             STATUS          PORTS
pgvector          Up X minutes    0.0.0.0:5432->5432/tcp
sre-prometheus    Up X minutes    0.0.0.0:9093->9090/tcp
sre-grafana       Up X minutes    0.0.0.0:3000->3000/tcp
```

---

## 9. Start AI Agent

### Initialize database (one-time or after container recreation)

```bash
cd ~/SRE-AI-Agent-Observability
source .venv/bin/activate
export $(cat .env | grep -v '^#' | xargs)

# Create pgvector schema
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent \
  -f vector-db/init.sql

# Check if runbooks are indexed
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent \
  -c "SELECT source, COUNT(*) as chunks FROM runbook_chunks GROUP BY source;"
```

Expected:
```
source              | chunks
api-5xx.md          |      3
api-availability.md |      7
high-latency.md     |      4
pod-restarts.md     |      5
(4 rows)
```

If empty → run indexer:
```bash
python -m rag.indexer
```

### Start the agent

```bash
uvicorn agent.main:app --host 0.0.0.0 --port 8001 --reload
```

### Test the agent

```bash
# Health check
curl http://localhost:8001/agent/health

# Triage an alert
curl -X POST http://localhost:8001/agent/triage \
  -H "Content-Type: application/json" \
  -d '{
    "alert_name": "Pod Restart Rate High",
    "severity": "P2",
    "service": "sre-ai-agent",
    "message": "Pod restarted 5 times in last 10 minutes, OOMKilled"
  }'

# View incident history
curl http://localhost:8001/agent/history | python3 -m json.tool
```

---

## 10. Connect to Each Service

### pgvector (PostgreSQL)

```bash
# Connect via psql CLI
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent

# Useful queries inside psql:
\dt                                          -- list tables
SELECT COUNT(*) FROM runbook_chunks;         -- check chunk count
SELECT source, COUNT(*) FROM runbook_chunks GROUP BY source;  -- per-runbook
SELECT id, source, LEFT(content,80) FROM runbook_chunks LIMIT 5;  -- preview chunks

# Exit psql
\q
```

**Connect via pgAdmin (Windows):**
```
Host:     localhost
Port:     5432
Database: sre_agent
Username: sre_user
Password: sre_pass
```

### Agent API (FastAPI)

| URL | What |
|---|---|
| `http://localhost:8001/docs` | Swagger UI — interactive API docs |
| `http://localhost:8001/redoc` | ReDoc — clean documentation |
| `http://localhost:8001/agent/health` | Health check |
| `http://localhost:8001/agent/triage` | POST — run agent |
| `http://localhost:8001/agent/history` | GET — all past runs |
| `http://localhost:8001/agent/rca/{id}/html` | GET — HTML RCA report |
| `http://localhost:8001/agent/rca/{id}/json` | GET — JSON RCA data |

### Prometheus

| URL | What |
|---|---|
| `http://localhost:9093` | Prometheus home |
| `http://localhost:9093/targets` | Scrape targets health |
| `http://localhost:9093/graph` | Query interface |
| `http://localhost:9093/api/v1/targets` | Targets API |

**Useful PromQL queries:**
```
sre_agent_eval_context_recall          # RAG accuracy
sre_agent_eval_confidence_avg          # avg LLM confidence
sre_agent_eval_rca_completeness        # RCA section coverage
sre_agent_eval_keyword_hit_rate        # keyword coverage
sre_agent_eval_case_confidence         # per-alert confidence
sre_agent_eval_pass_rate               # overall pass rate
```

### Metrics server

```bash
# Test metrics endpoint
curl http://localhost:9092/metrics.prom

# Check server is running
ss -tlnp | grep 9092
```

### Grafana

| URL | What |
|---|---|
| `http://localhost:3000` | Grafana home |
| `http://localhost:3000/dashboards` | All dashboards |
| `http://localhost:3000/connections/datasources` | Data sources |

**Login:** `admin` / `admin`

---

## 11. Grafana — Connect Prometheus + Import Dashboard

### Add Prometheus data source

1. Go to `http://localhost:3000`
2. Left sidebar → **Connections** → **Data sources**
3. Click **Add new data source**
4. Search and select **Prometheus**
5. Set URL: `http://host.docker.internal:9093`
6. Name: `SRE-AI-Agent-Prometheus`
7. Click **Save & test**
8. Confirm: **"Successfully queried the Prometheus API"** ✅

### Import AI Quality Dashboard

1. Left sidebar → **Dashboards** → **New** → **Import**
2. Click **Upload dashboard JSON file**
3. Select: `monitoring/grafana/sre-ai-agent-dashboard.json`
4. Select data source: `SRE-AI-Agent-Prometheus`
5. Click **Import**

**Dashboard panels:**

| Panel | Type | Shows |
|---|---|---|
| Context Recall | Gauge | RAG accuracy — target > 85% |
| Avg LLM Confidence | Gauge | Gemini confidence — target > 60% |
| RCA Completeness | Gauge | Sections present — target > 90% |
| Keyword Hit Rate | Gauge | Keywords found — target > 75% |
| Per-Alert Confidence | Bar gauge | Per test case breakdown |
| Eval Pass Rate | Stat | Overall pass rate |
| Total Eval Runs | Stat | How many evals run |

### Add Grafana transformations (for clean labels)

In Per-Alert Confidence panel → Edit → Transformations tab:

Click **+ Add transformation** → **Rename fields by regex** — add 6 entries:

| Match | Replace |
|---|---|
| `.*tc-001.*` | `Pod Restart (OOMKilled)` |
| `.*tc-002.*` | `High Error Rate` |
| `.*tc-003.*` | `High p99 Latency` |
| `.*tc-004.*` | `API Availability` |
| `.*tc-005.*` | `Pod Restart (CrashLoop)` |
| `.*tc-006.*` | `SLO Burn Rate` |

---

## 12. Run AI Evals

> Agent must be running on port 8001 before running evals.
> Gemini free tier = 20 requests/day. Quota resets at midnight Pacific.

```bash
cd ~/SRE-AI-Agent-Observability
source .venv/bin/activate
export $(cat .env | grep -v '^#' | xargs)

# Run full eval suite (6 test cases, ~60 seconds with sleep)
python -m evals.eval_runner
```

**Expected output:**
```
============================================================
EVAL RESULTS SUMMARY
============================================================
Total test cases : 6
Passed           : 3/6 (50%)
Context recall   : 1.00  ← RAG always finds right runbook
Keyword hit rate : 0.75
============================================================
tc-001 | Pod Restart (OOMKilled) | conf: 0.95 ✅
tc-002 | High Error Rate         | conf: 0.30 ✅
tc-003 | High p99 Latency        | conf: 0.30 ✅
```

### Check Prometheus scraped the eval metrics

```bash
# Verify metrics.prom was written
cat evals/metrics.prom | head -10

# Verify Prometheus scraped it
curl -s "http://localhost:9093/api/v1/query?query=sre_agent_eval_context_recall" \
  | python3 -m json.tool | grep value
```

---

## 13. Full Session Startup Checklist

Run this every time you start a new development session:

```bash
# ── WINDOWS ──────────────────────────────────────────────────
# 1. Start Rancher Desktop → wait for green status (~2 min)

# ── WSL TERMINAL 1 — Infra + Agent ───────────────────────────
cd ~/SRE-AI-Agent-Observability

# 2. Start Docker containers
docker start pgvector
docker start sre-prometheus

# 3. Fix DNS if needed
ping -c 1 google.com || sudo tee /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# 4. Activate venv + load env
source .venv/bin/activate
export $(cat .env | grep -v '^#' | xargs)

# 5. Load AWS secrets (if using EKS)
source scripts/load-secrets.sh

# 6. Check runbooks indexed (skip indexer if 19)
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent \
  -c "SELECT COUNT(*) FROM runbook_chunks;" 2>/dev/null | grep -E "^\s+[0-9]"
# If shows 0 → run: python -m rag.indexer

# 7. Start metrics server
nohup python3 /tmp/metrics_server.py > /tmp/metrics_server.log 2>&1 &

# 8. Start AI agent
uvicorn agent.main:app --host 0.0.0.0 --port 8001 --reload

# ── WSL TERMINAL 2 — Evals (when needed) ─────────────────────
cd ~/SRE-AI-Agent-Observability
source .venv/bin/activate
export $(cat .env | grep -v '^#' | xargs)
python -m evals.eval_runner

# ── BROWSER ──────────────────────────────────────────────────
# Agent API docs:    http://localhost:8001/docs
# Prometheus:        http://localhost:9093
# Grafana:           http://localhost:3000
# Datadog:           https://app.datadoghq.com
```

### Quick status check (paste all at once)

```bash
echo "=== Docker containers ===" && docker ps --format "{{.Names}}: {{.Status}}"
echo "=== pgvector chunks ===" && PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent -t -c "SELECT COUNT(*) FROM runbook_chunks;" 2>/dev/null
echo "=== Agent health ===" && curl -s http://localhost:8001/agent/health 2>/dev/null | python3 -m json.tool
echo "=== Prometheus ===" && curl -s http://localhost:9093/-/healthy 2>/dev/null
echo "=== Metrics server ===" && curl -s http://localhost:9092/metrics.prom | head -2
```

---

## 14. Teardown / Shutdown

### Stop local containers (keep data)

```bash
docker stop pgvector sre-prometheus sre-grafana
pkill -f metrics_server.py
```

### Destroy AWS infrastructure (saves cost)

```bash
cd ~/SRE-AI-Agent-Observability

# Full teardown (correct order to avoid orphaned ELBs)
./scripts/infra-down.sh

# Or manually:
# 1. Delete K8s LoadBalancer service first
kubectl delete svc sre-ai-agent -n sre-ai-agent

# 2. Destroy EKS + VPC
cd infrastructure/terraform/eks
terraform destroy -auto-approve

# NOTE: Never destroy DNS terraform — keeps machindra.online working
# cd infrastructure/terraform/dns → DO NOT destroy
```

### Keep Datadog resources (optional)

```bash
# Destroy Datadog monitors/SLOs/dashboards created by Terraform
cd infrastructure/terraform/datadog
terraform destroy -auto-approve
```

### Reset pgvector data (re-index)

```bash
# Drop and recreate runbook chunks table
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent \
  -f vector-db/init.sql

# Re-index
source .venv/bin/activate
export $(cat .env | grep -v '^#' | xargs)
python -m rag.indexer
```

---

## Troubleshooting

### pgvector connection refused

```bash
docker start pgvector
sleep 3
docker ps | grep pgvector
```

### Gemini API 429 rate limit

```bash
# Check quota at: https://ai.dev/rate-limit
# Free tier: 20 req/day per model
# Wait for midnight Pacific reset
# Or use different model: genai.list_models()
```

### WSL DNS failure

```bash
sudo unlink /etc/resolv.conf 2>/dev/null
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
ping -c 2 google.com
```

### Agent fails to start (port in use)

```bash
# Find what's using port 8001
ss -tlnp | grep 8001
# Kill it
pkill -f "uvicorn agent.main"
# Restart
uvicorn agent.main:app --host 0.0.0.0 --port 8001 --reload
```

### Prometheus not scraping

```bash
# Check target health
curl -s http://localhost:9093/api/v1/targets | python3 -m json.tool | grep health

# Check metrics server is running
curl -I http://localhost:9092/metrics.prom | grep content-type
# Must show: text/plain

# Restart if needed
pkill -f metrics_server.py
nohup python3 /tmp/metrics_server.py > /tmp/metrics_server.log 2>&1 &
docker restart sre-prometheus
```

### EKS pods not starting

```bash
kubectl describe pod -n sre-ai-agent -l app=sre-ai-agent
kubectl logs -n sre-ai-agent -l app=sre-ai-agent --tail=50
kubectl get events -n sre-ai-agent --sort-by='.lastTimestamp'
```

---

*SRE AI Agent Observability Platform*
*GitHub: Machindra220/SRE-AI-Agent-Observability*