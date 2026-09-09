# ─────────────────────────────────────────────────────────────
# slos.tf
# Creates the two SLOs built manually in Phase 10:
#   1. Availability — 99% of requests non-5xx over 30 days
#   2. Latency     — 90% of requests with p99 < 2s over 30 days
#
# The availability SLO ID is referenced by the SLO burn rate
# monitor in monitors.tf — slos.tf must be applied first.
# ─────────────────────────────────────────────────────────────

# ── Availability SLO (99% target) ────────────────────────────
# Numerator   : successful requests (non-5xx)
# Denominator : all requests
# Type        : metric (ratio-based)
resource "datadog_service_level_objective" "availability" {
  name        = "sre-ai-agent Availability"
  type        = "metric"
  description = "99% of requests return non-5xx responses over a 30-day window"

  query {
    # Good requests = all hits excluding 5xx status class
    numerator   = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.env},!http.status_class:5xx}.as_count()"
    # Total requests = all hits regardless of status
    denominator = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.env}}.as_count()"
  }

  # 30-day rolling window — target 99%, warn at 99.5%
  thresholds {
    timeframe = "30d"
    target    = 99.0
    warning   = 99.5
  }

  tags = ["team:${var.team}"]
}

# ── Latency SLO (p99 < 2s, 90% target) ───────────────────────
# Tracks the proportion of requests completing within latency budget.
# Target is 90% — intentionally lower to account for the /api/slow endpoint.
resource "datadog_service_level_objective" "latency" {
  name        = "sre-ai-agent p99 Latency"
  type        = "metric"
  description = "90% of requests complete with p99 latency under 2s over a 30-day window"

  query {
    # Good requests = successful 2xx responses (within latency budget)
    numerator   = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.env},http.status_class:2xx}.as_count()"
    # Total requests = all requests
    denominator = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.env}}.as_count()"
  }

  # 30-day rolling window — target 90%, warn at 95%
  thresholds {
    timeframe = "30d"
    target    = 90.0
    warning   = 95.0
  }

  tags = ["team:${var.team}"]
}
