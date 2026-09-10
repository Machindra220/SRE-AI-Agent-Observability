# =============================================================
# agent/state.py
# Defines the shared State object that flows through all nodes.
# Every node reads from this and writes back to it.
#
# Think of it as the "baton" in a relay race — each node
# picks it up, adds its contribution, and passes it forward.
# =============================================================

from typing import TypedDict, Optional


class AlertInput(TypedDict):
    """
    Raw alert payload received from the API.
    This is what Datadog (or a test caller) sends to /agent/triage.
    """
    alert_name: str        # e.g. "High Error Rate"
    severity:   str        # e.g. "P1", "P2", "P3"
    service:    str        # e.g. "sre-ai-agent"
    message:    str        # e.g. "12% of requests returning 500 errors"


class ParsedAlert(TypedDict):
    """
    Structured alert after Node 1 (alert_parser) processes it.
    Normalised fields that all downstream nodes can rely on.
    """
    alert_name:  str       # cleaned alert name
    severity:    str       # P1 / P2 / P3
    alert_type:  str       # high_error_rate / pod_restart / high_latency / availability
    service:     str       # service name
    message:     str       # original message
    search_query: str      # optimised query string for RAG retrieval


class AgentState(TypedDict):
    """
    The main state object passed between all LangGraph nodes.

    Flow:
        Node 1 (alert_parser)      → fills: alert_parsed, search_query
        Node 2 (runbook_retriever) → fills: runbook_context, runbook_source
        Node 3 (diagnoser)         → fills: diagnosis, confidence_score
        Node 4 (rca_writer)        → fills: rca_report

    Optional fields start as None and are filled as the agent progresses.
    """

    # ── Input (set at graph entry) ─────────────────────────────
    alert_raw: AlertInput          # original alert from API caller

    # ── Node 1 output ─────────────────────────────────────────
    alert_parsed: Optional[ParsedAlert]    # structured alert fields
    search_query: Optional[str]            # query string sent to RAG

    # ── Node 2 output ─────────────────────────────────────────
    runbook_context: Optional[str]         # combined runbook chunks as text
    runbook_source:  Optional[str]         # which runbook file was matched

    # ── Node 3 output ─────────────────────────────────────────
    diagnosis:        Optional[str]        # LLM root cause diagnosis
    confidence_score: Optional[float]      # 0.0 - 1.0 how confident the LLM is

    # ── Node 4 output ─────────────────────────────────────────
    rca_report: Optional[str]             # final formatted RCA markdown

    # ── Control flow ──────────────────────────────────────────
    retry_count: int                       # how many times diagnoser has retried
    error:       Optional[str]             # any error message if a node fails


def initial_state(alert: AlertInput) -> AgentState:
    """
    Creates a fresh AgentState from an incoming alert.
    All optional fields start as None — nodes fill them in.

    Args:
        alert: The raw alert dict from the API request

    Returns:
        AgentState ready to be passed into the LangGraph graph
    """
    return AgentState(
        alert_raw        = alert,
        alert_parsed     = None,
        search_query     = None,
        runbook_context  = None,
        runbook_source   = None,
        diagnosis        = None,
        confidence_score = None,
        rca_report       = None,
        retry_count      = 0,
        error            = None,
    )