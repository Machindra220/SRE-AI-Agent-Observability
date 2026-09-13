# =============================================================
# agent/main.py
# FastAPI app exposing the SRE agent as HTTP endpoints.
# ddtrace instruments every request for Datadog APM tracing.
#
# Endpoints:
#   POST /agent/triage          → run full LangGraph agent
#   GET  /agent/health          → health check
#   GET  /agent/rca/{id}/html   → view RCA as styled HTML page
#   GET  /agent/rca/{id}/json   → retrieve stored RCA as JSON
#   GET  /agent/history         → list all past triage runs
#
# Run locally:
#   uvicorn agent.main:app --host 0.0.0.0 --port 8001 --reload
# =============================================================

import logging
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

# ddtrace — Datadog APM tracing
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

# ── In-memory RCA store ───────────────────────────────────────
# Stores every triage result so it can be retrieved by incident_id
# In production: replace with PostgreSQL or Redis
rca_store: dict[str, dict] = {}


# ── Request / Response Models ─────────────────────────────────

class TriageRequest(BaseModel):
    alert_name: str
    severity:   str
    service:    str
    message:    str

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
    status:       str
    incident_id:  str
    alert_name:   str
    severity:     str
    service:      str
    runbook_used: str
    confidence:   float
    rca_report:   str
    generated_at: str
    html_url:     str
    error:        str | None = None


# ── Helper: confidence label ──────────────────────────────────

def confidence_label(score: float) -> tuple[str, str]:
    """Returns (label, css_class) based on confidence score."""
    if score >= 0.85:
        return "High", "high"
    elif score >= 0.60:
        return "Medium", "medium"
    else:
        return "Low — Human Review Required", "low"


# ── Helper: build styled HTML ─────────────────────────────────

def build_rca_html(data: dict) -> str:
    """
    Converts a stored RCA dict into a styled HTML page.
    Uses inline CSS — no external dependencies needed.
    Confidence badge changes colour: green/amber/red.
    """
    import markdown as md

    confidence     = data["confidence"]
    label, css_cls = confidence_label(confidence)
    rca_html_body  = md.markdown(
        data["rca_report"],
        extensions=["tables", "fenced_code"]
    )

    # Colour map for confidence badge
    badge_colors = {
        "high":   ("background:#1D9E75;color:#fff",  "✓"),
        "medium": ("background:#BA7517;color:#fff",  "~"),
        "low":    ("background:#D85A30;color:#fff",  "⚠"),
    }
    badge_style, badge_icon = badge_colors[css_cls]

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RCA — {data['alert_name']} | {data['incident_id']}</title>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    font-size: 15px;
    line-height: 1.7;
    color: #1a1a1a;
    background: #f5f5f5;
    padding: 32px 16px;
  }}
  .container {{
    max-width: 860px;
    margin: 0 auto;
    background: #fff;
    border-radius: 12px;
    box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    overflow: hidden;
  }}

  /* Header banner */
  .header {{
    background: #0f1f3d;
    color: #fff;
    padding: 24px 32px;
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    flex-wrap: wrap;
    gap: 12px;
  }}
  .header h1 {{ font-size: 20px; font-weight: 600; margin-bottom: 4px; }}
  .header .meta {{ font-size: 13px; opacity: 0.7; }}

  /* Confidence badge */
  .badge {{
    padding: 6px 16px;
    border-radius: 20px;
    font-size: 13px;
    font-weight: 600;
    white-space: nowrap;
    {badge_style};
  }}

  /* Summary cards row */
  .summary {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    gap: 0;
    border-bottom: 1px solid #eee;
  }}
  .summary-item {{
    padding: 16px 20px;
    border-right: 1px solid #eee;
  }}
  .summary-item:last-child {{ border-right: none; }}
  .summary-item .label {{
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #888;
    margin-bottom: 4px;
  }}
  .summary-item .value {{
    font-size: 15px;
    font-weight: 600;
    color: #1a1a1a;
  }}

  /* Severity colour coding */
  .sev-P1 {{ color: #D85A30; }}
  .sev-P2 {{ color: #BA7517; }}
  .sev-P3 {{ color: #1D9E75; }}

  /* Main content */
  .content {{ padding: 28px 32px; }}

  /* Markdown rendering */
  .content h1 {{ font-size: 22px; margin: 24px 0 12px; color: #0f1f3d; }}
  .content h2 {{
    font-size: 17px;
    margin: 24px 0 10px;
    color: #0f1f3d;
    padding-bottom: 6px;
    border-bottom: 2px solid #eef2ff;
  }}
  .content h3 {{ font-size: 15px; margin: 16px 0 8px; color: #333; }}
  .content p  {{ margin: 8px 0; color: #333; }}
  .content ul, .content ol {{ margin: 8px 0 8px 24px; color: #333; }}
  .content li {{ margin: 4px 0; }}
  .content strong {{ color: #0f1f3d; }}

  /* Tables */
  .content table {{
    border-collapse: collapse;
    width: 100%;
    margin: 12px 0;
    font-size: 14px;
  }}
  .content th {{
    background: #eef2ff;
    color: #0f1f3d;
    padding: 10px 14px;
    text-align: left;
    font-weight: 600;
    border: 1px solid #dde3f0;
  }}
  .content td {{
    padding: 9px 14px;
    border: 1px solid #eee;
    vertical-align: top;
  }}
  .content tr:nth-child(even) td {{ background: #fafafa; }}

  /* Code blocks */
  .content code {{
    background: #f4f6fa;
    color: #0f1f3d;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 13px;
  }}
  .content pre {{
    background: #1a1f2e;
    color: #e8eaf0;
    padding: 16px 20px;
    border-radius: 8px;
    overflow-x: auto;
    margin: 12px 0;
    font-size: 13px;
    line-height: 1.6;
  }}
  .content pre code {{
    background: none;
    color: inherit;
    padding: 0;
    font-size: inherit;
  }}

  /* Blockquotes / callouts */
  .content blockquote {{
    border-left: 4px solid #7f77dd;
    background: #f8f7ff;
    padding: 12px 16px;
    margin: 12px 0;
    color: #444;
    border-radius: 0 6px 6px 0;
  }}

  /* Low confidence warning banner */
  .warning-banner {{
    background: #fff8f0;
    border: 1px solid #f5c75a;
    border-left: 4px solid #BA7517;
    border-radius: 0 6px 6px 0;
    padding: 12px 16px;
    margin: 0 0 20px;
    font-size: 14px;
    color: #7a4f00;
  }}
  .warning-banner.critical {{
    background: #fff5f0;
    border-color: #f5a58a;
    border-left-color: #D85A30;
    color: #7a2000;
  }}

  /* Footer */
  .footer {{
    background: #f8f9fc;
    padding: 16px 32px;
    border-top: 1px solid #eee;
    font-size: 12px;
    color: #888;
    display: flex;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
  }}
  .footer a {{ color: #534AB7; text-decoration: none; }}
</style>
</head>
<body>
<div class="container">

  <!-- Header -->
  <div class="header">
    <div>
      <div class="meta">Incident ID: {data['incident_id']}</div>
      <h1>{data['alert_name']}</h1>
      <div class="meta">Generated {data['generated_at']} UTC</div>
    </div>
    <div class="badge">{badge_icon} Confidence {confidence:.0%} — {label}</div>
  </div>

  <!-- Summary cards -->
  <div class="summary">
    <div class="summary-item">
      <div class="label">Severity</div>
      <div class="value sev-{data['severity']}">{data['severity']}</div>
    </div>
    <div class="summary-item">
      <div class="label">Service</div>
      <div class="value">{data['service']}</div>
    </div>
    <div class="summary-item">
      <div class="label">Runbook used</div>
      <div class="value">{data['runbook_used']}</div>
    </div>
    <div class="summary-item">
      <div class="label">AI confidence</div>
      <div class="value">{confidence:.0%}</div>
    </div>
  </div>

  <!-- Main content -->
  <div class="content">

    {"<!-- Low confidence warning -->" if confidence < 0.85 else ""}
    {f'<div class="warning-banner{" critical" if confidence < 0.60 else ""}">'
     f'{"⚠️ LOW CONFIDENCE" if confidence < 0.60 else "~ MEDIUM CONFIDENCE"} — '
     f'This AI-generated diagnosis requires human validation before executing any remediation in production.'
     f'</div>' if confidence < 0.85 else ""}

    {rca_html_body}
  </div>

  <!-- Footer -->
  <div class="footer">
    <span>Generated by SRE AI Agent v1.0 — LangGraph + Gemini + pgvector</span>
    <span>
      <a href="/agent/rca/{data['incident_id']}/json">View JSON</a> ·
      <a href="/agent/history">All incidents</a> ·
      <a href="/docs">API docs</a>
    </span>
  </div>

</div>
</body>
</html>"""


# ── Endpoints ─────────────────────────────────────────────────

@app.get("/agent/health")
def health():
    """Health check — returns 200 if agent is running."""
    return {
        "status":  "healthy",
        "service": "sre-ai-agent",
        "version": "1.0.0",
        "rca_store_count": len(rca_store)
    }


@app.post("/agent/triage", response_model=TriageResponse)
def triage(request: TriageRequest):
    """
    Main endpoint — triggers the full LangGraph SRE agent.
    Stores result in rca_store keyed by incident_id.
    Returns incident_id + html_url so caller can open the HTML report.
    """
    # Generate unique incident ID for this triage run
    incident_id  = f"INC-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{str(uuid.uuid4())[:6].upper()}"
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")

    logger.info(f"[{incident_id}] Triage: {request.alert_name} ({request.severity})")

    alert: AlertInput = {
        "alert_name": request.alert_name,
        "severity":   request.severity,
        "service":    request.service,
        "message":    request.message,
    }
    state = initial_state(alert)

    try:
        with tracer.trace("sre_agent.triage", service="sre-ai-agent") as span:
            span.set_tag("alert.name",      request.alert_name)
            span.set_tag("alert.severity",  request.severity)
            span.set_tag("alert.service",   request.service)
            span.set_tag("incident.id",     incident_id)

            result = agent_graph.invoke(state)

            span.set_tag("agent.confidence",   result.get("confidence_score", 0.0))
            span.set_tag("agent.runbook_used", result.get("runbook_source", "none"))

        confidence   = result.get("confidence_score", 0.0)
        runbook_used = result.get("runbook_source", "none")
        rca_report   = result.get("rca_report", "No RCA generated")

        # Store result for HTML retrieval
        rca_store[incident_id] = {
            "incident_id":  incident_id,
            "alert_name":   request.alert_name,
            "severity":     request.severity,
            "service":      request.service,
            "message":      request.message,
            "runbook_used": runbook_used,
            "confidence":   confidence,
            "rca_report":   rca_report,
            "generated_at": generated_at,
            "error":        result.get("error"),
        }

        logger.info(f"[{incident_id}] Complete. Confidence: {confidence:.2f} Runbook: {runbook_used}")

        return TriageResponse(
            status       = "success",
            incident_id  = incident_id,
            alert_name   = request.alert_name,
            severity     = request.severity,
            service      = request.service,
            runbook_used = runbook_used,
            confidence   = confidence,
            rca_report   = rca_report,
            generated_at = generated_at,
            html_url     = f"http://localhost:8001/agent/rca/{incident_id}/html",
            error        = result.get("error"),
        )

    except Exception as e:
        logger.error(f"[{incident_id}] Agent failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Agent failed: {str(e)}")


@app.get("/agent/rca/{incident_id}/html", response_class=HTMLResponse)
def rca_html(incident_id: str):
    """
    Returns the RCA report as a styled HTML page.
    Open in browser for a formatted view of the diagnosis.

    Confidence badge:
      Green  = high (>= 0.85)
      Amber  = medium (0.60 - 0.84)
      Red    = low (< 0.60) with warning banner
    """
    if incident_id not in rca_store:
        raise HTTPException(
            status_code=404,
            detail=f"Incident {incident_id} not found. Run POST /agent/triage first."
        )
    return build_rca_html(rca_store[incident_id])


@app.get("/agent/rca/{incident_id}/json")
def rca_json(incident_id: str):
    """Returns the stored RCA data as JSON."""
    if incident_id not in rca_store:
        raise HTTPException(status_code=404, detail=f"Incident {incident_id} not found.")
    return rca_store[incident_id]


@app.get("/agent/history")
def history():
    """
    Lists all past triage runs in this session.
    Note: restarting uvicorn clears the store (in-memory only).
    """
    return {
        "total": len(rca_store),
        "incidents": [
            {
                "incident_id":  v["incident_id"],
                "alert_name":   v["alert_name"],
                "severity":     v["severity"],
                "confidence":   v["confidence"],
                "runbook_used": v["runbook_used"],
                "generated_at": v["generated_at"],
                "html_url":     f"http://localhost:8001/agent/rca/{k}/html",
            }
            for k, v in rca_store.items()
        ]
    }