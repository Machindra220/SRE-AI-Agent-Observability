# ─────────────────────────────────────────────────────────────
# dashboard.tf
# Recreates the Golden Signals dashboard from Phase 9 as code.
# Four widget groups: Traffic, Latency, Errors, Saturation.
# All metrics are scoped to service + env via variables.
# ─────────────────────────────────────────────────────────────

resource "datadog_dashboard" "golden_signals" {
  title       = "SRE AI — Golden Signals"
  layout_type = "ordered"  # widgets stack top-to-bottom
  description = "Traffic, Latency, Errors, Saturation for ${var.service}"

  # ── Signal 1: Traffic ───────────────────────────────────────
  # Shows requests per second — baseline for all other signals
  widget {
    group_definition {
      title       = "Traffic"
      layout_type = "ordered"

      widget {
        timeseries_definition {
          title = "Request Rate (req/s)"
          request {
            # .as_rate() converts the counter to a per-second rate
            q            = "sum:trace.fastapi.request.hits{service:${var.service},env:${var.env}}.as_rate()"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Signal 2: Latency ───────────────────────────────────────
  # Shows p50/p95/p99 — three lines reveal latency distribution shape
  widget {
    group_definition {
      title       = "Latency"
      layout_type = "ordered"

      widget {
        timeseries_definition {
          title = "p50 / p95 / p99 Latency"

          # p50 — median latency (green)
          request {
            q            = "p50:trace.fastapi.request{service:${var.service},env:${var.env}}"
            display_type = "line"
            style {
              palette    = "green"
              line_type  = "solid"
              line_width = "normal"
            }
          }

          # p95 — upper mid-range (yellow)
          request {
            q            = "p95:trace.fastapi.request{service:${var.service},env:${var.env}}"
            display_type = "line"
            style {
              palette    = "yellow"
              line_type  = "solid"
              line_width = "normal"
            }
          }

          # p99 — tail latency — this is what the SLO monitors (red)
          request {
            q            = "p99:trace.fastapi.request{service:${var.service},env:${var.env}}"
            display_type = "line"
            style {
              palette    = "red"
              line_type  = "solid"
              line_width = "normal"
            }
          }
        }
      }
    }
  }

  # ── Signal 3: Errors ────────────────────────────────────────
  # Two widgets: error rate over time + current error % as a value
  widget {
    group_definition {
      title       = "Errors"
      layout_type = "ordered"

      # Error rate timeseries — bar chart shows spikes clearly
      widget {
        timeseries_definition {
          title = "Error Rate"
          request {
            q            = "sum:trace.fastapi.request.errors{service:${var.service},env:${var.env}}.as_rate()"
            display_type = "bars"
            style {
              palette = "red"
            }
          }
        }
      }

      # Error percentage — single number with conditional colouring
      widget {
        query_value_definition {
          title     = "Error % (last 5m)"
          autoscale = true
          precision = 2

          request {
            # errors / total * 100 = error percentage
            q          = "sum:trace.fastapi.request.errors{service:${var.service},env:${var.env}}.as_count() / sum:trace.fastapi.request.hits{service:${var.service},env:${var.env}}.as_count() * 100"
            aggregator = "avg"

            # Green when error % < 1
            conditional_formats {
              comparator = "<"
              value      = 1
              palette    = "white_on_green"
            }

            # Red when error % >= 1
            conditional_formats {
              comparator = ">="
              value      = 1
              palette    = "white_on_red"
            }
          }
        }
      }
    }
  }

  # ── Signal 4: Saturation ────────────────────────────────────
  # CPU and memory of the app pods — from Kubernetes integration
  widget {
    group_definition {
      title       = "Saturation"
      layout_type = "ordered"

      # Pod CPU usage — scoped to deployment
      widget {
        timeseries_definition {
          title = "Pod CPU Usage"
          request {
            q            = "avg:kubernetes.cpu.usage.total{kube_namespace:${var.kube_namespace},kube_deployment:${var.service}}"
            display_type = "line"
          }
        }
      }

      # Pod memory usage — scoped to deployment
      widget {
        timeseries_definition {
          title = "Pod Memory Usage"
          request {
            q            = "avg:kubernetes.memory.usage{kube_namespace:${var.kube_namespace},kube_deployment:${var.service}}"
            display_type = "line"
          }
        }
      }
    }
  }

  # Only "team" and "ai" tag keys are allowed in this Datadog org
  tags = ["team:${var.team}"]
}
