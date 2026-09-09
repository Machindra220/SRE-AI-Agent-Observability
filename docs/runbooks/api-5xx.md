# Runbook: High Error Rate (5xx)

## Alert
[sre-ai-agent] High Error Rate (P2 High)

## Impact
Users receiving 500 errors. Service degraded but partially available.

## Initial Checks

### 1. Check error traces in APM
Datadog → APM → Traces
Filter: service:sre-ai-agent status:error

Look for: which endpoint, what exception, stack trace

### 2. Check error logs
Datadog → Logs
Filter: service:sre-ai-agent status:error


### 3. Check pod status
```bash
kubectl get pods -n sre-ai-agent
kubectl describe pod -n sre-ai-agent -l app=sre-ai-agent
```

### 4. Check recent deployments
```bash
kubectl rollout history deployment/sre-ai-agent -n sre-ai-agent
```

## Possible Causes

| Symptom | Cause | Fix |
|---|---|---|
| All endpoints failing | App bug | Rollback deployment |
| One endpoint failing | Specific bug | Fix and redeploy |
| Started after deploy | Bad deployment | Rollback |
| Random failures | Resource pressure | Scale up or increase limits |

## Mitigation

### Rollback deployment
```bash
kubectl rollout undo deployment/sre-ai-agent -n sre-ai-agent
```

### Check and increase resources
```bash
kubectl describe pod -n sre-ai-agent -l app=sre-ai-agent | grep -A5 "Limits"
```

## Recovery Validation
Datadog → Monitors → [sre-ai-agent] High Error Rate
Status should return to OK within 5 minutes