# SRE AI Agent: Every Real Error We Hit and How We Fixed It

Nov 3, 2026 . @Machindra

Building an AI-powered SRE agent on AWS EKS surfaced a long trail of real errors across Python, Kubernetes, AWS, and LLMs. This post documents every one: what broke, exactly why, and the precise fix. Use it as a troubleshooting reference.

**Stack:** Python 3.12 . LangGraph . fastembed . pgvector . FastAPI . AWS EKS . Grafana Cloud (Prometheus + Loki) . chaoskube

## 1. Python & Dependency Errors

### Error 1.1 — psycopg2-binary fails to install on Python 3.14

**Error message:**

```
error: metadata-generation-failed
subprocess-exited-with-error: python setup.py egg_info
```

**Why it happened:** psycopg2-binary ships pre-compiled C extension wheels. Python 3.14 was so new that no compatible wheel existed on PyPI. pip fell back to building from source, which requires `libpq-dev` headers, and even then the build fails on 3.14 due to internal API changes.

**Fix:** Always use Python 3.12 for this project.

```bash
# Check your Python version first
python3 --version

# If on 3.14, install 3.12 alongside it
sudo apt-get install python3.12 python3.12-venv

# Create the venv explicitly on 3.12
python3.12 -m venv .venv
source .venv/bin/activate

# Now psycopg2-binary installs cleanly
pip install psycopg2-binary
```

**Rule going forward:** Pin Python in your README. `python_requires='>=3.12,<3.14'` in setup.py, or a `.python-version` file if you use pyenv.

---

### Error 1.2 — fastembed downloads 130MB model on first run, no progress indicator

**Symptom:** The agent process hangs for 60-90 seconds on first startup with no output. Looks like a deadlock.

**Why it happened:** fastembed downloads the BAAI/bge-small-en-v1.5 embedding model (\~130MB) on first use and caches it in `~/.cache/fastembed`. There is no progress bar by default.

**Fix:** Pre-download the model before deploying, and add a log line so you know it is working:

```python
from fastembed import TextEmbedding
import logging

log = logging.getLogger(__name__)
log.info("Loading fastembed model (first run downloads ~130MB)...")
model = TextEmbedding("BAAI/bge-small-en-v1.5")
log.info("fastembed model ready")
```

In Docker/EKS, pre-bake the cache into the image:

```dockerfile
# In Dockerfile — run during build so download happens at build time, not runtime
RUN python -c "from fastembed import TextEmbedding; TextEmbedding('BAAI/bge-small-en-v1.5')"
```

---

### Error 1.3 — pgvector ivfflat index fails for dimensions > 2000

**Error message:**

```
ERROR: column cannot have more than 2000 dimensions for ivfflat index
```

**Why it happened:** pgvector's ivfflat index type has a hard limit of 2000 dimensions. OpenAI's `text-embedding-ada-002` produces 1536-dim vectors (fine). But if you experiment with larger models like `text-embedding-3-large` (3072-dim) or any 4096-dim model, the index creation fails.

**Fix:** Use fastembed BAAI/bge-small-en-v1.5 (384-dim) or another sub-2000 model. In init.sql:

```sql
-- This works (384 dimensions)
CREATE TABLE runbook_chunks (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(384),  -- must match model output dim
    metadata JSONB
);

CREATE INDEX ON runbook_chunks
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);  -- only valid for <= 2000 dims
```

If you need higher dimensions, use `hnsw` instead (no dimension limit):

```sql
CREATE INDEX ON runbook_chunks
  USING hnsw (embedding vector_cosine_ops);
```

## 2. LangGraph & LLM Errors

### Error 2.1 — chunk\_text infinite loop hangs the indexer

**Symptom:** `python rag/indexer.py` hangs forever. CPU at 100% on one core. No output.

**Why it happened:** The `chunk_text` function had a bug when `CHUNK_OVERLAP >= CHUNK_SIZE`. The sliding window `advance` value became zero or negative, so the loop never moved forward:

```python
# BROKEN - infinite loop when chunk_size <= chunk_overlap
def chunk_text(text, chunk_size=800, chunk_overlap=100):
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunks.append(text[start:end])
        start += chunk_size - chunk_overlap  # becomes 0 if overlap >= size
    return chunks
```

**Fix:** Add an advance guard:

```python
# FIXED - advance guard prevents infinite loop
def chunk_text(text, chunk_size=800, chunk_overlap=100):
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunks.append(text[start:end])
        advance = chunk_size - chunk_overlap
        if advance <= 0:          # guard: never get stuck
            advance = chunk_size
        start += advance
    return chunks
```

The safe production values used in this project: `CHUNK_SIZE=800`, `CHUNK_OVERLAP=100`.

---

### Error 2.2 — Gemini model name raises NotFound / 404

**Error message:**

```
google.api_core.exceptions.NotFound: 404 models/gemini-pro is not found
# or
google.api_core.exceptions.InvalidArgument: 400 model not found: gemini-2.5-flash
```

**Why it happened:** Google changes Gemini model IDs frequently. `gemini-pro`, `gemini-1.5-pro`, `gemini-2.5-flash` — names are versioned and some are deprecated or renamed without notice. What worked last month may 404 today.

**Fix:** Always look up available models before hardcoding a name:

```python
import google.generativeai as genai

genai.configure(api_key="your-key")

# List all models available to your key
for m in genai.list_models():
    if 'generateContent' in m.supported_generation_methods:
        print(m.name)  # e.g. models/gemini-1.5-flash
```

The working model for this project's free tier: `gemini-1.5-flash` (1500 req/day free). In `diagnoser.py`:

```python
model = genai.GenerativeModel('gemini-1.5-flash')
```

---

### Error 2.3 — Gemini rate limit: 429 Too Many Requests

**Error message:**

```
google.api_core.exceptions.ResourceExhausted: 429 Quota exceeded
```

**Why it happened:** The Gemini free tier allows 20 requests/day for some models (the eval suite alone used 6 per run). Running evals multiple times a day hit the ceiling.

**Fix options:**

1. Switch to `gemini-1.5-flash` which has a higher free quota (1500 req/day)
2. Add exponential backoff:

```python
import time
from google.api_core.exceptions import ResourceExhausted

def call_gemini_with_retry(model, prompt, max_retries=3):
    for attempt in range(max_retries):
        try:
            return model.generate_content(prompt)
        except ResourceExhausted as e:
            if attempt < max_retries - 1:
                wait = 2 ** attempt  # 1s, 2s, 4s
                time.sleep(wait)
            else:
                raise
```

3. Cache LLM responses during eval runs to avoid re-calling for the same prompt.

---

### Error 2.4 — LangGraph StateGraph node not receiving state fields

**Symptom:** A node receives the state but a field that a previous node wrote is `None`.

**Why it happened:** LangGraph state fields must be declared in the `TypedDict` state class. If a node writes a new key that was not in the original `TypedDict`, LangGraph silently drops it — it doesn't carry forward to the next node.

**Fix:** Declare every field a node may write in the state schema upfront:

```python
from typing import TypedDict, Optional

class SREAgentState(TypedDict):
    alert_data: dict
    pod_name: Optional[str]        # written by alert_parser
    pod_logs: Optional[str]        # written by log_fetcher
    runbook_context: Optional[str] # written by runbook_retriever
    diagnosis: Optional[str]       # written by diagnoser
    rca_id: Optional[str]          # written by rca_writer
```

Every field that any node reads or writes must appear here.

## 3. RBAC & Kubernetes Errors

### Error 3.1 — log\_fetcher returns empty logs silently (pods/log RBAC missing)

**Symptom:** `log_fetcher` node runs without error, but `pod_logs` in state is an empty string. The dashboard shows no pod logs.

**Why it happened:** Even from inside the cluster, accessing pod logs via the Kubernetes API requires explicit RBAC permission to the `pods/log` subresource. The ClusterRole only granted access to `pods` — not `pods/log`. The API server silently returns empty rather than 403 in some configurations.

The broken ClusterRole:

```yaml
rules:
- apiGroups: [""]
  resources: ["pods"]     # WRONG - this does not include pod logs
  verbs: ["get", "list"]
```

**Fix:** Add `pods/log` as a separate resource:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sre-agent-log-reader
rules:
- apiGroups: [""]
  resources: ["pods"]        # for pod metadata
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/log"]    # for actual log content - this is the one that was missing
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sre-agent-log-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sre-agent-log-reader
subjects:
- kind: ServiceAccount
  name: default
  namespace: sre-ai-agent
```

Apply with `kubectl apply -f rbac.yaml`. Verify it works:

```bash
# Test pod log access from inside cluster
kubectl auth can-i get pods/log -n sre-ai-agent --as=system:serviceaccount:sre-ai-agent:default
# Should print: yes
```

**Rule:** `pods` and `pods/log` are two distinct resources in Kubernetes RBAC. Granting one does not grant the other.

---

### Error 3.2 — t3.small node hits 11-pod limit, pods pending

**Symptom:** New pods stay in `Pending` state. `kubectl describe pod <pod>` shows:

```
Warning  FailedScheduling  0/3 nodes are available: 3 Too many pods
```

**Why it happened:** AWS t3.small supports a maximum of 11 pods per node (limited by the number of ENI secondary IPs). With 3 app\_nodes each capped at 11, the total cluster pod limit is 33. System pods (kube-dns, aws-node, kube-proxy) consume \~5-6 per node, leaving \~5-6 for workloads per node.

**Fix options:**

1. **Reduce system pod count** by disabling unused add-ons
2. **Add more nodes** to the node group
3. **Upgrade to t3.medium or larger** (allows 17 pods per node)
4. **Use prefix delegation** (VPC CNI feature that multiplies ENI capacity):

```bash
# Enable prefix delegation on the VPC CNI
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true

# After enabling, nodes need to be cycled (rolling replacement)
exsctl upgrade nodegroup --name app_nodes --cluster my-cluster
```

In this project the solution was staying on 4 nodes total (3 app + 1 agent) and being disciplined about workloads per node.

---

### Error 3.3 — MongoDB StatefulSet stuck Pending due to taint mismatch

**Symptom:** LitmusChaos MongoDB pod stays `Pending` with:

```
Warning  FailedScheduling  0/4 nodes are available: 1 node(s) had taint {workload: ai-agent} that the pod did not tolerate
```

**Why it happened:** The `agent_nodes` node group was tainted with `workload=ai-agent:NoSchedule`. LitmusChaos's MongoDB StatefulSet was scheduled to run on any available node — but with only the agent node having capacity, and that node rejecting untolerated pods, there was nowhere to place it.

**Fix:** Add the toleration to LitmusChaos's MongoDB helm values:

```yaml
# helm/litmus/values.yaml
mongodb:
  tolerations:
  - key: workload
    operator: Equal
    value: ai-agent
    effect: NoSchedule
  nodeSelector: {}
```

Then reinstall with the values file:

```bash
helm upgrade --install litmus litmuschaos/litmus \
  -n litmus \
  -f helm/litmus/values.yaml
```

---

### Error 3.4 — Promtail DaemonSet pods not scheduling on tainted nodes

**Symptom:** Promtail pods run on app\_nodes but not on agent\_node. Logs from the agent namespace not shipped to Loki.

**Why it happened:** DaemonSets schedule a pod on every node, but taint tolerations must be explicitly set. The default Promtail helm chart does not tolerate custom taints.

**Fix:** Set a broad toleration in promtail-values.yaml:

```yaml
# promtail-values.yaml
tolerations:
- operator: Exists   # tolerates ALL taints on any node
```

This is the correct approach for DaemonSets that must run everywhere (log shippers, monitoring agents). The `operator: Exists` form tolerates any taint regardless of key/value.

## 4. pgvector & Database Errors

### Error 4.1 — psycopg2-binary fails to install on Python 3.14

**Symptom:**

```
ERROR: Could not find a version that satisfies the requirement psycopg2-binary==2.9.9
ERROR: No matching distribution found for psycopg2-binary==2.9.9
```

or at runtime:

```
ImportError: /usr/local/lib/python3.14/site-packages/psycopg2/_psycopg.cpython-314...
```

**Why it happened:** `psycopg2-binary` ships pre-compiled C extensions. Wheels are published per Python version; as of mid-2025, no wheel exists for Python 3.14. Even if it installs from source, the C extension may not compile cleanly against newer CPython internals.

**Fix:** Pin your Docker base image to Python 3.12:

```dockerfile
# Dockerfile
FROM python:3.12-slim

# psycopg2-binary 2.9.9 has a wheel for 3.12 on linux/amd64
RUN pip install psycopg2-binary==2.9.9
```

Also pin in `requirements.txt`:

```
psycopg2-binary==2.9.9
```

Do not use `psycopg2` (source build) in production containers — the build requires `libpq-dev` and `gcc`, adding \~200MB to the image.

---

### Error 4.2 — pgvector connection refused when running locally

**Symptom:** `psycopg2.OperationalError: could not connect to server: Connection refused` when running the indexing script locally against the pgvector container.

**Why it happened:** Two root causes hit at different times:

1. The pgvector Docker container was not running (forgotten after a reboot)
2. The `DB_HOST` env var was set to the in-cluster service name (`postgres-service`) which only resolves inside Kubernetes — not on localhost

**Fix for local development:**

```bash
# Start the container
docker run -d \
  --name pgvector \
  -e POSTGRES_USER=sre_user \
  -e POSTGRES_PASSWORD=sre_pass \
  -e POSTGRES_DB=sre_db \
  -p 5432:5432 \
  pgvector/pgvector:pg17

# Verify it is listening
docker ps | grep pgvector
psql -h localhost -U sre_user -d sre_db -c 'SELECT 1'
```

For local runs against the in-cluster Postgres on EKS:

```bash
# Port-forward the postgres pod
kubectl port-forward svc/postgres-service 5432:5432 -n sre-ai-agent &

# Then set DB_HOST=localhost in your local .env
export DB_HOST=localhost
export DB_PORT=5432
```

---

### Error 4.3 — ivfflat index creation fails with >2000 dimensions

**Symptom:**

```
ERROR: ivfflat index does not support vectors with more than 2000 dimensions
```

**Why it happened:** The `ivfflat` index algorithm in pgvector has a hard-coded 2000-dimension limit. If you choose an embedding model that produces vectors larger than 2000 dims (e.g., `text-embedding-3-large` at 3072 dims), index creation fails entirely.

**Fix Option A — Use a model under 2000 dims (what this project does):**

We use `BAAI/bge-small-en-v1.5` via fastembed, which produces 384-dimensional vectors — well under the 2000 limit:

```python
# embedder.py
from fastembed import TextEmbedding

model = TextEmbedding(model_name="BAAI/bge-small-en-v1.5")  # 384 dims
```

```sql
-- Create ivfflat index on 384-dim column
CREATE INDEX ON runbook_chunks
USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);
```

**Fix Option B — Switch to hnsw (no dimension limit):**

```sql
CREATE INDEX ON runbook_chunks
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);
```

`hnsw` is generally faster at query time but uses more memory and takes longer to build. For this project's scale (< 10k chunks), either works; we chose ivfflat + 384-dim model.

---

### Error 4.4 — Runbook indexing produces zero vectors (silent failure)

**Symptom:** Script completes without error, but `SELECT COUNT(*) FROM runbook_chunks;` returns 0.

**Why it happened:** The runbook `.md` files were being read from the wrong path. The indexing script used a relative path `./runbooks/` which resolved correctly in local dev but failed silently inside the container (no such directory = no files = no chunks = no inserts).

**Fix:** Use an absolute path via an env var:

```python
# indexer.py
import os

RUNBOOK_DIR = os.getenv("RUNBOOK_DIR", "/app/runbooks")

def index_runbooks():
    files = list(Path(RUNBOOK_DIR).glob("*.md"))
    if not files:
        print(f"[WARN] No .md files found in {RUNBOOK_DIR}")
        return
    print(f"[INFO] Indexing {len(files)} runbooks from {RUNBOOK_DIR}")
    ...
```

And in `Dockerfile`:

```dockerfile
COPY runbooks/ /app/runbooks/
ENV RUNBOOK_DIR=/app/runbooks
```

Always add a count log after indexing so silent failures surface immediately.

## 5. Observability Stack Errors

### Error 5.1 — Prometheus port conflict (9090 already in use)

**Symptom:** Prometheus pod in `CrashLoopBackOff`. Logs show:

```
level=error ts=... caller=main.go msg="Opening storage failed" err="lock DB directory: ..."
```

or port-forward fails:

```
error: unable to forward port because pod is not running
```

**Why it happened:** Multiple Prometheus instances were deployed across namespaces (one for the app stack, one that came with LitmusChaos), and port-forward 9090 was already bound on the local machine from a previous session.

**Fix:**

```bash
# Check what is using 9090 locally
lsof -i :9090
# Kill the stale port-forward
kill <PID>

# Always use different local ports for different forwards
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9091:9090 -n monitoring &
kubectl port-forward svc/prometheus-operated 9092:9090 -n litmus &
```

For Alertmanager (which defaults to 9093), use 9094 locally if 9093 is taken:

```bash
kubectl port-forward svc/alertmanager-operated 9094:9093 -n monitoring &
```

---

### Error 5.2 — LOKI\_USER\_ID must be a number, not a stack name

**Symptom:** Promtail pods in `Error` state. Logs:

```
level=error msg="error sending batch" error="server returned HTTP status 401 Unauthorized"
```

Or Loki queries returning no data despite logs being shipped.

**Why it happened:** Grafana Cloud's Loki endpoint uses a numeric User ID (shown in the Loki data source connection details page as a 7-digit number like `1234567`). When setting up Promtail, the stack name (`scarletcanary2090`) was used instead of the numeric ID.

**Fix:** In Promtail's `promtail-values.yaml`, the `tenantId` and basic auth username must be the numeric Loki User ID:

```yaml
# promtail-values.yaml
config:
  clients:
  - url: https://logs-prod-ap-south-1.grafana.net/loki/api/v1/push
    tenant_id: "1234567"      # Numeric Loki User ID, NOT the stack name
    basic_auth:
      username: "1234567"     # Same numeric ID
      password_from_secret:
        name: loki-secret
        key: password
```

To find your numeric Loki User ID:

1. Go to Grafana Cloud → your stack → Loki
2. Click **"Details"** or **"Send Logs"**
3. The User field shows the numeric ID (e.g., `1234567`)

---

### Error 5.3 — Promtail not scraping logs from all namespaces

**Symptom:** Grafana shows logs only from some pods/namespaces; logs from `sre-ai-agent` and `chaos-testing` are missing.

**Why it happened:** Promtail's `pipelineStages` and `scrapeConfigs` were only targeting the `default` and `monitoring` namespaces. The additional namespaces (`sre-ai-agent`, `chaos-testing`, `litmus`) were not listed.

**Fix:** Update `promtail-values.yaml` to scrape all required namespaces:

```yaml
config:
  snippets:
    pipelineStages:
    - cri: {}
    scrapeConfigs: |
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
        - role: pod
          namespaces:
            names:
            - default
            - monitoring
            - sre-ai-agent
            - chaos-testing
            - litmus
        relabel_configs:
        - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
          action: keep
          regex: true
        - source_labels: [__meta_kubernetes_namespace]
          target_label: namespace
        - source_labels: [__meta_kubernetes_pod_name]
          target_label: pod
```

Then upgrade:

```bash
helm upgrade promtail grafana/promtail -n monitoring -f promtail-values.yaml
```

---

### Error 5.4 — fastembed hangs for 60–90 seconds on first run

**Symptom:** The SRE agent pod is healthy but the first request takes over a minute. Kubernetes liveness probe times out and kills the pod.

**Why it happened:** fastembed downloads the BAAI/bge-small-en-v1.5 model (\~130MB) from HuggingFace on first use. This download happens at runtime inside the container if the model is not pre-cached.

**Fix:** Pre-bake the model download into the Docker image:

```dockerfile
# Dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download fastembed model during build (not at runtime)
RUN python -c "
from fastembed import TextEmbedding
print('[BUILD] Downloading fastembed model...')
model = TextEmbedding(model_name='BAAI/bge-small-en-v1.5')
print('[BUILD] Model cached successfully')
"

COPY . .
CMD ["python", "app.py"]
```

Also add a startup log in your app so you can confirm the model loads from cache:

```python
import time
start = time.time()
model = TextEmbedding(model_name="BAAI/bge-small-en-v1.5")
print(f"[INFO] fastembed model loaded in {time.time()-start:.1f}s")
# With pre-bake: ~0.3s. Without: 60-90s.
```

And increase the Kubernetes startup probe to tolerate even a cache miss:

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 8000
  failureThreshold: 30
  periodSeconds: 5   # allows up to 150s startup
```

## 6. AWS Infrastructure Errors

### Error 6.1 — LitmusChaos MongoDB PVC stuck in WaitForFirstConsumer

**Symptom:** LitmusChaos installs but MongoDB StatefulSet pod stays `Pending`. `kubectl describe pvc` shows:

```
Waiting for a volume to be created either by the external provisioner 'ebs.csi.aws.com'
or for a volume bound manually...
WaitForFirstConsumer
```

**Why it happened:** The `gp2` StorageClass on EKS uses `volumeBindingMode: WaitForFirstConsumer`, which means the PVC won't bind until a pod is scheduled. But the EBS CSI driver was not installed, so no provisioner could fulfill the request. The pod stays Pending forever.

**Fix Step 1 — Install the EBS CSI driver add-on:**

```bash
# Check if EBS CSI is installed
kubectl get pods -n kube-system | grep ebs-csi

# Install via eksctl
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster <your-cluster-name> \
  --region ap-south-1 \
  --force

# Or via AWS console:
# EKS → Clusters → your cluster → Add-ons → Get more add-ons → Amazon EBS CSI Driver
```

**Fix Step 2 — Attach the required IAM policy to the node group role:**

```bash
# The EBS CSI driver needs this managed policy
aws iam attach-role-policy \
  --role-name <NodeGroupRoleName> \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

After installing the add-on, existing PVCs may need to be deleted and recreated, or the pod deleted so it reschedules and triggers the PVC binding.

---

### Error 6.2 — .terraform directory accidentally committed to git (twice)

**Symptom:** `git status` shows a huge diff with thousands of provider binary files. `git push` is either very slow or rejected for size limits.

**Why it happened:** `.gitignore` was not set up before `terraform init` was run. The `.terraform/` directory (containing provider plugins, \~50-200MB) was added to the repository by a blanket `git add .`.

**Fix — Remove it from git history:**

```bash
# Remove from index without deleting locally
git rm -r --cached .terraform/
git rm -r --cached .terraform.lock.hcl  # optional, usually safe to commit

# Add to .gitignore immediately
cat >> .gitignore << 'EOF'
.terraform/
*.tfstate
*.tfstate.backup
.terraform.tfvars
EOF

git add .gitignore
git commit -m "Remove .terraform from tracking, add to .gitignore"
```

If it was pushed to remote and you need to fully purge it (caution: rewrites history):

```bash
git filter-branch --force --index-filter \
  'git rm -r --cached --ignore-unmatch .terraform/' \
  --prune-empty --tag-name-filter cat -- --all
git push origin --force --all
```

For future safety, always run `terraform init` only after `.gitignore` is in place.

---

### Error 6.3 — EKS cluster migration us-east-1 → ap-south-1 breaks kubeconfig

**Symptom:** After recreating the cluster in ap-south-1, `kubectl get nodes` fails:

```
Unable to connect to the server: dial tcp: lookup <old-endpoint>.us-east-1.eks.amazonaws.com: no such host
```

**Why it happened:** The kubeconfig still pointed to the old us-east-1 endpoint. The context was not updated after cluster recreation.

**Fix:** Update kubeconfig for the new cluster:

```bash
aws eks update-kubeconfig \
  --name <cluster-name> \
  --region ap-south-1

# Verify
kubectl config current-context
kubectl get nodes
```

Also update any hard-coded region references in Terraform variables:

```hcl
# terraform/variables.tf
variable "region" {
  default = "ap-south-1"   # was us-east-1
}
```

---

### Error 6.4 — LitmusChaos chaos experiments not targeting correct pods (toleration/selector mismatch)

**Symptom:** ChaosEngine runs but `kubectl describe chaosresult` shows `Verdict: Awaited` then times out. The target pod is never found.

**Why it happened:** The `ChaosEngine` spec had `appLabel` pointing to a label that did not match the deployed pods, and the chaos runner pod could not schedule on the tainted agent node (missing toleration).

**Fix:** Match the chaos engine spec to your actual pod labels and add tolerations:

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: pod-delete-engine
  namespace: chaos-testing
spec:
  appinfo:
    appns: sre-ai-agent
    applabel: "app=sre-agent"     # must match actual pod label
    appkind: deployment
  experiments:
  - name: pod-delete
    spec:
      components:
        runner:
          tolerations:
          - key: workload
            operator: Equal
            value: ai-agent
            effect: NoSchedule
```

Verify your pod labels first:

```bash
kubectl get pods -n sre-ai-agent --show-labels
```

## 7. DNS & Networking Errors

### Error 7.1 — Two duplicate Route53 hosted zones causing NS mismatch

**Symptom:** HTTPS endpoint returns `NXDOMAIN` or certificate errors. `dig` shows the wrong nameservers:

```bash
dig NS myapp.example.com
# Returns NS records from zone Z03766052D7VJCPILHC1A
# But domain registrar delegates to Z0853158MC1FIFCWWDEB
```

**Why it happened:** Terraform created a hosted zone. Separately, a manual create in the AWS console created a second hosted zone for the same domain. Route53 happily hosts two zones with the same name — but DNS queries only hit one (whichever nameservers the registrar delegates to). The A/CNAME records were added to the wrong zone.

**How to diagnose:**

```bash
# List all zones for the domain
aws route53 list-hosted-zones-by-name \
  --dns-name myapp.example.com \
  --query 'HostedZones[*].{Id:Id,Name:Name,RecordCount:Config}'

# Check which zone the registrar points to
whois myapp.example.com | grep -i 'name server'
# Compare against the NS records in each zone:
aws route53 list-resource-record-sets \
  --hosted-zone-id Z0853158MC1FIFCWWDEB \
  --query "ResourceRecordSets[?Type=='NS']"
```

**Fix:**

1. Identify the zone the registrar's NS records match
2. Ensure all DNS records (A, CNAME, TXT for cert validation) are in THAT zone
3. Delete the duplicate zone

```bash
# Delete all records in the wrong zone first (can't delete non-empty zone)
aws route53 change-resource-record-sets \
  --hosted-zone-id <WRONG-ZONE-ID> \
  --change-batch '{"Changes": [{"Action": "DELETE", ...}]}'

# Then delete the zone
aws route53 delete-hosted-zone --id <WRONG-ZONE-ID>
```

If the zone was created by Terraform, remove it from state and let Terraform manage only one:

```bash
terraform state rm aws_route53_zone.duplicate
```

---

### Error 7.2 — WSL DNS resets to 8.8.8.8 after wsl --shutdown

**Symptom:** After `wsl --shutdown` and restart, DNS stops resolving internal or custom domains. `ping myapp.example.com` fails with `Temporary failure in name resolution`.

**Why it happened:** WSL2 auto-generates `/etc/resolv.conf` on startup, overwriting any manual changes with the Windows host's DNS (often `8.8.8.8` in corporate environments that block external DNS queries for internal domains).

**Fix:** Disable auto-generation and set a persistent nameserver:

```bash
# 1. Disable WSL auto-generating resolv.conf
sudo tee /etc/wsl.conf << 'EOF'
[network]
generateResolvConf = false
EOF

# 2. Remove the existing symlink (WSL uses a symlink to a generated file)
sudo unlink /etc/resolv.conf

# 3. Write a persistent resolv.conf
sudo tee /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# 4. Make it immutable so WSL can't overwrite it
sudo chattr +i /etc/resolv.conf
```

After `wsl --shutdown` and restart, the file persists.

To undo the immutability:

```bash
sudo chattr -i /etc/resolv.conf
```

---

### Error 7.3 — EKS pod DNS resolution failing inside cluster

**Symptom:** Pod can reach external IPs but cannot resolve Kubernetes service names:

```
nslookup postgres-service.sre-ai-agent.svc.cluster.local
;; connection timed out; no servers could be reached
```

**Why it happened:** CoreDNS pods were running but one was crash-looping due to a ConfigMap edit gone wrong. Because Kubernetes service DNS relies on CoreDNS, internal names stopped resolving.

**Fix:**

```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns

# If ConfigMap was edited incorrectly, reset to default
kubectl edit configmap coredns -n kube-system
# Ensure the 'forward . /etc/resolv.conf' line is present under 'forward'

# Restart CoreDNS pods
kubectl rollout restart deployment coredns -n kube-system

# Verify from a debug pod
kubectl run dnstest --image=busybox --rm -it --restart=Never -- \
  nslookup postgres-service.sre-ai-agent.svc.cluster.local
```

## 8. Namespace Teardown & EKS Cleanup Errors

### Error 8.1 — Namespace stuck in Terminating forever

**Symptom:** `kubectl delete namespace litmus` hangs. `kubectl get ns litmus` shows:

```
NAME     STATUS        AGE
litmus   Terminating   47m
```

`kubectl get all -n litmus` returns nothing — resources appear deleted, but the namespace won't close.

**Why it happened:** The namespace has a finalizer registered by the LitmusChaos operator or the AWS Load Balancer Controller. When those controllers were deleted before the namespace, nothing remained to process the finalizer and remove it. Kubernetes holds the namespace open indefinitely waiting for a controller that no longer exists.

**Diagnosis:**

```bash
# Check which finalizers are blocking
kubectl get ns litmus -o json | jq '.spec.finalizers'
# e.g. ["kubernetes"]

# Check for sub-resources with their own finalizers
kubectl api-resources --verbs=list --namespaced -o name | \
  xargs -I{} kubectl get {} -n litmus --ignore-not-found 2>/dev/null
```

**Fix — Force-finalize via the raw API:**

```bash
# Export the namespace spec
kubectl get ns litmus -o json > /tmp/litmus.json

# Remove finalizers from the spec
jq '.spec.finalizers = []' /tmp/litmus.json > /tmp/litmus-fix.json

# Submit via the finalize subresource (bypasses normal controller path)
kubectl replace --raw "/api/v1/namespaces/litmus/finalize" \
  -f /tmp/litmus-fix.json

# Confirm namespace is gone
kubectl get ns litmus
# Error from server (NotFound): namespaces "litmus" not found
```

---

### Error 8.2 — AWS Load Balancer Controller finalizers orphan NLBs

**Symptom:** After deleting the `aws-load-balancer-controller` Helm release, NLB LoadBalancer services remain:

```
kubectl get svc -A | grep LoadBalancer
# Still shows services with EXTERNAL-IP and finalizers
```

Services can't be deleted:

```
Error: unable to delete service: unable to remove finalizer: ...
elbv2.k8s.aws/resources, service.k8s.aws/resources
```

**Why it happened:** The AWS LB Controller writes finalizers onto Service objects it manages. When the controller is deleted first, nothing processes the finalizer removal. The services (and the NLBs in AWS) remain.

**Fix — Patch finalizers off the services:**

```bash
# List all services with LB finalizers
kubectl get svc -A -o json | \
  jq '.items[] | select(.metadata.finalizers != null) | \
  {ns: .metadata.namespace, name: .metadata.name, fin: .metadata.finalizers}'

# Patch each stuck service
kubectl patch svc <service-name> -n <namespace> \
  -p '{"metadata":{"finalizers":null}}'

# Then delete the service
kubectl delete svc <service-name> -n <namespace>
```

Also manually delete the orphaned NLBs in AWS:

```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?State.Code==`active`].{Name:LoadBalancerName,ARN:LoadBalancerArn}' \
  --output table

aws elbv2 delete-load-balancer --load-balancer-arn <ARN>
```

---

### Error 8.3 — CloudFormation DELETE\_FAILED: dependency violation

**Symptom:** `terraform destroy` completes but EKS cluster CloudFormation stacks show `DELETE_FAILED`:

```
AWS::CloudFormation::Stack eks-cluster DELETE_FAILED
"Resource handler returned message: Dependency Violation: The network interface
'eni-xxxx' has a pending attachment"
```

**Why it happened:** Two orphaned NLBs kept their ENIs attached to the VPC subnets. CloudFormation cannot delete the subnet or VPC while those ENIs exist. The NLBs were created by Kubernetes Service objects managed by the LB Controller but were not cleaned up before the cluster was deleted.

**Fix sequence:**

```bash
# 1. Find and delete the orphaned NLBs (see Error 8.2 above)
aws elbv2 describe-load-balancers --output table
aws elbv2 delete-load-balancer --load-balancer-arn <ARN>

# 2. Wait for NLBs to fully deregister (2-3 minutes)
aws elbv2 describe-load-balancers --load-balancer-arns <ARN>
# Wait until this returns empty

# 3. Find any remaining ENIs in the VPC
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=<VPC-ID>" \
  --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId,Status:Status,Desc:Description}'

# 4. Detach and delete non-ela-attach ENIs manually
# (ela-attach ENIs are AWS-managed and cannot be deleted — they release automatically)
aws ec2 detach-network-interface --attachment-id <AttachmentId>
aws ec2 delete-network-interface --network-interface-id <ENI-ID>

# 5. Retry the CloudFormation stack deletion
aws cloudformation delete-stack --stack-name <stack-name>
```

**Note on ela-attach ENIs:** ENIs with description starting `ELB ela-attach/` are managed by the EKS control plane and cannot be manually deleted. They are released automatically when the CloudFormation stack deletion proceeds. Do not attempt to force-delete them.

---

### Error 8.4 — Complete EKS teardown order (what to do and when)

Order matters. Reverse the install order:

```bash
# 1. Delete chaos experiments and engines first
kubectl delete chaosengine --all -n chaos-testing
kubectl delete chaosexperiment --all -n chaos-testing

# 2. Uninstall LitmusChaos (removes CRDs and the operator)
helm uninstall litmus -n litmus

# 3. Delete LoadBalancer services BEFORE removing LB Controller
kubectl delete svc -A -l 'service.kubernetes.io/type=LoadBalancer'
# Wait for NLBs to be deregistered by the controller (~2 min)

# 4. Uninstall AWS Load Balancer Controller
helm uninstall aws-load-balancer-controller -n kube-system

# 5. Delete all application namespaces
kubectl delete ns sre-ai-agent chaos-testing litmus monitoring

# 6. Now run terraform destroy
terraform destroy -auto-approve

# 7. If CloudFormation stacks remain stuck, check for orphaned NLBs
# and follow Error 8.3 fix above
```

---

### Error 8.5 — PVCs block namespace deletion during terraform destroy

**Symptom:** `kubectl delete ns litmus` hangs, or PVCs stay `Terminating` long after the Helm release is gone:

```
kubectl get pvc -n litmus
NAME              STATUS        VOLUME  ...
mongodb-data-0    Terminating   ...
```

The backing EBS volume stays as an unattached volume in AWS (still billing you).

**Why it happened:** PVCs backed by EBS have a finalizer `kubernetes.io/pvc-protection` that prevents deletion until the consuming pod is fully terminated. If you delete the Helm release or the namespace without first scaling down the StatefulSet, the PVC enters `Terminating` but can never finish — the controller that owns the pod termination signal (LitmusChaos operator) is already gone.

**Fix:** Scale down StatefulSets first, then delete PVCs explicitly:

```bash
# 1. Scale down MongoDB to 0 replicas
kubectl scale statefulset mongodb -n litmus --replicas=0
kubectl wait --for=delete pod/mongodb-0 -n litmus --timeout=60s

# 2. Delete PVCs explicitly BEFORE uninstalling Helm or deleting namespace
kubectl delete pvc --all -n litmus
sleep 30   # wait for EBS to detach from node

# 3. Now safe to delete namespace
kubectl delete ns litmus
```

This sequence is now codified in `infra-down.sh` — PVC deletion happens before Helm uninstall and before namespace deletion.

---

### Error 8.6 — EBS CSI add-on deletion fails / blocks terraform destroy

**Symptom:** `terraform destroy` errors out:

```
Error: error deleting EKS Add-On (my-cluster:aws-ebs-csi-driver):
Conflict: Addon is currently being updated
```

Or the add-on simply remains attached and orphaned after the cluster is gone, leaving IAM roles dangling.

**Why it happened:** The EBS CSI driver was installed via `eksctl create addon` (not Terraform), so Terraform had no record of it in state. Terraform destroys the cluster without cleaning up the add-on first, which can either conflict or leave orphaned IAM resources.

**Fix:** Delete the add-on and its IAM service account manually before `terraform destroy`:

```bash
# Delete the EBS CSI add-on
exsctl delete addon \
  --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME \
  --region ap-south-1

# Delete the associated IAM service account (created by eksctl)
exsctl delete iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster $CLUSTER_NAME \
  --region ap-south-1

# Now terraform destroy is clean
terraform destroy -auto-approve
```

This is now step 1 in `infra-down.sh`, before any namespace or Helm operations.

---

### Error 8.7 — gp2 StorageClass not default — LitmusChaos MongoDB PVC never binds

**Symptom:** After installing LitmusChaos on a fresh EKS cluster, MongoDB PVC stays in `Pending`:

```
kubectl describe pvc mongodb-data-0 -n litmus
Events:
  Normal  WaitForFirstConsumer  ...
  Warning  ProvisioningFailed    no default StorageClass found
```

**Why it happened:** EKS ships with a `gp2` StorageClass but it is **not** set as the default. LitmusChaos's MongoDB chart requests the cluster's default StorageClass (empty `storageClassName`). Without a default, no StorageClass is selected and the PVC is never provisioned.

Even after setting gp2 as default, `volumeBindingMode: WaitForFirstConsumer` means the PVC only binds once a pod is scheduled. Without the EBS CSI driver installed, the provisioner isn't present and binding never happens regardless.

**Fix:** Both conditions must be true before installing LitmusChaos:

```bash
# Step 1: Set gp2 as the default StorageClass
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verify
kubectl get sc
# NAME            PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# gp2 (default)   kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer

# Step 2: Ensure EBS CSI driver is installed (see Error 6.1)
exsctl create addon --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME --region ap-south-1 --force

# Step 3: Delete existing broken PVC and re-install LitmusChaos
kubectl delete pvc --all -n litmus
helm upgrade --install litmus litmuschaos/litmus \
  -n litmus -f helm/litmus/values.yaml
```

Both of these steps are now baked into `infra-up.sh` and run before the LitmusChaos Helm install.

---

### infra-down.sh — Final Correct Teardown Order

After hitting all of the above, the working teardown order is:

```bash
#!/bin/bash
# infra-down.sh
set -e

# 0. Variables
CLUSTER_NAME="sre-ai-cluster"
AWS_REGION="ap-south-1"

# 1. Delete chaos resources first
kubectl delete chaosengine --all -A 2>/dev/null || true
kubectl delete chaosexperiment --all -A 2>/dev/null || true

# 2. Scale down StatefulSets so PVCs can be cleanly deleted
kubectl scale statefulset --all -n litmus --replicas=0 2>/dev/null || true
kubectl wait pod --for=delete -l app.kubernetes.io/name=mongodb \
  -n litmus --timeout=60s 2>/dev/null || true

# 3. Delete PVCs explicitly BEFORE helm uninstall or namespace delete
kubectl delete pvc --all -n litmus 2>/dev/null || true
echo "Waiting 20s for EBS volumes to detach..."
sleep 20

# 4. Delete LoadBalancer services BEFORE removing LB Controller
#    (lets the controller deprovision the NLBs cleanly)
for NS in sre-ai-agent sre-ai-agent-llm monitoring; do
  kubectl delete svc -n $NS --field-selector spec.type=LoadBalancer 2>/dev/null || true
done
echo "Waiting 90s for NLBs to deregister from AWS..."
sleep 90

# 5. Uninstall Helm releases
helm uninstall litmus -n litmus 2>/dev/null || true
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
helm uninstall promtail -n monitoring 2>/dev/null || true
helm uninstall chaoskube -n chaos 2>/dev/null || true

# 6. Delete all application namespaces
kubectl delete ns litmus sre-ai-agent sre-ai-agent-llm chaos-testing monitoring 2>/dev/null || true

# 7. Delete EBS CSI add-on and IAM service account
exsctl delete addon --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true
exsctl delete iamserviceaccount --name ebs-csi-controller-sa \
  --namespace kube-system --cluster $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true

# 8. Terraform destroy
pushd infrastructure/terraform
terraform destroy -auto-approve
popd

# 9. Post-destroy sanity checks
echo ""
echo "=== POST-DESTROY CHECKS ==="
echo "Orphaned NLBs (should be empty):"
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[*].{Name:LoadBalancerName,State:State.Code}' \
  --output table
echo "Unattached EBS volumes (should be empty):"
aws ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query 'Volumes[*].{ID:VolumeId,Size:Size,AZ:AvailabilityZone}' \
  --output table
echo "CloudFormation stacks still active:"
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[*].{Name:StackName,Status:StackStatus}' \
  --output table
```

## 9. Dashboard & Frontend Errors

### Error 9.1 — Logs section silently shows nothing (duplicate DOM IDs)

**Symptom:** The dashboard loads, all pods display, metrics show — but clicking "View Logs" on any pod shows an empty modal. No error in the browser console. The logs API endpoint returns data when tested with curl.

**Why it happened:** The dashboard generated multiple pod cards, each containing a `<div id="logsBox-N">` element. When JavaScript called `document.getElementById("logsBox-1")`, the browser returned the first element with that ID in the DOM — which happened to be on a card that was scrolled off-screen and not the one the user clicked. The logs were being injected into the wrong (hidden) element.

Duplicate IDs violate the HTML spec: `getElementById` is only guaranteed to work correctly when IDs are unique per document.

**Fix:** Use unique IDs that include both index and context, and scope modal elements differently:

```javascript
// Before (broken): duplicate IDs when multiple pods rendered
function renderPodCard(pod, index) {
  return `
    <div class="pod-card">
      <div id="logsBox-${index}">...</div>  <!-- WRONG: reused per row -->
      <button onclick="showLogs(${index})">View Logs</button>
    </div>
  `;
}

// After (fixed): separate IDs for inline box vs modal
function renderPodCard(pod, index) {
  return `
    <div class="pod-card">
      <div id="inlineLogsBox-${index}">...</div>   <!-- unique -->
      <button onclick="showLogsModal(${index})">View Logs</button>
    </div>
  `;
}

// Modal uses its own ID, separate from pod cards
function showLogsModal(index) {
  const modal = document.getElementById('modalLogsBox');  // single modal
  const content = document.getElementById(`inlineLogsBox-${index}`);
  modal.innerHTML = content ? content.innerHTML : 'Loading...';
  modal.style.display = 'block';
}
```

**Key rule:** In any dynamically rendered list, every element that JavaScript accesses by ID must have a globally unique ID. The safest pattern: use `data-*` attributes and `querySelector` with context, rather than `getElementById` in loops:

```javascript
// Even safer: no IDs in the list at all
document.querySelectorAll('[data-pod-index="3"] .logs-box')
```

---

### Error 9.2 — Dashboard showing stale data after agent completes RCA

**Symptom:** The dashboard shows an old RCA result even after the agent has written a new one. Refreshing the page clears the issue.

**Why it happened:** The dashboard cached the `/api/rca` response in a JavaScript variable on page load and did not re-fetch when a new analysis arrived. The EventSource (SSE) stream updated the status indicator but not the RCA text panel.

**Fix:** Fetch RCA data on every SSE event rather than caching it:

```javascript
// Connect to SSE for live updates
const evtSource = new EventSource('/api/stream');

evtSource.onmessage = function(e) {
  const data = JSON.parse(e.data);
  updateStatus(data.status);
  
  // Re-fetch RCA on every new event, not just once
  if (data.status === 'complete' || data.rca_updated) {
    fetch('/api/rca')
      .then(r => r.json())
      .then(rca => {
        document.getElementById('rcaPanel').textContent = rca.summary;
      });
  }
};
```

## 10. Quick-Reference Error Index

Every error in one table. Find the symptom, jump to the section for the full fix.

| # | Error / Symptom | Root Cause | Quick Fix | Section |
| --- | --- | --- | --- | --- |
| 1.1 | `psycopg2-binary` install fails | No wheel for Python 3.14 | Use `python:3.12-slim` base image | §1 |
| 1.2 | Pod liveness probe kills agent on first request | fastembed downloads \~130MB at runtime | Pre-bake model in Dockerfile | §1 / §5 |
| 1.3 | `ivfflat index does not support vectors with >2000 dims` | Wrong embedding model dimension | Use 384-dim model (bge-small) or switch to hnsw index | §1 |
| 2.1 | `chunk_text` function hangs / infinite loop | `chunk_overlap >= chunk_size` makes advance=0 | Guard: `if advance <= 0: advance = chunk_size` | §2 |
| 2.2 | Gemini API 404 on model name | Model names change frequently | Run `genai.list_models()` to find current names | §2 |
| 2.3 | Gemini 429 rate limit | Free tier quota exhausted | Switch to `gemini-1.5-flash`, add exponential backoff | §2 |
| 2.4 | LangGraph node receives `None` for state field | Field not declared in TypedDict | Declare ALL fields in state schema upfront | §2 |
| 3.1 | `kubectl logs` returns empty silently | `pods/log` not in ClusterRole RBAC | Add `pods/log` as separate RBAC resource | §3 |
| 3.2 | Pods stuck Pending: `Too many pods` | t3.small limit of 11 pods/node | Use prefix delegation or larger instance type | §3 |
| 3.3 | MongoDB StatefulSet Pending: taint not tolerated | agent\_node taint has no matching toleration | Add toleration to LitmusChaos helm values | §3 |
| 3.4 | Promtail not running on tainted node | DaemonSet missing toleration | Set `operator: Exists` toleration in promtail-values.yaml | §3 |
| 4.1 | `psycopg2-binary` Python 3.14 incompatibility | No pre-built wheel for 3.14 | Pin `FROM python:3.12-slim` in Dockerfile | §4 |
| 4.2 | `Connection refused` to pgvector | Container not running, or wrong `DB_HOST` in-cluster name | Start container; use `kubectl port-forward` for local dev | §4 |
| 4.3 | `ivfflat` fails on >2000 dims | pgvector hard limit on ivfflat | Use 384-dim model or hnsw index | §4 |
| 4.4 | Runbook indexing inserts zero rows silently | Wrong relative path inside container | Use absolute path via env var; log file count | §4 |
| 5.1 | Prometheus port 9090 already in use | Multiple Prometheus instances + stale port-forward | Use different local ports per forward | §5 |
| 5.2 | Promtail 401 Unauthorized to Loki | Used stack name instead of numeric Loki User ID | Use numeric ID (7-digit) for `tenant_id` and `username` | §5 |
| 5.3 | Logs missing for some namespaces in Grafana | Promtail scrapeConfigs only listed 2 namespaces | Add all target namespaces to scrapeConfigs | §5 |
| 5.4 | Agent pod killed by liveness probe at startup | fastembed model downloads at runtime | Pre-bake in Dockerfile; increase startupProbe failureThreshold | §5 |
| 6.1 | PVC stuck in WaitForFirstConsumer | EBS CSI driver not installed | Install `aws-ebs-csi-driver` add-on + IAM policy | §6 |
| 6.2 | `.terraform/` committed to git | `.gitignore` missing before `terraform init` | `git rm -r --cached .terraform/` + add to `.gitignore` | §6 |
| 6.3 | `kubectl` connects to old cluster endpoint | kubeconfig not updated after region migration | `aws eks update-kubeconfig --region ap-south-1` | §6 |
| 6.4 | ChaosEngine verdict stays Awaited | Wrong `appLabel` + chaos runner missing toleration | Match pod labels; add toleration to runner spec | §6 |
| 7.1 | DNS NXDOMAIN / wrong NS records | Two duplicate Route53 hosted zones | Identify registrar's zone; delete the duplicate | §7 |
| 7.2 | WSL DNS resets after `wsl --shutdown` | WSL auto-regenerates `/etc/resolv.conf` | Disable via `wsl.conf`; `chattr +i` resolv.conf | §7 |
| 7.3 | Pod internal DNS resolution fails | CoreDNS crash-looping from bad ConfigMap edit | Reset CoreDNS ConfigMap; `rollout restart deployment coredns` | §7 |
| 8.1 | Namespace stuck Terminating forever | Finalizer owned by deleted controller | Force-finalize via `kubectl replace --raw` | §8 |
| 8.2 | LB services can't be deleted after removing LB Controller | Controller finalizers orphaned | `kubectl patch svc ... -p '{"metadata":{"finalizers":null}}'` | §8 |
| 8.3 | CloudFormation DELETE\_FAILED | Orphaned NLBs keep ENIs in subnets | Delete NLBs in AWS console/CLI before `terraform destroy` | §8 |
| 9.1 | Dashboard logs modal shows nothing | Duplicate DOM IDs — `getElementById` hits wrong element | Use unique IDs per card (`inlineLogsBox-N`, `modalLogsBox`) | §9 |
| 9.2 | Dashboard shows stale RCA after agent completes | RCA response cached in JS variable | Re-fetch `/api/rca` on every SSE event | §9 |
| 8.5 | PVC stuck Terminating after namespace delete | StatefulSet not scaled down before Helm uninstall; finalizer pvc-protection blocks deletion | Scale StatefulSet to 0 → delete PVCs → sleep 30 → delete namespace | §8 |
| 8.6 | terraform destroy fails / EBS CSI add-on left orphaned | EBS CSI installed via eksctl (not Terraform) — not in state, conflicts on destroy | eksctl delete addon aws-ebs-csi-driver + delete iamserviceaccount before terraform destroy | §8 |
| 8.7 | LitmusChaos MongoDB PVC never binds — no default StorageClass | gp2 exists but not set as default; WaitForFirstConsumer + no EBS CSI driver | Patch gp2 as default StorageClass + install EBS CSI driver before LitmusChaos install | §8 |

---

*All errors above were encountered and resolved during a real implementation. Each section contains the full diagnosis steps, root cause analysis, and copy-paste-ready fixes.*
