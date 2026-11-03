# SRE Daily Task Playbook

Oct 15, 2026 · @Machindra

Practical day-to-day work for an SRE on an AI platform — from morning checks to on-call response.

## Morning Routine (first 30 min)

Do this before picking up any new work. It sets the baseline for the day.

**1. Check overnight alerts**

- Open Grafana / PagerDuty / Alertmanager — scan for anything that fired overnight
- For each alert: is it resolved, still firing, or flapping? Assign severity.
- If something is actively firing → go to on-call response (Section 5) immediately

**2. Check pod / node health**

```bash
# Any crashlooping or pending pods?
kubectl get pods -A | grep -Ev 'Running|Completed'

# Node pressure (disk, memory, pid)?
kubectl describe nodes | grep -A5 'Conditions'

# Any PVCs stuck?
kubectl get pvc -A | grep -v Bound
```

**3. Scan the incident queue**

- Open ServiceNow / Jira / Slack #incidents channel
- Any new P1/P2 tickets assigned to you or your team?
- Any open RCAs that need a follow-up action from yesterday?

**4. Check CI/CD pipelines**

- Did any overnight deployment fail? Check GitHub Actions / ArgoCD
- If a pipeline is stuck: unblock it or raise with the owning team

**5. 5-minute Grafana scan**

- p99 latency trending up vs yesterday?
- Error rate spiking on any service?
- CPU/memory on agent and app nodes — any anomaly?

This whole ritual should take under 30 minutes. If it regularly takes longer, the alert noise is too high — that itself becomes a task (tune alerts).

## Core SRE Work Areas

Most of your day falls into one of these four buckets. Rotate through them; don’t let any go untouched for more than a week.

### Reliability

- **SLA/SLO tracking** — review error budget burn rate; is the service consuming budget faster than expected? If error budget < 20%, stop feature work and focus on reliability.
- **Runbook updates** — after every incident, update the relevant runbook in `docs/runbooks/`. Stale runbooks are as bad as no runbooks.
- **Load testing** — periodically run `k6` / `locust` against `/api/slow` and `/api/products` to confirm the service handles expected peak load. Document the numbers.
- **Dependency review** — check upstream dependency health (pgvector, Gemini API quota, ECR image freshness). Catch deprecations before they hit prod (see: `gemini-2.5-flash` incident).

### Observability

- **Alert tuning** — review alerts that fired in the last 7 days. Is each actionable? If an alert fires and nobody does anything, it’s noise — raise the threshold or add a `for` duration.
- **Dashboard gaps** — if you had to grep logs to answer a question during an incident, that question needs a panel in Grafana.
- **Log quality** — check that structured logs (JSON) include `trace_id`, `service`, `level`. Unstructured logs make incident correlation slow.
- **Prometheus remote write** — verify the filter regex includes all metrics needed for active alerts. Missing a metric (e.g. `kube_pod_created`) = silent alert failure.

### Automation

- **Toil reduction** — identify any task you did manually more than twice this week. Write a script or add it to a runbook. Target: < 20% of your time on manual toil.
- **Deploy scripts** — keep `deploy-agent.sh`, `deploy-app.sh` idempotent and tested. A broken deploy script during an incident is catastrophic.
- **CI/CD pipeline health** — review GitHub Actions run times weekly. If builds are slow, cache layers or parallelize jobs.
- **Secret rotation** — track expiry of API keys (Gemini, Grafana Cloud). Automate rotation where possible; manually track in a calendar event where not.

### Capacity

- **Node utilization** — CPU/memory on `app-nodes` and `agent-nodes`. If consistently > 70%, plan a scale-up before it becomes an incident.
- **PVC / storage** — pgvector data grows as runbooks are added. Monitor disk usage monthly.
- **Cost review** — EKS node groups, EBS volumes, NAT gateway data transfer. Flag unexpected spikes to engineering.
- **HPA review** — are Horizontal Pod Autoscalers scaling as expected under load? Check `kubectl get hpa -A` after a load test.

## Weekly Cadence

| Day | Focus |
| --- | --- |
| **Monday** | Review last week’s alerts and incidents. Set the week’s reliability goal (e.g. “fix the flapping PodMemoryHigh alert”). Sync with engineering on upcoming deploys. |
| **Tuesday** | Deep work: automation, scripting, CI/CD improvements. No context-switching — block calendar. |
| **Wednesday** | Observability day: dashboard review, alert tuning, log quality check. Run `kubectl top nodes` and review HPA state. |
| **Thursday** | Capacity and cost review. Check error budget burn. If on-call rotation changes this week, hand off context to the next person. |
| **Friday** | Runbook and documentation updates from the week’s incidents. Deploy any non-urgent changes before EOD. Review open RCA action items. |
| **Daily** | Morning routine (Section 1). Check Slack #alerts and #incidents. Update any in-flight incident tickets. |

**Monthly (pick one Friday per month)**

- SLO report: compute actual availability vs target for each service
- Chaos engineering exercise: deliberately kill a pod / saturate a node, verify alerts fire and runbooks work
- Dependency audit: check for deprecated APIs, expired certs, outdated base images

## AI / Agent-Specific SRE Tasks

These are unique to an SRE on an AI platform and don’t appear in a traditional SRE role.

### LangGraph pipeline health

- **Check agent logs daily** for node failures — which LangGraph node failed: `alert_parser`, `runbook_retriever`, `diagnoser`, or `rca_writer`?
- **Monitor end-to-end latency** of the triage pipeline. If p99 > 30s, the LLM call is slow or RAG retrieval is timing out.
- **Track `runbook_used: null`** in triage responses — this means RAG failed to find a relevant runbook. Investigate pgvector connectivity or embedding quality.

```bash
# Check recent triage calls for null runbook
kubectl logs -n sre-ai-agent-llm -l app=sre-ai-agent-llm \
  --tail=100 | grep '"runbook_used": null'
```

### RAG / vector store quality

- **Add new runbooks** to `docs/runbooks/` whenever a new alert type is added. Trigger a re-embed if the agent doesn’t retrieve it.
- **Validate retrieval scores** — if similarity score < 0.7, the runbook isn’t semantically close to the alert. Improve the runbook’s language or add synonyms.
- **Monitor pgvector disk** — embeddings grow over time; alert if PVC > 80% full.

### LLM observability (evals)

- **Track diagnosis quality** — after each incident, compare the LLM’s diagnosis to the actual RCA. Build a score over time (correct root cause? actionable remediation?).
- **Monitor Gemini API quota** — check for `429 Resource Exhausted` errors in agent logs. Set up an alert if daily quota burn > 80%.
- **Model version discipline** — when Google deprecates a model, you have a window before it returns 404. Watch the Gemini changelog monthly and update before forced migration.

```bash
# Check for LLM errors in agent logs
kubectl logs -n sre-ai-agent-llm -l app=sre-ai-agent-llm \
  --tail=200 | grep -E '429|404|quota|deprecated'
```

### Prompt engineering as SRE work

- If the LLM’s diagnosis is consistently wrong for a specific alert type, the system prompt or runbook context is the issue — treat it like a config bug, not a model bug.
- Keep a log of bad diagnoses with the alert input and actual RCA. Use these as eval cases.

### Agentic workflow reliability

- **Idempotency** — if triage is called twice for the same alert, does it create duplicate RCAs? It should deduplicate on `alert_name + timestamp`.
- **Timeout handling** — what happens if the LLM call hangs for 60s? The agent should time out and return a partial result, not block indefinitely.
- **Fallback behavior** — if pgvector is down, the agent should still diagnose using the base prompt, not crash.

## On-Call and Incident Response

Every alert follows the same loop: **detect → triage → mitigate → resolve → RCA**.

### When an alert fires

**1. Acknowledge within SLA** (typically P1: 5 min, P2: 15 min, P3: 1 hr)

```bash
# First thing: confirm what is actually broken
kubectl get pods -A | grep -Ev 'Running|Completed'
kubectl top nodes
```

**2. Assess blast radius**

- Is it one pod, one service, or the whole cluster?
- Are end users affected? Check the app’s `/api/health` and `/api/ready` endpoints.
- Is it degraded (slow) or fully down?

**3. Run the triage agent** (if on the AI platform)

```bash
curl -s -X POST "http://${AGENT_LB}/agent/triage" \
  -H "Content-Type: application/json" \
  -d '{"alert_name": "<alert>", "severity": "<sev>",
       "service": "sre-ai-agent", "message": "<description>"}'
```

Read the RCA HTML URL from the response. The agent retrieves the relevant runbook and produces a starting diagnosis in \~10–20s.

**4. Mitigate first, investigate second**

| Symptom | Quick mitigation |
| --- | --- |
| Pod crashlooping | `kubectl rollout restart deployment/<name> -n <ns>` |
| High latency | Scale up replicas: `kubectl scale deployment/<name> --replicas=3 -n <ns>` |
| OOMKilled | Increase memory limit in deployment YAML, redeploy |
| Node NotReady | Cordon + drain: `kubectl cordon <node>` then `kubectl drain <node> --ignore-daemonsets` |
| LLM quota exceeded | Switch to backup model or rate-limit incoming triage requests |
| pgvector down | Check PVC mount, restart pod, verify StorageClass |

**5. Communicate**

- Post a status update in Slack #incidents every 15 min during a P1: what you know, what you’re doing, ETA.
- Open a ServiceNow ticket if one isn’t auto-created.

**6. Resolve and write the RCA**

Within 24 hrs of a P1/P2 resolution:

- **What happened** (timeline with exact times)
- **Why it happened** (root cause — not “pod crashed” but “OOM due to embedding batch size too large”)
- **Why we didn’t catch it sooner** (detection gap)
- **Action items** with owner and due date

Update `docs/runbooks/<alert>.md` with anything the runbook got wrong or missed. This closes the feedback loop into the RAG store.
