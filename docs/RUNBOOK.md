# Ontology Refresh Engine — Run Book

One-page checklist for running this demo end to end. Run everything in order
top to bottom on first setup; for a repeat run, jump to **Cycle** below.

## 1. One-time setup

- [ ] `sql/00_setup/00_create_sandbox.sql` — create (or point at) the database, warehouse, and schemas. Fill in your warehouse name; uncomment the `CREATE DATABASE`/`CREATE SCHEMA` block only if you have the privilege, otherwise fill in existing names.
- [ ] `sql/01_source/01_ddl_v1.sql` — create the v1 source tables.
- [ ] `sql/01_source/02_sample_data_v1.sql` — load v1 sample data.
- [ ] `sql/02_ontology/01_ontology_core_ddl.sql` — create the `ONT_*` (ontology) and `ORE_*` (refresh engine) tables.
- [ ] `sql/02_ontology/02_seed_types_and_views.sql` — register the v1 node/edge types and their views.
- [ ] `sql/02_ontology/03_initial_load_v1.sql` — populate `ONT_KG_NODE`/`ONT_KG_EDGE` from v1.
- [ ] `sql/03_refresh_engine/00_seed_baseline.sql` — **stamp v1 as the known baseline.** Must run before any detection cycle, or the first detect run will report all of v1 as "new."
- [ ] `sql/04_control_plane/01_record_decision_proc.sql` — create the `RECORD_DECISION` procedure.
- [ ] `sql/05_codegen/01_generate_artifacts_proc.sql` — create the `GENERATE_ARTIFACTS` procedure.
- [ ] `sql/05_codegen/02_ai_refine_artifacts.sql` — create the `REFINE_ARTIFACTS` procedure.
- [ ] Deploy `streamlit_app/streamlit_app.py` + `streamlit_app/queries.py` as a Streamlit-in-Snowflake app (Snowsight → **+ Streamlit App**, add both files). The schema you create it in doesn't matter — the app sets its own database/schema at startup.

## 2. Cycle — detect a schema change, review, generate

- [ ] `sql/01_source/03_ddl_v2_delta.sql` — apply the demo's schema-change scenario (new column, new self-referencing FK, new junction table, new ambiguous table).
- [ ] `sql/03_refresh_engine/01_detect_information_schema.sql` — detect the change. (Or `01b_detect_account_usage.sql` if you have the `IMPORTED PRIVILEGES` grant — see that script's header.)
- [ ] `sql/03_refresh_engine/02_classify_columns.sql` — rule-based classification of column-level changes.
- [ ] `sql/03_refresh_engine/03_classify_new_tables_proc.sql` — rule-based classification of new tables (creates + calls `CLASSIFY_NEW_TABLES`).
- [ ] `sql/03_refresh_engine/04_ai_review_candidates.sql` — AI review pass over the rule engine's output.
- [ ] `sql/03_refresh_engine/05_persist_candidates.sql` — persist as proposals into the BA review queue (dedupes automatically).
- [ ] **Open the Streamlit app → Review Proposals tab.** Edit final name/kind as needed, Approve / Reject / Defer each proposal.
- [ ] **Streamlit app → Generate Code tab.** Click **Generate Code** to draft + AI-refine SQL for every approved proposal. Review the generated code inline (read-only).

## 3. Optional

- [ ] `sql/05_codegen/03_export_artifacts_for_review.sql` — export all generated artifacts as one JSON blob, for an offline/external review.
- [ ] Edit `ORE_APP_CONFIG` directly to change the AI model, industry context, or codegen header (`CONFIG_KEY` = `AI_MODEL` / `INDUSTRY_CONTEXT` / `CODEGEN_HEADER`).
- [ ] Edit `ORE_SOURCE_SCOPE` directly to change which tables the engine treats as sources (e.g. for a real deployment, replace the demo's `SRC_*`-prefix default with one `INCLUDE` row per real source schema).

## 4. Resetting to run the cycle again

- [ ] `sql/07_reset/01_reset_to_v1.sql` — drops the v2-only tables and clears all refresh-engine run-state (`ORE_DETECTED_CHANGES`, `ORE_CLASSIFIED_CANDIDATES`, `ORE_CANDIDATE_PROPOSALS`, `ORE_GENERATED_ARTIFACTS`). Config (`ORE_APP_CONFIG`, `ORE_SOURCE_SCOPE`) and the decision audit log (`ORE_DECISION_AUDIT_LOG`) are deliberately left untouched.
- [ ] Re-run, **in this order**: `sql/01_source/01_ddl_v1.sql` → `sql/01_source/02_sample_data_v1.sql` → `sql/03_refresh_engine/00_seed_baseline.sql`.
- [ ] Resume at **Cycle** above.

## Not in scope (by design)

- Actually applying generated/reviewed code to `ONT_*` tables (the second, technical human gate) — deliberately deferred; nothing under `sql/06_apply` exists yet.
- Scheduling/automation (Tasks, cron) — this demo is run manually end to end; automating the detection cycle is a natural next step once the manual flow is validated.
