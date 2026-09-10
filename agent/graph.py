# =============================================================
# agent/graph.py
# Wires all 4 nodes into a LangGraph state machine.
# This is the blueprint of the SRE agent's workflow.
#
# Flow:
#   START
#     → alert_parser
#     → runbook_retriever
#     → diagnoser
#       → [conditional] if low confidence + retries left → diagnoser again
#       → [conditional] else → rca_writer
#     → rca_writer
#   END
# =============================================================

from langgraph.graph import StateGraph, END
from agent.state import AgentState
from agent.nodes.alert_parser import parse_alert
from agent.nodes.runbook_retriever import retrieve_runbook
from agent.nodes.diagnoser import diagnose, should_retry
from agent.nodes.rca_writer import write_rca


def build_graph() -> StateGraph:
    """
    Constructs and compiles the LangGraph agent.

    Returns:
        A compiled LangGraph graph ready to invoke with an AgentState.

    Usage:
        graph = build_graph()
        result = graph.invoke(initial_state(alert))
        print(result["rca_report"])
    """

    # Step 1: Create a new graph with AgentState as the shared state schema
    graph = StateGraph(AgentState)

    # Step 2: Register all nodes
    # Each node is a function that takes AgentState and returns updated AgentState
    graph.add_node("alert_parser",       parse_alert)
    graph.add_node("runbook_retriever",  retrieve_runbook)
    graph.add_node("diagnoser",          diagnose)
    graph.add_node("rca_writer",         write_rca)

    # Step 3: Set the entry point — first node to run
    graph.set_entry_point("alert_parser")

    # Step 4: Add linear edges (unconditional — always go to next node)
    graph.add_edge("alert_parser",      "runbook_retriever")
    graph.add_edge("runbook_retriever", "diagnoser")

    # Step 5: Add conditional edge after diagnoser
    # should_retry() returns "retry" or "continue"
    # "retry"    → loop back to diagnoser (another LLM call with same context)
    # "continue" → proceed to rca_writer
    graph.add_conditional_edges(
        "diagnoser",      # source node
        should_retry,     # function that decides the next node
        {
            "retry":    "diagnoser",   # loop back
            "continue": "rca_writer",  # proceed
        }
    )

    # Step 6: rca_writer → END (final node)
    graph.add_edge("rca_writer", END)

    # Step 7: Compile — validates graph structure and returns executable graph
    return graph.compile()


# Module-level compiled graph instance
# Imported by main.py so the graph is compiled once at startup
agent_graph = build_graph()