# Phase 20 — AI Observability: Evals + Prometheus + Grafana

> **Repo:** Machindra220/SRE-AI-Agent-Observability
> **Phase:** 20 — LLM Evals + Prometheus + Grafana AI Quality Dashboard
> **Status:** ✅ Complete
> **Purpose:** Monitor AI agent quality the same way we monitor API health

---

## Table of Contents

1. [What We Built](#1-what-we-built)
2. [Why AI Observability?](#2-why-ai-observability)
3. [Architecture](#3-architecture)
4. [What are Evals?](#4-what-are-evals)
5. [Files Built](#5-files-built)
6. [Complete Workflow](#6-complete-workflow)
7. [What Failed and Why](#7-what-failed-and-why)
8. [Final Results](#8-final-results)
9. [Grafana Dashboard](#9-grafana-dashboard)
10. [Key Learnings](#10-key-learnings)
11. [Session Startup Checklist](#11-session-startup-checklist)

---

## 1. What We Built

```mermaid
flowchart LR
    A["evals/eval_runner.py\nRun 6 test cases\nagainst agent"] -->|scores| B["evals/metrics.py\nPrometheus metrics"]
    B -->|write| C["evals/metrics.prom\nPrometheus text file"]
    C -->|HTTP GET| D["metrics server\nport 9092\ntext/plain"]
    D -->|scrape every 15s| E["Prometheus\nport 9093"]
    E -->|query| F["Grafana\nport 3000"]
    F --> G["AI Quality Dashboard\n7 panels"]
```

**What it monitors:**

| Metric | What it measures | Our result |
|---|---|---|
| Context Recall | Did RAG find the right runbook? | **100%** ✅ |
| Avg LLM Confidence | Average Gemini confidence score | 24% ⚠️ (rate limited) |
| RCA Completeness | All sections in RCA? | 67% 🟡 |
| Keyword Hit Rate | Expected keywords in RCA? | 75% 🟢 |
| Per-Alert Confidence | Per test case breakdown | tc-001: 95% ⭐ |
| Eval Pass Rate | Overall pass rate | 50% 🟡 |
| Total Eval Runs | How many times run | 1 |

---

## 2. Why AI Observability?

Traditional SRE monitors API quality. AI systems need their own quality monitoring.

```mermaid
flowchart TD
    subgraph Traditional SRE Monitoring
        A1["Error rate < 1%"]
        A2["Latency p99 < 2s"]
        A3["Availability > 99%"]
    end

    subgraph AI Observability - what we built
        B1["Context Recall > 85%\nRight runbook found?"]
        B2["Confidence > 60%\nLLM certainty?"]
        B3["RCA Completeness > 90%\nAll sections present?"]
        B4["Keyword Hit Rate > 75%\nGrounded in runbook?"]
    end

    Traditional SRE Monitoring -->|same principle| AI Observability - what we built
```

**Without AI observability:**
- You don't know if the LLM started hallucinating
- You don't know if RAG retrieval quality degraded
- You don't know if RCA reports are missing sections
- Silent quality degradation in production

**With AI observability:**
- Grafana dashboard shows quality trends
- Alert fires if context recall drops below 85%
- Catch model degradation before users notice

---

## 3. Architecture

```mermaid
flowchart TD
    subgraph Setup - run once
        S1["vector-db/init.sql\nCreate pgvector schema"]
        S2["rag/indexer.py\nIndex 4 runbooks\n19 chunks in pgvector"]
        S1 --> S2
    end

    subgraph Runtime - every alert
        R1["POST /agent/triage\nalert arrives"]
        R2["Node 1: alert_parser\nclassify alert type"]
        R3["Node 2: runbook_retriever\nRAG search pgvector"]
        R4["Node 3: diagnoser\nGemini LLM call"]
        R5["Node 4: rca_writer\nformat RCA report"]
        R6["GET /agent/rca/html\nstyled HTML report"]
        R1 --> R2 --> R3 --> R4 --> R5 --> R6
    end

    subgraph AI Observability - Phase 20
        E1["evals/eval_runner.py\n6 test cases"]
        E2["Score each result\ncontext_recall\ncompleteness\nkeyword_hit_rate"]
        E3["evals/metrics.prom\nPrometheus text format"]
        E4["metrics server :9092\nserve with text/plain"]
        E5["Prometheus :9093\nscrape every 15s"]
        E6["Grafana :3000\nAI Quality Dashboard"]
        E1 --> E2 --> E3 --> E4 --> E5 --> E6
    end
```

---

## 4. What are Evals?

**Evals = Automated quality testing for AI systems.**

Just like unit tests check if code returns the right value, evals check if the AI returns a good diagnosis.

```mermaid
flowchart LR
    subgraph Unit Tests
        U1["Input: function(2,3)"]
        U2["Expected: 5"]
        U3["Actual: 5 ✅"]
        U1 --> U2 --> U3
    end

    subgraph Evals - what we built
        E1["Input: OOMKilled alert"]
        E2["Expected: pod-restarts.md\nconfidence > 0.70\nall RCA sections"]
        E3["Actual: pod-restarts.md ✅\nconfidence: 0.95 ✅\nall sections ✅ PASS"]
        E1 --> E2 --> E3
    end
```

### Our 6 test cases

| ID | Alert | Expected Runbook | Min Confidence |
|---|---|---|---|
| tc-001 | Pod Restart (OOMKilled) | pod-restarts.md | 0.70 |
| tc-002 | High Error Rate | api-5xx.md | 0.20 |
| tc-003 | High p99 Latency | high-latency.md | 0.20 |
| tc-004 | API Availability | api-availability.md | 0.10 |
| tc-005 | Pod Restart (CrashLoop) | pod-restarts.md | 0.10 |
| tc-006 | SLO Burn Rate | api-availability.md | 0.10 |

### How scoring works

```mermaid
flowchart TD
    A["Run test case through agent"]
    B["Score 1: Context Recall\nexpected_runbook == actual_runbook?"]
    C["Score 2: RCA Completeness\nRoot Cause + Evidence + Steps present?"]
    D["Score 3: Keyword Hit Rate\nexpected_keywords in rca_report?"]
    E["Score 4: Confidence\nactual >= expected_min_confidence?"]
    F{All criteria\nmet?}
    G["✅ PASS"]
    H["❌ FAIL"]

    A --> B --> C --> D --> E --> F
    F -->|YES| G
    F -->|NO| H
```

---

## 5. Files Built

### `evals/test_cases.json`

Ground truth dataset — 6 known alerts with expected outputs.

```json
{
  "id": "tc-001",
  "alert": { "alert_name": "Pod Restart Rate High", "severity": "P2",
             "service": "sre-ai-agent", "message": "OOMKilled 5 times" },
  "expected_runbook": "pod-restarts.md",
  "expected_keywords": ["OOMKilled", "memory", "limit", "kubectl"],
  "expected_min_confidence": 0.70
}
```

### `evals/metrics.py`

Prometheus metric definitions — 8 metrics:

```python
sre_agent_eval_confidence_avg      # Gauge: avg confidence 0-1
sre_agent_eval_context_recall      # Gauge: right runbook fraction
sre_agent_eval_rca_completeness    # Gauge: sections present fraction
sre_agent_eval_keyword_hit_rate    # Gauge: keywords found fraction
sre_agent_eval_pass_rate           # Gauge: test cases passed fraction
sre_agent_eval_case_confidence     # Gauge: per-case, labelled by tc_id
sre_agent_eval_runs_total          # Counter: total eval runs
sre_agent_eval_passed_total        # Counter: total cases passed
```

### `evals/eval_runner.py`

Runs all test cases, scores them, exports to Prometheus:

```mermaid
sequenceDiagram
    participant R as eval_runner.py
    participant A as Agent API :8001
    participant S as metrics.py
    participant P as metrics.prom

    R->>R: Load 6 test cases from test_cases.json
    loop For each test case
        R->>A: POST /agent/triage
        A->>R: JSON response (confidence, runbook, rca)
        R->>R: score_context_recall()
        R->>R: score_rca_completeness()
        R->>R: score_keyword_hit_rate()
        R->>R: score_confidence()
        R->>R: sleep(6s) ← avoid Gemini rate limit
    end
    R->>S: Update all Prometheus gauges
    R->>P: write_to_textfile(metrics.prom)
    R->>R: Print human-readable report
```

### `monitoring/prometheus/prometheus.yml`

```yaml
scrape_configs:
  - job_name: "sre_agent_evals"
    static_configs:
      - targets: ["host.docker.internal:9092"]
    metrics_path: "/metrics.prom"
```

### `monitoring/grafana/sre-ai-agent-dashboard.json`

7-panel Grafana dashboard:

| Panel | Type | Query |
|---|---|---|
| Context Recall | Gauge | `sre_agent_eval_context_recall` |
| Avg LLM Confidence | Gauge | `sre_agent_eval_confidence_avg` |
| RCA Completeness | Gauge | `sre_agent_eval_rca_completeness` |
| Keyword Hit Rate | Gauge | `sre_agent_eval_keyword_hit_rate` |
| Per-Alert Confidence | Bar gauge | `sre_agent_eval_case_confidence` |
| Eval Pass Rate | Stat | `sre_agent_eval_pass_rate` |
| Total Eval Runs | Stat | `sre_agent_eval_runs_total` |

---

## 6. Complete Workflow

### Data flow: eval → Prometheus → Grafana

```mermaid
sequenceDiagram
    participant E as eval_runner.py
    participant M as metrics.prom file
    participant S as Python HTTP server :9092
    participant P as Prometheus :9093
    participant G as Grafana :3000

    E->>E: Run 6 test cases
    E->>M: write_to_textfile() — Prometheus text format
    Note over M: sre_agent_eval_context_recall 1.0\nsre_agent_eval_confidence_avg 0.24\n...

    loop Every 15 seconds
        P->>S: GET /metrics.prom
        S->>M: Read file
        M->>S: Return content
        S->>P: text/plain; version=0.0.4
        P->>P: Store time series
    end

    G->>P: PromQL query: sre_agent_eval_context_recall
    P->>G: Return value: 1.0
    G->>G: Render gauge panel: 100% GREEN
```

### How Prometheus scraping works

```mermaid
flowchart LR
    A["metrics.prom\n# HELP sre_agent_eval_context_recall ...\n# TYPE ... gauge\nsre_agent_eval_context_recall 1.0"]
    B["Python HTTP server\nport 9092\nContent-Type: text/plain"]
    C["Prometheus\nGET /metrics.prom\nevery 15 seconds"]
    D["Time series DB\nstored with timestamp"]
    E["Grafana\nPromQL query\nrender panel"]

    A --> B --> C --> D --> E
```

---

## 7. What Failed and Why

### Failure 1 — Gemini API Rate Limiting (429 error)

**What happened:**
Ran evals twice in quick succession. All test cases returned `confidence: 0.00`.

**Error:**
```
429 You exceeded your current quota
Quota: generativelanguage.googleapis.com/generate_content_free_tier_requests
Limit: 20 requests/day per model
```

**Why it failed:**
Free tier Gemini API has a daily quota of 20 requests per model.
Testing + evals consumed all 20 quickly.

**How we fixed it:**
- Added `time.sleep(6)` between eval calls
- Wait for quota reset (midnight Pacific time)
- Use different model (`gemini-3.6-flash` has separate quota from `gemini-3.5-flash`)

```mermaid
flowchart TD
    A["Run evals — 6 API calls"]
    B{Rate limit\nhit?}
    C["confidence: 0.00\nall test cases fail"]
    D["Wait for quota reset\nmidnight Pacific"]
    E["sleep(6) between calls\nstay under rate limit"]
    F["Evals run successfully"]

    A --> B
    B -->|YES| C --> D --> E --> F
    B -->|NO| F
```

**Lesson:** Always add delays between LLM API calls in automated eval runners. Free tier = 20 req/day. Plan accordingly.

---

### Failure 2 — Wrong Content-Type for Prometheus Scraping

**What happened:**
Prometheus logs showed:
```
received unsupported Content-Type "application/octet-stream"
and no fallback_scrape_protocol specified
```

**Why it failed:**
Python's built-in `http.server` serves `.prom` files as `application/octet-stream`.
Prometheus requires `text/plain; version=0.0.4` Content-Type.

**What we tried:**
1. `python3 -m http.server 9091` → `application/octet-stream` ❌
2. Added `scrape_protocols` to prometheus.yml → YAML validation error ❌
3. Custom Python HTTP server with correct Content-Type → ✅

**How we fixed it:**
```python
class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        content = METRICS_FILE.read_bytes()
        self.send_response(200)
        self.send_header(
            "Content-Type",
            "text/plain; version=0.0.4; charset=utf-8"  # ← correct header
        )
        self.end_headers()
        self.wfile.write(content)
```

**Lesson:** Prometheus is strict about Content-Type. Always serve metrics with `text/plain; version=0.0.4`.

---

### Failure 3 — Port Conflicts (9090, 9091, 3000)

**What happened:**
All three standard ports were already occupied by an existing project (Flask screener app).

```
Port 9090 → existing Prometheus (Flask/stock screener project)
Port 9091 → existing metrics server (Flask project)
Port 3000 → existing Grafana (Flask project)
```

**Why it failed:**
Running two Prometheus instances on the same port causes one to fail silently.

**How we fixed it:**
- Prometheus → port **9093** (our new container)
- Metrics server → port **9092**
- Grafana → reused existing on port 3000 (added new data source)

```mermaid
flowchart LR
    subgraph Old project ports
        O1["Prometheus :9090"]
        O2["Metrics :9091"]
        O3["Grafana :3000"]
    end

    subgraph New project ports
        N1["Prometheus :9093 ✅"]
        N2["Metrics :9092 ✅"]
        N3["Grafana :3000\nshared, new datasource ✅"]
    end
```

**Lesson:** Always check for port conflicts before starting new services. Use `ss -tlnp | grep PORT`.

---

### Failure 4 — Grafana Data Source Not Linked

**What happened:**
Dashboard imported but all panels showed "No data".

**Why it failed:**
Dashboard JSON had `"type": "prometheus"` without a specific UID.
Grafana couldn't match it to our new data source automatically.

**How we fixed it:**
Edited each panel manually → changed data source dropdown to `SRE-AI-Agent-Prometheus`.

**Better fix (for next time):**
Get the data source UID first, embed it in the JSON:
```bash
curl -s http://admin:admin@localhost:3000/api/datasources \
  | python3 -m json.tool | grep uid
```

---

### Failure 5 — Bar Chart Labels Truncated

**What happened:**
Per-Alert Confidence panel showed:
```
API Availability No Traffic (tc-00...   10%   ← truncated
```

**Why it failed:**
Prometheus label format: `sre_agent_eval_case_confidence{alert_name="API Availability No Traffic", test_case_id="tc-004"}` — Grafana uses the full label as display name, which is too long.

**How we fixed it:**
Added **Rename fields by regex** transformations in Grafana panel editor:

```
Match: .*tc-001.*  →  Replace: Pod Restart (OOMKilled)
Match: .*tc-002.*  →  Replace: High Error Rate
Match: .*tc-003.*  →  Replace: High p99 Latency
Match: .*tc-004.*  →  Replace: API Availability
Match: .*tc-005.*  →  Replace: Pod Restart (CrashLoop)
Match: .*tc-006.*  →  Replace: SLO Burn Rate
```

**Lesson:** Always use Grafana transformations to make metric labels human-readable. Raw Prometheus labels are verbose.

---

## 8. Final Results

### Eval suite output (best run — before rate limiting)

```
============================================================
EVAL RESULTS SUMMARY
============================================================
Total test cases : 6
Passed           : 3/6 (50%)
Avg confidence   : 0.24
Context recall   : 1.00  ← RAG finds right runbook 100%
RCA completeness : 0.67
Keyword hit rate : 0.75
============================================================

Per-test breakdown:
  ✅ tc-001 | Pod Restart (OOMKilled)   | conf: 0.95 | runbook: ✓ | complete: 1.00
  ✅ tc-002 | High Error Rate           | conf: 0.20 | runbook: ✓ | complete: 1.00
  ✅ tc-003 | High p99 Latency          | conf: 0.30 | runbook: ✓ | complete: 1.00
  ❌ tc-004 | API Availability          | conf: 0.00 | runbook: ✓ | complete: 0.33
  ❌ tc-005 | Pod Restart (CrashLoop)   | conf: 0.00 | runbook: ✓ | complete: 0.33
  ❌ tc-006 | SLO Burn Rate             | conf: 0.00 | runbook: ✓ | complete: 0.33
============================================================
```

tc-004, tc-005, tc-006 failed due to Gemini rate limiting — confidence 0.00 means API quota exhausted, not wrong diagnosis.

### Grafana dashboard metrics

| Panel | Value | Colour | Target |
|---|---|---|---|
| Context Recall | 100% | 🟢 Green | > 85% ✅ |
| Avg LLM Confidence | 24% | 🔴 Red | > 60% ❌ (rate limited) |
| RCA Completeness | 67% | 🟡 Yellow | > 90% ⚠️ |
| Keyword Hit Rate | 75% | 🟢 Green | > 75% ✅ |
| Pod Restart (OOMKilled) | 95% | 🟢 Green | Best result ⭐ |
| Eval Pass Rate | 50% | 🟡 Yellow | > 70% ⚠️ |
| Total Eval Runs | 1 | 🔵 Blue | — |

---

## 9. Grafana Dashboard

### Panel layout

```
┌─────────────────┬─────────────────┬─────────────────┬─────────────────┐
│  Context Recall │  Avg Confidence │ RCA Completeness│ Keyword Hit Rate│
│     100% 🟢     │     24% 🔴      │     67% 🟡      │     75% 🟢      │
│   Gauge panel   │   Gauge panel   │   Gauge panel   │   Gauge panel   │
├─────────────────────────────────┬──────────────────┬──────────────────┤
│   Per-Alert Confidence Score    │  Eval Pass Rate  │  Total Eval Runs │
│   API Availability       10%    │                  │                  │
│   High Error Rate         30%   │      50% 🟡      │        1         │
│   High p99 Latency        30%   │   Stat panel     │   Stat panel     │
│   Pod Restart (OOMKilled) 95% ⭐│                  │                  │
│   Pod Restart (CrashLoop) 30%   │                  │                  │
│   SLO Burn Rate           10%   │                  │                  │
│   Bar gauge panel               │                  │                  │
└─────────────────────────────────┴──────────────────┴──────────────────┘
```

### Colour thresholds

```mermaid
flowchart LR
    R["🔴 RED\n0 - 0.59\nBelow target\nAction required"]
    Y["🟡 YELLOW\n0.60 - 0.84\nAcceptable\nMonitor closely"]
    G["🟢 GREEN\n0.85 - 1.0\nOn target\nAll good"]

    R --> Y --> G
```

---

## 10. Key Learnings

### Technical learnings

| Learning | Details |
|---|---|
| Gemini free tier = 20 req/day | Always add `sleep(6)` between eval API calls |
| Prometheus needs `text/plain` Content-Type | Python `http.server` sends `application/octet-stream` — use custom server |
| Port conflicts are silent | Always check `ss -tlnp` before starting new services |
| Grafana data source UID needed | Get UID first, embed in dashboard JSON |
| `write_to_textfile()` format | prometheus_client writes correct Prometheus text format automatically |
| `host.docker.internal` | Docker containers use this to reach WSL host services |

### Architecture learnings

```mermaid
flowchart TD
    A["Wrong: Serve metrics\nwith python -m http.server"]
    B["Right: Custom HTTP server\nwith correct Content-Type"]

    C["Wrong: Run Prometheus\non existing port 9090"]
    D["Right: Use non-conflicting\nport 9093"]

    E["Wrong: Hard-code\nGrafana data source"]
    F["Right: Get UID first,\nembed in JSON or link manually"]

    A -->|lesson| B
    C -->|lesson| D
    E -->|lesson| F
```

### What 100% Context Recall means

The most important metric in our eval is **Context Recall = 1.00**.

This means RAG correctly retrieved the right runbook for **every single alert**, even during rate limiting. The vector similarity search is working perfectly — fastembed + pgvector is a reliable retrieval system.

The low confidence scores are a Gemini API limitation, not an agent design problem.

---

## 11. Session Startup Checklist

Every session, run in this order:

```bash
# 1. Start Rancher Desktop (Windows) — wait for green

# 2. WSL Terminal 1 — databases and agent
docker start pgvector
docker start sre-prometheus
cd ~/SRE-AI-Agent-Observability
source .venv/bin/activate
export $(cat .env | grep -v '^#' | xargs)

# 3. Check chunks (skip indexer if 19)
PGPASSWORD=sre_pass psql -h localhost -U sre_user -d sre_agent \
  -c "SELECT COUNT(*) FROM runbook_chunks;"

# 4. Start metrics server (if not already running)
nohup python3 /tmp/metrics_server.py > /tmp/metrics_server.log 2>&1 &

# 5. Start agent
uvicorn agent.main:app --host 0.0.0.0 --port 8001 --reload

# 6. WSL Terminal 2 — run evals (wait for quota if needed)
python -m evals.eval_runner

# 7. Open in browser
# Agent API docs: http://localhost:8001/docs
# Prometheus:     http://localhost:9093
# Grafana:        http://localhost:3000
```

---

*Phase 20 complete — SRE-AI-Agent-Observability*
*GitHub: Machindra220/SRE-AI-Agent-Observability*