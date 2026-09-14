# ─────────────────────────────────────────────────────────────
# variables.tf
# Input variables shared across all Datadog resources.
# Datadog API/APP keys are NOT variables here — they come from
# AWS Secrets Manager in providers.tf.
# ─────────────────────────────────────────────────────────────

# Environment tag applied to every Datadog resource (monitor, SLO, dashboard)
variable "env" {
  description = "Environment tag — matches the env tag set on the Datadog agent"
  type        = string
  default     = "dev"
}

# Must match the APM service name reported by ddtrace
variable "service" {
  description = "APM service name — must match service:xxx tag in Datadog"
  type        = string
  default     = "sre-ai-agent"
}

# Kubernetes namespace where the app pods run
variable "kube_namespace" {
  description = "Kubernetes namespace — used in K8s metric filters"
  type        = string
  default     = "sre-ai-agent"
}

# Team tag for grouping and filtering resources in Datadog
variable "team" {
  description = "Team tag applied to all Datadog resources"
  type        = string
  default     = "sre"
}
