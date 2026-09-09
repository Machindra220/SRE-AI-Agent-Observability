# Runbook: High p99 Latency

## Alert
[sre-ai-agent] High p99 Latency (P3 Medium)

## Impact
Slow responses for worst-case users. Service available but degraded.

## Initial Checks

### 1. Check APM traces for slow requests
Datadog → APM → Traces
Filter: service:sre-ai-agent
Sort by: Duration (descending)

Look for: which endpoint is slowest, what operations take longest

### 2. Check resource saturation
Datadog → Dashboard → SRE - Kubernetes Infrastructure
Check: App CPU Saturation, App Memory Saturation


### 3. Check node resources
```bash
kubectl top nodes
kubectl top pods -n sre-ai-agent
```

## Possible Causes

| Symptom | Cause | Fix |
|---|---|---|
| Specific endpoint slow | Code issue | Optimize or fix |
| All endpoints slow | Resource pressure | Scale up |
| Started after deploy | Bad deployment | Rollback |
| Intermittent spikes | GC pauses | Tune memory limits |

## Mitigation

### Scale up pods
```bash
kubectl scale deployment sre-ai-agent --replicas=2 -n sre-ai-agent
```

### Rollback if after deployment
```bash
kubectl rollout undo deployment/sre-ai-agent -n sre-ai-agent
```

## Recovery Validation
Datadog → Monitors → [sre-ai-agent] High p99 Latency
p99 should drop below 2s within 5 minutes

