# =============================================================
# agent/nodes/diagnoser.py
# Node 3 — The AI reasoning step. Sends alert + runbook to
# Claude and gets a root cause diagnosis back.
#
# Input:  state["alert_parsed"], state["runbook_context"]
# Output: state["diagnosis"], state["confidence_score"]
#
# Why this exists:
#   This is where AI adds value — reasoning about ambiguous
#   production issues that rule-based systems cannot handle.
# =============================================================

import os
import json
import logging
from anthropic import Anthropic
from agent.state import AgentState

logger = logging.getLogger(__name__)

# Anthropic client — reads ANTHROPIC_API_KEY from environment
client = Anthropic()

# LLM model to use
MODEL = "claude-sonnet-4-6"

# If confidence is below this, the graph will retry diagnosis
# (with a note asking for more specific reasoning)
LOW_CONFIDENCE_THRESHOLD = 0.60

# Max retries to avoid infinite loops
MAX_RETRIES = 2


def build_diagnosis_prompt(state: AgentState) -> str:
    """
    Build the user prompt sent to Claude.

    Good prompt engineering principles used here:
    1. Specific role ("senior SRE")
    2. Structured context (alert fields clearly labelled)
    3. Grounded knowledge (runbook content)
    4. Explicit output format (JSON)
    5. Confidence score requested (for retry logic)
    """
    alert = state["alert_parsed"]
    runbook = state["runbook_context"]

    return f"""You are a senior Site Reliability Engineer (SRE) diagnosing a production alert.

## Alert Details
- Alert Name: {alert['alert_name']}
- Severity:   {alert['severity']}
- Service:    {alert['service']}
- Type:       {alert['alert_type']}
- Message:    {alert['message']}

## Relevant Runbook Content
{runbook}

## Your Task
Based on the alert details and the runbook content above:
1. Identify the most likely root cause
2. Identify supporting evidence from the runbook
3. Suggest immediate remediation steps
4. Rate your confidence (0.0 to 1.0) based on how well the runbook matches the alert

## Response Format
Respond ONLY with valid JSON — no preamble, no markdown, no explanation outside the JSON:

{{
    "root_cause": "One clear sentence describing the most likely root cause",
    "evidence": ["Evidence point 1 from runbook", "Evidence point 2", "Evidence point 3"],
    "immediate_steps": ["Step 1 command or action", "Step 2", "Step 3"],
    "confidence": 0.85
}}
"""


SYSTEM_PROMPT = """You are a senior SRE with 10 years of experience troubleshooting 
production incidents on Kubernetes and cloud platforms. 
You diagnose alerts based on runbooks and return structured JSON only.
Never hallucinate — if the runbook doesn't have enough information, 
say so in root_cause and set confidence below 0.5."""


def diagnose(state: AgentState) -> AgentState:
    """
    LangGraph Node 3 — LLM Diagnoser.

    Reads:  state["alert_parsed"], state["runbook_context"], state["retry_count"]
    Writes: state["diagnosis"], state["confidence_score"]

    Args:
        state: Current AgentState with alert and runbook populated

    Returns:
        Updated AgentState with diagnosis and confidence_score filled in.
    """
    retry = state.get("retry_count", 0)
    logger.info(f"[Node 3] Running diagnosis (attempt {retry + 1})")

    prompt = build_diagnosis_prompt(state)

    try:
        # Call Claude API
        response = client.messages.create(
            model=MODEL,
            max_tokens=1000,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": prompt}]
        )

        raw_response = response.content[0].text
        logger.info(f"[Node 3] Raw LLM response: {raw_response[:200]}...")

        # Parse JSON response from Claude
        # Strip any accidental markdown code fences
        clean = raw_response.strip().replace("```json", "").replace("```", "").strip()
        result = json.loads(clean)

        root_cause       = result.get("root_cause", "Unknown root cause")
        evidence         = result.get("evidence", [])
        immediate_steps  = result.get("immediate_steps", [])
        confidence       = float(result.get("confidence", 0.5))

        # Format diagnosis as readable text for the next node
        diagnosis = (
            f"**Root Cause:** {root_cause}\n\n"
            f"**Evidence:**\n" + "\n".join(f"- {e}" for e in evidence) + "\n\n"
            f"**Immediate Steps:**\n" + "\n".join(f"{i+1}. {s}" for i, s in enumerate(immediate_steps))
        )

        logger.info(f"[Node 3] Diagnosis complete. Confidence: {confidence:.2f}")

        return {
            **state,
            "diagnosis":        diagnosis,
            "confidence_score": confidence,
            "retry_count":      retry + 1,
        }

    except json.JSONDecodeError as e:
        logger.error(f"[Node 3] Failed to parse LLM JSON response: {e}")
        return {
            **state,
            "diagnosis":        f"Diagnosis failed — LLM returned invalid JSON: {raw_response[:200]}",
            "confidence_score": 0.0,
            "retry_count":      retry + 1,
            "error":            str(e),
        }
    except Exception as e:
        logger.error(f"[Node 3] Unexpected error during diagnosis: {e}")
        return {
            **state,
            "diagnosis":        f"Diagnosis failed — unexpected error: {str(e)}",
            "confidence_score": 0.0,
            "retry_count":      retry + 1,
            "error":            str(e),
        }


def should_retry(state: AgentState) -> str:
    """
    Conditional edge function for LangGraph.
    Decides whether to retry diagnosis or proceed to rca_writer.

    Returns:
        "retry"     → loop back to diagnoser (low confidence)
        "continue"  → proceed to rca_writer
    """
    confidence  = state.get("confidence_score", 0.0)
    retry_count = state.get("retry_count", 0)
    error       = state.get("error")

    # Always continue if there's an error (avoid infinite error loops)
    if error:
        return "continue"

    # Retry if confidence is low and we haven't hit the max retries
    if confidence < LOW_CONFIDENCE_THRESHOLD and retry_count < MAX_RETRIES:
        logger.info(
            f"[Node 3] Low confidence ({confidence:.2f}) — retrying "
            f"(attempt {retry_count + 1}/{MAX_RETRIES})"
        )
        return "retry"

    return "continue"