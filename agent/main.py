# =============================================================
# agent/main.py
# FastAPI app exposing the SRE agent as an HTTP endpoint.
# ddtrace instruments every request for Datadog APM tracing.
#
# Endpoints:
#   POST /agent/triage  → run the full LangGraph agent
#   GET  /agent/health  → health check
#
# Run locally:
#   uvicorn agent.main:app --host 0.0.0.0 --port 8001 --reload
# =============================================================

import logging
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# ddtrace — Datadog APM tracing
# patch_all() instruments FastAPI, httpx, and other libraries automatically
from ddtrace import patch_all, tracer
patch_all(fastapi=True)

from agent.state import AlertInput, initial_state
from agent.graph import agent_graph

# ── Logging ───────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s"
)
logger = logging.getLogger(__name__)

# ── FastAPI App ───────────────────────────────────────────────
app = FastAPI(
    title="SRE AI Agent",
    description=(
        "LangGraph-powered SRE agent that triages production alerts, "
        "retrieves runbooks via RAG, and generates structured RCA reports."
    ),
    version="1.0.0",
)


# ── Request / Response Models ─────────────────────────────────

class TriageRequest(BaseModel):
    """
    Payload sent to POST /agent/triage.
    Mirrors the AlertInput TypedDict — Pydantic handles validation.
    """
    alert_name: str   # e.g. "High Error Rate"
    severity:   str   # e.g. "P2"
    service:    str   # e.g. "sre-ai-agent"
    message:    str   # e.g. "12% of requests returning 500 errors"

    class Config:
        json_schema_extra = {
            "example": {
                "alert_name": "High Error Rate",
                "severity":   "P2",
                "service":    "sre-ai-agent",
                "message":    "12% of requests returning 500 errors in the last 5 minutes"
            }
        }


class TriageResponse(BaseModel):
    """
    Response from POST /agent/triage.
    """
    status:          str    # "success" or "error"
    alert_name:      str
    severity:        str
    service:         str
    runbook_used:    str    # which runbook was retrieved
    confidence:      float  # 0.0 - 1.0
    rca_report:      str    # full markdown RCA
    generated_at:    str    # UTC timestamp
    error:           str | None = None


# ── Endpoints ─────────────────────────────────────────────────

@app.get("/agent/health")
def health():
    """
    Health check endpoint.
    Returns 200 if the agent service is running.
    """
    return {"status": "healthy", "service": "sre-ai-agent", "version": "1.0.0"}


@app.post("/agent/triage", response_model=TriageResponse)
def triage(request: TriageRequest):
    """
    Main endpoint — triggers the full LangGraph SRE agent.

    Flow:
        1. Validate request (Pydantic)
        2. Build initial AgentState
        3. Invoke LangGraph graph (4 nodes run sequentially)
        4. Return RCA report

    The entire flow is traced by ddtrace — visible in Datadog APM
    as a single trace with child spans per node.
    """
    logger.info(
        f"Received triage request: {request.alert_name} "
        f"({request.severity}) on {request.service}"
    )

    # Build AlertInput dict from request
    alert: AlertInput = {
        "alert_name": request.alert_name,
        "severity":   request.severity,
        "service":    request.service,
        "message":    request.message,
    }

    # Build initial state with all optional fields as None
    state = initial_state(alert)

    try:
        # ── Datadog APM: custom span for the full agent run ───
        with tracer.trace("sre_agent.triage", service="sre-ai-agent") as span:
            span.set_tag("alert.name",     request.alert_name)
            span.set_tag("alert.severity", request.severity)
            span.set_tag("alert.service",  request.service)

            # Invoke LangGraph — runs all 4 nodes
            result = agent_graph.invoke(state)

            # Tag span with outcome
            span.set_tag("agent.confidence",   result.get("confidence_score", 0.0))
            span.set_tag("agent.runbook_used", result.get("runbook_source", "none"))

        logger.info(
            f"Triage complete for {request.alert_name}. "
            f"Confidence: {result.get('confidence_score', 0.0):.2f}"
        )

        return TriageResponse(
            status       = "success",
            alert_name   = request.alert_name,
            severity     = request.severity,
            service      = request.service,
            runbook_used = result.get("runbook_source", "none"),
            confidence   = result.get("confidence_score", 0.0),
            rca_report   = result.get("rca_report", "No RCA generated"),
            generated_at = datetime.now(timezone.utc).isoformat(),
            error        = result.get("error"),
        )

    except Exception as e:
        logger.error(f"Agent failed for {request.alert_name}: {e}", exc_info=True)
        raise HTTPException(
            status_code=500,
            detail=f"Agent failed to process alert: {str(e)}"
        )