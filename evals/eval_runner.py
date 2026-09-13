# =============================================================
# evals/eval_runner.py
# Runs the full eval suite against the SRE AI agent.
#
# What it does:
#   1. Loads test cases from test_cases.json
#   2. Runs each alert through the agent (POST /agent/triage)
#   3. Scores each result using custom metrics
#   4. Exports scores to Prometheus
#   5. Prints a human-readable report
#
# Run:
#   python -m evals.eval_runner
#
# Requirements:
#   Agent must be running: uvicorn agent.main:app --port 8001
# =============================================================

import json
import logging
import requests
from pathlib import Path
from datetime import datetime, timezone
from prometheus_client import write_to_textfile

from evals.metrics import (
    EVAL_REGISTRY,
    sre_agent_eval_confidence_avg,
    sre_agent_eval_context_recall,
    sre_agent_eval_rca_completeness,
    sre_agent_eval_keyword_hit_rate,
    sre_agent_eval_pass_rate,
    sre_agent_eval_case_confidence,
    sre_agent_eval_runs_total,
    sre_agent_eval_passed_total,
    sre_agent_eval_failed_total,
)

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s — %(message)s")
logger = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────
AGENT_URL       = "http://localhost:8001/agent/triage"
TEST_CASES_PATH = Path("evals/test_cases.json")
METRICS_OUT     = Path("evals/metrics.prom")   # Prometheus text file output

# Required sections every RCA must contain
REQUIRED_RCA_SECTIONS = ["Root Cause", "Evidence", "Immediate Steps"]

# Thresholds for pass/fail per test case
CONFIDENCE_THRESHOLD   = 0.20   # min confidence to pass
COMPLETENESS_THRESHOLD = 0.67   # at least 2/3 sections must be present


# ── Scoring functions ─────────────────────────────────────────

def score_context_recall(result: dict, test_case: dict) -> tuple[bool, str]:
    """
    Context Recall: Did RAG retrieve the expected runbook?

    Returns (passed, reason)
    """
    expected = test_case["expected_runbook"]
    actual   = result.get("runbook_used", "none")

    if actual == expected:
        return True, f"correct runbook: {actual}"
    else:
        return False, f"expected {expected}, got {actual}"


def score_rca_completeness(result: dict, test_case: dict) -> tuple[float, str]:
    """
    RCA Completeness: Does the RCA contain all required sections?

    Returns (score 0.0-1.0, reason)
    score = sections_found / total_required_sections
    """
    rca     = result.get("rca_report", "")
    found   = [s for s in REQUIRED_RCA_SECTIONS if s in rca]
    score   = len(found) / len(REQUIRED_RCA_SECTIONS)
    missing = [s for s in REQUIRED_RCA_SECTIONS if s not in rca]

    if missing:
        return score, f"missing sections: {missing}"
    return score, "all sections present"


def score_keyword_hit_rate(result: dict, test_case: dict) -> tuple[float, str]:
    """
    Keyword Hit Rate: Does the RCA mention the expected keywords?

    Measures groundedness — if the expected keywords (OOMKilled, memory,
    kubectl etc.) appear in the RCA, it means the LLM is reasoning
    about the right things.

    Returns (score 0.0-1.0, reason)
    """
    rca      = result.get("rca_report", "").lower()
    keywords = test_case.get("expected_keywords", [])

    if not keywords:
        return 1.0, "no keywords defined"

    found = [k for k in keywords if k.lower() in rca]
    score = len(found) / len(keywords)
    missed = [k for k in keywords if k.lower() not in rca]

    if missed:
        return score, f"missing keywords: {missed}"
    return score, f"all {len(keywords)} keywords found"


def score_confidence(result: dict, test_case: dict) -> tuple[bool, str]:
    """
    Confidence check: Is the LLM confidence above the expected minimum?

    Returns (passed, reason)
    """
    actual   = result.get("confidence", 0.0)
    expected = test_case.get("expected_min_confidence", 0.20)

    if actual >= expected:
        return True, f"confidence {actual:.2f} >= threshold {expected:.2f}"
    return False, f"confidence {actual:.2f} < threshold {expected:.2f}"


def evaluate_test_case(test_case: dict) -> dict:
    """
    Run a single test case through the agent and score it.

    Returns a result dict with all scores and pass/fail status.
    """
    tc_id   = test_case["id"]
    alert   = test_case["alert"]

    logger.info(f"Running test case {tc_id}: {alert['alert_name']}")

    # Call the agent
    try:
        response = requests.post(
            AGENT_URL,
            json=alert,
            timeout=60
        )
        response.raise_for_status()
        result = response.json()
    except requests.exceptions.RequestException as e:
        logger.error(f"[{tc_id}] Agent call failed: {e}")
        return {
            "id":          tc_id,
            "alert_name":  alert["alert_name"],
            "passed":      False,
            "error":       str(e),
            "confidence":  0.0,
            "context_recall": False,
            "completeness":   0.0,
            "keyword_hit_rate": 0.0,
        }

    # Score the result
    context_ok,  context_reason      = score_context_recall(result, test_case)
    completeness, completeness_reason = score_rca_completeness(result, test_case)
    keyword_rate, keyword_reason      = score_keyword_hit_rate(result, test_case)
    confidence_ok, confidence_reason  = score_confidence(result, test_case)

    # Overall pass = all criteria met
    passed = (
        context_ok
        and completeness >= COMPLETENESS_THRESHOLD
        and confidence_ok
    )

    status = "✅ PASS" if passed else "❌ FAIL"
    logger.info(
        f"[{tc_id}] {status} | "
        f"confidence: {result.get('confidence', 0):.2f} | "
        f"runbook: {result.get('runbook_used')} | "
        f"completeness: {completeness:.2f}"
    )

    return {
        "id":               tc_id,
        "alert_name":       alert["alert_name"],
        "passed":           passed,
        "confidence":       result.get("confidence", 0.0),
        "runbook_used":     result.get("runbook_used", "none"),
        "context_recall":   context_ok,
        "context_reason":   context_reason,
        "completeness":     completeness,
        "completeness_reason": completeness_reason,
        "keyword_hit_rate": keyword_rate,
        "keyword_reason":   keyword_reason,
        "confidence_ok":    confidence_ok,
        "confidence_reason": confidence_reason,
        "incident_id":      result.get("incident_id", ""),
        "html_url":         result.get("html_url", ""),
        "error":            result.get("error"),
    }


def run_evals() -> dict:
    """
    Run the full eval suite and return aggregated scores.
    """
    logger.info("=" * 60)
    logger.info("SRE AI Agent — Eval Suite")
    logger.info(f"Time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    logger.info("=" * 60)

    # Load test cases
    test_cases = json.loads(TEST_CASES_PATH.read_text())
    logger.info(f"Loaded {len(test_cases)} test cases")

    # Run all test cases
    import time
    results = []
    for tc in test_cases:
        results.append(evaluate_test_case(tc))
        time.sleep(6)  # avoid rate limiting

    # Aggregate scores
    total           = len(results)
    passed          = sum(1 for r in results if r["passed"])
    avg_confidence  = sum(r["confidence"] for r in results) / total
    context_recall  = sum(1 for r in results if r["context_recall"]) / total
    avg_completeness = sum(r["completeness"] for r in results) / total
    avg_keyword_rate = sum(r["keyword_hit_rate"] for r in results) / total
    pass_rate       = passed / total

    # ── Update Prometheus metrics ──────────────────────────────
    sre_agent_eval_runs_total.inc()
    sre_agent_eval_passed_total.inc(passed)
    sre_agent_eval_failed_total.inc(total - passed)

    sre_agent_eval_confidence_avg.set(avg_confidence)
    sre_agent_eval_context_recall.set(context_recall)
    sre_agent_eval_rca_completeness.set(avg_completeness)
    sre_agent_eval_keyword_hit_rate.set(avg_keyword_rate)
    sre_agent_eval_pass_rate.set(pass_rate)

    # Per-case confidence
    for r in results:
        sre_agent_eval_case_confidence.labels(
            test_case_id=r["id"],
            alert_name=r["alert_name"]
        ).set(r["confidence"])

    # Write Prometheus text file (scraped by Prometheus node exporter)
    METRICS_OUT.parent.mkdir(parents=True, exist_ok=True)
    write_to_textfile(str(METRICS_OUT), EVAL_REGISTRY)
    logger.info(f"Prometheus metrics written to {METRICS_OUT}")

    # ── Print human-readable report ────────────────────────────
    summary = {
        "total":             total,
        "passed":            passed,
        "pass_rate":         pass_rate,
        "avg_confidence":    avg_confidence,
        "context_recall":    context_recall,
        "avg_completeness":  avg_completeness,
        "avg_keyword_rate":  avg_keyword_rate,
        "results":           results,
        "timestamp":         datetime.now(timezone.utc).isoformat(),
    }

    print("\n" + "=" * 60)
    print("EVAL RESULTS SUMMARY")
    print("=" * 60)
    print(f"Total test cases : {total}")
    print(f"Passed           : {passed}/{total} ({pass_rate:.0%})")
    print(f"Avg confidence   : {avg_confidence:.2f}")
    print(f"Context recall   : {context_recall:.2f}  (right runbook?)")
    print(f"RCA completeness : {avg_completeness:.2f} (all sections?)")
    print(f"Keyword hit rate : {avg_keyword_rate:.2f} (right keywords?)")
    print("=" * 60)
    print("\nPer-test breakdown:")
    for r in results:
        icon = "✅" if r["passed"] else "❌"
        print(
            f"  {icon} {r['id']} | {r['alert_name'][:30]:<30} | "
            f"conf: {r['confidence']:.2f} | "
            f"runbook: {'✓' if r['context_recall'] else '✗'} | "
            f"complete: {r['completeness']:.2f}"
        )
    print("=" * 60)

    return summary


if __name__ == "__main__":
    run_evals()