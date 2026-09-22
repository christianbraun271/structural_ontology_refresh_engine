-- =============================================================================
-- 01b_detect_account_usage.sql   [OPTIONAL UPGRADE PATH -- not the demo default]
-- Weekly schema crawl via SNOWFLAKE.ACCOUNT_USAGE -- native CREATED/DELETED
-- history, so no snapshot table to maintain. Tradeoff: latency up to ~3hrs,
-- and requires the IMPORTED PRIVILEGES grant noted in
-- sql/00_setup/00_create_sandbox.sql.
--
-- This demo assumes INFORMATION_SCHEMA-only access by default -- use
-- 01_detect_information_schema.sql for that. This script is kept as the
-- documented upgrade path for later, once that grant is available. Run
-- exactly one of 01 / 01b per cycle, not both -- they don't share state.
--
-- Requires ORE_REFRESH_CONTROL, ORE_DETECTED_CHANGES, and ORE_SOURCE_SCOPE to
-- already exist (sql/02_ontology/01_ontology_core_ddl.sql) -- this script
-- only reads and updates them, it doesn't create them.
--
-- Which tables count as "source" tables is config-driven via
-- ORE_SOURCE_SCOPE, not a fixed schema name -- see that table's comment in
-- 01_ontology_core_ddl.sql. Note ORE_SOURCE_SCOPE only scopes schema + table
-- name; TABLE_CATALOG below is still a fixed single-database assumption (see
-- ORE_SOURCE_SCOPE's comment for the multi-database extension point).
--
-- Produces rows in ORE_DETECTED_CHANGES for this run and prints the RUN_ID
-- for your own reference -- you don't need to carry it anywhere by hand.
-- 02_classify_columns.sql / 03_classify_new_tables_proc.sql / 04 / 05 each
-- independently pick up "the most recent run in ORE_DETECTED_CHANGES" on
-- their own, so they work whether run in this same session or a fresh one.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB        = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

-- Seed the watermark on first-ever run (belt-and-suspenders fallback --
-- normally 00_seed_baseline.sql has already stamped this before you ever get
-- here). NOTE: without that baseline step, LAST_RUN_TS defaults to
-- 1970-01-01 and this run would report the ENTIRE current source schema as
-- "new" -- fine for a real first-time onboarding, but wrong for this demo's
-- v1-then-v2 flow, where v1 needs to already be the known baseline before
-- this runs against the v2 delta. Run 00_seed_baseline.sql once, right after
-- loading v1, before ever running this script for real.
INSERT INTO ORE_REFRESH_CONTROL (LAST_RUN_TS)
SELECT '1970-01-01'::TIMESTAMP_NTZ
WHERE NOT EXISTS (SELECT 1 FROM ORE_REFRESH_CONTROL);

SET run_id = (SELECT UUID_STRING());
SET last_run_ts = (SELECT LAST_RUN_TS FROM ORE_REFRESH_CONTROL LIMIT 1);

-- New / dropped columns on tables that already existed at LAST_RUN_TS.
-- (Columns on brand-new tables are excluded here -- they're picked up as
-- part of the NEW_TABLE candidate below and classified as a unit by
-- 03_classify_new_tables_proc.sql instead of one-by-one as attributes.)
INSERT INTO ORE_DETECTED_CHANGES (RUN_ID, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHANGE_TYPE)
SELECT
    $run_id,
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    c.COLUMN_NAME,
    c.DATA_TYPE,
    CASE
        WHEN c.DELETED IS NOT NULL AND c.DELETED > $last_run_ts THEN 'DROPPED_COLUMN'
        WHEN c.CREATED > $last_run_ts THEN 'NEW_COLUMN'
    END AS CHANGE_TYPE
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t
  ON t.TABLE_ID = c.TABLE_ID
WHERE c.TABLE_CATALOG = $DEMO_DB
  AND EXISTS (
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
      )
  AND t.DELETED IS NULL                 -- table itself still live
  AND t.CREATED <= $last_run_ts         -- table existed before this run -> a column-level delta, not a new table
  AND (c.CREATED > $last_run_ts OR (c.DELETED IS NOT NULL AND c.DELETED > $last_run_ts));

-- New tables since last run.
INSERT INTO ORE_DETECTED_CHANGES (RUN_ID, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHANGE_TYPE)
SELECT DISTINCT
    $run_id, t.TABLE_SCHEMA, t.TABLE_NAME, NULL, NULL, 'NEW_TABLE'
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
WHERE t.TABLE_CATALOG = $DEMO_DB
  AND EXISTS (
        SELECT 1 FROM ORE_SOURCE_SCOPE inc
        WHERE inc.FILTER_TYPE = 'INCLUDE'
          AND t.TABLE_SCHEMA LIKE inc.SCHEMA_PATTERN
          AND t.TABLE_NAME   LIKE inc.TABLE_PATTERN
      )
  AND NOT EXISTS (
        SELECT 1 FROM ORE_SOURCE_SCOPE exc
        WHERE exc.FILTER_TYPE = 'EXCLUDE'
          AND t.TABLE_SCHEMA LIKE exc.SCHEMA_PATTERN
          AND t.TABLE_NAME   LIKE exc.TABLE_PATTERN
      )
  AND t.DELETED IS NULL
  AND t.CREATED > $last_run_ts;

UPDATE ORE_REFRESH_CONTROL SET LAST_RUN_TS = CURRENT_TIMESTAMP();

SELECT $run_id AS RUN_ID, COUNT(*) AS CHANGES_DETECTED
FROM ORE_DETECTED_CHANGES WHERE RUN_ID = $run_id;
