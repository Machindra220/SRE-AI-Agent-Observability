# SRE AI Agent — Demo Preparation Guide

Nov 3, 2026 · @Machindra

This guide prepares Machindranath Wagare to demo the SRE-AI-Agent-Observability project end-to-end for the SRE for AI Platform role.

## Page 1 — Project Overview

You built an **AI-powered SRE agent** that automatically detects Kubernetes pod failures, fetches live pod logs, retrieves relevant runbooks via RAG, diagnoses the root cause using an LLM (Gemini gemini-1.5-flash), and writes a structured RCA — all within seconds of a Grafana alert firing. This eliminates the manual triage loop that SREs do at 2 AM.

### The Problem It Solves

In production, when a pod crashes (OOMKilled, CrashLoopBackOff), an on-call SRE must: (1) check Grafana alerts, (2) SSH or kubectl into the cluster, (3) grep pod logs, (4) look up the runbook, (5) write the RCA. This project automates all five steps end-to-end.

### What Makes It SRE-for-AI Relevant

This project was purpose-built for the **SRE for AI Platform** JD. It demonstrates a real-time agentic workflow (LangGraph), RAG with a vector database (pgvector), LLM evals for AI observability, and production-grade deployment on EKS with chaos engineering.

### Tech Stack at a Glance

| Layer | Technology |
| --- | --- |
| Agentic Framework | LangGraph + LangChain |
| LLM | Gemini gemini-1.5-flash (free tier, 1500 req/day) |
| Embeddings | fastembed BAAI/bge-small-en-v1.5 (384-dim, local) |
| Vector DB | pgvector on PostgreSQL 17 (EBS-backed PVC) |
| API | FastAPI — /agent/triage + /triage endpoints |
| Cloud | AWS EKS ap-south-1, t3.small nodes |
| Observability | Grafana Cloud (Prometheus + Loki), Promtail DaameonSet |
| Chaos | chaoskube — kills pod every 2 min |
| CI/CD | GitHub Actions, ECR, Helm, Terraform |
| Evals | Custom LLM eval suite — context\_recall 100% |

### GitHub Repo

[Machindra220/SRE-AI-Agent-Observability](https://github.com/Machindra220/SRE-AI-Agent-Observability)

## Page 2 — Architecture Deep Dive

### AWS Infrastructure

- **Region**: ap-south-1 (Mumbai)
- **EKS Cluster**: 2 node groups — `app_nodes` (t3.small ×3, no taint) + `agent_nodes` (t3.small ×1, taint `workload=ai-agent:NoSchedule`)
- **Networking**: NLB via AWS Load Balancer Controller, EBS CSI driver for PVC storage (gp2 StorageClass)
- **DNS**: sre.machindra.online → Route53 → EKS NLB
- **Namespaces**: `sre-ai-agent` (FastAPI), `sre-ai-agent-llm` (LangGraph + pgvector), `monitoring` (Prometheus + Grafana), `chaos` (chaoskube)

### LangGraph 5-Node Pipeline

| # | Node | What It Does |
| --- | --- | --- |
| 1 | alert\_parser | Parses Grafana webhook JSON — extracts pod name, namespace, alert type, severity |
| 2 | log\_fetcher | Calls kubectl API in-cluster — fetches raw pod logs before pod restarts |
| 3 | runbook\_retriever | Embeds alert text with fastembed, cosine-searches pgvector for top-3 runbook chunks |
| 4 | diagnoser | Sends logs + runbook context to Gemini gemini-1.5-flash — returns root cause |
| 5 | rca\_writer | Stores structured RCA in pgvector + returns JSON response to FastAPI |

### How log\_fetcher Accesses Pod Logs

This is the most technically interesting part. The LangGraph pod runs on `agent_nodes` (tainted). It uses the **in-cluster Kubernetes API** via a `ServiceAccount` bound to a `ClusterRole` named `sre-agent-log-reader`.

```
ClusterRole rules:
  resources: ["pods"]       → verbs: get, list
  resources: ["pods/log"]   → verbs: get   (critical: pods/log is a separate resource)
```

The key lesson here: granting `pods` does NOT grant `pods/log` — they are two distinct API resources in Kubernetes RBAC.

### Observability Flow

chaoskube kills pod (every 2 min) → Grafana alert fires (PodRestartRateHigh) → webhook POST to `/agent/triage` on NLB → FastAPI on `app_nodes` triggers LangGraph → LangGraph on `agent_nodes` runs pipeline → RCA stored + returned → Promtail ships all logs to Grafana Cloud Loki → dashboard shows RCA + pod logs at incident time

## Page 3 — Pre-Demo Checklist

Run through this list at least 30 minutes before the demo. If the cluster is not running, `infra-up.sh` takes \~20 minutes.

### Infrastructure

- [ ] EKS cluster is up: `kubectl get nodes` shows 4 nodes (3 app\_nodes + 1 agent\_node)
- [ ] All pods running: `kubectl get pods -A` — no CrashLoopBackOff or Pending
- [ ] FastAPI pod running in `sre-ai-agent` namespace
- [ ] LangGraph + pgvector pods running in `sre-ai-agent-llm` namespace
- [ ] chaoskube running in `chaos` namespace
- [ ] Promtail DaemonSet running on all 4 nodes
- [ ] NLB external IP is accessible: `curl http://<NLB_URL>/agent/health` returns `{"status": "ok"}`

### Grafana Cloud

- [ ] Grafana Cloud dashboard open: scarletcanary2090 stack
- [ ] Prometheus datasource showing metrics (check: query `kube_pod_container_status_restarts_total`)
- [ ] Loki datasource showing logs (check: query `{namespace="sre-ai-agent"}`)
- [ ] Alert rules active: PodRestartRateHigh rule is in `Alerting` or `Normal` state
- [ ] Contact point webhook URL matches current NLB LoadBalancer hostname
- [ ] grafana-chaos-dashboard.json loaded — all 8 panels rendering

### Agent Readiness

- [ ] Runbook embeddings indexed in pgvector: `kubectl exec -n sre-ai-agent-llm <pgvector-pod> -- psql -U sre_user -d sre_agent -c "SELECT COUNT(*) FROM document_chunks;"` — should return 14 rows
- [ ] Test the triage endpoint manually before demo: `curl -X POST http://<NLB_URL>/agent/triage -H 'Content-Type: application/json' -d '{"alertname":"PodRestartRateHigh","pod":"test-pod","namespace":"sre-ai-agent","severity":"critical"}'`
- [ ] Gemini API key in env: `kubectl exec -n sre-ai-agent-llm <agent-pod> -- env | grep GEMINI`
- [ ] RBAC ClusterRoleBinding is present: `kubectl get clusterrolebinding sre-agent-log-reader-binding`

### Laptop / Screen

- [ ] Two browser tabs open: Grafana Cloud dashboard + RCA dashboard (http://\<NLB\_URL>)
- [ ] One terminal open with: `kubectl get pods -n sre-ai-agent -w` (watch mode)
- [ ] Slides deck open at slide 1 (cover)
- [ ] GitHub repo open in browser at README
- [ ] Screen resolution set so all windows are legible for screen share
- [ ] Notes (this doc) open on second monitor or phone

## Page 4 — Step-by-Step Demo Walkthrough

Total demo time: **12–15 minutes**. Follow these steps in order.

### Step 1 — Open with the Problem (1 min)

Share screen. Open the slides deck at the cover slide. Say: "I’m going to show you a working AI agent that acts as an SRE’s first responder — it detects pod failures, reads the logs, looks up the runbook, and writes the RCA automatically."

Advance to the Goal slide. Show the 5-node pipeline diagram slide.

### Step 2 — Show the AWS Architecture (2 min)

Switch to the AWS Architecture slide. Walk through:

1. "Grafana Cloud sends a webhook to `/agent/triage` on this NLB"
2. "FastAPI receives it on app\_nodes, triggers LangGraph"
3. "LangGraph runs on dedicated agent\_nodes — tainted so nothing else schedules there"
4. "log\_fetcher calls the Kubernetes API in-cluster using RBAC — this is how we get real pod logs"
5. "pgvector stores runbook embeddings and completed RCAs"

### Step 3 — Show Live Cluster (2 min)

Switch to terminal. Run:

```
kubectl get pods -A
kubectl get nodes
```

Point out the 4 nodes, the namespaces, and the tainted agent\_node. Show: `kubectl describe node <agent-node> | grep Taint`

### Step 4 — Trigger the Chaos (2 min)

Switch to Grafana Cloud dashboard. Show the "Pod Restart Rate" panel — it should already have spikes from chaoskube.

Show in terminal: `kubectl get pods -n sre-ai-agent -w` — watch chaoskube kill and recreate the pod live.

Explain: "chaoskube kills the pod every 2 minutes. When the restart rate crosses the threshold, Grafana fires the PodRestartRateHigh alert and POSTs to our agent."

### Step 5 — Manually Trigger the Agent (2 min)

If the alert hasn’t fired yet, trigger manually:

```
curl -X POST http://<NLB_URL>/agent/triage \
  -H 'Content-Type: application/json' \
  -d '{"alertname":"PodRestartRateHigh",
       "pod":"sre-ai-agent-<hash>",
       "namespace":"sre-ai-agent",
       "severity":"critical"}'
```

Show the JSON response in the terminal with the RCA text.

### Step 6 — Show the RCA Dashboard (2 min)

Switch to the RCA dashboard in the browser (`http://<NLB_URL>` or the frontend).

Point out:

- **Root Cause** section: LLM-generated diagnosis
- **POD LOGS AT INCIDENT TIME**: raw kubectl logs fetched before the pod restarted
- **Runbook chunks** used: which runbook sections the RAG retrieved
- **Confidence score** from the LLM eval

### Step 7 — Show LLM Evals (1 min)

Switch to Grafana — open the AI Quality Dashboard. Show the `context_recall`, `answer_relevance`, and `faithfulness` metric panels. Explain: "This is AI observability — we’re measuring the quality of the agent’s answers against ground truth, in production."

### Step 8 — Show the Code (2 min)

Switch to GitHub repo. Navigate to:

- `agent/nodes/log_fetcher.py` — show the kubectl API call and RBAC dependency
- `agent/graph.py` — show the LangGraph StateGraph with all 5 nodes
- `rag/indexer.py` — show fastembed + pgvector insertion
- `infrastructure/terraform/` — briefly show EKS module

### Step 9 — Close with JD Alignment (1 min)

Switch back to slides. Say: "This project covers every skill in the JD: LangGraph agentic workflow, RAG with vector DB, LLM evals for AI observability, EKS on AWS, Grafana + Prometheus + Loki, Kubernetes RBAC, Terraform IaC, chaos engineering, and CI/CD with GitHub Actions."

## Page 5 — Live Demo Script

Use this as a speaking guide. Speak naturally — don’t read word-for-word.

### Opening (30 sec)

"The problem I wanted to solve: when a pod crashes in production, an SRE gets paged at 2 AM, opens the cluster, grep logs, looks up the runbook, writes an RCA ticket. That whole loop takes 20–40 minutes. I built an AI agent that does it in under 10 seconds."

### On the LangGraph pipeline (1 min)

"The agent is a 5-node LangGraph pipeline. First node parses the Grafana alert webhook — it extracts pod name, namespace, severity. Second node — and this is the key one — calls the Kubernetes API in-cluster and fetches the actual pod logs before the pod restarts. Third node embeds the alert text and does a cosine search on pgvector to retrieve the most relevant runbook sections. Fourth node sends logs plus runbook context to Gemini and asks for a root cause. Fifth node writes the structured RCA back to the database and returns the response."

### On RBAC (30 sec)

"One of the most common mistakes I see is granting pods access in RBAC and assuming you get pod logs too. You don’t. `pods` and `pods/log` are two completely separate resources in the Kubernetes API. The ClusterRole needs both explicitly. I hit this exact bug during development."

### On the infrastructure (1 min)

"Everything runs on EKS in ap-south-1. I have two node groups — app\_nodes for the FastAPI and pgvector, and agent\_nodes which are tainted so only the LangGraph agent can schedule there. The taint is `workload=ai-agent:NoSchedule`. The agent pod has a matching toleration. I also have Promtail as a DaemonSet shipping logs from all 4 namespaces to Grafana Cloud Loki. The whole infra is Terraform + Helm, deployed in one script."

### On chaos engineering (30 sec)

"chaoskube runs as a lightweight pod in the chaos namespace. It kills the sre-ai-agent pod every 2 minutes. This continuously tests the pipeline — every kill triggers a Grafana alert, fires the webhook, runs the LangGraph agent, and produces an RCA. So the demo is always live — it’s not a mock."

### On AI observability / evals (30 sec)

"I have a custom LLM eval suite with 6 test cases. It measures context\_recall, answer\_relevance, and faithfulness. The scores export to a Prometheus metrics endpoint and show up on a Grafana dashboard. Context\_recall is at 100% — that means the RAG is retrieving the right runbook sections every time. This is what LLM evaluation for AI observability looks like in practice."

### On the pgvector + fastembed choice (30 sec)

"I chose fastembed over OpenAI embeddings because it runs locally with no API calls and no cost. BAAI/bge-small-en-v1.5 is a 384-dimensional model — small, fast, and good enough for runbook text. I pre-bake the model into the Docker image so the first request doesn’t stall waiting for a 130MB download."

### Closing (20 sec)

"This project covers every item in the JD — LangGraph agentic workflow, RAG with vector DB, LLM evals, EKS, Grafana, Prometheus, Loki, Kubernetes RBAC, Terraform, chaos engineering. It’s not a tutorial reproduction — I built it from scratch, hit real production bugs, and wrote up the errors and fixes on Medium."

### If asked about cost

"OpenAI gpt-4o-mini. Grafana Cloud is permanent free tier. The EKS cluster costs about $5–8 per day on t3.small — I tear it down after each test run with a single script. Total build cost was under $50."

## Page 6 — Key Technical Talking Points

These are the depth topics interviewers are likely to probe. Know them cold.

### LangGraph vs LangChain

- LangGraph is a state machine framework built on LangChain. It lets you define nodes as Python functions and edges as conditional transitions.
- Use LangGraph when you need branching logic, retry loops, or parallel branches. Use plain LangChain for linear chains.
- In this project: each node receives and returns a `GraphState` TypedDict. The graph is a DAG with `StateGraph` — `alert_parser → log_fetcher → runbook_retriever → diagnoser → rca_writer → END`.

### RAG Pipeline Details

- Runbooks are chunked at CHUNK\_SIZE=800, CHUNK\_OVERLAP=100.
- Each chunk is embedded with fastembed (BAAI/bge-small-en-v1.5, 384-dim). Model runs locally, no API calls.
- Stored in pgvector with an `ivfflat` index on the `embedding` column (vector(384)), cosine distance.
- At query time: alert text is embedded, top-3 chunks retrieved by cosine similarity. These are passed to Gemini as context.
- 14 chunks indexed across 4 runbooks: api-5xx, api-availability, high-latency, pod-restarts.

### Kubernetes RBAC for In-Cluster API Access

- The LangGraph pod uses a `ServiceAccount` (`sre-agent-sa`) in the `sre-ai-agent-llm` namespace.
- A `ClusterRole` (`sre-agent-log-reader`) grants: `pods` (get, list) AND `pods/log` (get). These are two separate resources.
- A `ClusterRoleBinding` binds the role to the ServiceAccount.
- In code: `kubernetes.client.CoreV1Api().read_namespaced_pod_log(name=pod, namespace=ns)` — this uses the in-cluster service account token at `/var/run/secrets/kubernetes.io/serviceaccount/token`.

### EKS Node Isolation Design

- `app_nodes` (t3.small ×3): FastAPI + pgvector. No taints. Standard workloads.
- `agent_nodes` (t3.small ×1): LangGraph agent. Taint: `workload=ai-agent:NoSchedule`. Only pods with matching toleration schedule here.
- Why isolate? LLM inference can spike CPU/memory. Isolation prevents the agent from starving the API service.
- t3.small has a hard limit of 11 pods due to ENI secondary IPs (`max-pods = (3 ENIs - 1) * 4 + 2 = 10` — actually varies by instance type).

### Promtail + Loki Architecture

- Promtail runs as a DaemonSet on all 4 nodes. It scrapes container logs from `/var/log/pods/`.
- Configured to watch 4 namespaces: `sre-ai-agent`, `sre-ai-agent-llm`, `chaos`, `monitoring`.
- Ships to Grafana Cloud Loki endpoint: `logs-prod-ap-south-1.grafana.net`.
- Toleration `operator: Exists` on the DaemonSet so Promtail runs even on the tainted `agent_nodes`.
- The `LOKI_USER_ID` is a numeric ID from the Grafana Cloud Loki Details page, NOT the stack name.

### LLM Evals

- 6 test cases in `evals/test_cases.json`, each with: input alert, expected\_root\_cause, expected\_runbook\_sections.
- Metrics: `context_recall` (did RAG retrieve the right chunks?), `answer_relevance` (is LLM answer on-topic?), `faithfulness` (is the answer grounded in the context?).
- Scores exported via `prometheus_client` to `metrics.prom`, served on port 9092.
- Prometheus scrapes port 9092 and stores time-series. Grafana shows trends.
- context\_recall = 100% — the RAG retrieves the correct runbook every time.

### SLI/SLO Thinking for This System

- **SLI**: triage\_latency\_p99 (time from alert webhook to RCA response), triage\_success\_rate (% of alerts that produce a valid RCA).
- **SLO**: triage\_latency\_p99 < 30s, triage\_success\_rate > 99%.
- **Error budget**: at 99%, you have 7h 18min downtime per month before burning the budget.
- Alert on 3x burn rate to catch incidents early.

## Page 7 — Anticipated Questions & Answers

### "Why LangGraph and not just LangChain?"

LangGraph lets me define the agent as an explicit state machine with named nodes and edges. This is important for production because: (1) I can add conditional branching later — e.g., skip log\_fetcher if the pod is already gone; (2) the state object is typed, so each node's inputs and outputs are explicit; (3) it’s easier to add retries or human-in-the-loop checkpoints. Plain LangChain chains are fine for linear pipelines, but the moment you need branching, LangGraph is the right choice.

### "How accurate is the RCA? What’s the eval score?"

Context\_recall is 100% on my 6-case eval suite — the RAG retrieves the correct runbook sections every time. Answer\_relevance and faithfulness are also high. However, I’m clear that 6 test cases is a small sample. The evals framework is designed to grow — add more test cases, run nightly, trend the scores over time. The important thing is the *mechanism* is in place.

### "Why not use OpenAI GPT-4?"

Two reasons: cost and rate limits. Gemini gemini-1.5-flash is free tier at 1500 requests per day, which is more than enough for this use case. The model is capable enough for structured RCA generation from a template. If I were scaling this to a large organization I’d benchmark GPT-4o-mini vs Gemini and pick based on cost-per-RCA.

### "How would you make this production-ready?"

- Replace the single-replica FastAPI pod with HPA + PDB.
- Add a dead-letter queue for failed triage requests (SQS or Kafka).
- Implement circuit-breaker on the Gemini call — if LLM fails, fall back to retrieval-only RCA.
- Add audit logging: every alert processed, which runbook chunks were retrieved, RCA text, confidence score.
- Set SLOs: triage\_latency\_p99 < 30s, triage\_success\_rate > 99%.
- Rotate API keys via AWS Secrets Manager instead of env vars in the pod.

### "What’s the biggest technical challenge you faced?"

The log\_fetcher RBAC issue. I granted the ServiceAccount the `pods` resource and assumed that covered pod logs. The agent kept returning empty logs silently. Turned out `pods/log` is a completely separate Kubernetes API resource that must be explicitly granted. Finding this required comparing the Kubernetes API server audit logs against the RBAC rules. Once I understood it, the fix was a two-line YAML change — but diagnosing it took hours.

### "How does this scale to multiple clusters or cloud providers?"

The agent currently connects to one EKS cluster via in-cluster API. To support multiple clusters: (1) use a Kubernetes federation or multi-cluster tool like Rancher or Flux; (2) parameterize the cluster endpoint and credentials in the LangGraph state; (3) the Grafana Cloud datasource is already cloud-agnostic — Prometheus remote\_write works from any cloud. The RAG runbooks are generic enough to work across environments.

### "Why not use ELK/EFK instead of Loki?"

Loki is operationally much lighter — it indexes labels only, not the full log content. For this project, I don’t need full-text log search across the cluster; I need structured label-based queries (namespace, pod, container). Loki + Grafana Cloud is free tier and requires zero infrastructure management. ELK would add Elasticsearch storage cost and operational complexity.

### "What would you add next?"

- Multi-step agentic reasoning: if the first RCA has low confidence, the agent autonomously tries a second retrieval query with different keywords.
- Human-in-the-loop: add a LangGraph checkpoint node that posts the draft RCA to Slack and waits for SRE approval before closing the alert.
- Knowledge graph over runbooks: instead of flat cosine search, build a graph of failure modes and their relationships for more precise retrieval.
- GitHub Actions CI/CD: rebuild and redeploy the agent image automatically on every push to main.

## Page 8 — JD Alignment Table

Every JD skill is covered by a specific component you built. Use this to answer "tell me about your experience with X."

| JD Skill | What You Built | Where to Show It |
| --- | --- | --- |
| LangGraph / Agentic Systems | 5-node LangGraph StateGraph pipeline | `agent/graph.py` — StateGraph definition |
| RAG | fastembed + pgvector cosine search, 4 runbooks, 14 chunks | `rag/indexer.py`, `rag/retriever.py` |
| LLM (Gemini gemini-1.5-flash) | diagnoser node calls Gemini with alert + runbook context | `agent/nodes/diagnoser.py` |
| LLM Evals / AI Observability | 6-case eval suite, Prometheus metrics, Grafana dashboard | `evals/`, Grafana AI Quality Dashboard |
| Vector Database (pgvector) | pg17 + pgvector, ivfflat index, 384-dim embeddings | `vector-db/init.sql`, pgvector pod on EKS |
| Kubernetes | EKS cluster, 2 node groups, taints/tolerations, RBAC, DaemonSet | All k8s manifests in `infrastructure/helm/` |
| Observability (Grafana + Prometheus + Loki) | Grafana Cloud, Prometheus remote\_write, Promtail → Loki, 8-panel chaos dashboard | Grafana Cloud dashboard live |
| Chaos Engineering | chaoskube — kills pod every 2 min, end-to-end chaos→RCA loop | `infrastructure/helm/chaoskube/` |
| Cloud (AWS) | EKS, ECR, NLB, EBS CSI, IAM SA, Route53, Terraform | `infrastructure/terraform/` |
| CI/CD (GitHub Actions) | Planned — repo has workflow stubs; manual deploy via Helm today | `infrastructure/helm/`, `.github/workflows/` |
| SRE Core (SLI/SLO, alerting) | 3 Grafana alert rules (PodRestartRateHigh, High Error Rate, High p99 Latency), SLI/SLO framing | Grafana alert rules |
| Python | Entire agent, RAG, evals, FastAPI in Python 3.12 | All of `agent/`, `rag/`, `evals/` |
| Incident Handling | The project IS an automated incident responder; RCA output maps directly to incident ticket fields | RCA dashboard |
| Infrastructure as Code | Full EKS + DNS + EBS CSI in Terraform, Helm for all services | `infrastructure/terraform/`, `infra-up.sh` |

### Your Strongest Differentiators

- **Built a real-time agentic workflow** — the JD says "Highly Preferred". You have a working one.
- **AI observability with LLM evals** — most SRE candidates know Prometheus/Grafana but not LLM eval metrics.
- **log\_fetcher node** — captures pod logs before the pod restarts. This is a production SRE insight, not a tutorial detail.
- **Full infrastructure lifecycle** — infra-up.sh and infra-down.sh with correct teardown order to avoid NLB orphaning CloudFormation stacks.
- **Real bugs documented** — you wrote a Medium post with 29 real errors and fixes. This shows production experience, not just green-path demos.

### One-Line Summary for the Interview

"I built an AI agent that acts as an automated SRE first responder — it runs on EKS, uses LangGraph for agentic orchestration, RAG with pgvector for runbook retrieval, Gemini for LLM reasoning, and Grafana Cloud for observability including LLM evals. It’s live, it’s chaos-tested, and the whole stack is in Terraform and Helm on GitHub."
