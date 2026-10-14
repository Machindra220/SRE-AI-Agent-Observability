# Phase 22 — Full Automation Scripts: Complete Guide

> **Repo:** Machindra220/SRE-AI-Agent-Observability
> **Phase:** 22 — One-Command Platform Deployment Automation
> **Status:** ✅ Complete
> **Goal:** Turn a 55-step manual deployment into a single script that deploys the entire SRE AI Agent platform from zero

---

## Table of Contents

1. [What We Built](#1-what-we-built)
2. [Architecture Overview](#2-architecture-overview)
3. [All Scripts Explained](#3-all-scripts-explained)
4. [infra-up-complete.sh — 15 Steps Deep Dive](#4-infra-up-completesh--15-steps-deep-dive)
5. [infra-down.sh — Safe Teardown](#5-infra-downsh--safe-teardown)
6. [Failures, Root Causes, and Fixes](#6-failures-root-causes-and-fixes)
7. [AWS Resource Inventory After Deployment](#7-aws-resource-inventory-after-deployment)
8. [Key Learnings](#8-key-learnings)
9. [Interview QA](#9-interview-qa)

---

## 1. What We Built

Phase 22 transformed what was previously 55+ manual steps across CLI, AWS console, and Kubernetes into a single automation suite:

```
./scripts/infra-up-complete.sh     ← Deploy everything from zero
./scripts/infra-down.sh            ← Tear everything down safely
./scripts/deploy-agent.sh          ← Deploy only the AI agent
./scripts/deploy-monitoring.sh     ← Deploy only Prometheus + Grafana
./scripts/deploy-litmuschaos.sh    ← Deploy only LitmusChaos
```

### What "Complete" means

When `infra-up-complete.sh` finishes, you have:

| Service | Where | Access |
|---|---|---|
| FastAPI SRE app | EKS app_nodes | AWS ELB URL |
| Datadog Agent | EKS (all nodes) | Datadog Cloud dashboard |
| LangGraph AI Agent | EKS agent_nodes | AWS ELB URL |
| pgvector | EKS agent_nodes | Internal K8s service |
| Runbook knowledge base | pgvector | 14 chunks indexed |
| Prometheus | EKS app_nodes | AWS ELB URL |
| Grafana | EKS app_nodes | AWS ELB URL |
| LitmusChaos | EKS agent_nodes | AWS ELB URL:9091 |
| Custom domain | Route53 | sre.machindra.online |

---

## 2. Architecture Overview

### EKS Cluster Layout

```
EKS Cluster: sre-ai-agent-dev-eks-cluster (us-east-1, K8s 1.32)
│
├── app_nodes (t3.small × 3, no taint)
│   ├── namespace: sre-ai-agent
│   │   ├── sre-ai-agent (FastAPI app, 1 replica)
│   │   └── datadog-agent (DaemonSet — 1 pod per node)
│   ├── namespace: monitoring
│   │   ├── prometheus-server
│   │   └── grafana
│   └── kube-system (coredns, aws-node, kube-proxy)
│
└── agent_nodes (t3.small × 1, taint: workload=ai-agent:NoSchedule)
    ├── namespace: sre-ai-agent-llm
    │   ├── sre-ai-agent-llm (LangGraph agent)
    │   └── pgvector (PostgreSQL + pgvector extension)
    └── namespace: litmus
        ├── chaos-mongodb (StatefulSet, EBS PVC)
        └── litmusportal-frontend / backend / subscriber
```

### Node Capacity Planning

```
t3.small = 2 vCPU, 2 GB RAM
Maximum pods per t3.small = 11 (AWS ENI limit)

app_nodes (3 nodes × 11 pods = 33 pod slots):
  - kube-system: ~9 pods (coredns x2, aws-node x3, kube-proxy x3)
  - datadog DaemonSet: 3 pods (1 per node)
  - sre-ai-agent: 1 pod
  - prometheus: 3 pods (server, alertmanager, pushgateway)
  - grafana: 1 pod
  Total: ~17 pods across 3 nodes ✅ fits

agent_nodes (1 node × 11 pods):
  - kube-system: ~3 pods (aws-node, kube-proxy)
  - sre-ai-agent-llm: 1 pod
  - pgvector: 1 pod
  - litmus: 4 pods (frontend, backend, subscriber, mongodb)
  Total: ~9 pods ✅ fits
```

---

## 3. All Scripts Explained

### `scripts/infra-up-complete.sh` — Master deployment (15 steps)

```bash
#!/bin/bash
set -e   # Exit on first error — critical for sequential deployment

# Step 1: Terraform EKS + VPC
# Step 2: Configure kubectl
# Step 3: Create K8s namespaces
# Step 4: Create app K8s secrets
# Step 5: Build + push app Docker image to ECR
# Step 6: Deploy app K8s manifests
# Step 7: Create Datadog K8s secret
# Step 8: Install Datadog via Helm
# Step 9: Update DNS (auto-detect app LB hostname → update Route53 variables.tf → terraform apply)
# Step 10: Create agent K8s secret
# Step 11: Install EBS CSI driver (for LitmusChaos MongoDB PVC)
# Step 12: Build + push agent Docker image to ECR
# Step 13: Deploy agent + pgvector K8s manifests
# Step 14: Initialize pgvector schema + index runbooks
# Step 15: Install Prometheus + Grafana + LitmusChaos via Helm
```

### `scripts/infra-up-eks.sh` — EKS only (no agent, no monitoring)

Used when you only need to redeploy EKS infra without rebuilding Docker images. Runs Steps 1–9 of infra-up-complete.sh.

### `scripts/infra-up-with-dns-up.sh` — EKS + DNS together

Wraps Terraform EKS + DNS in sequence. Used when the hosted zone already exists and only ELB hostname needs updating.

### `scripts/deploy-agent.sh` — Agent-only deployment

```bash
# What it does:
# 1. ECR login
# 2. docker build + push (agent image)
# 3. kubectl create secret (GEMINI_API_KEY, DB_PASSWORD)
# 4. kubectl apply -f kubernetes/pgvector-*.yaml
# 5. kubectl apply -f kubernetes/agent-*.yaml
# 6. kubectl port-forward pgvector pod 5432:5432 &
# 7. python rag/indexer.py   (indexes 4 runbooks → 14 chunks)
```

Use this when you only need to redeploy the AI agent without touching EKS infra.

### `scripts/deploy-monitoring.sh` — Monitoring-only deployment

```bash
# What it does:
# 1. helm repo add prometheus-community / grafana
# 2. helm repo update
# 3. helm upgrade --install prometheus prometheus-community/prometheus
#    --namespace monitoring --set server.service.type=LoadBalancer
#    --set server.persistentVolume.enabled=false
# 4. helm upgrade --install grafana grafana/grafana
#    --namespace monitoring --set service.type=LoadBalancer
#    --set persistence.enabled=false
#    --set datasources."datasources\.yaml".datasources[0].url=http://prometheus-server
```

### `scripts/deploy-litmuschaos.sh` — LitmusChaos-only deployment

```bash
# What it does:
# 1. EBS CSI driver check + install if missing
# 2. Set gp2 as default StorageClass
# 3. kubectl create namespace litmus
# 4. helm upgrade --install litmuschaos litmuschaos/litmus
#    --namespace litmus
#    -f infrastructure/helm/litmus/values.yaml
#    --set portal.frontend.service.type=LoadBalancer
```

### `scripts/load-secrets.sh` — Secret loader

```bash
#!/bin/bash
# Loads environment variables needed for all scripts
export DD_API_KEY=$(cat ~/.secrets/dd_api_key)
export DD_APP_KEY=$(cat ~/.secrets/dd_app_key)
export AWS_ACCESS_KEY_ID=$(cat ~/.secrets/aws_access_key)
export AWS_SECRET_ACCESS_KEY=$(cat ~/.secrets/aws_secret_key)
export AWS_DEFAULT_REGION=us-east-1

# FIXED: Uses 'python' not 'python3' for Git Bash on Windows
# On Git Bash: python3 is not aliased by default
```

### `scripts/infra-down.sh` — Safe teardown

Covered in depth in [Section 5](#5-infra-downsh--safe-teardown).

---

## 4. infra-up-complete.sh — 15 Steps Deep Dive

### Step 1 — Terraform EKS + VPC (~20 minutes)

```bash
cd infrastructure/terraform/eks
terraform init
terraform apply -auto-approve
```

**What terraform creates:**
- VPC: 10.0.0.0/16, 3 public subnets, 3 private subnets
- Internet Gateway + NAT Gateway
- EKS cluster: sre-ai-agent-dev-eks-cluster
- Node group: app_nodes (t3.small, min=1 max=5 desired=3)
- Node group: agent_nodes (t3.small, min=1 max=2 desired=1, taint: workload=ai-agent:NoSchedule)
- IAM roles: eks-cluster-role, eks-node-role
- Security groups: cluster SG, node SG

**Timing:** 18-22 minutes (EKS control plane takes longest)

### Step 2 — Configure kubectl (~30 seconds)

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name sre-ai-agent-dev-eks-cluster
```

Verify:
```bash
kubectl get nodes
# NAME                         STATUS   ROLES    AGE   VERSION
# ip-10-0-1-xxx.ec2.internal   Ready    <none>   2m    v1.32.x
# ip-10-0-2-xxx.ec2.internal   Ready    <none>   2m    v1.32.x
# ip-10-0-3-xxx.ec2.internal   Ready    <none>   2m    v1.32.x
# ip-10-0-4-xxx.ec2.internal   Ready    <none>   1m    v1.32.x  ← agent_node
```

### Step 3 — Create K8s Namespaces

```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/agent-namespace.yaml
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace litmus --dry-run=client -o yaml | kubectl apply -f -
```

**Why `--dry-run=client -o yaml | kubectl apply -f -`?**
Makes it idempotent. If namespace exists, command succeeds instead of erroring.
Without this, re-running the script fails at namespace creation.

### Step 4 — Create App K8s Secrets (BEFORE Helm)

```bash
# Critical: Create secret BEFORE Datadog Helm install
# If secret missing, Datadog agent crashes with CrashLoopBackOff
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace sre-ai-agent \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Lesson learned:** In Phase 21, the script failed midway, secret wasn't created,
Helm installed Datadog but pods crashed because the secret was missing.
Moving secret creation BEFORE Helm install and making it idempotent fixed this.

### Step 5 — Build + Push App Docker Image (~3 minutes)

```bash
# ECR login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  502274764708.dkr.ecr.us-east-1.amazonaws.com

# Build
docker build -t sre-ai-agent-dev-ecr-api ./app

# Tag
docker tag sre-ai-agent-dev-ecr-api:latest \
  502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-dev-ecr-api:latest

# Push
docker push \
  502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-dev-ecr-api:latest
```

### Step 6 — Deploy App Manifests

```bash
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/hpa.yaml

# Wait for app to be ready
kubectl rollout status deployment/sre-ai-agent -n sre-ai-agent --timeout=300s
```

### Step 7 — Install Datadog via Helm (~5 minutes)

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update

helm upgrade --install datadog-agent datadog/datadog \
  --namespace sre-ai-agent \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.appKeyExistingSecret=datadog-secret \
  --set datadog.logs.enabled=true \
  --set datadog.logs.containerCollectAll=true \
  --set datadog.apm.portEnabled=true \
  --set datadog.processAgent.enabled=true \
  --set agents.tolerations[0].operator=Exists \
  --timeout 300s
```

**`--set agents.tolerations[0].operator=Exists`** → Allows Datadog DaemonSet to run on
agent_nodes despite the `workload=ai-agent:NoSchedule` taint. Without this,
agent_nodes would have no Datadog monitoring.

### Step 8 — Update DNS (Auto-detect ELB)

```bash
# Poll for app LB hostname (may take 2-3 minutes to appear)
APP_LB=""
while [ -z "$APP_LB" ]; do
  APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [ -z "$APP_LB" ] && sleep 10
done

# Auto-update variables.tf with real LB hostname
sed -i "s|default = \".*\"|default = \"$APP_LB\"|" \
  infrastructure/terraform/dns/variables.tf

# Apply DNS
cd infrastructure/terraform/dns
terraform apply -auto-approve
```

### Step 9 — Install EBS CSI Driver (Pre-req for LitmusChaos)

```bash
aws eks create-addon \
  --cluster-name sre-ai-agent-dev-eks-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1 || echo "addon may already exist"

# Wait for addon to be active
aws eks wait addon-active \
  --cluster-name sre-ai-agent-dev-eks-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1

# IAM service account for EBS CSI
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster sre-ai-agent-dev-eks-cluster \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --region us-east-1 || echo "SA may already exist"

# Set gp2 as default StorageClass
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Step 10 — Build + Push Agent Image + Deploy Agent

```bash
# Build agent image
docker build -t sre-ai-agent-llm ./agent
docker tag sre-ai-agent-llm:latest \
  502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-llm:latest
docker push \
  502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-ai-agent-llm:latest

# Create agent secret
kubectl create secret generic agent-secret \
  --from-literal=gemini-api-key=$GEMINI_API_KEY \
  --from-literal=db-password=sre_pass \
  --namespace sre-ai-agent-llm \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy pgvector + agent
kubectl apply -f kubernetes/pgvector-deployment.yaml
kubectl apply -f kubernetes/pgvector-service.yaml
kubectl apply -f kubernetes/agent-configmap.yaml
kubectl apply -f kubernetes/agent-deployment.yaml
kubectl apply -f kubernetes/agent-service.yaml

# Wait for pgvector to be ready
kubectl rollout status deployment/pgvector -n sre-ai-agent-llm --timeout=300s
```

### Step 11 — Index Runbooks into pgvector

```bash
# Port-forward pgvector to localhost
kubectl port-forward -n sre-ai-agent-llm \
  deployment/pgvector 5432:5432 &
PF_PID=$!
sleep 5

# Initialize schema
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent \
  -f vector-db/init.sql

# Index all runbooks
source .venv/bin/activate || source .venv/Scripts/activate
python rag/indexer.py

# Kill port-forward
kill $PF_PID 2>/dev/null || true
```

**Expected output:**
```
Indexing docs/runbooks/api-5xx-errors.md... ✓ 4 chunks
Indexing docs/runbooks/api-availability.md... ✓ 3 chunks
Indexing docs/runbooks/high-latency.md... ✓ 3 chunks
Indexing docs/runbooks/pod-restarts.md... ✓ 4 chunks
Total: 14 chunks indexed
```

### Step 12 — Install Prometheus + Grafana + LitmusChaos

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update

# Prometheus
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring --create-namespace \
  --set server.service.type=LoadBalancer \
  --set server.persistentVolume.enabled=false

# Grafana
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --set service.type=LoadBalancer \
  --set adminPassword=admin \
  --set persistence.enabled=false \
  --set "datasources.datasources\.yaml.apiVersion=1" \
  --set "datasources.datasources\.yaml.datasources[0].name=Prometheus" \
  --set "datasources.datasources\.yaml.datasources[0].type=prometheus" \
  --set "datasources.datasources\.yaml.datasources[0].url=http://prometheus-server.monitoring.svc.cluster.local"

# LitmusChaos
helm upgrade --install litmuschaos litmuschaos/litmus \
  --namespace litmus \
  -f infrastructure/helm/litmus/values.yaml \
  --set portal.frontend.service.type=LoadBalancer
```

### `infrastructure/helm/litmus/values.yaml`

```yaml
# Critical: MongoDB tolerations so it runs on agent_nodes
mongodb:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "ai-agent"
      effect: "NoSchedule"
  nodeSelector:
    workload: "ai-agent"
  persistence:
    storageClass: "gp2"
    size: 20Gi
```

---

## 5. infra-down.sh — Safe Teardown

**Order matters critically.** Wrong order = orphaned AWS resources = Terraform destroy fails.

### Correct Teardown Order

```bash
#!/bin/bash
set -e

echo "=== Step 1: Uninstall Helm releases (removes K8s resources) ==="
helm uninstall litmuschaos -n litmus || true
helm uninstall prometheus -n monitoring || true
helm uninstall grafana -n monitoring || true
helm uninstall datadog-agent -n sre-ai-agent || true

echo "=== Step 2: Delete LoadBalancer services (triggers AWS ELB deletion) ==="
kubectl delete svc sre-ai-agent -n sre-ai-agent || true
kubectl delete svc sre-ai-agent-llm -n sre-ai-agent-llm || true
kubectl delete svc prometheus-server -n monitoring || true
kubectl delete svc grafana -n monitoring || true
kubectl delete svc litmusportal-frontend-service -n litmus || true

echo "=== Step 3: Delete PVCs (releases EBS volumes) ==="
kubectl delete pvc --all -n litmus || true

echo "=== Step 4: Force delete all namespaces ==="
kubectl delete namespace sre-ai-agent --force --grace-period=0 || true
kubectl delete namespace sre-ai-agent-llm --force --grace-period=0 || true
kubectl delete namespace monitoring --force --grace-period=0 || true
kubectl delete namespace litmus --force --grace-period=0 || true

echo "=== Step 5: Wait for AWS ELBs to be deleted (60s) ==="
sleep 60

echo "=== Step 6: Verify ELBs are gone ==="
aws elbv2 describe-load-balancers --region us-east-1 \
  --query 'LoadBalancers[].LoadBalancerName'

echo "=== Step 7: EBS CSI cleanup ==="
aws eks delete-addon \
  --cluster-name sre-ai-agent-dev-eks-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1 || true

eksctl delete iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster sre-ai-agent-dev-eks-cluster \
  --region us-east-1 || true

echo "=== Step 8: Terraform destroy EKS + VPC ==="
cd infrastructure/terraform/eks
terraform destroy -auto-approve

# NOTE: DNS section is COMMENTED OUT — never destroy hosted zone
# NS records at BigRock are permanent — destroying zone loses them
# cd infrastructure/terraform/dns
# terraform destroy -auto-approve
```

### Why This Order?

```
Problem: ELBs are created by K8s (via LoadBalancer service type)
         Terraform does NOT know about them
         If Terraform destroys VPC first → ELBs remain → VPC can't delete
                                                         (orphaned AWS resource)

Solution:
  1. Delete K8s LoadBalancer services → AWS ELB gets deleted by K8s controller
  2. Wait 60s for AWS to process ELB deletion
  3. Then terraform destroy → VPC is clean → succeeds

Problem 2: EBS volumes (for MongoDB PVC) attached to nodes
           Terraform can't delete node group while volumes attached

Solution:
  1. Delete PVCs → EBS volumes detach + get deleted
  2. Then terraform destroy → node groups can be deleted
```

---

## 6. Failures, Root Causes, and Fixes

### Failure 1 — LitmusChaos MongoDB PVC Stuck Pending

**When:** First deployment after adding LitmusChaos to infra-up-complete.sh

**Symptom:**
```bash
kubectl get pvc -n litmus
# NAME                         STATUS    VOLUME  CAPACITY  ACCESS MODES
# data-volume-chaos-mongodb-0  Pending   <none>  <none>    <none>

kubectl describe pvc data-volume-chaos-mongodb-0 -n litmus
# Events:
#   Warning ProvisioningFailed  waiting for a volume to be created,
#   either by external provisioner "ebs.csi.aws.com" or manually created by system administrator
```

**Root Cause:**
EKS does not install the EBS CSI driver by default. Without it, `ebs.csi.aws.com`
provisioner doesn't exist, so no StorageClass can fulfill PVC requests.

```
PVC (WaitForFirstConsumer)
  → needs gp2 StorageClass
     → needs aws-ebs-csi-driver addon
        → NOT installed by default on EKS!
```

**Fix:**
```bash
# 1. Install EBS CSI addon
aws eks create-addon \
  --cluster-name sre-ai-agent-dev-eks-cluster \
  --addon-name aws-ebs-csi-driver

# 2. Create IAM service account (addon needs AWS permissions)
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster sre-ai-agent-dev-eks-cluster \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

# 3. Set gp2 as default StorageClass
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 4. Delete stuck PVC and re-deploy
kubectl delete pvc --all -n litmus
helm uninstall litmuschaos -n litmus
helm install litmuschaos ... -f infrastructure/helm/litmus/values.yaml
```

**Permanent fix:** Added EBS CSI installation as Step 9 of infra-up-complete.sh.

---

### Failure 2 — Datadog Pods CrashLoopBackOff (Missing Secret)

**When:** Script was interrupted after Helm install but before secret creation

**Symptom:**
```bash
kubectl describe pod datadog-agent-xxx -n sre-ai-agent
# Error: secret "datadog-secret" not found
# State: CrashLoopBackOff
# Reason: Error
```

**Root Cause:** Original script created the secret AFTER Helm install.
Script failed midway → Helm installed → no secret → crash.

**Fix:** Secret creation moved to Step 4 (BEFORE Step 7 Helm install).
Also made idempotent:
```bash
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --dry-run=client -o yaml | kubectl apply -f -
#  ^^^^^^^^ Makes it safe to re-run — won't fail if secret exists
```

---

### Failure 3 — Namespace Stuck Terminating

**When:** Re-running infra-down.sh after partial failure

**Symptom:**
```bash
kubectl delete namespace sre-ai-agent
# ...waits for 15 minutes...
# namespace "sre-ai-agent" stuck in Terminating state
```

**Root Cause:**
Some resources had finalizers that prevented deletion. LoadBalancer service
was still waiting for AWS ELB to be deleted, blocking namespace termination.

**Fix:**
```bash
# Force delete — skips finalizers
kubectl delete namespace sre-ai-agent --force --grace-period=0
```

**Also:** Always delete LoadBalancer services BEFORE deleting namespace.

---

### Failure 4 — .terraform/ Accidentally Committed to Git

**When:** Second time this happened (first was in Phase 21 with EKS terraform)

**This time:** `infrastructure/terraform/dns/.terraform/` containing providers (814 MB)

**Symptom:**
```
remote: error: File .terraform/providers/registry.terraform.io/hashicorp/aws/
        5.94.1/linux_amd64/terraform-provider-aws_v5.94.1_x5 is 814.23 MB
remote: error: GH001: Large files detected.
```

**Root Cause:**
`.gitignore` had:
```
**/.terraform/
```
But this only works for UNTRACKED files. If `.terraform/` was ever committed
(even accidentally in a previous add), git still tracks it.

**Fix:**
```bash
# Remove from git tracking WITHOUT deleting the files
git rm -r --cached infrastructure/terraform/dns/.terraform/
git rm -r --cached infrastructure/terraform/eks/.terraform/

# Reset to last good commit
git reset --soft origin/main

# Now add only what you want
git add infrastructure/terraform/dns/route53.tf
git add infrastructure/terraform/dns/variables.tf
# ... only specific files
git commit -m "add dns terraform files"
git push
```

**Prevention — verify .gitignore has these lines:**
```gitignore
**/.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
kubernetes/agent-secret.yaml
.env
```

**Also run after every terraform init:**
```bash
git status | grep .terraform
# Should show nothing — if it shows .terraform files, add them to .gitignore NOW
```

---

### Failure 5 — Duplicate Route53 Hosted Zones

**When:** Re-deploying from scratch after terraform destroy (which preserved DNS)

**Symptom:**
```bash
nslookup sre.machindra.online
# Returns: 185.38.109.200 (not the ELB)
# Expected: <ELB hostname>
```

**Root Cause:**
Two hosted zones for `machindra.online`:
- `Z0853158MC1FIFCWWDEB` — Original zone (BigRock NS records point to this)
- `Z03766052D7VJCPILHC1A` — New zone created by terraform on re-deploy

Terraform's DNS apply created a NEW hosted zone instead of using the existing one.
BigRock registrar NS records pointed to the OLD zone's nameservers.
All Route53 records (sre.machindra.online) went into NEW zone → not visible to internet.

**Fix:**
```bash
# 1. Find which zone BigRock NS records point to
# Go to BigRock control panel → see NS records
# e.g.: ns-1433.awsdns-51.org → this is the old zone Z0853158MC1FIFCWWDEB

# 2. Import old zone into terraform state
cd infrastructure/terraform/dns
terraform import aws_route53_zone.main Z0853158MC1FIFCWWDEB

# 3. Delete the new (wrong) zone
aws route53 delete-hosted-zone --id Z03766052D7VJCPILHC1A

# 4. Apply DNS terraform (now uses correct zone)
terraform apply
```

**Prevention:**
NEVER destroy DNS terraform. infra-down.sh has DNS section commented out.
If terraform state is lost, always `terraform import` before `terraform apply`.

---

### Failure 6 — t3.small Pod Limit Hit

**When:** Adding Prometheus + Grafana to already-running cluster

**Symptom:**
```bash
kubectl describe pod prometheus-server-xxx -n monitoring
# Events:
#   Warning  FailedScheduling  0/2 nodes are available:
#             2 Insufficient cpu, 2 Insufficient memory
```

**Root Cause:**
Started with app_nodes desired=1 (1 node, 11 pod slots).
kube-system + datadog + app already used ~9 pods.
Prometheus needed 3 more pods → only 2 slots left.

**Fix:**
Increase node group desired count:
```bash
aws eks update-nodegroup-config \
  --cluster-name sre-ai-agent-dev-eks-cluster \
  --nodegroup-name app_nodes \
  --scaling-config minSize=1,maxSize=5,desiredSize=3 \
  --region us-east-1
```

Updated `infrastructure/terraform/eks/eks.tf`:
```hcl
scaling_config {
  desired_size = 3
  max_size     = 5
  min_size     = 1
}
```

---

## 7. AWS Resource Inventory After Deployment

After successful `infra-up-complete.sh`:

| Resource Type | Name/ID | Details |
|---|---|---|
| VPC | vpc-0f54a5717508fbfcb | 10.0.0.0/16, us-east-1 |
| EKS Cluster | sre-ai-agent-dev-eks-cluster | K8s 1.32 |
| Node Group | app_nodes | t3.small × 3 |
| Node Group | agent_nodes | t3.small × 1 |
| ECR Repo (app) | sre-ai-agent-dev-ecr-api | FastAPI image |
| ECR Repo (agent) | sre-ai-agent-llm | LangGraph image |
| ELB (app) | a8936145499d44636ad2bcb8498a628f | sre-ai-agent |
| ELB (agent) | a3232e47903ab4dc19280bed0da4c027 | sre-ai-agent-llm |
| ELB (grafana) | a2d11fbf9838f43ebbaa9f3952fd81e7 | admin/admin |
| ELB (prometheus) | a41db33a577984b7ba58dd3643b028cd | metrics |
| ELB (litmus) | a8deac0f42a5b426f9368c9da7ae1e66:9091 | admin/litmus |
| Route53 Zone | Z0853158MC1FIFCWWDEB | machindra.online |
| Route53 Record | sre.machindra.online | CNAME → app ELB |
| EBS Volume | auto-provisioned | 20Gi for MongoDB |
| EBS CSI Addon | aws-ebs-csi-driver | Required for PVC |

---

## 8. Key Learnings

| # | Learning | Why It Matters |
|---|---|---|
| 1 | **EBS CSI driver is NOT installed by default on EKS** | Any StatefulSet with PVC will get stuck Pending without it |
| 2 | **Create K8s secrets BEFORE Helm install** | Helm-installed apps that reference secrets crash immediately if secret missing |
| 3 | **Always use `--dry-run=client -o yaml \| kubectl apply`** | Makes all resource creation idempotent — safe to re-run script |
| 4 | **`--force --grace-period=0` for namespace deletion** | Prevents stuck Terminating namespaces blocking subsequent runs |
| 5 | **Never commit .terraform/** | Provider binaries are 800MB+. `git rm --cached` to untrack |
| 6 | **Never destroy Route53 hosted zone** | BigRock NS records are permanent — losing zone = losing DNS forever |
| 7 | **Always delete LoadBalancer services before terraform destroy** | K8s creates ELBs that terraform doesn't know about — must clean up manually |
| 8 | **t3.small = 11 pods max** | Plan pod count before choosing instance type — unexpected scheduling failures |
| 9 | **LitmusChaos MongoDB needs agent_nodes toleration** | Default values.yaml has no tolerations — must override with custom values.yaml |
| 10 | **`python3` alias broken on Git Bash Windows** | Fix: `alias python3='python'` — all scripts use `python` not `python3` |

---

## 9. Interview Q&A

**Q: How did you automate EKS deployment?**
> Built a 15-step bash script (`infra-up-complete.sh`) that chains Terraform (EKS + VPC), Docker build/push to ECR, kubectl manifests, Helm installs (Datadog, Prometheus, Grafana, LitmusChaos), and pgvector schema + runbook indexing — all in one command. The script uses idempotent patterns (`kubectl apply --dry-run=client -o yaml`) so re-runs are safe.

**Q: What was the most complex failure you debugged in the automation?**
> LitmusChaos MongoDB PVC stuck in Pending state. Traced it to missing EBS CSI driver (not installed by default on EKS). Dug into StorageClass provisioner chain: MongoDB StatefulSet → PVC → `ebs.csi.aws.com` provisioner → addon not installed → no provisioner to fulfill PVC. Fixed by adding EBS CSI addon installation as an early step in infra-up-complete.sh.

**Q: How did you handle secret management in automation scripts?**
> Three-layer approach: (1) `.env` file gitignored, loaded with `export $(cat .env | grep -v '^#' | xargs)`; (2) `load-secrets.sh` reads from `~/.secrets/` directory (also gitignored); (3) `kubernetes/agent-secret.yaml` is gitignored — created dynamically in script. Helm installs reference secrets by name using `--set datadog.apiKeyExistingSecret=datadog-secret` so credentials never appear in Helm values.

**Q: How do you safely tear down an EKS cluster without orphaned resources?**
> Specific order: (1) Helm uninstall first (removes K8s resources); (2) Delete LoadBalancer services (triggers ELB deletion in AWS); (3) Delete PVCs (releases EBS volumes); (4) Force-delete namespaces; (5) Wait 60s for AWS to process ELB deletion; (6) Then terraform destroy. Wrong order causes VPC deletion failure because AWS won't delete a VPC containing ELBs.

---

*Phase 22 Complete — SRE AI Agent Observability Platform*
*GitHub: Machindra220/SRE-AI-Agent-Observability*
