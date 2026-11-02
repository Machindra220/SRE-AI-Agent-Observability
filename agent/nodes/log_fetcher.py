# =============================================================
# agent/nodes/log_fetcher.py
# Node 1.5 — Fetches recent pod logs from Kubernetes.
# Runs after alert_parser, before runbook_retriever.
#
# Input:  state["alert_parsed"] (uses service as namespace)
# Output: state["raw_logs"]
# =============================================================

import subprocess
import logging
from agent.state import AgentState

logger = logging.getLogger(__name__)


def fetch_logs(state: AgentState) -> AgentState:
    alert     = state.get("alert_parsed") or {}
    namespace = alert.get("service", "sre-ai-agent")

    logger.info(f"[LogFetcher] Fetching logs from namespace: {namespace}")

    logs = _fetch_current_logs(namespace) or _fetch_previous_logs(namespace)

    if logs:
        logger.info(f"[LogFetcher] Fetched {len(logs.splitlines())} log lines")
    else:
        logger.warning(f"[LogFetcher] No logs for namespace: {namespace}")
        logs = "No logs available"

    return {**state, "raw_logs": logs}


def _fetch_current_logs(namespace: str) -> str:
    try:
        result = subprocess.run(
            ["kubectl", "logs", "-n", namespace,
             "-l", f"app={namespace}", "--tail=50", "--prefix=true"],
            capture_output=True, text=True, timeout=15
        )
        output = result.stdout.strip()
        if output:
            return output
    except subprocess.TimeoutExpired:
        logger.warning("[LogFetcher] kubectl logs timed out (current)")
    except FileNotFoundError:
        logger.warning("[LogFetcher] kubectl not found in PATH")
    except Exception as e:
        logger.warning(f"[LogFetcher] Error: {e}")
    return ""


def _fetch_previous_logs(namespace: str) -> str:
    try:
        result = subprocess.run(
            ["kubectl", "logs", "-n", namespace,
             "-l", f"app={namespace}", "--tail=50", "--previous", "--prefix=true"],
            capture_output=True, text=True, timeout=15
        )
        output = result.stdout.strip()
        if output:
            return f"[Previous container logs]\n{output}"
    except Exception as e:
        logger.warning(f"[LogFetcher] Previous logs error: {e}")
    return ""
