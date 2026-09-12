# =============================================================
# agent/nodes/alert_parser.py
# Node 1 — Parses and normalises the raw incoming alert.
#
# Input:  state["alert_raw"]   (raw dict from API)
# Output: state["alert_parsed"] + state["search_query"]
#
# Why this exists:
#   Alerts from Datadog are messy. This node cleans them into
#   a consistent structure all downstream nodes can rely on.
# =============================================================

import logging
from agent.state import AgentState, ParsedAlert

logger = logging.getLogger(__name__)

# Map alert names → internal alert_type keys
# alert_type is used to build a better RAG search query
ALERT_TYPE_MAP = {
    "error rate":    "high_error_rate",
    "5xx":           "high_error_rate",
    "500":           "high_error_rate",
    "latency":       "high_latency",
    "slow":          "high_latency",
    "p99":           "high_latency",
    "pod restart":   "pod_restart",
    "crashloop":     "pod_restart",
    "oomkilled":     "pod_restart",
    "availability":  "availability",
    "no traffic":    "availability",
    "slo":           "availability",
}

# Maps alert_type → optimised RAG search query
# More specific queries retrieve better runbook matches
SEARCH_QUERY_MAP = {
    "high_error_rate": "high error rate 5xx 500 errors api returning 500 internal server error",
    "high_latency":    "high latency p99 slow response time degraded performance",
    "pod_restart":     "pod restarting crashloop OOMKilled container restart",
    "availability":    "service down no traffic availability SLO breach",
}


def detect_alert_type(alert_name: str, message: str) -> str:
    """
    Detect the alert type from alert name and message text.
    Falls back to "unknown" if no keyword matches.
    """
    combined = f"{alert_name} {message}".lower()
    for keyword, alert_type in ALERT_TYPE_MAP.items():
        if keyword in combined:
            return alert_type
    return "unknown"


def parse_alert(state: AgentState) -> AgentState:
    """
    LangGraph Node 1 — Alert Parser.

    Reads:  state["alert_raw"]
    Writes: state["alert_parsed"], state["search_query"]

    Args:
        state: Current AgentState (only alert_raw is populated)

    Returns:
        Updated AgentState with alert_parsed and search_query filled in.
    """
    alert = state["alert_raw"]
    logger.info(f"[Node 1] Parsing alert: {alert['alert_name']} ({alert['severity']})")

    # Detect alert type from name + message
    alert_type = detect_alert_type(alert["alert_name"], alert["message"])
    logger.info(f"[Node 1] Detected alert_type: {alert_type}")

    # Build optimised search query for RAG
    # Uses the known query map, falls back to raw alert text
    search_query = SEARCH_QUERY_MAP.get(
        alert_type,
        f"{alert['alert_name']} {alert['message']}"  # fallback
    )

    # Build the parsed alert structure
    alert_parsed: ParsedAlert = {
        "alert_name":   alert["alert_name"].strip(),
        "severity":     alert["severity"].upper().strip(),
        "alert_type":   alert_type,
        "service":      alert["service"].strip(),
        "message":      alert["message"].strip(),
        "search_query": search_query,
    }

    logger.info(f"[Node 1] Alert parsed successfully: {alert_parsed}")

    # Return updated state — LangGraph merges this with existing state
    return {
        **state,
        "alert_parsed": alert_parsed,
        "search_query": search_query,
    }