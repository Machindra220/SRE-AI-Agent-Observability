# ─────────────────────────────────────────────────────────────
# monitors.tf
# Creates all 5 Datadog monitors matching what was built
# manually in Phase 11. Each monitor has:
#   - priority (P1–P3)
#   - alert + warning thresholds
#   - message with runbook context
#   - tags for filtering in Datadog UI
# ─────────────────────────────────────────────────────────────

# ── P1: API Availability ──────────────────────────────────────
# Fires when request count drops to zero — complete outage signal.
# Wired to the Phase 12 workflow automation via @workflow handle.
resource "datadog_monitor" "api_availability" {
  name    = "[sre-ai-agent] API Availability - No Traffic - created-using-terraform-code"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}🔴 API Availability CRITICAL — no traffic detected on sre-ai-agent.
    Check: https://app.datadoghq.com/apm/services/sre-ai-agent
    {{/is_alert}}
    {{#is_recovery}}✅ sre-ai-agent traffic recovered.{{/is_recovery}}
    @workflow-sre-create-incident
  EOT

  # Alert when request count < 1 in last 5 minutes
  query = "sum(last_5m):count:trace.fastapi.request{service:${var.service},env:${var.env}} < 1"

  monitor_thresholds {
    critical = 1
    warning  = 5
  }

  priority            = 1
  require_full_window = false
  notify_no_data      = false
  evaluation_delay    = 60  # seconds — allows metrics to arrive before evaluation

  tags = ["team:${var.team}"]
}

# ── P2: High Error Rate ───────────────────────────────────────
# Fires when 5xx error count exceeds threshold in a 5-minute window.
# Uses trace.fastapi.request.errors — populated by ddtrace APM.
resource "datadog_monitor" "high_error_rate" {
  name    = "[sre-ai-agent] High Error Rate - created-using-terraform-code"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}🔴 High error rate detected on sre-ai-agent. Errors in last 5 minutes: {{value}}
    Check: https://app.datadoghq.com/apm/services/sre-ai-agent {{/is_alert}}
    {{#is_recovery}}✅ sre-ai-agent error rate recovered.{{/is_recovery}}
  EOT

  # Alert when total errors > 10 in last 5 minutes
  query = "sum(last_5m):sum:trace.fastapi.request.errors{service:${var.service},env:${var.env}} > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  priority            = 2
  require_full_window = false
  notify_no_data      = false
  evaluation_delay    = 60

  tags = ["team:${var.team}"]
}

# ── P2: Pod Restart Rate ──────────────────────────────────────
# Fires when container restarts exceed threshold — catches CrashLoopBackOff.
# Uses kubernetes_state metrics from the Datadog Kubernetes integration.
resource "datadog_monitor" "pod_restart_rate" {
  name    = "[sre-ai-agent] Pod Restart Rate - created-using-terraform-code"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}🔴 Pod restart rate high in namespace ${var.kube_namespace}. Restarts: {{value}}
    Check: https://app.datadoghq.com/orchestration/overview/pod {{/is_alert}}
    {{#is_recovery}}✅ Pod restart rate recovered.{{/is_recovery}}
  EOT

  # Alert when cumulative restarts > 3 in last 15 minutes
  query = "sum(last_15m):sum:kubernetes_state.container.restarts{kube_namespace:${var.kube_namespace},kube_deployment:${var.service}}.as_count() > 3"

  monitor_thresholds {
    critical = 3
    warning  = 1
  }

  priority            = 2
  require_full_window = false
  notify_no_data      = false

  tags = ["team:${var.team}"]
}

# ── P2: SLO Burn Rate ─────────────────────────────────────────
# Fires when the availability SLO error budget is burning too fast.
# burn_rate > 14.4 means the budget will be exhausted in ~2 days.
# References the availability SLO created in slos.tf.
resource "datadog_monitor" "slo_burn_rate" {
  name    = "[sre-ai-agent] SLO Error Budget Burn Rate - created-using-terraform-code"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}🔴 SLO error budget burning fast — sre-ai-agent availability SLO at risk.{{/is_alert}}
    {{#is_recovery}}✅ SLO burn rate recovered.{{/is_recovery}}
  EOT

  # Alert when error rate exceeds 1% — proxy for SLO budget pressure
  query = "sum(last_5m):sum:trace.fastapi.request.errors{service:${var.service},env:${var.env}}.as_count() / sum:trace.fastapi.request.hits{service:${var.service},env:${var.env}}.as_count() * 100 > 1"

  monitor_thresholds {
    critical = 1
    warning  = 0.5
  }

  priority            = 2
  require_full_window = false
  notify_no_data      = false

  tags = ["team:${var.team}"]
}

# ── P3: High p99 Latency ──────────────────────────────────────
# Fires when p99 response time exceeds 2 seconds.
# Uses percentile aggregation over trace.fastapi.request duration.
resource "datadog_monitor" "high_latency" {
  name    = "[sre-ai-agent] High p99 Latency - created-using-terraform-code"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}🟡 p99 latency above 2s on sre-ai-agent. Current: {{value}}s
    Check: https://app.datadoghq.com/apm/services/sre-ai-agent {{/is_alert}}
    {{#is_recovery}}✅ Latency recovered.{{/is_recovery}}
  EOT

  # Alert when p99 latency > 2s in last 5 minutes
  query = "percentile(last_5m):p99:trace.fastapi.request{service:${var.service},env:${var.env}} > 2"

  monitor_thresholds {
    critical = 2
    warning  = 1
  }

  priority            = 3
  require_full_window = false
  notify_no_data      = false
  evaluation_delay    = 60

  tags = ["team:${var.team}"]
}
