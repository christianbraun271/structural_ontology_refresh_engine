-- =============================================================================
-- 01_detect_information_schema.sql   [PRIMARY detection path -- demo default]
-- Real-time, no special grant needed -- assumed by this demo since it only
-- requires ordinary SELECT on INFORMATION_SCHEMA for schemas you can already
-- see. INFORMATION_SCHEMA has no history, so ORE_SCHEMA_FINGERPRINT is
-- maintained here as the "last known state" to diff against -- a dropped
-- object vanishes immediately from INFORMATION_SCHEMA, so a fingerprint row
-- with no current match is how we notice a drop.
--
-- See 01b_detect_account_usage.sql for the optional upgrade path (native
-- history, no fingerprint table to maintain, but needs an extra grant and
-- has latency). Run exactly one of 01 / 01b per cycle, not both -- they
-- don't share state.
--
-- Requires ORE_SCHEMA_FINGERPRINT, ORE_DETECTED_CHANGES, and ORE_SOURCE_SCOPE
-- to already exist (sql/02_ontology/01_ontology_core_ddl.sql) -- this script
-- only reads and updates them, it doesn't create them.
--
-- Produces rows in ORE_DETECTED_CHANGES for this run and prints the RUN_ID
-- for your own reference -- you don't need to carry it anywhere by hand.
-- 02_classify_columns.sql / 03_classify_new_tables_proc.sql / 04 / 05 each
-- independently pick up "the most recent run in ORE_DETECTED_CHANGES" on
-- their own, so they work whether run in this same session or a fresh one.
--
-- IDENTIFIER() does not accept an expression (e.g. $DEMO_DB || '.SCHEMA.TABLE')
-- inline -- the concatenated name has to be precomputed into its own
-- variable first, then passed to IDENTIFIER() bare. See _TBL below.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB        = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

SET run_id = (SELECT UUID_STRING());

-- Which tables count as "source" tables is config-driven, not a fixed schema
-- name -- see ORE_SOURCE_SCOPE in sql/02_ontology/01_ontology_core_ddl.sql.
-- This is what keeps ONT_/ORE_ tables from being mistaken for source tables
-- when everything shares one schema.

-- NOTE on first-ever run: ORE_SCHEMA_FINGERPRINT starts empty, so running
-- this script before a baseline exists would report the ENTIRE current
-- source schema as new tables -- fine for a real first-time onboarding, but
-- wrong for this demo's v1-then-v2 flow, where v1 needs to already be the
-- known baseline before this runs against the v2 delta. Run
-- 00_seed_baseline.sql once, right after loading v1 (sql/02_ontology),
-- before ever running this script for real -- this script itself is only
-- meant to run against a delta (like the v2 one), not to establish the
-- baseline.
SET _TBL = $DEMO_DB || '.INFORMATION_SCHEMA.COLUMNS';
CREATE OR REPLACE TEMPORARY TABLE CURRENT_SCHEMA_STATE AS
    SELECT c.TABLE_SCHEMA, c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
    FROM IDENTIFIER($_TBL) c
    WHERE EXISTS (
            SELECT 1 FROM ORE_SOURCE_SCOPE inc
            WHERE inc.FILTER_TYPE = 'INCLUDE'
              AND c.TABLE_SCHEMA LIKE inc.SCHEMA_PATTERN
              AND c.TABLE_NAME   LIKE inc.TABLE_PATTERN
          )
      AND NOT EXISTS (
            SELECT 1 FROM ORE_SOURCE_SCOPE exc
            WHERE exc.FILTER_TYPE = 'EXCLUDE'
              AND c.TABLE_SCHEMA LIKE exc.SCHEMA_PATTERN
              AND c.TABLE_NAME   LIKE exc.TABLE_PATTERN
          );

-- Column-level deltas: new, dropped, or type-changed
INSERT INTO ORE_DETECTED_CHANGES (RUN_ID, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHANGE_TYPE)
SELECT
    $run_id,
    COALESCE(c.TABLE_SCHEMA, f.TABLE_SCHEMA),
    COALESCE(c.TABLE_NAME, f.TABLE_NAME),
    COALESCE(c.COLUMN_NAME, f.COLUMN_NAME),
    c.DATA_TYPE,
    CASE
        WHEN f.COLUMN_NAME IS NULL THEN 'NEW_COLUMN'
        WHEN c.COLUMN_NAME IS NULL THEN 'DROPPED_COLUMN'
        WHEN c.DATA_TYPE <> f.DATA_TYPE THEN 'TYPE_CHANGED'
    END AS CHANGE_TYPE
FROM CURRENT_SCHEMA_STATE c
FULL OUTER JOIN ORE_SCHEMA_FINGERPRINT f
  ON c.TABLE_SCHEMA = f.TABLE_SCHEMA
 AND c.TABLE_NAME   = f.TABLE_NAME
 AND c.COLUMN_NAME  = f.COLUMN_NAME
WHERE (f.COLUMN_NAME IS NULL AND c.COLUMN_NAME IS NOT NULL)   -- new
   OR (c.COLUMN_NAME IS NULL AND f.COLUMN_NAME IS NOT NULL)   -- dropped
   OR (c.DATA_TYPE IS DISTINCT FROM f.DATA_TYPE);              -- type changed

-- Table-level: a "new table" is one where every column just showed up as NEW
-- and the table itself had no fingerprint row at all.
INSERT INTO ORE_DETECTED_CHANGES (RUN_ID, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHANGE_TYPE)
SELECT DISTINCT $run_id, c.TABLE_SCHEMA, c.TABLE_NAME, NULL, NULL, 'NEW_TABLE'
FROM CURRENT_SCHEMA_STATE c
WHERE NOT EXISTS (
    SELECT 1 FROM ORE_SCHEMA_FINGERPRINT f
    WHERE f.TABLE_SCHEMA = c.TABLE_SCHEMA AND f.TABLE_NAME = c.TABLE_NAME
);

-- Demote the per-column NEW_COLUMN rows that belong to a table just flagged
-- NEW_TABLE above -- same reasoning as the ACCOUNT_USAGE path: a brand-new
-- table is classified as a unit, not column by column.
DELETE FROM ORE_DETECTED_CHANGES
WHERE RUN_ID = $run_id
  AND CHANGE_TYPE = 'NEW_COLUMN'
  AND (TABLE_SCHEMA, TABLE_NAME) IN (
      SELECT TABLE_SCHEMA, TABLE_NAME FROM ORE_DETECTED_CHANGES
      WHERE RUN_ID = $run_id AND CHANGE_TYPE = 'NEW_TABLE'
  );

-- Refresh the fingerprint to the current state for next run's diff. Deleted
-- by the same scope predicate used to build CURRENT_SCHEMA_STATE (rather
-- than a fixed schema name), so this stays correct if scope ever spans
-- multiple schemas.
DELETE FROM ORE_SCHEMA_FINGERPRINT f
WHERE EXISTS (
        SELECT 1 FROM ORE_SOURCE_SCOPE inc
        WHERE inc.FILTER_TYPE = 'INCLUDE'
          AND f.TABLE_SCHEMA LIKE inc.SCHEMA_PATTERN
          AND f.TABLE_NAME   LIKE inc.TABLE_PATTERN
      )
  AND NOT EXISTS (
        SELECT 1 FROM ORE_SOURCE_SCOPE exc
        WHERE exc.FILTER_TYPE = 'EXCLUDE'
          AND f.TABLE_SCHEMA LIKE exc.SCHEMA_PATTERN
          AND f.TABLE_NAME   LIKE exc.TABLE_PATTERN
      );
INSERT INTO ORE_SCHEMA_FINGERPRINT (TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE)
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM CURRENT_SCHEMA_STATE;

SELECT $run_id AS RUN_ID, COUNT(*) AS CHANGES_DETECTED
FROM ORE_DETECTED_CHANGES WHERE RUN_ID = $run_id;
