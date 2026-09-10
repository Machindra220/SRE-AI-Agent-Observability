# Phase 19 & 20 — Complete Folder Structure & Concepts Guide

> Covers all 4 new folders: `agent/`, `rag/`, `vector-db/`, `evals/`
> Written for beginners — explains WHAT each file does, WHY it exists,
> and the CONCEPT behind it before any code is written.

---

## Big Picture — What Are We Building?

```
                        ┌─────────────────────────────────────┐
                        │     SRE AI Agent Observability       │
                        │                                      │
  Datadog Alert ───────▶│  agent/     ← AI brain (LangGraph)  │
                        │     │                                │
                        │     ▼                                │
                        │  rag/       ← finds right runbook    │
                        │     │                                │
                        │     ▼                                │
                        │  vector-db/ ← stores runbook vectors │
                        │                                      │
                        │  evals/     ← measures AI quality    │
                        └─────────────────────────────────────┘
                                        │
                                        ▼
                                   RCA Report
                              (logged to Datadog)
```

In plain English:
- An alert fires → the **agent** wakes up
- The agent asks **rag** "which runbook is relevant?"
- RAG searches the **vector-db** and returns the best runbook
- The agent feeds the runbook to Claude (LLM) → gets a diagnosis
- The agent writes a structured RCA report
- **evals** periodically scores how good the RCA reports are

---

# FOLDER 1: `agent/`

## What is LangGraph? (Core Concept)

LangGraph is a Python framework for building **AI agents that follow steps**.

Think of it like a **flowchart that runs itself**:

```
Step 1: Parse alert
    ↓
Step 2: Find runbook
    ↓
Step 3: Diagnose with LLM
    ↓
Step 4: Write RCA
    ↓
  Done
```

Each step is called a **Node**. The flowchart is called a **Graph**.
Between nodes, data is passed via a shared object called **State**.

Why LangGraph over writing plain Python functions?
→ LangGraph handles **loops, conditions, retries, and parallel steps** cleanly.
→ It makes complex agent logic readable and maintainable.
→ It's the industry standard for production agentic systems in 2025.

---

## `agent/state.py`

**What:** Defines the shared data object that flows through all nodes.

**Concept — The State Pattern:**
Imagine a paper form that travels from desk to desk in an office.
Each person (node) reads what's already filled in and adds their section.
By the end, the form is complete.

```
Empty form enters:
  alert_raw: ""
  alert_parsed: {}
  runbook_content: ""
  diagnosis: ""
  rca_report: ""
  confidence_score: 0.0

After Node 1 (alert_parser):
  alert_raw: "[P2] High Error Rate — 12% errors"
  alert_parsed: { severity: "P2", type: "high_error_rate" }
  runbook_content: ""     ← not filled yet
  ...

After Node 2 (runbook_retriever):
  alert_parsed: { severity: "P2", type: "high_error_rate" }
  runbook_content: "Step 1: Check 5xx logs..."
  diagnosis: ""           ← not filled yet
  ...

After Node 3 (diagnoser):
  runbook_content: "Step 1: Check 5xx logs..."
  diagnosis: "Bad deploy introduced unhandled exceptions"
  rca_report: ""          ← not filled yet
  ...

After Node 4 (rca_writer):
  diagnosis: "Bad deploy introduced unhandled exceptions"
  rca_report: "## RCA\n**Root Cause:** Bad deploy..."
  ← Complete!
```

**Why it exists:** LangGraph requires a typed schema. Without it,
nodes wouldn't know what fields exist or what type they are.

---

## `agent/graph.py`

**What:** Wires all nodes together into the agent's workflow.

**Concept — The Graph Pattern:**
This file is the **architect's blueprint**. It defines:
- Which nodes exist
- What order they run in
- Any conditional logic (e.g. "if confidence < 0.5, retry diagnosis")

```python
# Simplified view of what graph.py does:
graph = StateGraph(AgentState)
graph.add_node("alert_parser", parse_alert)
graph.add_node("runbook_retriever", retrieve_runbook)
graph.add_node("diagnoser", diagnose)
graph.add_node("rca_writer", write_rca)

graph.set_entry_point("alert_parser")
graph.add_edge("alert_parser", "runbook_retriever")
graph.add_edge("runbook_retriever", "diagnoser")
graph.add_conditional_edges("diagnoser", check_confidence)  ← loop or continue
graph.add_edge("diagnoser", "rca_writer")
graph.add_edge("rca_writer", END)
```

**Why it exists:** Without the graph, the 4 node files are just
isolated functions. The graph gives the agent its logic and flow.

---

## `agent/main.py`

**What:** FastAPI HTTP endpoint that triggers the agent.

**Concept — API-first Design:**
The agent needs to be triggered by something — a Datadog webhook,
a CI/CD pipeline, a human, or a scheduled job.

Making it a REST API means anything can call it:

```
POST /agent/triage
{
  "alert_name": "High Error Rate",
  "severity": "P2",
  "service": "sre-ai-agent",
  "message": "12% of requests returning 500 errors"
}

Response:
{
  "status": "success",
  "rca": "## Root Cause Analysis\n**Alert:** High Error Rate...",
  "confidence": 0.87,
  "runbook_used": "api-5xx.md"
}
```

Also includes **ddtrace instrumentation** so every agent run
appears as a trace in Datadog APM — this is AI observability.

**Why it exists:** Makes the agent production-ready and integratable
with any external system (Datadog, PagerDuty, ServiceNow).

---

## `agent/nodes/alert_parser.py`

**What:** Node 1 — Cleans and structures the raw alert.

**Concept — Data Normalisation:**
Alerts from Datadog come in messy, inconsistent formats:
```
"[P2 - HIGH] sre-ai-agent: Error rate is 12.3% (threshold: 5%)"
"ALERT: pod restart count exceeded on namespace sre-ai-agent"
"SLO burn rate critical — availability dropping below 99%"
```

This node extracts the key fields every downstream node needs:
- severity (P1/P2/P3)
- alert_type (high_error_rate / pod_restart / high_latency / availability)
- service name
- threshold value
- timestamp

**Why it exists:** Garbage in = garbage out.
A well-parsed alert = better runbook retrieval = better LLM diagnosis.
This is standard ETL (Extract-Transform-Load) applied to AI pipelines.

---

## `agent/nodes/runbook_retriever.py`

**What:** Node 2 — Finds the most relevant runbook using RAG.

**Concept — Retrieval Step of RAG:**
This node is the bridge between the agent and the RAG system.

```
Input:  Parsed alert { alert_type: "high_error_rate", service: "sre-ai-agent" }
Action: 
  1. Convert alert to embedding (vector of numbers)
  2. Search pgvector for most similar runbook embedding
  3. Return the runbook text
Output: Runbook content from docs/runbooks/api-5xx.md
```

The similarity search means even if the alert says
"5xx errors spiking" and the runbook is titled "High Error Rate",
they'll match because their *meaning* is similar.

**Why it exists:** Grounds the LLM in your actual runbooks
instead of making things up. This is the key difference between
a hallucinating chatbot and a reliable SRE agent.

---

## `agent/nodes/diagnoser.py`

**What:** Node 3 — The AI reasoning step. The brain of the agent.

**Concept — Prompt Engineering:**
This node constructs a carefully designed prompt and sends it to Claude.

A good SRE diagnosis prompt has:
1. **Role** — "You are a senior SRE..."
2. **Context** — the alert details
3. **Knowledge** — the runbook content
4. **Task** — "Diagnose the root cause"
5. **Format** — "Respond in JSON with fields: root_cause, confidence, evidence"

```
Prompt structure:
┌─────────────────────────────────────────────────┐
│ System: You are a senior SRE at a tech company. │
│         Your job is to diagnose production       │
│         incidents based on alerts and runbooks.  │
├─────────────────────────────────────────────────┤
│ User:   Alert: High Error Rate (P2)              │
│         Service: sre-ai-agent                    │
│         Details: 12% requests returning 500      │
│                                                  │
│         Relevant Runbook:                        │
│         [runbook content inserted here]          │
│                                                  │
│         Diagnose the root cause. Be specific.    │
│         Return confidence score 0-1.             │
└─────────────────────────────────────────────────┘
```

**Why it exists:** This is where AI adds value — reasoning about
ambiguous production issues that rule-based systems cannot handle.

---

## `agent/nodes/rca_writer.py`

**What:** Node 4 — Formats diagnosis into a professional RCA report.

**Concept — Structured Output:**
Raw LLM responses are free-form text. SRE teams need
consistent, structured RCA documents they can:
- Store in a wiki
- Attach to ServiceNow tickets
- Use for post-mortems
- Feed back into the eval system

This node enforces a standard RCA template:

```markdown
## Root Cause Analysis

| Field        | Value                                    |
|--------------|------------------------------------------|
| Alert        | High Error Rate (P2)                     |
| Service      | sre-ai-agent                             |
| Detected     | 2026-09-10 17:30 UTC                     |
| Duration     | ~8 minutes                               |
| Confidence   | 87%                                      |

### Root Cause
Bad deployment (commit abc123) introduced an unhandled exception
in the /api/error endpoint causing 12% of requests to return 500.

### Evidence
- Error rate spike at 17:22 UTC matches deployment at 17:20 UTC
- Runbook step 3: rollout history confirms recent deploy

### Resolution Steps
1. kubectl rollout undo deployment/sre-ai-agent -n sre-ai-agent
2. Verify error rate drops below 1% in Datadog
3. Open incident ticket in ServiceNow

### Prevention
- Add integration tests for error endpoints in CI pipeline
- Set deployment freeze during peak hours
```

**Why it exists:** Consistent format = faster human review,
easier automation, and better post-mortem quality.

---

---

# FOLDER 2: `rag/`

## What is RAG? (Core Concept)

**RAG = Retrieval-Augmented Generation**

The problem with plain LLMs:
- They only know what they were trained on
- They don't know YOUR runbooks, YOUR service names, YOUR thresholds
- They hallucinate when asked about specific systems

The RAG solution:
```
Your runbooks → embed → store in vector DB
                                    ↑
Alert comes in → embed → search ───┘ → top match returned
                                              ↓
                                    LLM gets: alert + runbook
                                              ↓
                                    LLM outputs: grounded diagnosis
```

RAG = giving the LLM an open-book exam instead of a closed-book one.

---

## `rag/embeddings.py`

**What:** Wrapper around the embedding model.

**Concept — What are Embeddings?**

An embedding model converts text into a list of numbers (a vector)
that captures the *semantic meaning* of the text:

```
"pod is crashing"        → [0.23, -0.87, 0.45, 0.12, ...]  384 numbers
"container restarting"   → [0.21, -0.85, 0.47, 0.11, ...]  very similar!
"quarterly revenue grew" → [0.91,  0.34, -0.22, 0.78, ...] very different
```

Texts with similar meaning → similar vectors → close in vector space.

We use `sentence-transformers` (a free, local model) for embeddings:
- Model: `all-MiniLM-L6-v2` (fast, good quality, runs on CPU)
- Output: 384-dimensional vector per text chunk

**Why it exists:** Every part of the RAG system (indexer + retriever)
needs to embed text. Centralising the embedding model here means
one place to change the model if needed.

---

## `rag/indexer.py`

**What:** Reads all runbooks, embeds them, stores in pgvector.

**Concept — The Indexing Pipeline:**
This is a one-time (or periodic) job that runs before the agent:

```
docs/runbooks/
├── api-5xx.md          ┐
├── api-availability.md ├── Read → chunk → embed → store in pgvector
├── high-latency.md     │
└── pod-restarts.md     ┘
```

Step by step:
1. **Read** — load each .md file from docs/runbooks/
2. **Chunk** — split into smaller pieces (e.g. 500 chars each)
   Why chunk? LLMs have context limits; smaller chunks = more precise retrieval
3. **Embed** — convert each chunk to a 384-dim vector via embeddings.py
4. **Store** — insert (chunk_text, vector, source_file) into pgvector table

```
pgvector table: runbook_chunks
┌─────┬──────────────────────────┬──────────────────────┬──────────────┐
│ id  │ content                  │ embedding            │ source       │
├─────┼──────────────────────────┼──────────────────────┼──────────────┤
│  1  │ "Check 5xx logs using..."│ [0.23, -0.87, ...]   │ api-5xx.md   │
│  2  │ "Describe pods to see..."│ [0.19, -0.91, ...]   │ api-5xx.md   │
│  3  │ "Get pod list in ns..."  │ [0.44,  0.23, ...]   │ pod-restarts │
└─────┴──────────────────────────┴──────────────────────┴──────────────┘
```

**Why it exists:** The vector DB needs to be populated before
the agent can search it. This is the "loading the library" step.

---

## `rag/retriever.py`

**What:** Searches pgvector for the most relevant runbook chunk.

**Concept — Similarity Search:**
Given a query (the alert), find the most similar stored chunk.

```
Query: "high error rate 500 errors sre-ai-agent"
    ↓
Embed query → [0.25, -0.88, 0.43, ...]
    ↓
pgvector: find top-3 chunks with closest vectors
    ↓
Returns:
  1. api-5xx.md chunk 1 (similarity: 0.94) ← best match
  2. api-5xx.md chunk 2 (similarity: 0.91)
  3. api-availability.md chunk 3 (similarity: 0.72)
    ↓
Return top-3 chunks combined as context
```

pgvector uses **cosine similarity** — measures the angle between
two vectors. Smaller angle = more similar meaning.

**Why it exists:** This is the "search the library" step.
The agent calls this every time it needs a runbook.

---

---

# FOLDER 3: `vector-db/`

## What is pgvector? (Core Concept)

**pgvector** is a PostgreSQL extension that adds vector storage
and similarity search to a regular Postgres database.

Why PostgreSQL + pgvector instead of a dedicated vector DB (Pinecone, Weaviate)?
- You already know SQL
- No extra service to manage
- Combines structured data (metadata) with vector search in one DB
- Production-proven, runs on AWS RDS

```
Regular PostgreSQL:               PostgreSQL + pgvector:
┌──────────────────────┐         ┌──────────────────────────────────────┐
│ id  │ name │ age     │         │ id │ content │ embedding              │
│ 1   │ "foo"│ 25      │    +    │ 1  │ "text"  │ [0.23, -0.87, ...]    │
│ 2   │ "bar"│ 30      │  vector │ 2  │ "more"  │ [0.44,  0.12, ...]    │
└──────────────────────┘  search └──────────────────────────────────────┘
```

---

## `vector-db/init.sql`

**What:** SQL script that sets up the pgvector schema.

**Concept — Schema Design:**
Before storing anything, we need to define the table structure.

```sql
-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Table to store runbook chunks and their embeddings
CREATE TABLE IF NOT EXISTS runbook_chunks (
    id          SERIAL PRIMARY KEY,
    source      TEXT NOT NULL,        -- which runbook file
    content     TEXT NOT NULL,        -- the chunk text
    embedding   vector(384),          -- 384-dim embedding vector
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Index for fast similarity search
-- ivfflat = Inverted File Index (good for < 1M vectors)
CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
    ON runbook_chunks
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 10);
```

The **index** is critical for performance — without it,
pgvector does a brute-force scan of every row.
With the index, it finds similar vectors in milliseconds.

**Why it exists:** Database schema must be created before
the indexer can insert data. This script is run once at setup.

---

---

# FOLDER 4: `evals/`

## What are LLM Evals? (Core Concept)

**Evals = Evaluation = measuring how good the AI output is.**

The problem: How do you know if your agent is doing a good job?
- Is the RCA accurate?
- Is the runbook retrieval finding the right document?
- Is the diagnosis hallucinating or grounded in the runbook?

You need metrics — just like you have SLOs for your API,
you need quality scores for your AI system.

```
Traditional SRE metrics:        AI Observability metrics:
- Error rate < 1%               - Answer relevance > 0.8
- p99 latency < 2s              - Faithfulness > 0.85 (no hallucination)
- Availability > 99%            - Context recall > 0.9 (right runbook found)
- SLO burn rate < 1%            - RCA quality score > 0.75
```

This is called **AI Observability** — the JD specifically asks for this.

---

## `evals/eval_runner.py`

**What:** Runs the evaluation suite against the agent.

**Concept — The Eval Loop:**
```
Test cases (alert → expected RCA) 
    ↓
Run agent on each test case
    ↓
Score each output using ragas metrics
    ↓
Log scores to Prometheus (scraped by Grafana)
    ↓
Alert if quality drops below threshold
```

We use **ragas** — an open-source LLM evaluation framework:

| Metric | What it measures | Target |
|---|---|---|
| Answer Relevance | Is the RCA relevant to the alert? | > 0.80 |
| Faithfulness | Does the RCA stick to the runbook? (no hallucination) | > 0.85 |
| Context Recall | Did retrieval find the right runbook? | > 0.90 |
| RCA Completeness | Does RCA have all required sections? | > 0.75 |

**Why it exists:** Without evals, you're flying blind.
AI quality can degrade silently — wrong model, bad prompt,
poor retrieval. Evals catch this before it affects real incidents.

---

## `evals/test_cases.json`

**What:** Ground truth dataset — known alerts with expected outputs.

**Concept — Ground Truth:**
To score the agent, you need to know what a *good* answer looks like.

```json
[
  {
    "id": "tc-001",
    "alert": {
      "alert_name": "High Error Rate",
      "severity": "P2",
      "service": "sre-ai-agent",
      "message": "12% of requests returning 500 errors"
    },
    "expected_runbook": "api-5xx.md",
    "expected_root_cause_keywords": ["deployment", "500", "rollback"],
    "expected_rca_sections": ["Root Cause", "Evidence", "Resolution", "Prevention"]
  },
  {
    "id": "tc-002",
    "alert": {
      "alert_name": "Pod Restart Rate High",
      "severity": "P2",
      "service": "sre-ai-agent",
      "message": "Pod restarted 5 times in last 10 minutes"
    },
    "expected_runbook": "pod-restarts.md",
    "expected_root_cause_keywords": ["OOMKilled", "memory", "limits"],
    "expected_rca_sections": ["Root Cause", "Evidence", "Resolution", "Prevention"]
  }
]
```

**Why it exists:** Ground truth is the foundation of any eval system.
Without known-good examples, you can't measure quality.

---

## `evals/metrics.py`

**What:** Custom Prometheus metrics for AI quality scores.

**Concept — Exporting AI Metrics:**
Just like `ddtrace` exports APM metrics to Datadog,
this file uses `prometheus_client` to export eval scores
so Grafana can visualise them and alerts can fire on quality drops.

```python
# Metrics exported to Prometheus:
sre_agent_answer_relevance    # gauge: 0.0 - 1.0
sre_agent_faithfulness        # gauge: 0.0 - 1.0
sre_agent_context_recall      # gauge: 0.0 - 1.0
sre_agent_rca_completeness    # gauge: 0.0 - 1.0
sre_agent_eval_runs_total     # counter: number of evals run
```

These appear in Grafana as a dashboard panel:
```
AI Quality Dashboard:
  Answer Relevance  ████████░░ 0.82
  Faithfulness      █████████░ 0.91
  Context Recall    █████████░ 0.89
  RCA Completeness  ███████░░░ 0.76  ← below threshold → alert fires
```

**Why it exists:** Closes the observability loop —
you can now monitor AI quality the same way you monitor API health.

---

---

# How All 4 Folders Work Together

```
SETUP (run once):
vector-db/init.sql   → creates pgvector schema
rag/indexer.py       → reads runbooks → embeds → stores in pgvector

RUNTIME (every alert):
  Datadog alert
      ↓
  agent/main.py          ← receives POST /agent/triage
      ↓
  agent/graph.py         ← starts LangGraph state machine
      ↓
  Node 1: alert_parser   ← cleans alert, extracts fields
      ↓
  Node 2: runbook_retriever ← calls rag/retriever.py
                                    ↓
                              rag/embeddings.py  ← embeds alert
                                    ↓
                              pgvector search    ← finds closest runbook
                                    ↓
                              returns runbook text
      ↓
  Node 3: diagnoser      ← sends alert + runbook to Claude LLM
      ↓
  Node 4: rca_writer     ← formats RCA report
      ↓
  RCA returned to caller + logged to Datadog via ddtrace

QUALITY LOOP (scheduled, e.g. daily):
  evals/eval_runner.py   ← runs test cases through agent
      ↓
  evals/metrics.py       ← scores results with ragas
      ↓
  Prometheus             ← scrapes quality metrics
      ↓
  Grafana dashboard      ← visualises AI quality over time
      ↓
  Datadog monitor        ← alerts if quality drops
```

---

# Complete File Reference

| Folder | File | Role | When it runs |
|---|---|---|---|
| `agent/` | `state.py` | Shared data schema | Every agent run |
| `agent/` | `graph.py` | Agent workflow blueprint | Every agent run |
| `agent/` | `main.py` | FastAPI HTTP entry point | Every alert |
| `agent/nodes/` | `alert_parser.py` | Node 1 — clean alert | Every agent run |
| `agent/nodes/` | `runbook_retriever.py` | Node 2 — RAG lookup | Every agent run |
| `agent/nodes/` | `diagnoser.py` | Node 3 — LLM reasoning | Every agent run |
| `agent/nodes/` | `rca_writer.py` | Node 4 — format RCA | Every agent run |
| `rag/` | `embeddings.py` | Embedding model wrapper | Indexing + retrieval |
| `rag/` | `indexer.py` | Runbook → vector DB | Once at setup |
| `rag/` | `retriever.py` | Search vector DB | Every agent run |
| `vector-db/` | `init.sql` | Create pgvector schema | Once at setup |
| `evals/` | `eval_runner.py` | Run eval test cases | Scheduled/daily |
| `evals/` | `test_cases.json` | Ground truth dataset | During evals |
| `evals/` | `metrics.py` | Export scores to Prometheus | During evals |

---

# Key Terms Glossary

| Term | Simple Definition |
|---|---|
| LangGraph | Framework for building AI agents as a flowchart |
| Node | One step in the agent's workflow |
| State | Shared data object passed between all nodes |
| Graph | The wiring that connects nodes in order |
| RAG | Give the LLM your own documents as context |
| Embedding | List of numbers representing the meaning of text |
| Vector | Another word for embedding — a list of numbers |
| Similarity Search | Finding vectors (texts) with closest meaning |
| pgvector | PostgreSQL extension for storing and searching vectors |
| Chunking | Splitting large documents into smaller pieces for better retrieval |
| Cosine Similarity | Math formula to measure how similar two vectors are |
| Prompt Engineering | Designing the text sent to the LLM to get better responses |
| Evals | Automated tests that measure AI output quality |
| ragas | Python library for evaluating RAG pipelines |
| Faithfulness | Eval metric: does the answer stick to the given context? |
| Answer Relevance | Eval metric: is the answer relevant to the question? |
| Context Recall | Eval metric: did retrieval find the right document? |
| AI Observability | Monitoring AI system quality like you monitor API health |
| RCA | Root Cause Analysis — structured report explaining what went wrong |
| LLM | Large Language Model — the AI that does the reasoning (Claude) |
| ddtrace | Datadog's Python library for tracing code execution |