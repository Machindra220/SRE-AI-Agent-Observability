SRE-AI-Agent-Observability

# Complete Deployment Flow

Step-by-step build order — from EKS cluster to live chaos-to-RCA loop

4 Node Groups · t3.small EKS + Grafana Cloud LangGraph RCA Agent Phase 22 → 24

System overview

```mermaid
flowchart TB
    subgraph AWS["☁ AWS (free tier)"]
        direction TB
        EKS["EKS Cluster\nt3.small ×4"]
        subgraph Namespaces["Kubernetes Namespaces"]
            NS1["sre-ai-agent\n(FastAPI + chaoskube target)"]
            NS2["sre-ai-agent-llm\n(LangGraph agent + pgvector)"]
            NS3["monitoring\n(Prometheus + Grafana + Promtail)"]
            NS4["chaos\n(chaoskube)"]
        end
        EKS --> Namespaces
    end

    subgraph GrafanaCloud["☁ Grafana Cloud (free tier)"]
        Mimir["Mimir\n(Prometheus remote)"]
        Loki["Loki\n(log storage)"]
        Alerts["Alert Rules\n+ Notification Policy"]
        Dashboard["Chaos Dashboard"]
    end

    subgraph LangGraph["🤖 LangGraph RCA Pipeline"]
        P1["alert_parser"]
        P2["runbook_retriever\n(pgvector RAG)"]
        P3["diagnoser\n(Gemini)"]
        P4["rca_writer"]
        P1 --> P2 --> P3 --> P4
    end

    NS3 -->|"remote_write"| Mimir
    NS3 -->|"Promtail push"| Loki
    Mimir --> Alerts
    Alerts -->|"webhook POST /agent/triage"| NS2
    NS2 --> LangGraph
    Loki --> Dashboard
    Mimir --> Dashboard
    
```

Deployment phases

Phase 22-A Infrastructure Bootstrap `infra-up-complete.sh` ▶

**1. EKS Cluster**eksctl creates cluster + VPC + subnets

**2. Node Groups**app_nodes (×3 t3.small) + agent_nodes (×1, tainted)

**3. IAM Roles**OIDC provider + service account IRSA bindings

**4. aws-load-balancer-controller**Helm install — provisions ALBs for services

**5. Namespaces**sre-ai-agent, sre-ai-agent-llm, monitoring, chaos

**6. Secrets**ECR pull secret, GEMINI_API_KEY, Grafana token

✓ kubectl get nodes → 4 Ready INSTALL_DATADOG=false INSTALL_LITMUSCHAOS=false

Phase 22-B pgvector + Runbook Seeding `deploy-pgvector.sh` ▶

**1. pgvector StatefulSet**PostgreSQL + pgvector extension in sre-ai-agent-llm

**2. PVC**10Gi EBS volume for vector index + runbook data

**3. Seed runbooks**Embed SRE runbook chunks → store in pgvector

**4. Verify**SELECT COUNT(\*) from runbook_chunks → N rows

✓ pgvector ready namespace: sre-ai-agent-llm port: 5432

Phase 22-C FastAPI App Deploy `deploy-app.sh` ▶

**1. Build image**docker build → push to ECR

**2. Deployment**3 replicas of FastAPI app in sre-ai-agent

**3. Service (LoadBalancer)**AWS ELB → /health, /metrics endpoints

**4. HorizontalPodAutoscaler**min=2, max=5 replicas on CPU 70%

✓ GET /health → 200 namespace: sre-ai-agent replicas: 3

Phase 22-D LangGraph Agent Deploy `deploy-agent.sh` ▶

**1. Agent image**Build LangGraph 4-node pipeline → push ECR

**2. Deployment**1 replica on agent_nodes (toleration: workload=ai-agent)

**3. Service (LoadBalancer)**Exposes /agent/triage for Grafana webhook

**4. GEMINI_API_KEY secret**Mounted as env var for diagnoser node

✓ POST /agent/triage → RCA returned namespace: sre-ai-agent-llm node: agent_nodes

Phase 22-E Prometheus + Grafana (local) `infra-up-complete.sh` ▶

**1. kube-prometheus-stack**Helm install — Prometheus + Grafana + AlertManager

**2. ServiceMonitors**Scrape sre-ai-agent /metrics every 15s

**3. PrometheusRules**High error rate, pod restarts, p99 latency alerts

**4. local Grafana dashboard**Import sre-ai-agent-dashboard.json

✓ Prometheus scraping namespace: monitoring port-forward: 3000

Phase 23 Grafana Cloud + Alerting Webhook `configure-grafana-cloud.sh` ▶

**1. remote_write config**Prometheus → Grafana Cloud Mimir (scarletcanary2090)

**2. Alert rules (Cloud)**Pod Restart Rate High, High Error Rate, p99 Latency

**3. Contact point**Webhook → http://\<AGENT_LB>/agent/triage

**4. Notification policy**Routes sre-ai-agent alerts to webhook contact point

**5. GRAFANA_CLOUD_API_KEY**Added to .env — used by Prometheus + Promtail

✓ Metrics visible in Grafana Cloud stack: scarletcanary2090 region: ap-south-1

Phase 24-A chaoskube (pod killer) `deploy-chaoskube.sh` ▶

**1. chaos namespace**Isolated from app — chaoskube runs here

**2. RBAC**ClusterRole: list+delete pods in sre-ai-agent only

**3. Helm install chaoskube v0.29.0**interval=2m, minimumAge=30s, \~50MB RAM

**4. Verify kill logs**kubectl logs -n chaos deployment/chaoskube

✓ Pod killed every 2 min target: sre-ai-agent DRY_RUN=false

Phase 24-B Promtail → Grafana Cloud Loki `deploy-loki-promtail.sh` ▶

**1. .env credentials**LOKI_USER_ID=1800xxx + GRAFANA_CLOUD_API_KEY

**2. promtail-loki-secret**kubectl create secret in monitoring namespace

**3. Helm install Promtail DaemonSet**values.yaml + --set credentials; 1 pod per node

**4. Scrapes 4 namespaces**sre-ai-agent, sre-ai-agent-llm, chaos, monitoring

**5. Verify in Grafana Cloud**Explore → Loki → {namespace="sre-ai-agent"}

✓ Logs in Grafana Cloud Loki url: logs-prod-028.grafana.net tolerations: Exists

Phase 24-C Grafana Cloud Chaos Dashboard `grafana-chaos-dashboard.json` ▶

**1. Import JSON**Grafana Cloud → Dashboards → Import

**2. Bind datasources**DS_PROMETHEUS → grafanacloud-...-prom · DS_LOKI → ...-logs

**3. 5 dashboard rows**Chaos Status · Impact · LangGraph RCA · Events · AI Quality

**4. Update webhook URL**Alerting → Contact point → set real AGENT_LB hostname

✓ Live chaos + RCA visible refresh: 30s 8 panels

Live chaos-to-RCA loop

```mermaid
sequenceDiagram
    participant C  as chaoskube
    participant K  as Kubernetes
    participant P  as Prometheus
    participant GC as Grafana Cloud
    participant W  as Webhook /agent/triage
    participant LG as LangGraph Agent
    participant L  as Loki

    C->>K: DELETE pod (every 2 min)
    K->>K: Restart pod (Deployment controller)
    Note over K: kube_pod_container_restarts_total ++
    P->>GC: remote_write metrics (15s)
    GC->>GC: Evaluate: rate(restarts[2m]) > 0.1
    GC->>W: POST AlertManager JSON payload
    W->>LG: alert_parser node
    LG->>LG: runbook_retriever (pgvector RAG)
    LG->>LG: diagnoser (Gemini API)
    LG->>LG: rca_writer
    LG->>L: Log RCA to stdout (Promtail scrapes)
    L->>GC: Push logs to Loki
    GC->>GC: Dashboard: chaos event + RCA visible
    
```

Kubernetes namespace map

sre-ai-agent

- FastAPI app (×3)
- Service (LoadBalancer)
- ⚡ chaoskube TARGET
- HPA (2–5 replicas)

sre-ai-agent-llm

- LangGraph agent (×1)
- Service (LoadBalancer)
- pgvector StatefulSet
- PVC (10Gi EBS)

monitoring

- Prometheus
- Grafana (local)
- AlertManager
- Promtail DaemonSet (×4)

chaos

- chaoskube
- ClusterRole (RBAC)
- ServiceAccount

Build order dependency graph

```mermaid
flowchart TD
    A["1 · EKS Cluster\neksctl create"] --> B["2 · Node Groups\napp_nodes + agent_nodes"]
    B --> C["3 · ALB Controller\nHelminstall"]
    B --> D["4 · Namespaces\n4× kubectl create ns"]
    C --> E["5 · pgvector\nStatefulSet + PVC"]
    D --> E
    D --> F["6 · FastAPI App\nDeploy + Service + HPA"]
    E --> G["7 · Runbook seed\npython seed_runbooks.py"]
    G --> H["8 · LangGraph Agent\nDeploy + Service"]
    F --> I["9 · kube-prometheus-stack\nHelm install"]
    H --> I
    I --> J["10 · Grafana Cloud\nremote_write config"]
    J --> K["11 · Alert rules\n+ webhook contact point"]
    K --> L["12 · chaoskube\ndeploy-chaoskube.sh"]
    J --> M["13 · Promtail DaemonSet\ndeploy-loki-promtail.sh"]
    L --> N["14 · Chaos Dashboard\nimport JSON"]
    M --> N
    N --> O["✅ Full loop live\nchaos → alert → RCA → Loki → dashboard"]

    style A fill:#21262d,stroke:#d29922,color:#e6edf3
    style O fill:#21262d,stroke:#3fb950,color:#3fb950
    style L fill:#21262d,stroke:#f85149,color:#f85149
    style H fill:#21262d,stroke:#bc8cff,color:#bc8cff
    
```

.env file — all required keys

| Key | Example value | Used by |
| --- | --- | --- |
| AWS_REGION | ap-south-1 | eksctl, ECR, ALB |
| CLUSTER_NAME | sre-ai-agent-cluster | eksctl, kubectl context |
| ECR_REGISTRY | 123456.dkr.ecr.ap-south-1.amazonaws.com | docker build, Helm values |
| GEMINI_API_KEY | AIza… | LangGraph diagnoser node |
| GRAFANA_CLOUD_API_KEY | glc\_… | Prometheus remote_write, Promtail |
| LOKI_USER_ID | 1800xxx | deploy-loki-promtail.sh Basic Auth |
| GRAFANA_CLOUD_PROMETHEUS_URL | https://prometheus-prod-…/api/prom/push | Prometheus remote_write |
| INSTALL_DATADOG | false | infra-up-complete.sh flag |
| INSTALL_LITMUSCHAOS | false | infra-up-complete.sh flag |

Scripts at a glance

```mermaid
flowchart LR
    subgraph UP["🚀 Bring Up"]
        S1["infra-up-complete.sh\nEKS + ALB + namespaces + secrets"]
        S2["deploy-pgvector.sh\npgvector StatefulSet + seed"]
        S3["deploy-app.sh\nFastAPI Deployment + HPA"]
        S4["deploy-agent.sh\nLangGraph agent pod"]
        S5["deploy-chaoskube.sh\npod killer on chaos ns"]
        S6["deploy-loki-promtail.sh\nDaemonSet → Loki"]
    end

    subgraph DOWN["🧹 Tear Down"]
        T1["infra-down.sh\nHelm uninstall + EKS destroy"]
    end

    S1 --> S2 --> S3 --> S4 --> S5 --> S6
    
```