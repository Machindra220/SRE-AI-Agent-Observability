# Runbook: High Error Rate (5xx)

## Alert
[sre-ai-agent] High Error Rate (P2 High)

## Impact
Users receiving 500 errors. Service degraded but partially available.

## Diagnosis Steps

### 1. Check pod status
```bash
kubectl get pods -n sre-ai-agent
kubectl describe pod -n sre-ai-agent -l app=sre-ai-agent
```
Expected: pods in Running state. If CrashLoopBackOff → check logs.

### 2. Check application logs
```bash
kubectl logs -n sre-ai-agent -l app=sre-ai-agent --tail=100
kubectl logs -n sre-ai-agent -l app=sre-ai-agent --previous
```
Look for: exceptions, stack traces, connection errors, OOM errors.

### 3. Check recent deployments
```bash
kubectl rollout history deployment/sre-ai-agent -n sre-ai-agent
```
If recent deploy → likely root cause → rollback immediately.

### 4. Check error endpoints in Datadog
Filter: service:sre-ai-agent status:error
Look for: which endpoints returning 500, error frequency, pattern.

### 5. Check resource limits
```bash
kubectl top pods -n sre-ai-agent
kubectl describe pod -n sre-ai-agent -l app=sre-ai-agent | grep -A5 "Limits"
```

## Mitigation

### Rollback deployment (if deploy caused issue)
```bash
kubectl rollout undo deployment/sre-ai-agent -n sre-ai-agent
kubectl rollout status deployment/sre-ai-agent -n sre-ai-agent
```

### Restart pods (if stuck/deadlock)
```bash
kubectl rollout restart deployment/sre-ai-agent -n sre-ai-agent
```

### Scale up (if resource pressure)
```bash
kubectl scale deployment sre-ai-agent --replicas=3 -n sre-ai-agent
```

## Root Cause Patterns
| Symptom | Cause | Fix |
|---|---|---|
| All endpoints failing | App bug or bad deploy | Rollback deployment |
| One endpoint failing | Specific code bug | Fix and redeploy |
| Started after deploy | Bad deployment | Rollback |
| Random failures | Resource pressure | Scale up or increase limits |
| OOMKilled in logs | Memory limit too low | Increase memory limits |

## Recovery Validation
```bash
curl http://${LB}/api/health
curl http://${LB}/api/normal
```
Status should return to OK within 5 minutes.

## Escalation
If not resolved in 30 minutes → escalate to senior engineer.
