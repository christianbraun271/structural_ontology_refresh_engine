"""
streamlit_app.py -- the Control Plane app: a BA reviews PENDING ontology
change proposals, can edit the proposed name / final kind, and decides
Approve / Reject / Defer. A separate "Generate Code" action then drafts and
AI-refines the SQL for every APPROVED-but-not-yet-generated proposal. Every
write goes through a stored procedure -- RECORD_DECISION for decisions,
GENERATE_ARTIFACTS + REFINE_ARTIFACTS for codegen -- this app never writes
STATUS/audit-log rows or generated SQL itself.

The "Generate Code" button is a batch action over ALL approved proposals
system-wide, not scoped to whatever's currently visible in the pending-review
list below it (approved proposals aren't shown there at all -- only PENDING
ones are). It reads ONTOLOGY_SCHEMA from ORE_APP_CONFIG (seeded by
sql/03_refresh_engine/00_seed_baseline.sql) to pass into GENERATE_ARTIFACTS.

Deploy as Streamlit in Snowflake via Snowsight's "+ Streamlit App" UI, with
this file as the main file and queries.py added alongside it. Which schema
you create the Streamlit object in doesn't matter functionally -- the app
sets its own database/schema explicitly via queries.use_control_schema()
right below, rather than relying on wherever Snowsight happens to default
the session to.
"""

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

import queries

st.set_page_config(page_title="Ontology Refresh -- Control Plane", layout="wide")

session = get_active_session()
queries.use_control_schema(session)

ACTIONABLE_KINDS = ["", "ATTRIBUTE", "NODE_TYPE", "EDGE_TYPE"]


def _rerun() -> None:
    # st.rerun() replaced st.experimental_rerun() around Streamlit 1.27 --
    # falling back covers whichever version Snowflake's Streamlit runtime
    # pins for this account.
    try:
        st.rerun()
    except AttributeError:
        st.experimental_rerun()


def _blank_to_none(value):
    return value if value else None


def _render_proposal(row) -> None:
    proposal_id = row["PROPOSAL_ID"]
    source_object = f'{row["TABLE_SCHEMA"]}.{row["TABLE_NAME"]}'
    if row["COLUMN_NAME"]:
        source_object += f'.{row["COLUMN_NAME"]}'

    with st.expander(
        f'{row["FINAL_NAME"] or "(unnamed)"}  —  {row["FINAL_OBJECT_KIND"] or "kind not set"}',
        expanded=True,
    ):
        col_edit, col_context = st.columns([1, 1])

        with col_edit:
            st.caption("Your review")
            final_name = st.text_input(
                "Final name", value=row["FINAL_NAME"] or "", key=f"name_{proposal_id}"
            )
            current_kind = row["FINAL_OBJECT_KIND"] or ""
            kind_index = (
                ACTIONABLE_KINDS.index(current_kind)
                if current_kind in ACTIONABLE_KINDS
                else 0
            )
            final_kind = st.selectbox(
                "Final kind",
                ACTIONABLE_KINDS,
                index=kind_index,
                key=f"kind_{proposal_id}",
                help="Must be set to ATTRIBUTE, NODE_TYPE, or EDGE_TYPE before this can be approved.",
            )
            rationale = st.text_area(
                "Your rationale (optional)", key=f"rationale_{proposal_id}"
            )

        with col_context:
            st.caption("Rule engine & AI context")
            st.write(f"**Source object:** {source_object}")
            st.write(
                f"**Rule classification:** {row['RULE_OBJECT_KIND']} "
                f"(rule: {row['RULE_APPLIED']})"
            )
            st.write(f"**Rule-proposed name:** {row['PROPOSED_NAME'] or '(none)'}")
            if row["EDGE_FROM"] or row["EDGE_TO"]:
                st.write(f"**Edge endpoints:** {row['EDGE_FROM']} -> {row['EDGE_TO']}")
            if row["AI_RECOMMENDED_KIND"]:
                agree = "agreed" if row["AI_AGREES_WITH_RULE"] else "disagreed"
                # NULL AI_CONFIDENCE comes back from Snowpark's to_pandas() as
                # float NaN, not Python None -- `is not None` would miss it.
                if pd.notna(row["AI_CONFIDENCE"]):
                    st.write(
                        f"**AI review:** {agree} with the rule "
                        f"(recommended {row['AI_RECOMMENDED_KIND']}, "
                        f"confidence {row['AI_CONFIDENCE']:.2f})"
                    )
                else:
                    st.write(f"**AI review:** {agree} with the rule (recommended {row['AI_RECOMMENDED_KIND']})")
                if row["AI_RATIONALE"]:
                    st.write(f"**AI rationale:** {row['AI_RATIONALE']}")
                if row["AI_INDUSTRY_NOTE"]:
                    st.write(f"**Industry note:** {row['AI_INDUSTRY_NOTE']}")
            else:
                st.write("**AI review:** not yet reviewed")

        st.divider()
        col_approve, col_reject, col_defer = st.columns(3)

        def _decide(status: str) -> None:
            result = queries.record_decision(
                session,
                proposal_id=proposal_id,
                status=status,
                rationale=_blank_to_none(rationale),
                final_name=_blank_to_none(final_name),
                final_object_kind=_blank_to_none(final_kind),
            )
            if result == "OK":
                st.success(f"Recorded: {status}")
                _rerun()
            else:
                st.error(result)

        if col_approve.button("Approve", key=f"approve_{proposal_id}", type="primary"):
            _decide("APPROVED")
        if col_reject.button("Reject", key=f"reject_{proposal_id}"):
            _decide("REJECTED")
        if col_defer.button("Defer", key=f"defer_{proposal_id}"):
            _decide("DEFERRED")


def _render_generate_section() -> None:
    awaiting = queries.count_approved_awaiting_generation(session)

    col_status, col_button = st.columns([3, 1])
    with col_status:
        if awaiting:
            st.write(f"**{awaiting}** approved proposal(s) awaiting code generation.")
        else:
            st.write("No approved proposals are awaiting code generation right now.")
    with col_button:
        if st.button("Generate Code", disabled=(awaiting == 0), type="primary"):
            ontology_schema = queries.get_ontology_schema(session)
            if not ontology_schema:
                st.error(
                    "ERROR: ONTOLOGY_SCHEMA is not set in ORE_APP_CONFIG -- "
                    "run sql/03_refresh_engine/00_seed_baseline.sql."
                )
            else:
                before = queries.count_generated_artifacts(session)
                with st.spinner("Drafting code, then running the AI refine pass..."):
                    result = queries.generate_and_refine_artifacts(session, ontology_schema)
                after = queries.count_generated_artifacts(session)

                if result["generate"] == "OK" and result["refine"] == "OK":
                    st.success(f"Drafted {after - before} new artifact(s).")
                    _rerun()
                else:
                    st.error(f"Generate: {result['generate']}  |  Refine: {result['refine']}")


def _render_generated_artifact_group(group_df) -> None:
    first = group_df.iloc[0]
    label = (
        f'{first["FINAL_NAME"] or "(unnamed)"}  —  {first["FINAL_OBJECT_KIND"] or "kind not set"}'
        f"  ({len(group_df)} artifact(s))"
    )
    with st.expander(label, expanded=False):
        for _, row in group_df.iterrows():
            st.markdown(f"**{row['ARTIFACT_TYPE']}**  ·  dev status: `{row['DEV_STATUS']}`")
            col_template, col_refined = st.columns(2)
            with col_template:
                st.caption("Template (mechanical draft)")
                st.code(row["TEMPLATE_SQL"] or "", language="sql")
            with col_refined:
                st.caption("AI-refined")
                st.code(row["AI_REFINED_SQL"] or "(not yet refined)", language="sql")
            if row["AI_NOTES"]:
                st.caption(f"AI notes: {row['AI_NOTES']}")
            st.divider()


def _render_generate_tab() -> None:
    st.subheader("Generate code for approved proposals")
    _render_generate_section()
    st.divider()

    st.subheader("Generated code")
    st.caption(
        "Read-only -- draft SQL for a developer to review before any of it runs against "
        "ONT_* tables. Nothing on this tab writes anything."
    )
    artifacts = queries.fetch_generated_artifacts(session)
    if artifacts.empty:
        st.info("No code has been generated yet.")
        return

    n_proposals = artifacts["PROPOSAL_ID"].nunique()
    st.write(f"**{n_proposals}** proposal(s), **{len(artifacts)}** artifact(s) total.")
    for _, group in artifacts.groupby("PROPOSAL_ID", sort=False):
        _render_generated_artifact_group(group)


def _render_review_tab() -> None:
    st.subheader("Pending review")
    proposals = queries.fetch_pending_proposals(session)

    if proposals.empty:
        st.info("No pending proposals right now.")
        return

    st.write(f"**{len(proposals)}** proposal(s) awaiting review.")
    for _, row in proposals.iterrows():
        _render_proposal(row)


def main() -> None:
    st.title("Ontology Refresh Engine -- Control Plane")
    st.caption(
        "Review candidate ontology changes detected from source schema evolution. "
        "Approving drafts code for a developer to review separately -- nothing here "
        "touches ONT_* tables directly."
    )

    # Streamlit does not reliably preserve which tab was selected across a
    # rerun in older versions -- after Approve/Reject/Defer or Generate Code,
    # the page may land back on the first tab rather than staying put.
    # Cosmetic, not functional.
    tab_review, tab_generate = st.tabs(["Review Proposals", "Generate Code"])
    with tab_review:
        _render_review_tab()
    with tab_generate:
        _render_generate_tab()


main()
