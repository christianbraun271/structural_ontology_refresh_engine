-- =============================================================================
-- 00_seed_baseline.sql
-- Stamps the current source schema as the refresh engine's known baseline,
-- and seeds ORE_SOURCE_SCOPE with its default scope if not already set.
--
-- Run this exactly once, right after onboarding v1
-- (sql/01_source/01_ddl_v1.sql + sql/02_ontology), and BEFORE ever applying
-- sql/01_source/03_ddl_v2_delta.sql or running a detection script for real.
--
-- Without this step, the first detection run would see every v1 table/column
-- as brand new -- because from the refresh engine's point of view, nothing
-- has been seen yet -- even though you just manually onboarded all of v1 by
-- hand. This script closes that gap by recording v1's current shape as
-- "already known" before any real detection ever runs.
--
-- It seeds state for BOTH detection paths at once, so it doesn't matter yet
-- which one (01 or 01b) you end up using:
--   - ORE_SCHEMA_FINGERPRINT <- a full snapshot of the current in-scope
--     tables/columns (what 01b diffs against).
--   - ORE_REFRESH_CONTROL.LAST_RUN_TS <- CURRENT_TIMESTAMP() (what 01 diffs
--     against). Every v1 object's CREATED timestamp is necessarily earlier
--     than this, so a later ACCOUNT_USAGE run correctly treats v1 as known
--     and only the v2 delta as new.
--
-- "In scope" is defined by ORE_SOURCE_SCOPE (see sql/02_ontology/01_ontology_core_ddl.sql
-- for the matching rules) -- this matters because, in a single-shared-schema
-- deployment, ONT_/ORE_ tables sit alongside SRC_ tables and must NOT be
-- fingerprinted as if they were sources.
--
-- Re-running this script: the fingerprint/watermark portions are safe to
-- re-run (they fully overwrite to the current state -- also how you'd
-- deliberately move the baseline forward later, e.g. after a batch of
-- approved changes has been applied). The scope-seeding portion only inserts
-- a default row if ORE_SOURCE_SCOPE is completely empty, so it won't
-- clobber scope rows you've since customized.
--
-- IDENTIFIER() does not accept an expression (e.g. $DEMO_DB || '.SCHEMA.TABLE')
-- inline -- the concatenated name has to be precomputed into its own
-- variable first, then passed to IDENTIFIER() bare. See _TBL below.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB         = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA  = 'ORE_CONTROL';
SET SRC_SCHEMA      = 'ORE_SRC';
SET ONTOLOGY_SCHEMA = 'ORE_ONTOLOGY';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

-- -----------------------------------------------------------------------------
-- Seed ORE_APP_CONFIG.ONTOLOGY_SCHEMA (only if not already set)
-- -----------------------------------------------------------------------------
-- NOTE this is the only cross-script config value that belongs in
-- ORE_APP_CONFIG -- DEMO_DB/CONTROL_SCHEMA never can, since that table lives
-- inside that very database/schema (you have to already know them to even
-- query it -- a bootstrapping problem, not a style choice). Every SQL script
-- keeps its own local `SET DEMO_DB/CONTROL_SCHEMA/ONTOLOGY_SCHEMA = ...`
-- exactly as before; this key exists solely for the future Control Plane
-- Streamlit app, which -- unlike a one-shot script -- is a long-lived
-- process with no natural "SET at the top" moment, and needs to know
-- ONTOLOGY_SCHEMA at runtime to pass into CALL GENERATE_ARTIFACTS(...).
INSERT INTO ORE_APP_CONFIG (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
SELECT 'ONTOLOGY_SCHEMA', $ONTOLOGY_SCHEMA,
       'The ONTOLOGY schema name -- read by the Control Plane app at runtime (e.g. to CALL GENERATE_ARTIFACTS). Not consumed by any SQL pipeline script -- those each set their own local SET ONTOLOGY_SCHEMA instead.'
WHERE NOT EXISTS (SELECT 1 FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'ONTOLOGY_SCHEMA');

-- -----------------------------------------------------------------------------
-- Seed ORE_SOURCE_SCOPE with its default (only if empty -- see header)
-- -----------------------------------------------------------------------------
-- Demo default: only the actual source schema ($SRC_SCHEMA), and within it,
-- only tables named SRC_*. Deliberately NOT SCHEMA_PATTERN = '%' -- that
-- would also match a same-named SRC_-prefixed table sitting in some
-- unrelated schema elsewhere in the database, which the TABLE_PATTERN alone
-- can't rule out. Pinning SCHEMA_PATTERN to the real source schema removes
-- that risk entirely, at zero cost, since we already know which schema the
-- source tables are supposed to live in.
-- For a real deployment with its own schema separation and no SRC_ naming
-- convention, replace this row with one INCLUDE row per real source schema
-- instead (SCHEMA_PATTERN = '<your_schema>', TABLE_PATTERN = '%').
--
-- TRIM($SRC_SCHEMA, '"'): if your schema name needs double-quoting to
-- reference (e.g. it contains dots or @ characters), $SRC_SCHEMA holds those
-- literal quote characters -- correct for IDENTIFIER($SRC_SCHEMA) elsewhere,
-- since that needs the quoted form to parse the name correctly. But
-- SCHEMA_PATTERN here is matched with a plain LIKE against
-- INFORMATION_SCHEMA/ACCOUNT_USAGE's TABLE_SCHEMA column, which stores the
-- schema's actual name WITHOUT surrounding quotes -- so the quoted form
-- would never match. TRIM strips a leading/trailing '"' if present, and is
-- a no-op if your schema name has none, so this is safe either way.
INSERT INTO ORE_SOURCE_SCOPE (FILTER_TYPE, SCHEMA_PATTERN, TABLE_PATTERN, DESCRIPTION)
SELECT 'INCLUDE', TRIM($SRC_SCHEMA, '"'), 'SRC_%',
       'Demo default: the ' || TRIM($SRC_SCHEMA, '"') || ' schema, SRC_-prefixed tables only.'
WHERE NOT EXISTS (SELECT 1 FROM ORE_SOURCE_SCOPE);

-- -----------------------------------------------------------------------------
-- Seed ORE_SCHEMA_FINGERPRINT (for 01_detect_information_schema.sql)
-- -----------------------------------------------------------------------------
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

SET _TBL = $DEMO_DB || '.INFORMATION_SCHEMA.COLUMNS';
INSERT INTO ORE_SCHEMA_FINGERPRINT (TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE)
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

-- -----------------------------------------------------------------------------
-- Seed ORE_REFRESH_CONTROL (for 01b_detect_account_usage.sql)
-- -----------------------------------------------------------------------------
DELETE FROM ORE_REFRESH_CONTROL;
INSERT INTO ORE_REFRESH_CONTROL (LAST_RUN_TS)
SELECT CURRENT_TIMESTAMP();

-- -----------------------------------------------------------------------------
-- Sanity check -- confirm every v1 table got fingerprinted before you move on
-- -----------------------------------------------------------------------------
SELECT TABLE_SCHEMA, TABLE_NAME, COUNT(*) AS COLUMN_COUNT
FROM ORE_SCHEMA_FINGERPRINT
GROUP BY TABLE_SCHEMA, TABLE_NAME
ORDER BY TABLE_SCHEMA, TABLE_NAME;
