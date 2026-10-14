# Phase 23 — Grafana Cloud Webhook Integration: Complete Guide

> **Repo:** Machindra220/SRE-AI-Agent-Observability
> **Phase:** 23 — Grafana Cloud Alerts → LangGraph AI Agent (Replaces Datadog)
> **Status:** 🔄 In Progress (setup complete, end-to-end test pending)
> **Goal:** Replace Datadog alerting (trial expired) with Grafana Cloud free tier — permanent, no expiry

---

## Table of Contents

1. [Why We Switched from Datadog to Grafana Cloud](#1-why-we-switched-from-datadog-to-grafana-cloud)
2. [Grafana Cloud Architecture](#2-grafana-cloud-architecture)
3. [Step-by-Step Setup](#3-step-by-step-setup)
4. [Alert Rules Configured](#4-alert-rules-configured)
5. [Contact Points and Notification Policies](#5-contact-points-and-notification-policies)
6. [prometheus.yml Remote Write Configuration](#6-prometheusyml-remote-write-configuration)
7. [Webhook Payload Format](#7-webhook-payload-format)
8. [infra-up-complete.sh Updates](#8-infra-up-completesh-updates)
9. [Pending: End-to-End Test](#9-pending-end-to-end-test)
10. [Key Learnings](#10-key-learnings)
11. [Interview Q&A](#11-interview-qa)

---

## 1. Why We Switched from Datadog to Grafana Cloud

### The Problem

After Phase 21 (Datadog webhook end-to-end confirmed), Datadog free trial expired.
Datadog free trial is 14 days — not renewable. All monitors, dashboards, and alerting
were built inside Datadog's platform. Without a paid account, alerting stopped.

### Options Evaluated

| Tool | Cost | Expiry | Webhook Support | Prometheus Scrape |
|---|---|---|---|---|
| Datadog | $23/host/month | Trial expired | ✅ | ✅ |
| New Relic | Free tier 100GB/month | No expiry | ✅ | ✅ |
| **Grafana Cloud** | **Free tier permanent** | **No expiry** | **✅** | **✅** |
| Prometheus Alertmanager | Self-hosted | No expiry | ✅ | ✅ but complex |

### Why Grafana Cloud

1. **Free tier is permanent** — no trial, no credit card needed
2. **Existing stack** — we already had Prometheus on EKS sending metrics
3. **Remote Write** — Prometheus can push metrics to Grafana Cloud Mimir with one config block
4. **Grafana Cloud Alerting** — identical to Prometheus Alertmanager but with better UI
5. **Same PromQL** — all existing queries work unchanged

### Architecture Change

**Before (Datadog):**
```
App (ddtrace) → Datadog Agent → Datadog Cloud → Monitor fires → Webhook → Agent
```

**After (Grafana Cloud):**
```
App (metrics) → Prometheus (EKS) → Remote Write → Grafana Cloud Mimir
                                                         ↓
                                              Alert Rule (PromQL)
                                                         ↓
                                              Notification Policy
                                                         ↓
                                              Contact Point (Webhook)
                                                         ↓
                                              POST /agent/triage (LangGraph)
```

---

## 2. Grafana Cloud Architecture

### Grafana Cloud Stack Details

```
Stack name:    scarletcanary2090
Region:        India - prod-ap-south-1 - mimir-prod-43
Cloud Provider: aws - ap-south-1

Remote Write URL: https://prometheus-prod-43-prod-ap-south-1.grafana.net/api/prom/push
Query URL:        https://prometheus-prod-43-prod-ap-south-1.grafana.net/api/prom
Username (ID):    3609050
API Token:        stored in .env as GRAFANA_CLOUD_API_KEY
Active Series:    6,948 (from Prometheus scraping EKS)
```

### Component Map

```
Grafana Cloud Platform
├── Mimir (metrics storage)         ← receives Prometheus remote_write
├── Alert Engine (Grafana-managed)  ← evaluates PromQL rules every 1m
│   └── Alert Rules
│       ├── folder: GrafanaCloud (built-in)
│       │   └── "Alert if P95 response time exceeds 500ms"
│       └── folder: sre-ai-agent (our rules)
│           └── eval group: default-eval (1m interval)
│               ├── High Error Rate
│               ├── Pod Restart Rate High
│               └── High p99 Latency
├── Notification Configuration
│   ├── Contact Points
│   │   ├── empty (default — no integrations)
│   │   ├── Machindra (Email: machindra220@gmail.com)
│   │   └── sre-ai-agent-webhook (Webhook: http://PLACEHOLDER/agent/triage
│   │                             + Email: machindra220@gmail.com)
│   └── Notification Policies
│       └── ai-agent-notification
│           ├── Default contact point: sre-ai-agent-webhook
│           ├── Group by: grafana_folder, alertname, personal-email
│           └── Timing: GroupWait=30s, GroupInterval=5m, Repeat=4h
└── Dashboards
    └── (existing dashboards from local Grafana can be imported)
```

---

## 3. Step-by-Step Setup

### 3.1 — Create Grafana Cloud Account

1. Go to https://grafana.com/auth/sign-up/create-user
2. Choose free plan — "Grafana Cloud Free" (permanent, no credit card)
3. Create stack: choose any name (used: `scarletcanary2090`)
4. Select region closest to EKS: chose India (ap-south-1) to match EKS us-east-1

### 3.2 — Generate API Token for Remote Write

Navigate: **Home → Connections → Add new connection → Prometheus → Send metrics to Grafana Cloud**

The setup page shows:
- Grafana Cloud cluster/region: `India - prod-ap-south-1 - mimir-prod-43`
- Cloud Service Provider: `aws - ap-south-1`
- Active Series: `6,948`
- Remote Write Endpoint: `https://prometheus-prod-43-prod-ap-south-1.grafana.net/api/prom/push`
- Username / Instance ID: `3609050`
- Password / API Token: click **"Generate now"**

**API Token creation dialog:**
- Access policy name: `stack-1842413-hm-write` (auto-generated)
- Token name: `AI-project`
- Expiration: `30 days`
- Scopes: `metrics:write, metrics:import, logs:write, traces:write, alerts:write, rules:write, profiles:write, datadog:validate`

**Click "Create token"** → copy token immediately (shown only once)

Store in `.env`:
```bash
GRAFANA_CLOUD_API_KEY=<token>
GRAFANA_CLOUD_USERNAME=3609050
GRAFANA_CLOUD_REMOTE_WRITE_URL=https://prometheus-prod-43-prod-ap-south-1.grafana.net/api/prom/push
```

### 3.3 — Configure Prometheus Remote Write

See [Section 6](#6-prometheusyml-remote-write-configuration) for full config.

### 3.4 — Create Contact Point: sre-ai-agent-webhook

Navigate: **Alerts & IRM → Alerting → Notification configuration → Contact points → + New contact point**

**Contact point: `sre-ai-agent-webhook`**
- Integration 1: **Webhook**
  - URL: `http://PLACEHOLDER/agent/triage`
  - *(PLACEHOLDER = agent ELB hostname — must update after each EKS deployment)*
- Integration 2: **Email**
  - Addresses: `machindra220@gmail.com`

**Status after creation:**
```
sre-ai-agent-webhook    ⚠️ Unused (before notification policy linked)
  🔗 Webhook  http://PLACEHOLDER/agent/triage
     ⊘ Last delivery attempt failed  ← expected, PLACEHOLDER not a real URL
  ✉️ Email    machindra220@gmail.com
     No delivery attempts
```

**Also created: `Machindra` contact point** (email-only, used by some alert rules)
- Integration: Email
- Addresses: `machindra220@gmail.com`

### 3.5 — Create Notification Policy

Navigate: **Alerts & IRM → Alerting → Notification configuration → Notification policies → + New policy**

**Policy: `ai-agent-notification`**
- Name: `ai-agent-notification`
- Default contact point: `sre-ai-agent-webhook`
- Group by: `grafana_folder`, `alertname`
- Timing options:
  - Group wait: `30s`
  - Group interval: `5m`
  - Repeat interval: `4h`

**Updated default route:**
- Default contact point: `sre-ai-agent-webhook`
- Group by: `grafana_folder`, `alertname`, `personal-email`

### 3.6 — Create Alert Rules

Navigate: **Alerts & IRM → Alerting → Alert rules → + New alert rule**

**Folder:** `sre-ai-agent`
**Eval group:** `default-eval`
**Eval interval:** `1m`

**Labels (applied to all rules):**
From the "Edit labels" dialog (showing service_name, team_name as available keys):
- `service_name = sre-ai-agent`
- `team_name = sre-platform`

See [Section 4](#4-alert-rules-configured) for all three rules.

---

## 4. Alert Rules Configured

### Rule 1 — High Error Rate

```yaml
Name: High Error Rate
Folder: sre-ai-agent
Group: default-eval
Interval: 1m

Query (A):
  Datasource: grafanacloud-scarletcanary2090-prom
  PromQL: |
    rate(http_requests_total{status=~"5.."}[5m])
    /
    rate(http_requests_total[5m])
    > 0.05

Condition: A > 0 (fires when query returns any result)

Labels:
  severity: P2
  service_name: sre-ai-agent

Annotations:
  summary: High error rate detected on {{ $labels.job }}
  runbook_url: https://github.com/Machindra220/SRE-AI-Agent-Observability

Contact point: Machindra (email)
```

**What this catches:** More than 5% of HTTP requests returning 5xx errors

### Rule 2 — Pod Restart Rate High

```yaml
Name: Pod Restart Rate High
Folder: sre-ai-agent
Group: default-eval
Interval: 1m

Query (A):
  Datasource: grafanacloud-scarletcanary2090-prom
  PromQL: |
    increase(kube_pod_container_status_restarts_total[5m]) > 3

Condition: A > 0

Labels:
  severity: P2

Annotations:
  summary: Pod restart rate high
  runbook_url: https://github.com/Machindra220/SRE-AI-Agent-Observability
```

**What this catches:** Any pod restarting more than 3 times in 5 minutes (CrashLoopBackOff pattern)

### Rule 3 — High p99 Latency

```yaml
Name: High p99 Latency
Folder: sre-ai-agent
Group: default-eval
Interval: 1m

Query (A):
  Datasource: grafanacloud-scarletcanary2090-prom
  PromQL: |
    histogram_quantile(0.99,
      rate(flask_http_request_duration_seconds_bucket[5m])
    ) > 2

Condition: A > 0

Labels:
  severity: P3

Annotations:
  summary: p99 latency exceeds 2 seconds
  runbook_url: https://github.com/Machindra220/SRE-AI-Agent-Observability
```

**What this catches:** 99th percentile response time exceeding 2 seconds

### Alert Rules as Seen in UI

Alert rules list shows two folders:
- **GrafanaCloud** → `Alert if P95 response time exceeds 500ms` (built-in)
- **sre-ai-agent** → `default-eval` group → `High Error Rate` (state: ⚠️ Pending/Firing)

The `High Error Rate` rule shows datasource: `grafanacloud-scarletcanary2090-prom`
and `2 labels` (service_name + severity).

---

## 5. Contact Points and Notification Policies

### Contact Points Summary

From the Notification Configuration UI:

```
Contact Points tab:

┌─────────────────────────────────────────────────────────────────┐
│ empty          Used by 1 notification policies                  │
│ ⚠️ No integrations configured                                   │
├─────────────────────────────────────────────────────────────────┤
│ Machindra      Used by 1 alert rules                            │
│ ✉️ Email  machindra220@gmail.com                                │
│    No delivery attempts                                          │
├─────────────────────────────────────────────────────────────────┤
│ sre-ai-agent-webhook  ⚠️ Unused                                 │
│ 🔗 Webhook  http://PLACEHOLDER/agent/triage                     │
│    ⊘ Last delivery attempt failed                               │
│ ✉️ Email  machindra220@gmail.com (added later)                  │
└─────────────────────────────────────────────────────────────────┘
```

**Note on "Last delivery attempt failed":** This is expected — PLACEHOLDER is not a real URL.
Will be fixed after next EKS deployment by replacing PLACEHOLDER with real agent LB hostname.

### After Adding Email to sre-ai-agent-webhook

The contact point now has both integrations:
- Webhook: `http://PLACEHOLDER/agent/triage` (will replace with real ELB)
- Email: `machindra220@gmail.com` (fallback — works immediately)

### Notification Policy Flow

```
Alert fires (PromQL condition true)
      ↓
Notification Policy: ai-agent-notification
      ↓
Wait 30s (Group wait) — collect alerts into batch
      ↓
Route to: sre-ai-agent-webhook
      ↓
   ├── POST http://<agent-lb>/agent/triage  ← LangGraph agent
   └── Email machindra220@gmail.com         ← Human notification
```

---

## 6. prometheus.yml Remote Write Configuration

File: `monitoring/prometheus/prometheus.yml`
Committed to git. API key loaded from `.env` at runtime.

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# Scrape jobs (existing from Phase 20)
scrape_configs:
  - job_name: 'sre-ai-agent'
    static_configs:
      - targets: ['localhost:8000']
    metrics_path: '/metrics'

  - job_name: 'sre-ai-agent-llm'
    static_configs:
      - targets: ['localhost:8001']
    metrics_path: '/metrics'

  - job_name: 'ai-quality-metrics'
    static_configs:
      - targets: ['localhost:9092']    # Custom metrics server
    metrics_path: '/metrics'

# ─── NEW in Phase 23 ───
remote_write:
  - url: "https://prometheus-prod-43-prod-ap-south-1.grafana.net/api/prom/push"
    basic_auth:
      username: "3609050"
      password_file: "/etc/prometheus/grafana_token"  # OR use password: with env var
    # Alternative (simpler for local dev):
    # basic_auth:
    #   username: "3609050"
    #   password: "${GRAFANA_CLOUD_API_KEY}"
    queue_config:
      max_samples_per_send: 1000
      max_shards: 200
      capacity: 2500
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "sre_.*|http_requests.*|flask_.*|kube_.*"
        action: keep   # Only send our metrics, not all Prometheus internal metrics
```

### How Remote Write Works

```
Prometheus (EKS pod, port 9093)
    ↓
Scrapes metrics from app (every 15s)
    ↓
remote_write queue (in-memory buffer)
    ↓
HTTPS POST to Grafana Cloud Mimir
    (URL: prometheus-prod-43-prod-ap-south-1.grafana.net/api/prom/push)
    (Auth: Basic username=3609050, password=<API_TOKEN>)
    ↓
Mimir stores metrics (6,948 active series currently)
    ↓
Grafana Cloud Alert Engine queries Mimir every 1m
    ↓
Alert fires if PromQL condition is true
```

### Deploying Updated prometheus.yml to EKS

```bash
# Create ConfigMap from file
kubectl create configmap prometheus-config \
  --from-file=prometheus.yml=monitoring/prometheus/prometheus.yml \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

# Create secret for Grafana token
kubectl create secret generic grafana-cloud-token \
  --from-literal=token=$GRAFANA_CLOUD_API_KEY \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Prometheus to pick up new config
kubectl rollout restart deployment/prometheus-server -n monitoring
```

---

## 7. Webhook Payload Format

When a Grafana Cloud alert fires, it sends a POST to `/agent/triage` with this JSON body:

```json
{
  "receiver": "sre-ai-agent-webhook",
  "status": "firing",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "High Error Rate",
        "grafana_folder": "sre-ai-agent",
        "severity": "P2",
        "service_name": "sre-ai-agent"
      },
      "annotations": {
        "summary": "High error rate detected on sre-ai-agent",
        "runbook_url": "https://github.com/Machindra220/SRE-AI-Agent-Observability"
      },
      "startsAt": "2024-10-14T08:00:00Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "https://scarletcanary2090.grafana.net/alerting/...",
      "fingerprint": "abc123def456"
    }
  ],
  "groupLabels": {
    "alertname": "High Error Rate",
    "grafana_folder": "sre-ai-agent"
  },
  "commonLabels": {
    "severity": "P2"
  },
  "commonAnnotations": {
    "summary": "High error rate detected"
  },
  "externalURL": "https://scarletcanary2090.grafana.net",
  "version": "1",
  "groupKey": "{}:{alertname=\"High Error Rate\"}",
  "truncatedAlerts": 0,
  "orgId": 1,
  "title": "[FIRING:1] High Error Rate",
  "state": "alerting",
  "message": "High error rate detected on sre-ai-agent"
}
```

### How agent/main.py Parses This

The LangGraph agent's `/agent/triage` FastAPI endpoint receives this payload.
The `alert_parser` node in the LangGraph pipeline extracts:

```python
@app.post("/agent/triage")
async def triage(payload: dict):
    # Grafana Cloud sends array of alerts
    alert = payload.get("alerts", [{}])[0]
    alert_name = alert.get("labels", {}).get("alertname", "Unknown")
    severity = alert.get("labels", {}).get("severity", "P3")
    summary = alert.get("annotations", {}).get("summary", "")

    # Build alert dict for LangGraph
    alert_input = {
        "alert_name": alert_name,
        "severity": severity,
        "description": summary,
        "source": "grafana-cloud",
        "raw_payload": payload
    }
    # Run LangGraph pipeline
    result = await run_langgraph_pipeline(alert_input)
    return result
```

---

## 8. infra-up-complete.sh Updates

### PENDING: INSTALL_DATADOG Flag

The master script needs to be updated to make Datadog optional:

```bash
#!/bin/bash
set -e

# ── Configuration Flags ──────────────────────────────
INSTALL_DATADOG=${INSTALL_DATADOG:-false}   # Set to true to install Datadog Agent
INSTALL_GRAFANA_CLOUD=${INSTALL_GRAFANA_CLOUD:-true}   # Grafana Cloud remote_write
# ──────────────────────────────────────────────────────

# ... Steps 1-6 (EKS, kubectl, namespaces, app deploy) ...

# Step 7: Datadog (optional)
if [ "$INSTALL_DATADOG" = "true" ]; then
  echo "=== Installing Datadog Agent ==="
  kubectl create secret generic datadog-secret \
    --from-literal=api-key=$DD_API_KEY \
    --from-literal=app-key=$DD_APP_KEY \
    --namespace sre-ai-agent \
    --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install datadog-agent datadog/datadog \
    --namespace sre-ai-agent \
    --set datadog.apiKeyExistingSecret=datadog-secret \
    ...
else
  echo "=== Skipping Datadog (INSTALL_DATADOG=false) ==="
fi

# Step 8: Grafana Cloud remote_write (always on if INSTALL_GRAFANA_CLOUD=true)
if [ "$INSTALL_GRAFANA_CLOUD" = "true" ]; then
  echo "=== Configuring Grafana Cloud remote_write ==="
  kubectl create secret generic grafana-cloud-token \
    --from-literal=token=$GRAFANA_CLOUD_API_KEY \
    --namespace monitoring \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap prometheus-config \
    --from-file=prometheus.yml=monitoring/prometheus/prometheus.yml \
    --namespace monitoring \
    --dry-run=client -o yaml | kubectl apply -f -
fi
```

**Usage:**
```bash
# Without Datadog (default — Grafana Cloud only)
./scripts/infra-up-complete.sh

# With Datadog (if trial active)
INSTALL_DATADOG=true ./scripts/infra-up-complete.sh
```

### PENDING: Update Webhook URL

After each EKS deployment, update Grafana Cloud contact point webhook URL:

```bash
# Get agent LB hostname
AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Update Grafana Cloud webhook URL to:"
echo "http://$AGENT_LB/agent/triage"

# Then go to Grafana Cloud UI:
# Alerts & IRM → Notification configuration → Contact points
# → sre-ai-agent-webhook → Edit
# → Update Webhook URL from PLACEHOLDER to $AGENT_LB
```

---

## 9. Pending: End-to-End Test

### Test Plan

Once webhook URL is updated with real agent LB:

**Step 1 — Verify metrics flowing to Grafana Cloud:**
```bash
# Check active series count in Grafana Cloud UI
# Home → Connections → Your data → Active Series > 6000 ✅
```

**Step 2 — Trigger High Error Rate alert manually:**
```bash
# Hit the app with 5xx-producing requests
AGENT_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Generate errors (hit non-existent endpoint)
for i in $(seq 1 50); do
  curl -s http://$AGENT_LB/nonexistent > /dev/null
done
```

**Step 3 — Monitor alert state in Grafana Cloud:**
```
Alert rules → sre-ai-agent → default-eval → High Error Rate
→ State should change: Normal → Pending (30s) → Firing
```

**Step 4 — Check webhook delivery:**
```
Notification configuration → Contact points → sre-ai-agent-webhook → History
→ Should show delivery attempt with status 200
```

**Step 5 — Verify agent received and processed:**
```bash
# Check agent logs
kubectl logs -f deployment/sre-ai-agent-llm -n sre-ai-agent-llm

# Expected log output:
# POST /agent/triage - 200 OK
# [alert_parser] Parsed: High Error Rate, severity=P2
# [runbook_retriever] Found 4 relevant chunks
# [diagnoser] Confidence: 78%, root_cause: High 5xx error rate
# [rca_writer] RCA generated
```

**Step 6 — Verify email received:**
```
Check machindra220@gmail.com inbox for Grafana alert email
```

### Expected End-to-End Flow Timing

```
T+0:00  → Error rate > 5% (threshold crossed)
T+0:01  → Grafana Cloud evaluates PromQL (1m interval)
T+0:30  → GroupWait expires — notification sent
T+0:31  → Webhook POST to /agent/triage
T+0:35  → LangGraph completes (4 nodes × ~1s each + Gemini API ~3s)
T+0:35  → RCA report generated, response 200 OK
T+0:36  → Email sent to machindra220@gmail.com
```

---

## 10. Key Learnings

| # | Learning | Detail |
|---|---|---|
| 1 | **Grafana Cloud free tier is permanent** | No trial expiry, no credit card needed. Datadog trial = 14 days only. Always use permanent free tier for personal projects |
| 2 | **Prometheus remote_write is one config block** | Migrate from Datadog to Grafana Cloud with just `remote_write` section in prometheus.yml + API token. No SDK change, no app code change |
| 3 | **Grafana Cloud uses Mimir as backend** | Not vanilla Prometheus. Mimir is horizontally scalable, multi-tenant. Same PromQL query language |
| 4 | **Alert rules in Grafana Cloud = Grafana-managed alerts** | Stored in Grafana Cloud, not in Prometheus Alertmanager. Evaluated by Grafana's own alert engine against Mimir |
| 5 | **Contact points are not tied to notification policies by default** | Must create notification policy AND link it to contact point. A contact point with no policy = "Unused" — alerts won't reach it |
| 6 | **PLACEHOLDER webhook causes delivery failure** | Grafana tries to deliver immediately on test — shows "Last delivery attempt failed". Expected behavior until real LB URL is set |
| 7 | **API token has 30-day expiry** | Must regenerate and update Kubernetes secret + prometheus.yml every 30 days. Consider creating a longer-lived token for production |
| 8 | **Group by controls notification batching** | `grafana_folder + alertname` → each alert rule gets its own notification. Adding `personal-email` as group_by key segments notifications differently |
| 9 | **write_relabel_configs reduce cardinality** | Remote write sends ALL metrics by default — can exceed free tier 10,000 series limit. Use relabeling to only send relevant metrics |
| 10 | **Grafana Cloud webhook is Alertmanager-compatible** | Same format as Prometheus Alertmanager webhook. Can reuse webhook receivers built for Alertmanager with Grafana Cloud |

---

## 11. Interview Q&A

**Q: Why did you replace Datadog with Grafana Cloud?**
> Datadog free trial is 14 days — it expired after Phase 21. For a portfolio project, I needed a permanent solution. Grafana Cloud free tier is permanent (no expiry) and supports Prometheus remote_write natively. The switch required only one config block added to prometheus.yml — no app code changes, no SDK replacement, no re-instrumentation.

**Q: How does Prometheus remote_write work with Grafana Cloud?**
> Prometheus scrapes metrics from apps every 15 seconds locally. With remote_write configured, it also batches those metrics and POSTs them to Grafana Cloud Mimir via HTTPS with Basic Auth (username = instance ID, password = API token). Mimir stores the time series. Grafana's alert engine then queries Mimir every 1 minute using PromQL. When a rule fires, Grafana's alertmanager routes to the configured contact point (webhook + email).

**Q: Walk me through setting up Grafana Cloud alerting end to end.**
> Five steps: (1) Create Grafana Cloud account and get remote_write URL + username; (2) Generate API token with metrics:write scope; (3) Add remote_write config to prometheus.yml and redeploy; (4) In Grafana Cloud UI — create contact point (webhook URL + email), create notification policy linking to that contact point; (5) Create alert rules in PromQL with folder/group/interval settings. When alert fires: Grafana → notification policy → contact point → POST to webhook.

**Q: What is the Grafana Cloud webhook payload format?**
> Alertmanager-compatible JSON with top-level `alerts` array. Each alert has `labels` (alertname, severity, grafana_folder), `annotations` (summary, runbook_url), `startsAt`, `fingerprint`. The `status` field is `firing` or `resolved`. Our LangGraph agent's `/agent/triage` endpoint parses `alerts[0].labels.alertname` to determine alert type, then routes through the 4-node pipeline: alert_parser → runbook_retriever → diagnoser → rca_writer.

**Q: What's the difference between a contact point and a notification policy in Grafana?**
> A contact point defines WHERE notifications go (webhook URL, email address, Slack channel, PagerDuty). A notification policy defines WHEN and HOW — it sets the routing tree (which alerts go to which contact point), grouping (batch alerts by label), and timing (group wait, repeat interval). You can have a contact point with no policy — it'll show as "Unused" and never receive alerts. The policy is what connects alert rules to delivery channels.

**Q: How would you handle the API token 30-day expiry in production?**
> Three approaches: (1) Use a service account token with no expiry instead of a user token; (2) Automate token rotation with a scheduled job that calls Grafana Cloud API to create a new token, updates the Kubernetes secret, and restarts Prometheus; (3) Use Grafana Cloud's built-in long-lived API keys (Admin → API Keys → select longer expiry or no expiry). For this portfolio project, 30 days is fine — we note it in the documentation and rotation is manual.

---

## Appendix: Grafana Cloud UI Navigation Reference

| Task | Path |
|---|---|
| View instance details | Home → Connections → Your data |
| Generate API token | Home → Connections → Add new connection → Prometheus → Send metrics |
| Create contact point | Alerts & IRM → Alerting → Notification configuration → Contact points |
| Create notification policy | Alerts & IRM → Alerting → Notification configuration → Notification policies |
| Create alert rule | Alerts & IRM → Alerting → Alert rules → + New alert rule |
| View alert history | Alerts & IRM → Alerting → History |
| Silence an alert | Alerts & IRM → Alerting → Silences |
| View metrics in explore | Home → Explore → Select datasource: grafanacloud-…-prom |
| Check active series count | Home → Connections → Your data → Active Series |

---

*Phase 23 — SRE AI Agent Observability Platform*
*GitHub: Machindra220/SRE-AI-Agent-Observability*
