# SRE AI Agent — Demo Runbook

Oct 15, 2026 · @Machindra

End-to-end cheatsheet: find LBs, verify the stack, trigger chaos, triage via agent, read the RCA.

## 1 · Find the Load-Balancer URLs

Run these two commands to get the external hostnames before anything else.

**App LB** (SRE demo API — products, orders, slow endpoint)

```bash
kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Save it:

```bash
export APP_LB=$(kubectl get svc sre-ai-agent -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "App LB: $APP_LB"
```

**Agent LB** (LangGraph triage API)

```bash
kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Save it:

```bash
export AGENT_LB=$(kubectl get svc sre-ai-agent-llm -n sre-ai-agent-llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Agent LB: $AGENT_LB"
```

**Quick sanity check** — both should return HTTP 200:

```bash
curl -s -o /dev/null -w "%{http_code}" http://$APP_LB/api/health
# expect: 200

curl -s -o /dev/null -w "%{http_code}" http://$AGENT_LB/health
# expect: 200
```

> If either LB shows `<pending>`, the ALB controller is still provisioning — wait 2–3 min and re-run.

## 2 · Pre-Flight Checks

Run these before starting the demo to confirm every component is healthy.

**Pods**

```bash
# App pods (expect: 1+ Running, RESTARTS low)
kubectl get pods -n sre-ai-agent

# Agent pods (expect: 1+ Running)
kubectl get pods -n sre-ai-agent-llm

# Monitoring (Prometheus, Grafana, Alertmanager)
kubectl get pods -n monitoring

# chaoskube (expect: 1 Running, will kill pods every 2 min)
kubectl get pods -n chaos
```

**chaoskube is active** — confirm it’s killing pods:

```bash
kubectl logs -n chaos -l app.kubernetes.io/name=chaoskube --tail=10
# look for lines like:
# Killing pod: sre-ai-agent/sre-ai-agent-<hash>
```

**Watch live pod churn** (open in a second terminal during the demo):

```bash
kubectl get pods -n sre-ai-agent -w
# You will see pods terminate and new ones come up with RESTARTS=0
# New pod = chaoskube kill (graceful termination, not a crash restart)
```

**Prometheus is scraping**

```bash
# Port-forward Prometheus UI (optional — for verification only)
kubectl port-forward svc/prometheus-kube-prometheus-stack-prometheus \
  -n monitoring 9090:9090
# then open http://localhost:9090/targets
```

**API endpoints available**

| Endpoint | Purpose |
| --- | --- |
| `GET /api/health` | Liveness probe |
| `GET /api/ready` | Readiness probe |
| `GET /api/products` | Normal load |
| `GET /api/orders` | Normal load |
| `GET /api/users` | Normal load |
| `GET /api/slow` | Triggers high latency (use this to simulate incident) |
| `GET /api/error` | Triggers 500 errors |

Full Swagger UI: `http://$APP_LB/docs`

## 3 · Execute the Full Workflow

Follow these steps in order. Each step produces a visible output you can point to.

### Step A — Trigger the incident (slow endpoint)

This generates high-latency traffic that will appear in Prometheus metrics.

```bash
# Fire 20 slow requests (each takes ~2s)
for i in {1..20}; do
  curl -s http://$APP_LB/api/slow &
done
wait
echo "Done — check Grafana for p99 latency spike"
```

Or trigger errors:

```bash
for i in {1..20}; do
  curl -s http://$APP_LB/api/error &
done
wait
```

### Step B — Observe chaos in action

chaoskube kills a pod every 2 minutes automatically. To watch it live:

```bash
# Terminal 1 — watch pods cycle
kubectl get pods -n sre-ai-agent -w

# Terminal 2 — watch chaoskube logs confirm the kill
kubectl logs -n chaos -l app.kubernetes.io/name=chaoskube -f
```

### Step C — Check the Grafana alert fired

1. Open Grafana Cloud → **Alerting → Alert rules**
2. Look for **`PodChurnRateHigh`** — state should be **Firing**
3. Alternatively, run the alert query directly in **Explore**:

```promql
count(
  (time() - kube_pod_created{namespace="sre-ai-agent"}) < 180
)
```

Expected result: value `≥ 1` (a bar chart showing pods created in last 3 min).

### Step D — Manually trigger agent triage

This is the correct flat-body format the agent expects (NOT Alertmanager nested format):

```bash
curl -s -X POST "http://${AGENT_LB}/agent/triage" \
  -H "Content-Type: application/json" \
  -d '{
    "alert_name": "HighP99Latency",
    "severity": "warning",
    "service": "sre-ai-agent",
    "message": "p99 latency = 2.3s — high latency detected under load test"
  }' | jq .
```

For a pod churn alert:

```bash
curl -s -X POST "http://${AGENT_LB}/agent/triage" \
  -H "Content-Type: application/json" \
  -d '{
    "alert_name": "PodChurnRateHigh",
    "severity": "warning",
    "service": "sre-ai-agent",
    "message": "3 pods created in last 3 minutes — chaoskube kill detected"
  }' | jq .
```

> **⚠️ Schema note:** The agent expects `alert_name`, `severity`, `service`, `message` as top-level fields. Sending Alertmanager’s nested `{alerts:[{labels:{alertname:...}}]}` format returns `422 Unprocessable Entity`.

### Step E — Read the RCA report

The triage response includes an `incident_id` like `INC-20261015-145348-A35DFF`.

```bash
# Store the incident ID from the triage response
INC_ID="INC-YYYYMMDD-HHMMSS-XXXXXX"   # replace with actual value

# HTML report (for demo — paste in browser)
echo "http://${APP_LB}/agent/rca/${INC_ID}/html"

# JSON report (raw)
curl -s "http://${AGENT_LB}/agent/rca/${INC_ID}" | jq .
```

Open the HTML URL in a browser to show the formatted RCA with incident timeline, diagnosis, and remediation steps.

## 4 · Verify Outputs at Each Step

### Triage response — what to look for

A successful `/agent/triage` call returns JSON with these fields:

```json
{
  "incident_id": "INC-20261015-145348-A35DFF",
  "status": "triaged",
  "runbook_used": "high-latency.md",
  "diagnosis": "High p99 latency caused by ...",
  "rca_url": "/agent/rca/INC-20261015-145348-A35DFF",
  "rca_html_url": "/agent/rca/INC-20261015-145348-A35DFF/html"
}
```

`runbook_used` confirms RAG retrieved the right runbook from pgvector. If it shows `null` the embedding search failed.

### Agent logs — confirm LangGraph pipeline ran

```bash
# Live logs during/after triage
kubectl logs -n sre-ai-agent-llm \
  -l app=sre-ai-agent-llm --tail=50

# Look for these lines (LangGraph nodes in order):
# [alert_parser]    parsed: PodChurnRateHigh / warning
# [runbook_retriever] found: high-latency.md (score=0.87)
# [diagnoser]       LLM call to gemini-2.0-flash
# [rca_writer]      wrote INC-20261015-...
```

### RCA HTML report in browser

```bash
# Print the URL then paste it in Chrome/Safari
echo "http://${APP_LB}/agent/rca/${INC_ID}/html"
```

The page shows: incident ID, severity, affected service, timeline, LLM diagnosis paragraph, and recommended remediation steps.

### Grafana Cloud — what to show

| What to open | Where |
| --- | --- |
| Pod churn metric live | Explore → `count((time() - kube_pod_created{namespace="sre-ai-agent"}) < 180)` |
| PodChurnRateHigh alert | Alerting → Alert rules → filter by `sre-ai-agent` |
| Latency panel | Dashboards → Kubernetes / Pods or custom SRE dashboard |
| Loki logs | Explore → Loki → `{namespace="sre-ai-agent"}` |

### pgvector — confirm RAG store is populated

```bash
# Port-forward pgvector
kubectl port-forward svc/pgvector -n sre-ai-agent 5432:5432

# In another terminal
psql -h localhost -U postgres -d sre_agent -c \
  "SELECT id, LEFT(content,80) FROM documents LIMIT 5;"
# Should return rows for: high-latency.md, pod-restart.md, etc.
```

## 5 · Pending Fixes Before a Clean Run

Two issues remain that will cause partial failures. Fix both before a full demo.

### Fix 1 — Gemini model deprecation (HIGH priority)

**Symptom:** Agent triage returns a diagnosis of `null` or logs show:

```
404 This model models/gemini-2.5-flash is no longer available
```

**Fix:**

```bash
# 1. Find the file
grep -r "gemini-2.5-flash" agent/ --include="*.py" -n

# 2. Replace with the stable GA model
sed -i 's/gemini-2.5-flash/gemini-2.0-flash/g' \
  $(grep -rl "gemini-2.5-flash" agent/ --include="*.py")

# 3. Verify
grep -r "gemini" agent/ --include="*.py" -n

# 4. Rebuild and redeploy
bash scripts/deploy-agent.sh
```

After deploy, wait for the new pod to be Running, then re-run the triage curl.

### Fix 2 — Grafana Cloud webhook → agent format mismatch (for auto-alerting)

**Symptom:** Grafana Cloud fires an alert and calls the agent webhook, but agent returns `422 Unprocessable Entity`.

**Root cause:** Grafana Cloud sends Alertmanager format:

```json
{"alerts": [{"labels": {"alertname": "PodChurnRateHigh", ...}, "status": "firing"}]}
```

The agent expects flat body: `{"alert_name": ..., "severity": ..., "service": ..., "message": ...}`

**Options:**

- **Option A (quickest):** Add an adapter endpoint `/agent/webhook` that translates Alertmanager format → flat body, then calls `/agent/triage` internally. Point Grafana contact point to `/agent/webhook`.
- **Option B:** Update the agent’s `/agent/triage` to also accept Alertmanager format with a union schema.

For now, **manually trigger triage** (Section 3, Step D) to demonstrate the full pipeline during the demo.

### Fix 3 — Apply PrometheusRule (if not yet done)

If `PodChurnRateHigh` does not appear in Grafana Alerting, apply the rule:

```bash
kubectl apply -f - <<'EOF'
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
    - alert: PodChurnRateHigh
      expr: |
        count(
          (time() - kube_pod_created{namespace="sre-ai-agent"}) < 180
        ) > 0
      for: 0m
      labels:
        severity: warning
      annotations:
        summary: "Pod churn detected in sre-ai-agent"
        description: "{{ $value }} pod(s) created in last 3 minutes"
EOF

# Verify it loaded
kubectl get prometheusrule sre-ai-agent-rules -n monitoring
```
