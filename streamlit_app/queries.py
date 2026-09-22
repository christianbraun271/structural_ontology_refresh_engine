"""
queries.py -- every SQL / Snowpark call the Control Plane app makes, kept in
one place so streamlit_app.py never writes SQL inline, only calls these
named functions.

DEMO_DB / CONTROL_SCHEMA below are this file's equivalent of the
`SET DEMO_DB = ...; USE DATABASE ...; USE SCHEMA ...;` block every SQL
script in this project starts with -- ONE place to edit if either name ever
changes, rather than repeated across query strings. A Streamlit-in-Snowflake
app's session does not reliably default its current database/schema to
wherever the Streamlit object itself was created, so use_control_schema()
below sets it explicitly instead of relying on ambient context, the same
approach every SQL script here takes with its own USE DATABASE/USE SCHEMA.
DEMO_DB/CONTROL_SCHEMA can't come from ORE_APP_CONFIG for the same
bootstrapping reason documented throughout the SQL scripts: that table lives
inside the very database/schema you'd need to already know to query it.
"""

from __future__ import annotations

from typing import Optional

import pandas as pd
from snowflake.snowpark import Session

# Edit these two if your database/schema names differ.
DEMO_DB = "ORE_DEMO_DB"
CONTROL_SCHEMA = "ORE_CONTROL"


def use_control_schema(session: Session) -> None:
    """Call once, right after get_active_session() -- sets the session's
    current database/schema explicitly rather than assuming the app's
    ambient context already points here. Every other function in this file
    references tables/procs unqualified, relying on this having been called
    first."""
    session.use_database(DEMO_DB)
    session.use_schema(CONTROL_SCHEMA)


# -----------------------------------------------------------------------------
# Fetch
# -----------------------------------------------------------------------------

PENDING_PROPOSALS_QUERY = """
    SELECT
        PROPOSAL_ID,
        FINAL_NAME,
        FINAL_OBJECT_KIND,
        OBJECT_KIND                           AS RULE_OBJECT_KIND,
        RULE_APPLIED,
        PROPOSED_NAME,
        EDGE_FROM,
        EDGE_TO,
        AI_AGREES_WITH_RULE,
        AI_RECOMMENDED_KIND,
        AI_CONFIDENCE,
        AI_RATIONALE,
        AI_INDUSTRY_NOTE,
        SOURCE_OBJECT:table_schema::VARCHAR   AS TABLE_SCHEMA,
        SOURCE_OBJECT:table_name::VARCHAR     AS TABLE_NAME,
        SOURCE_OBJECT:column_name::VARCHAR    AS COLUMN_NAME,
        DETECTED_TS
    FROM ORE_CANDIDATE_PROPOSALS
    WHERE STATUS = 'PENDING'
    ORDER BY DETECTED_TS
"""


def fetch_pending_proposals(session: Session) -> pd.DataFrame:
    """One row per PENDING proposal, oldest first. Always queried fresh -- not
    cached -- so the list reflects decisions made moments ago in this same
    session."""
    return session.sql(PENDING_PROPOSALS_QUERY).to_pandas()


# -----------------------------------------------------------------------------
# Decide
# -----------------------------------------------------------------------------


def record_decision(
    session: Session,
    proposal_id: str,
    status: str,
    rationale: Optional[str],
    final_name: Optional[str],
    final_object_kind: Optional[str],
) -> str:
    """
    Calls RECORD_DECISION (sql/04_control_plane/01_record_decision_proc.sql).
    Pass None for rationale/final_name/final_object_kind to leave that field
    unchanged -- never an empty string, which the procedure would treat as a
    real (blank) value rather than "no change".

    Returns 'OK' on success, or a string starting with 'ERROR: ' -- this
    function does not raise for an expected validation failure (e.g.
    approving a proposal with no FINAL_OBJECT_KIND set); callers must check
    the returned string themselves.
    """
    return session.call(
        "RECORD_DECISION",
        proposal_id,
        status,
        rationale,
        final_name,
        final_object_kind,
    )


# -----------------------------------------------------------------------------
# Generate
# -----------------------------------------------------------------------------


def get_ontology_schema(session: Session) -> Optional[str]:
    """Reads the ONTOLOGY_SCHEMA value seeded in ORE_APP_CONFIG (see
    sql/03_refresh_engine/00_seed_baseline.sql) -- the one config value the
    app needs that genuinely can't be a Python constant, since it names a
    schema this app doesn't itself run from. Returns None if the key is
    missing (shouldn't happen once 00_seed_baseline.sql has run, but the
    caller should handle it rather than assume)."""
    rows = session.sql(
        "SELECT CONFIG_VALUE FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'ONTOLOGY_SCHEMA'"
    ).collect()
    return rows[0]["CONFIG_VALUE"] if rows else None


def count_approved_awaiting_generation(session: Session) -> int:
    """How many APPROVED proposals have no ORE_GENERATED_ARTIFACTS rows yet --
    i.e. what a 'Generate Code' click would actually act on."""
    row = session.sql(
        """
        SELECT COUNT(*) AS CNT
        FROM ORE_CANDIDATE_PROPOSALS p
        WHERE p.STATUS = 'APPROVED'
          AND NOT EXISTS (SELECT 1 FROM ORE_GENERATED_ARTIFACTS g WHERE g.PROPOSAL_ID = p.PROPOSAL_ID)
        """
    ).collect()[0]
    return int(row["CNT"])


def count_generated_artifacts(session: Session) -> int:
    """Total row count in ORE_GENERATED_ARTIFACTS -- used to report how many
    new artifacts a generate action actually produced, via a before/after
    diff (GENERATE_ARTIFACTS/REFINE_ARTIFACTS return 'OK'/'ERROR: ...'
    strings, not a count, themselves)."""
    row = session.sql("SELECT COUNT(*) AS CNT FROM ORE_GENERATED_ARTIFACTS").collect()[0]
    return int(row["CNT"])


GENERATED_ARTIFACTS_QUERY = """
    SELECT
        p.PROPOSAL_ID,
        p.FINAL_NAME,
        p.FINAL_OBJECT_KIND,
        g.ARTIFACT_ID,
        g.ARTIFACT_TYPE,
        g.DEV_STATUS,
        g.TEMPLATE_SQL,
        g.AI_REFINED_SQL,
        g.AI_NOTES,
        g.GENERATED_TS,
        MAX(g.GENERATED_TS) OVER (PARTITION BY p.PROPOSAL_ID) AS PROPOSAL_LATEST_TS
    FROM ORE_GENERATED_ARTIFACTS g
    JOIN ORE_CANDIDATE_PROPOSALS p ON p.PROPOSAL_ID = g.PROPOSAL_ID
    ORDER BY PROPOSAL_LATEST_TS DESC, p.PROPOSAL_ID, g.ARTIFACT_TYPE
"""


def fetch_generated_artifacts(session: Session) -> pd.DataFrame:
    """Every drafted artifact -- most-recently-generated proposal first, each
    proposal's own artifacts grouped together (via the window function) and
    ordered by ARTIFACT_TYPE within it. Read-only viewer data for the
    Generate Code tab -- never used to decide anything."""
    return session.sql(GENERATED_ARTIFACTS_QUERY).to_pandas()


def generate_and_refine_artifacts(session: Session, ontology_schema: str) -> dict:
    """
    Calls GENERATE_ARTIFACTS(ontology_schema) then REFINE_ARTIFACTS() in
    sequence -- one "Generate Code" action covering both the template draft
    and the AI polish pass. Both procedures are designed to return an
    'OK'/'ERROR: ...' string rather than raise, but a transient Cortex error
    inside REFINE_ARTIFACTS's AI_COMPLETE call could still raise instead of
    returning cleanly -- each call is wrapped individually so any exception
    is caught and turned into the same 'ERROR: ...' shape the caller already
    has to handle either way, rather than crashing the app.
    """
    try:
        gen_result = session.call("GENERATE_ARTIFACTS", ontology_schema)
    except Exception as exc:  # noqa: BLE001 -- deliberately broad, see docstring
        gen_result = f"ERROR: {exc}"

    try:
        refine_result = session.call("REFINE_ARTIFACTS")
    except Exception as exc:  # noqa: BLE001
        refine_result = f"ERROR: {exc}"

    return {"generate": gen_result, "refine": refine_result}
