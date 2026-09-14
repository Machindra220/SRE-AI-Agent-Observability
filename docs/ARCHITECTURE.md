# SRE AI Agent Observability Platform — Complete Architecture

> **Repos:**
> - Phase 1-18: [Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)
> - Phase 19-22: [Machindra220/SRE-AI-Agent-Observability](https://github.com/Machindra220/SRE-AI-Agent-Observability)
>
> **Domain:** sre.machindra.online
> **Stack:** LangGraph · fastembed · pgvector · Gemini · Datadog · Prometheus · Grafana · EKS · Terraform

---

## 1. Complete Project Journey — Phase 1 to 22

```mermaid
flowchart TD
    subgraph Foundation["Foundation — Phases 1 to 6"]
        P1["Phase 1\nFastAPI App\nddtrace + structlog + pytest"]
        P2["Phase 2\nAWS Infra\nTerraform EKS + VPC + ECR"]
        P3["Phase 3\nK8s Deploy\nManifests + HPA"]
        P4["Phase 4\nCI/CD\nGitHub Actions"]
        P5["Phase 5\nDatadog Agent\nHelm on EKS"]
        P6["Phase 6\nK8s Monitoring\nDatadog Explorer"]
        P1 --> P2 --> P3 --> P4 --> P5 --> P6
    end

    subgraph Observability["Observability — Phases 7 to 12"]
        P7["Phase 7\nDatadog APM\nFlame graphs"]
        P8["Phase 8\nLog-Trace\nCorrelation"]
        P9["Phase 9\nGolden Signals\nDashboard"]
        P10["Phase 10\nSLOs\n99% availability"]
        P11["Phase 11\n5 Monitors\nP1/P2/P3 alerts"]
        P12["Phase 12\nIncident Workflow\nAuto SEV-1"]
        P7 --> P8 --> P9 --> P10 --> P11 --> P12
    end

    subgraph ChaosIaC["Chaos + IaC — Phases 13 to 16"]
        P13["Phase 13\nChaos Engineering\n4 scenarios"]
        P14["Phase 14\nIncident Investigation\nRCA methodology"]
        P15["Phase 15\nDatadog as Code\nTerraform monitors/SLOs"]
        P16["Phase 16\nPlatform Summary\n16 Medium articles"]
        P13 --> P14 --> P15 --> P16
    end

    subgraph DNS["Domain — Phases 17 to 18"]
        P17["Phase 17\nCustom Domain\nmachindra.online"]
        P18["Phase 18\nDNS as Code\nTerraform Route53"]
        P17 --> P18
    end

    subgraph AI["AI Agent — Phases 19 to 22"]
        P19["Phase 19\nLangGraph SRE Agent\nRAG + Gemini + pgvector"]
        P20["Phase 20\nAI Observability\nEvals + Prometheus + Grafana"]
        P21["Phase 21\nDatadog Webhook\nEnd-to-end automation"]
        P22["Phase 22\nFull Automation\nOne-command deploy"]
        P19 --> P20 --> P21 --> P22
    end

    Foundation --> Observability --> ChaosIaC --> DNS --> AI
```

---

## 2. AWS Infrastructure Architecture

```mermaid
flowchart TD
    subgraph AWS["AWS Account — us-east-1"]
        subgraph VPC["VPC — vpc-0f54a5717508fbfcb"]
            subgraph EKS["EKS Cluster — sre-ai-agent-dev-eks-cluster (K8s 1.32)"]
                subgraph AppNode["app_nodes — t3.small (workload=app)"]
                    APP["sre-ai-agent pod\nFastAPI :8000\nddtrace instrumented"]
                    DD["datadog-agent\nmetrics + traces + logs"]
                    HPA["HPA — auto-scales\nbased on CPU"]
                end
                subgraph AgentNode["agent_nodes — t3.small (workload=ai-agent, tainted)"]
                    AGENT["sre-ai-agent-llm pod\nLangGraph agent :8001"]
                    PG["pgvector pod\nPostgreSQL 17 + vector\n14 runbook chunks"]
                end
            end
            LB1["LoadBalancer\nsre.machindra.online :80"]
            LB2["LoadBalancer\nagent ELB :80→8001"]
        end
        ECR["ECR\nsre-ai-agent-dev-ecr-api\nsre-ai-agent-llm"]
        R53["Route53\nsre.machindra.online\nCNAME → ELB"]
        SM["Secrets Manager\nsre-demo/datadog2\nsre-demo/aws-iam"]
    end

    LB1 --> APP
    LB2 --> AGENT
    AGENT --> PG
    ECR --> APP
    ECR --> AGENT
    R53 --> LB1
```

---

## 3. LangGraph Agent Pipeline

```mermaid
flowchart TD
    IN["POST /agent/triage\n{alert_name, severity, service, message}"]

    subgraph LG["LangGraph State Machine — agent/graph.py"]
        N1["Node 1: alert_parser\nDetect alert type\nBuild RAG search query"]
        N2["Node 2: runbook_retriever\nEmbed query via fastembed\nSearch pgvector cosine similarity\nReturn top-3 chunks"]
        N3["Node 3: diagnoser\nBuild structured prompt\nCall Gemini gemini-3.6-flash\nParse JSON response"]
        N4["Node 4: rca_writer\nFormat markdown RCA\nAdd confidence badge\nAdd timestamp + incident ID"]

        N1 -->|search_query| N2
        N2 -->|runbook_context| N3
        N3 --> CONF{confidence\n>= 0.60?}
        CONF -->|NO — retry max 2x| N3
        CONF -->|YES| N4
    end

    OUT["RCA Report\nJSON + HTML\nStored in incident history"]

    IN --> N1
    N4 --> OUT
```

---

## 4. RAG Pipeline

```mermaid
flowchart LR
    subgraph Setup["Setup — run once: rag/indexer.py"]
        R["docs/runbooks/\n4 markdown files\napi-5xx, api-availability\nhigh-latency, pod-restarts"]
        CH["Chunker\n800-char pieces\n14 chunks total"]
        EM["fastembed\nBAAI/bge-small-en-v1.5\n384-dim vectors\nno GPU needed"]
        PGV[("pgvector\nrunbook_chunks table\nsource + content + embedding")]
        R -->|read| CH -->|embed| EM -->|INSERT| PGV
    end

    subgraph Runtime["Runtime — every alert: rag/retriever.py"]
        A["Alert text\ne.g. 'OOMKilled 5 times'"]
        Q["embed_query()\nalert → 384-dim vector"]
        S["pgvector search\nSELECT ... ORDER BY\nembedding <=> query\nLIMIT 3"]
        T["Top-3 chunks\npod-restarts.md 0.87\npod-restarts.md 0.82\napi-5xx.md 0.71"]
        P["LLM Prompt\nalert + runbook context\n→ Gemini"]

        A --> Q -->|cosine similarity| S --> T --> P
    end
```

---

## 5. Datadog Webhook — End-to-End Flow (Phase 21)

```mermaid
sequenceDiagram
    participant App as FastAPI App<br/>sre.machindra.online
    participant DD as Datadog
    participant WH as Webhook
    participant AG as SRE AI Agent<br/>EKS :8001
    participant PG as pgvector<br/>EKS
    participant GM as Gemini API

    App->>DD: metrics + traces (ddtrace)
    DD->>DD: monitor threshold breached\n(error rate > 5%)
    DD->>WH: @webhook-sre-ai-agent-triage fires
    WH->>AG: POST /agent/triage\n{alert_name, severity, message}
    AG->>AG: Node 1 — parse alert\ndetect: high_error_rate
    AG->>PG: Node 2 — embed + search\nreturns api-5xx.md (0.68)
    PG->>AG: top-3 runbook chunks
    AG->>GM: Node 3 — LLM call\nalert + runbook context
    GM->>AG: JSON {root_cause, evidence,\nsteps, confidence: 0.95}
    AG->>AG: Node 4 — format RCA\nINC-20260914-XXXXXX
    AG->>DD: (optional) post RCA as event
```

---

## 6. AI Observability Pipeline (Phase 20)

```mermaid
flowchart LR
    subgraph Evals["evals/ — run periodically"]
        TC["test_cases.json\n6 ground truth cases"]
        ER["eval_runner.py\nPOST /agent/triage\nfor each test case"]
        SC["Score each result\ncontext_recall\nrca_completeness\nkeyword_hit_rate\nconfidence"]
        MP["metrics.prom\nPrometheus text format"]
        TC --> ER --> SC --> MP
    end

    subgraph Monitor["Monitoring stack"]
        MS["Python HTTP server\nport 9092\nContent-Type: text/plain"]
        PR["Prometheus\nport 9093\nscrape every 15s"]
        GR["Grafana\nport 3000\nAI Quality Dashboard\n7 panels"]
        MP --> MS -->|GET /metrics.prom| PR -->|PromQL| GR
    end

    subgraph Results["Dashboard results"]
        R1["Context Recall\n100% GREEN"]
        R2["Avg Confidence\n24% (rate limited)"]
        R3["RCA Completeness\n67% AMBER"]
        R4["Keyword Hit Rate\n75% GREEN"]
        R5["Pod Restart OOMKilled\n95% conf ⭐"]
        GR --> R1 & R2 & R3 & R4 & R5
    end
```

---

## 7. Automation Scripts — One Command Deploy (Phase 22)

```mermaid
flowchart TD
    START["./scripts/infra-up-complete.sh"] --> S1

    S1["Step 1-3\nTerraform EKS + VPC\nKubectl connect\nWait for nodes"]
    S2["Step 4-6\nECR login\nBuild + push app image\nBuild + push agent image"]
    S3["Step 7\nDeploy app manifests\nkubectl apply -f kubernetes/"]
    S4["Step 8\nInstall Datadog Agent\nHelm upgrade --install"]
    S5["Step 9\nDNS auto-detect ELB\nTerraform Route53 apply"]
    S6["Step 10-11\nDeploy pgvector\nDeploy agent to EKS"]
    S7["Step 12-13\nInit pgvector schema\nIndex runbooks via port-forward"]
    S8["Step 14\ndeploy-monitoring.sh\nPrometheus + Grafana Helm"]
    S9["Step 15\ndeploy-litmuschaos.sh\nLitmusChaos Helm"]
    DONE["All services running\nApp + Agent + Datadog\nPrometheus + Grafana\nLitmusChaos"]

    S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7 --> S8 --> S9 --> DONE
```

---

## 8. Complete Technology Stack

```mermaid
mindmap
  root((SRE AI Agent\nPlatform))
    Cloud
      AWS EKS K8s 1.32
      AWS VPC + ECR
      AWS Route53
      AWS Secrets Manager
      Terraform IaC
    Application
      FastAPI Python 3.12
      ddtrace APM
      structlog JSON logs
      pytest
      Docker
    Kubernetes
      2 node groups
      HPA autoscaling
      Helm charts
      ConfigMap + Secret
      LoadBalancer services
    Observability
      Datadog APM + K8s
      5 monitors + 2 SLOs
      Golden Signals dashboard
      Prometheus port 9093
      Grafana AI dashboard
    AI Agent
      LangGraph 4 nodes
      fastembed BAAI bge-small
      pgvector PostgreSQL 17
      Gemini gemini-3.6-flash
      RAG pipeline
    AI Observability
      6 eval test cases
      prometheus-client
      Grafana 7 panels
      context_recall 100%
    Chaos
      LitmusChaos Helm
      4 chaos scenarios
      restore-all.sh
    Automation
      infra-up-complete.sh
      deploy-agent.sh
      deploy-monitoring.sh
      deploy-litmuschaos.sh
    Domain
      machindra.online BigRock
      sre.machindra.online
      Route53 CNAME
```

---

## 9. Eval Results Summary

```mermaid
xychart-beta
    title "Per-Alert Confidence Score"
    x-axis ["Pod Restart (OOMKilled)", "High Error Rate", "High Latency", "API Availability", "Pod Restart (CrashLoop)", "SLO Burn Rate"]
    y-axis "Confidence" 0 --> 1
    bar [0.95, 0.30, 0.30, 0.10, 0.30, 0.10]
```

---

## 10. Key Numbers

| Metric | Value |
|---|---|
| Total phases | 22 |
| GitHub repos | 2 |
| Medium articles | 16 |
| EKS node groups | 2 (app_nodes + agent_nodes) |
| LangGraph nodes | 4 (parse → retrieve → diagnose → write) |
| Runbook chunks in pgvector | 14 |
| Eval test cases | 6 |
| Best confidence score | **95%** (Pod Restart OOMKilled) |
| Context recall | **100%** (RAG finds right runbook every time) |
| Datadog monitors | 5 |
| Datadog SLOs | 2 |
| Grafana dashboard panels | 7 |
| Automation scripts | 5 |

---

*GitHub: [Machindra220/SRE-AI-Agent-Observability](https://github.com/Machindra220/SRE-AI-Agent-Observability)*
*Domain: [sre.machindra.online](http://sre.machindra.online)*
