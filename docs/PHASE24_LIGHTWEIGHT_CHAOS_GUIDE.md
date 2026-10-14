# Phase 24 — Lightweight Chaos Engineering + Grafana Cloud Observability

**File:** `PHASE24_LIGHTWEIGHT_CHAOS_GUIDE.md`  
**Phase:** 24 — chaoskube + Loki/Promtail log scraping + Grafana Cloud chaos dashboard  
**Prerequisite:** Phase 22 (EKS running) + Phase 23 (Grafana Cloud + webhook)

---

## 1. What We Built

Phase 24 completes the full chaos-to-RCA demo loop on **free-tier AWS (t3.small nodes)**:

```
chaoskube kills pod
    ↓
pod restarts → kube_pod_container_restarts_total rises
    ↓
Prometheus remote_write → Grafana Cloud Mimir
    ↓
Grafana Cloud alert rule fires (Pod Restart Rate High)
    ↓
Notification Policy → contact point (webhook POST)
    ↓
http://<AGENT_LB>/agent/triage
    ↓
LangGraph 4-node pipeline:
  alert_parser → runbook_retriever → diagnoser → rca_writer
    ↓
RCA logged → Promtail scrapes log → Grafana Cloud Loki
    ↓
Grafana chaos dashboard shows kill + recovery + RCA in real-time
```

---

## 2. Why We Replaced LitmusChaos with chaoskube

| Aspect | LitmusChaos | chaoskube |
|---|---|---|
| Memory footprint | ~1.5GB (MongoDB StatefulSet) | ~50MB (single pod) |
| Storage requirement | EBS CSI + PVC (~10GB) | None |
| Node requirement | t3.medium+ | t3.small ✓ |
| Cost (free tier) | ❌ Exceeds free tier | ✓ Free tier compatible |
| Install complexity | Helm + EBS CSI + IAM role + gp2 patch | Single `helm upgrade --install` |
| Feature set | Full chaos platform, fault libraries | Random pod killer |
| Purpose (this project) | Enterprise demo | SRE demo: trigger Grafana alert → LangGraph RCA ✓ |

**Decision:** chaoskube does exactly what this demo needs — kill a pod, trigger the alert, prove the RCA pipeline works. No MongoDB, no EBS, no IAM footprint.

---

## 3. Files Delivered

```
scripts/
├── deploy-chaoskube.sh          # Install chaoskube on EKS
├── deploy-loki-promtail.sh      # Ship EKS logs to Grafana Cloud Loki
├── infra-up-complete.sh         # Updated: INSTALL_DATADOG/LITMUSCHAOS flags
└── infra-down.sh                # Updated: matching teardown flags

infrastructure/helm/
└── promtail/
    └── values.yaml              # Promtail DaemonSet config — scrapes 4 namespaces

monitoring/grafana/
└── grafana-chaos-dashboard.json # Import to Grafana Cloud — 8 panels, 2 datasources
```

---

## 4. Step-by-Step Deployment

### Pre-checks
```bash
# Verify cluster is running
kubectl get nodes
# Expected: 4 nodes (3 app_nodes + 1 agent_node), all Ready

# Verify Grafana Cloud alert rules are configured (Phase 23)
# Grafana Cloud → Alerting → Alert rules → "SRE AI Agent" folder
# Should have: High Error Rate, Pod Restart Rate High, High p99 Latency

# Verify agent LB is running
kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm
# STATUS: LoadBalancer with EXTERNAL-IP
```

### Step 1 — Deploy chaoskube (pod killer)
```bash
# Default: kills a random pod in sre-ai-agent every 2 minutes
./scripts/deploy-chaoskube.sh

# Optional: test without actual kills first
DRY_RUN=true ./scripts/deploy-chaoskube.sh

# Optional: slower interval (demo-friendly)
CHAOS_INTERVAL=5m ./scripts/deploy-chaoskube.sh
```

**What happens:**
- Helm installs chaoskube v0.29.0 in `chaos` namespace
- ClusterRole grants list+delete pods (least-privilege)
- chaoskube targets all pods in `sre-ai-agent` namespace
- Every 2 minutes, one random pod gets deleted
- Kubernetes restarts it immediately (Deployment controller)

**Verify:**
```bash
# Watch chaoskube kill logs in real-time
kubectl logs -n chaos -f deployment/chaoskube

# Expected output (JSON format):
# {"level":"info","msg":"killing pod","name":"sre-ai-agent-xxxxx","namespace":"sre-ai-agent"}

# Watch pod getting killed and recreated
kubectl get pods -n sre-ai-agent -w
```

### Step 2 — Deploy Promtail → Grafana Cloud Loki (log scraping)
```bash
# Credentials are loaded from .env automatically.
# Ensure your .env has:
#   LOKI_USER_ID=1800194
#   GRAFANA_CLOUD_API_KEY=<same-token-from-phase-23>
#
# (LOKI_USER_ID = numeric User field from grafanacloud-scarletcanary2090-logs datasource)

./scripts/deploy-loki-promtail.sh
```

**What happens:**
- Adds `infrastructure/helm/promtail/values.yaml` values
- Creates `promtail-loki-secret` in monitoring namespace
- Deploys Promtail DaemonSet (one pod per EKS node)
- Scrapes logs from: `sre-ai-agent`, `sre-ai-agent-llm`, `chaos`, `monitoring`
- Ships to: `https://logs-prod-ap-south-1.grafana.net/loki/api/v1/push`

**Verify in Grafana Cloud:**
```
Grafana Cloud → Explore → Loki datasource
Query: {namespace="sre-ai-agent"}
→ Should see app pod logs within 60s of deployment
```

### Step 3 — Import Grafana Cloud chaos dashboard
```
1. Grafana Cloud → Dashboards → Import
2. Upload: monitoring/grafana/grafana-chaos-dashboard.json
3. Select datasources:
   - Grafana Cloud Prometheus → grafanacloud-<stack>-prom
   - Grafana Cloud Loki      → grafanacloud-<stack>-logs
4. Click Import
5. Dashboard opens: "SRE AI Agent — Chaos Monitoring (Phase 24)"
```

**Dashboard panels:**
- Row 1 — Chaos Status: 6 stat tiles (restarts, error rate, p99, not-running pods, running pods, recovery time)
- Row 2 — Chaos Impact: pod restart rate, HTTP error rate, latency percentiles (p50/p95/p99), pod count
- Row 3 — LangGraph RCA Agent: live log panel showing triage/diagnosis/rca output
- Row 4 — Chaos Events: chaoskube kill log + app error log side-by-side
- Row 5 — AI Quality Metrics: eval scores (context_recall, faithfulness, correctness) + triage call counter

Auto-refresh: 30 seconds

### Step 4 — Update Grafana Cloud webhook URL (from Phase 23)
```
Grafana Cloud → Alerting → Contact points → sre-ai-agent-webhook
URL: http://<AGENT_LB>/agent/triage

Replace <AGENT_LB> with:
kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

---

## 5. End-to-End Chaos Demo — Timeline

| Time | Event | Where to see it |
|---|---|---|
| T+0:00 | chaoskube kills a pod | `kubectl logs -n chaos deployment/chaoskube` |
| T+0:05 | Pod shows Terminating | `kubectl get pods -n sre-ai-agent -w` |
| T+0:10 | New pod starts (ContainerCreating) | Dashboard: "Pod Count" panel dips + recovers |
| T+0:15 | `kube_pod_container_restarts_total` increments | Dashboard: "Pod Restarts" spike |
| T+0:30 | Grafana Cloud alert fires (Pod Restart Rate High) | Grafana Cloud → Alerting → Active alerts |
| T+0:36 | Webhook POST hits `/agent/triage` | Agent pod logs: `kubectl logs -n sre-ai-agent-llm deployment/sre-ai-agent-llm` |
| T+0:40 | LangGraph starts: alert_parser node | Dashboard: "LangGraph RCA Agent" log panel |
| T+0:50 | runbook_retriever fetches runbook chunks from pgvector | Agent logs: "Retrieved N chunks" |
| T+1:00 | diagnoser calls Gemini → diagnosis | Agent logs: "Diagnosis: ..." |
| T+1:10 | rca_writer formats RCA | Dashboard: full RCA visible in Loki panel |
| T+2:00 | chaoskube kills next pod | Loop restarts |

---

## 6. Control Chaos

```bash
# Pause chaos (scale to 0)
kubectl scale deployment chaoskube -n chaos --replicas=0

# Resume chaos
kubectl scale deployment chaoskube -n chaos --replicas=1

# Change kill interval (re-install with new interval)
CHAOS_INTERVAL=5m ./scripts/deploy-chaoskube.sh

# Enable dry-run (logs kill intent but doesn't execute)
helm upgrade chaoskube chaoskube/chaoskube \
  -n chaos --set dryRun=true

# Stop chaos permanently
helm uninstall chaoskube -n chaos
```

---

## 7. Promtail Log Query Reference

```logql
# All app logs
{namespace="sre-ai-agent"}

# chaoskube kill events only
{namespace="chaos"}

# LangGraph RCA output
{namespace="sre-ai-agent-llm"} |= "rca"

# Errors during chaos
{namespace=~"sre-ai-agent.*"} |= "ERROR"

# Pod restart events
{namespace="sre-ai-agent"} |= "restart"

# Full chaos event chain (all namespaces, time-ordered)
{namespace=~"sre-ai-agent.*|chaos"} | json

# Alert triage calls
{namespace="sre-ai-agent-llm"} |= "triage"
```

---

## 8. Resource Usage on t3.small

After Phase 24 full deployment:

| Component | Namespace | CPU (req) | Memory (req) |
|---|---|---|---|
| sre-ai-agent | sre-ai-agent | 100m | 128Mi |
| sre-ai-agent-llm | sre-ai-agent-llm | 200m | 256Mi |
| pgvector | sre-ai-agent-llm | 100m | 256Mi |
| prometheus | monitoring | 200m | 256Mi |
| grafana | monitoring | 100m | 128Mi |
| **chaoskube** | **chaos** | **10m** | **32Mi** |
| **promtail (×4 nodes)** | **monitoring** | **50m ×4** | **64Mi ×4** |

chaoskube is negligible. Promtail adds 200m CPU + 256Mi total across 4 nodes — well within t3.small capacity (2 vCPU, 2GB each).

---

## 9. Documented Failures and Fixes

### Failure 1: Promtail can't access logs on agent_nodes
**Symptom:** Promtail pod on agent_node in `Pending` state  
**Root cause:** agent_node has taint `workload=ai-agent:NoSchedule` — Promtail DaemonSet doesn't tolerate it  
**Fix:** Added `tolerations: [{operator: Exists}]` in `promtail-values.yaml` — tolerates ALL taints  
**Lesson:** DaemonSets must tolerate all node taints to deploy on every node

### Failure 2: Loki push returns 401 Unauthorized
**Symptom:** Promtail logs show `401` on push  
**Root cause:** LOKI_USER_ID is the numeric username (e.g. `1234567`), not the stack name  
**Fix:** In Grafana Cloud → Loki → Details — copy the numeric "User" field, not the URL hostname  
**Lesson:** Grafana Cloud Loki uses `username=<numeric-id>`, `password=<api-token>` for Basic Auth

### Failure 3: chaoskube kills pgvector pod
**Symptom:** Runbook retriever fails — pgvector connection refused  
**Root cause:** chaoskube targets ALL pods in `sre-ai-agent` namespace, including pgvector  
**Fix:** pgvector is in `sre-ai-agent-llm` namespace — not targeted. App and agent are in separate namespaces by design  
**Lesson:** Namespace isolation protects stateful components from chaos

### Failure 4: Grafana Cloud dashboard shows "No data" for Loki panels
**Symptom:** Loki log panels empty despite Promtail running  
**Root cause:** Wrong Loki datasource selected at import time (local Grafana vs Cloud)  
**Fix:** In Grafana Cloud → Explore, confirm datasource is `grafanacloud-<stack>-logs`, then re-import dashboard selecting that datasource  
**Lesson:** Always verify datasource UID in Explore before importing dashboards

### Failure 5: Alert webhook fires before agent LB is ready
**Symptom:** Grafana sends webhook but gets `connection refused`  
**Root cause:** Agent LB takes 3-5 minutes to provision after EKS deploy  
**Fix:** In deploy flow, wait for agent LB before configuring Grafana Cloud webhook URL  
**Detection:** `kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm -w` — wait for EXTERNAL-IP  
**Lesson:** LoadBalancer services require waiting — never assume immediate availability

---

## 10. Key Learnings

| Learning | Detail |
|---|---|
| chaoskube is enough for SRE demos | Kills pods every N minutes, triggers real alerts, proves the pipeline. No need for LitmusChaos on t3.small. |
| Promtail DaemonSet must tolerate all taints | Without `tolerations: [{operator: Exists}]`, tainted nodes get no log scraping |
| Grafana Cloud Loki auth: numeric user ID | Basic auth username is not the stack name — it's a numeric ID in Loki Details |
| Namespace isolation protects chaos scope | chaoskube targeting `sre-ai-agent` only — pgvector and agent in `sre-ai-agent-llm` are safe |
| Annotate chaos events in Grafana | `kube_pod_container_restarts_total` change = annotation trigger — instantly shows on all panels where chaos happened |
| Log labels are crucial | Without `{app, namespace, pod, container}` labels on Loki logs, queries are unfiltered noise |
| chaoskube `minimumAge=30s` | Prevents killing pods that just restarted — avoids kill spiral on slow starts |
| `--dry-run` mode for safe testing | `DRY_RUN=true` logs what would be killed without doing it — essential for verifying targeting before live chaos |

---

## 11. Phase 24 vs Phase 22 Architecture Comparison

**Phase 22 (before):**
```
EKS → Prometheus → Grafana (local) → no alerting
LitmusChaos (commented out — too heavy)
No log aggregation
```

**Phase 24 (after):**
```
EKS → Prometheus → remote_write → Grafana Cloud Mimir → alerts → webhook → LangGraph
EKS → Promtail → Grafana Cloud Loki → chaos dashboard
chaoskube → pod kills → real alerts → real RCA
```

---

## 12. Interview Questions and Answers

**Q: Why use chaoskube instead of LitmusChaos?**  
A: LitmusChaos requires MongoDB StatefulSet (~1.5GB RAM) and EBS CSI driver for PVC storage. Our EKS nodes are t3.small (2GB RAM) — the full cluster would run out of memory just running the chaos platform. chaoskube is a single 50MB Deployment with no storage requirement, deploys in seconds, and achieves the same goal: randomly kill pods to trigger real alerts and validate the LangGraph RCA pipeline.

**Q: How does Promtail scrape Kubernetes pod logs?**  
A: Promtail runs as a DaemonSet — one pod per EKS node. Each Promtail pod mounts the host's `/var/log/pods/` directory (read-only). It discovers pod metadata through the Kubernetes SD (service discovery) API, matches pods to log files using pod UID, and enriches every log line with labels: `{namespace, pod, container, app, node}`. Enriched logs are pushed to Grafana Cloud Loki via HTTPS with Basic Auth (numeric user ID + API token).

**Q: What's the complete chaos-to-RCA flow in this system?**  
A: chaoskube kills a pod in the sre-ai-agent namespace every 2 minutes. The Deployment controller immediately starts a replacement, which increments `kube_pod_container_restarts_total`. Prometheus scrapes this metric and ships it to Grafana Cloud Mimir via remote_write. The "Pod Restart Rate High" alert rule (PromQL: `rate(kube_pod_container_restarts_total[2m]) > 0.1`) evaluates and fires. The notification policy routes it to the contact point, which POSTs the Alertmanager-format JSON to the agent LB at `/agent/triage`. The LangGraph 4-node pipeline runs: `alert_parser` extracts severity and labels, `runbook_retriever` queries pgvector for matching runbook chunks (RAG), `diagnoser` calls Gemini with alert + context, `rca_writer` formats the structured RCA. The agent logs the full RCA, Promtail scrapes it, and it appears in the Grafana Cloud chaos dashboard's Loki log panel within ~30 seconds of the pod kill.

**Q: How do you ensure Promtail covers nodes with scheduling taints?**  
A: By setting `tolerations: [{operator: Exists}]` in Promtail's Helm values. The `Exists` operator without specifying a key matches all taints on all nodes — including our `workload=ai-agent:NoSchedule` taint on agent_nodes. Without this, the Promtail DaemonSet would never schedule a pod on tainted nodes, leaving those nodes' pod logs unscraped.

**Q: How is chaos scoped to avoid killing critical components?**  
A: chaoskube is configured with `--namespaces=sre-ai-agent`, so it only targets pods in that namespace. Our stateful components — pgvector and the LangGraph agent — are in the `sre-ai-agent-llm` namespace and are never targeted. This is enforced at the namespace level, not through labels, so even if a pod in `sre-ai-agent` has the wrong labels, it's still in scope; pgvector can never be in scope. Additionally, `--minimum-age=30s` prevents chaoskube from immediately re-killing a pod that just restarted, avoiding kill spirals.
