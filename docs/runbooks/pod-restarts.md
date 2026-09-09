# Runbook: Pod Restart Rate

## Alert
[sre-ai-agent] Pod Restart Rate (P2 High)

## Impact
Application crashing repeatedly. Brief downtime during each restart.

## Initial Checks

### 1. Check pod status
```bash
kubectl get pods -n sre-ai-agent
kubectl describe pod -n sre-ai-agent -l app=sre-ai-agent
```
Look for: restart count, last state, reason

### 2. Check previous container logs
```bash
# Logs from the PREVIOUS (crashed) container
kubectl logs -n sre-ai-agent -l app=sre-ai-agent --previous
```

### 3. Check events
```bash
kubectl get events -n sre-ai-agent --sort-by='.lastTimestamp'
```
Look for: OOMKilled, Liveness probe failed, Back-off restarting

## Possible Causes

| Reason | Cause | Fix |
|---|---|---|
| OOMKilled | Memory limit too low | Increase memory limit |
| Liveness probe failed | App too slow to start | Increase initialDelaySeconds |
| Error | App crash on startup | Fix bug, check env vars |
| Back-off | Repeated crashes | Fix root cause first |

## Mitigation

### Increase memory limit (if OOMKilled)
Edit `kubernetes/deployment.yaml`:
```yaml
resources:
  limits:
    memory: "512Mi"  # increase from 256Mi
```
```bash
kubectl apply -f kubernetes/deployment.yaml
```

### Increase liveness probe delay
Edit `kubernetes/deployment.yaml`:
```yaml
livenessProbe:
  initialDelaySeconds: 30  # increase from 10
```

## Recovery Validation
```bash
kubectl get pods -n sre-ai-agent
# RESTARTS column should stop incrementing
```