-- =============================================================================
-- 01_reset_to_v1.sql
-- Gets the demo back to a clean, repeatable v1 baseline so the whole
-- detect -> classify -> review cycle can be re-run from scratch.
--
-- Deliberately does NOT duplicate the v1 table/data definitions -- those
-- already live in exactly one place (sql/01_source/01_ddl_v1.sql and
-- 02_sample_data_v1.sql), and both are already idempotent (CREATE OR REPLACE
-- TABLE + plain INSERTs). Duplicating that DDL here would just create a
-- second copy that has to be hand-kept in sync forever -- the same drift
-- risk a dedicated "undo the v2 delta" script would have. Instead, this
-- script does only the two things those existing scripts DON'T cover:
--   1. Drop the tables that only exist in v2 (01_ddl_v1.sql has no statement
--      that would remove a table it never defined).
--   2. Clear the refresh engine's run-state, so a fresh detection run
--      doesn't get deduped away by leftover proposals from the last cycle
--      (05_persist_candidates.sql dedupes by a content hash -- a stale
--      APPROVED/REJECTED/PENDING row for the same table/column would
--      silently suppress the new one).
--
-- REQUIRED RUN ORDER for a full reset:
--   1. This script (drops v2-only tables + clears run-state) -- do this
--      FIRST, before step 2, so no FK from a v2-only table is still
--      pointing at SRC_PROVIDER_PROFESSIONAL when it gets replaced.
--   2. sql/01_source/01_ddl_v1.sql      (restores SRC_PROVIDER_PROFESSIONAL
--                                        to its v1 shape -- CREATE OR REPLACE
--                                        drops the v2 columns/FK for you)
--   3. sql/01_source/02_sample_data_v1.sql  (reloads v1 sample rows)
--   4. sql/03_refresh_engine/00_seed_baseline.sql  (re-fingerprints the
--      now-v1-shaped source schema as the known baseline)
-- Then sql/01_source/03_ddl_v2_delta.sql can be re-applied to re-run the
-- demo scenario from a clean starting point.
--
-- NOT reset (deliberately):
--   - ORE_SOURCE_SCOPE / ORE_APP_CONFIG -- genuine config, not run-state.
--     00_seed_baseline.sql only seeds ORE_SOURCE_SCOPE if empty, so it's
--     never touched by a normal reset cycle.
--   - ORE_DECISION_AUDIT_LOG -- kept intact across resets for now, so BA
--     decision history accumulates across demo runs rather than
--     disappearing. Revisit if that turns out to be the wrong default.
--
-- SCOPE: this resets everything through codegen (ORE_CANDIDATE_PROPOSALS and
-- ORE_GENERATED_ARTIFACTS). It does NOT undo anything sql/06_apply would
-- eventually do (new node/edge types actually created and loaded into
-- ONT_NODE_TYPES/ONT_EDGE_TYPES/ONT_KG_NODE/ONT_KG_EDGE) -- that script
-- doesn't exist yet, so there's nothing to undo there today. Once it does,
-- this script's scope should be revisited.
--
-- Right after running THIS script (before steps 2-4 above), SRC_PROVIDER_
-- PROFESSIONAL will still show its v2 columns -- that's expected; only
-- re-running 01_ddl_v1.sql actually restores it.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB        = 'ORE_DEMO_DB';
SET SRC_SCHEMA     = 'ORE_SRC';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);

-- -----------------------------------------------------------------------------
-- 1. Drop v2-only tables (in SRC_SCHEMA), and confirm while still in that
--    schema context -- using the current-schema form of SHOW TABLES
--    (SHOW TABLES LIKE '...', no IN clause) for consistency with the rest
--    of this project.
-- -----------------------------------------------------------------------------
USE SCHEMA IDENTIFIER($SRC_SCHEMA);

DROP TABLE IF EXISTS SRC_PROFESSIONAL_LANGUAGE;
DROP TABLE IF EXISTS SRC_PROFESSIONAL_LOCATION_ASSIGNMENT;

-- expect zero rows back from each -- confirms the drop
SHOW TABLES LIKE 'SRC_PROFESSIONAL_LANGUAGE';
SHOW TABLES LIKE 'SRC_PROFESSIONAL_LOCATION_ASSIGNMENT';

-- -----------------------------------------------------------------------------
-- 2. Clear refresh-engine run-state (in CONTROL_SCHEMA)
-- -----------------------------------------------------------------------------
USE SCHEMA IDENTIFIER($CONTROL_SCHEMA);

-- Cleared before ORE_CANDIDATE_PROPOSALS (its logical, unenforced parent) --
-- order doesn't matter for correctness here, just reads more naturally as
-- child-before-parent.
DELETE FROM ORE_GENERATED_ARTIFACTS;
DELETE FROM ORE_CANDIDATE_PROPOSALS;
DELETE FROM ORE_CLASSIFIED_CANDIDATES;
DELETE FROM ORE_DETECTED_CHANGES;
-- ORE_SCHEMA_FINGERPRINT and ORE_REFRESH_CONTROL are left as-is here -- they
-- still reflect the (soon to be wrong) v2 shape until step 4 re-seeds them,
-- which fully overwrites both anyway. No point clearing them twice.

-- Sanity check -- all four should read 0
SELECT
    (SELECT COUNT(*) FROM ORE_DETECTED_CHANGES)      AS DETECTED_CHANGES_REMAINING,
    (SELECT COUNT(*) FROM ORE_CLASSIFIED_CANDIDATES) AS CLASSIFIED_CANDIDATES_REMAINING,
    (SELECT COUNT(*) FROM ORE_CANDIDATE_PROPOSALS)   AS CANDIDATE_PROPOSALS_REMAINING,
    (SELECT COUNT(*) FROM ORE_GENERATED_ARTIFACTS)   AS GENERATED_ARTIFACTS_REMAINING;

SELECT 'Next: re-run 01_ddl_v1.sql, then 02_sample_data_v1.sql, then 00_seed_baseline.sql.' AS NEXT_STEPS;
