# ─────────────────────────────────────────────────────────────
# outputs.tf
# Exposes resource IDs after terraform apply.
# Useful for referencing resources in other modules or scripts.
# ─────────────────────────────────────────────────────────────

# Monitor IDs — one per monitor created in monitors.tf
output "monitor_ids" {
  description = "IDs of all Datadog monitors created by Terraform"
  value = {
    api_availability = datadog_monitor.api_availability.id
    high_error_rate  = datadog_monitor.high_error_rate.id
    pod_restart_rate = datadog_monitor.pod_restart_rate.id
    slo_burn_rate    = datadog_monitor.slo_burn_rate.id
    high_latency     = datadog_monitor.high_latency.id
  }
}

# SLO IDs — referenced by the burn rate monitor and useful for API calls
output "slo_ids" {
  description = "IDs of all SLOs created by Terraform"
  value = {
    availability = datadog_service_level_objective.availability.id
    latency      = datadog_service_level_objective.latency.id
  }
}

# Direct URL to open the Golden Signals dashboard in Datadog
output "dashboard_url" {
  description = "URL of the Golden Signals dashboard"
  value       = "https://app.datadoghq.com/dashboard/${datadog_dashboard.golden_signals.id}"
}
