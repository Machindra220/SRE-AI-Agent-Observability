# =============================================================
# evals/metrics.py
# Prometheus metrics for AI agent quality scores.
#
# Why this exists:
#   Just like we monitor API error rate and latency,
#   we monitor AI quality metrics — confidence, retrieval
#   accuracy, RCA completeness. This closes the observability
#   loop: Prometheus scrapes → Grafana visualises → alert fires
#   if quality drops below threshold.
#
# Metrics exported:
#   sre_agent_eval_confidence_avg      ← avg LLM confidence
#   sre_agent_eval_context_recall      ← right runbook found?
#   sre_agent_eval_rca_completeness    ← all sections present?
#   sre_agent_eval_keyword_hit_rate    ← expected keywords in RCA?
#   sre_agent_eval_runs_total          ← how many evals run
#   sre_agent_eval_passed_total        ← how many passed
# =============================================================

from prometheus_client import Gauge, Counter, CollectorRegistry

# Create a dedicated registry for eval metrics
# (keeps eval metrics separate from app metrics)
EVAL_REGISTRY = CollectorRegistry()

# ── Gauge metrics (current value, can go up or down) ─────────

sre_agent_eval_confidence_avg = Gauge(
    name        = "sre_agent_eval_confidence_avg",
    documentation = (
        "Average LLM confidence score across all eval test cases. "
        "Range: 0.0-1.0. Target: > 0.60"
    ),
    registry    = EVAL_REGISTRY
)

sre_agent_eval_context_recall = Gauge(
    name        = "sre_agent_eval_context_recall",
    documentation = (
        "Fraction of test cases where RAG retrieved the correct runbook. "
        "Range: 0.0-1.0. Target: > 0.85"
    ),
    registry    = EVAL_REGISTRY
)

sre_agent_eval_rca_completeness = Gauge(
    name        = "sre_agent_eval_rca_completeness",
    documentation = (
        "Fraction of RCA reports containing all required sections "
        "(Root Cause, Evidence, Immediate Steps). "
        "Range: 0.0-1.0. Target: > 0.90"
    ),
    registry    = EVAL_REGISTRY
)

sre_agent_eval_keyword_hit_rate = Gauge(
    name        = "sre_agent_eval_keyword_hit_rate",
    documentation = (
        "Fraction of expected keywords found in generated RCA reports. "
        "Measures groundedness — does the RCA mention what it should? "
        "Range: 0.0-1.0. Target: > 0.75"
    ),
    registry    = EVAL_REGISTRY
)

sre_agent_eval_pass_rate = Gauge(
    name        = "sre_agent_eval_pass_rate",
    documentation = (
        "Fraction of test cases that passed all eval criteria. "
        "Range: 0.0-1.0. Target: > 0.70"
    ),
    registry    = EVAL_REGISTRY
)

# Per-test-case confidence gauge (labelled by test case ID)
sre_agent_eval_case_confidence = Gauge(
    name        = "sre_agent_eval_case_confidence",
    documentation = "LLM confidence score per test case.",
    labelnames  = ["test_case_id", "alert_name"],
    registry    = EVAL_REGISTRY
)

# ── Counter metrics (monotonically increasing) ────────────────

sre_agent_eval_runs_total = Counter(
    name        = "sre_agent_eval_runs_total",
    documentation = "Total number of eval suite runs since process start.",
    registry    = EVAL_REGISTRY
)

sre_agent_eval_passed_total = Counter(
    name        = "sre_agent_eval_passed_total",
    documentation = "Total number of individual test cases that passed.",
    registry    = EVAL_REGISTRY
)

sre_agent_eval_failed_total = Counter(
    name        = "sre_agent_eval_failed_total",
    documentation = "Total number of individual test cases that failed.",
    registry    = EVAL_REGISTRY
)