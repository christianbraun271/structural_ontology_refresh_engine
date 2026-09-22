-- =============================================================================
-- 02_classify_columns.sql
-- Column-level classification rules -- the flat, deterministic part of
-- classification: a plain INSERT with a CASE WHEN and a join to FK metadata.
-- Table-level rules (node vs. junction) are handled separately by
-- 03_classify_new_tables_proc.sql, since they need real control flow.
--
-- Rules applied here:
--   - New non-FK scalar column           -> ATTRIBUTE   (rule: COLUMN_TO_ATTRIBUTE)
--   - New FK column (incl. self-referencing, which becomes a self-loop edge
--     since EDGE_FROM = EDGE_TO in that case) -> EDGE_TYPE (rule: FK_TO_EDGE)
--
-- Deliberately NOT handled here (out of scope for this demo, not silently
-- ignored): DROPPED_COLUMN and TYPE_CHANGED changes are detected (see
-- ORE_DETECTED_CHANGES) but never classified into a candidate -- retiring an
-- attribute or migrating its type is a materially different, riskier
-- operation than adding one, and isn't one of the four scenarios this demo
-- models. A real deployment would want an explicit proposal type for those.
--
-- Columns belonging to a table that is itself brand new this run are also
-- skipped here -- 03_classify_new_tables_proc.sql classifies a new table as
-- a unit (node, junction, or flagged), not column-by-column.
--
-- Edge naming: an edge type's proposed name is derived from the FK column's
-- own name (stripped of a trailing _ID/_CODE), not from the table pair --
-- this is what lets two different FK columns between the same two tables
-- (e.g. a billing-provider FK and a rendering-provider FK, both -> PROVIDER)
-- become two distinct edge type candidates instead of colliding into one.
-- Keying by column role rather than table pair is what makes that possible.
--
-- Run this after a detection script (01 or 01b) has populated
-- ORE_DETECTED_CHANGES for the run you want classified -- it always operates
-- on the most recent run, so nothing needs to be carried over by hand.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB         = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA  = 'ORE_CONTROL';
SET ONTOLOGY_SCHEMA = 'ORE_ONTOLOGY';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

SET run_id = (SELECT RUN_ID FROM ORE_DETECTED_CHANGES ORDER BY DETECTED_TS DESC LIMIT 1);

-- FK lookup: which (schema, table, column) triples are foreign keys, and
-- what do they reference.
--
-- Snowflake has no INFORMATION_SCHEMA.KEY_COLUMN_USAGE -- that's a standard
-- ANSI view in Postgres/MySQL/SQL Server, not something Snowflake exposes.
-- Snowflake's mechanism for FK column-level detail is the SHOW IMPORTED KEYS
-- command instead, consumed via TABLE(RESULT_SCAN(LAST_QUERY_ID())) to turn
-- its output into a queryable result set -- there is no equivalent
-- plain-SELECT-able view for this. SHOW command output columns come back
-- lowercase and need double-quoting to reference exactly.
-- See https://docs.snowflake.com/en/sql-reference/sql/show-imported-keys
-- for the full column list.
SHOW IMPORTED KEYS IN DATABASE;

CREATE OR REPLACE TEMPORARY TABLE FK_LOOKUP AS
SELECT
    "fk_schema_name" AS TABLE_SCHEMA,
    "fk_table_name"  AS TABLE_NAME,
    "fk_column_name" AS COLUMN_NAME,
    "pk_schema_name" AS REF_TABLE_SCHEMA,
    "pk_table_name"  AS REF_TABLE_NAME
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- -----------------------------------------------------------------------------
-- Rule: new non-FK scalar column -> ATTRIBUTE
-- -----------------------------------------------------------------------------
INSERT INTO ORE_CLASSIFIED_CANDIDATES (
    RUN_ID, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
    OBJECT_KIND, RULE_APPLIED, PROPOSED_NAME, RAW_DETAILS
)
SELECT
    dc.RUN_ID, dc.TABLE_SCHEMA, dc.TABLE_NAME, dc.COLUMN_NAME,
    'ATTRIBUTE', 'COLUMN_TO_ATTRIBUTE', LOWER(dc.COLUMN_NAME),
    OBJECT_CONSTRUCT('data_type', dc.DATA_TYPE, 'change_type', dc.CHANGE_TYPE)
FROM ORE_DETECTED_CHANGES dc
LEFT JOIN FK_LOOKUP fk
  ON fk.TABLE_SCHEMA = dc.TABLE_SCHEMA
 AND fk.TABLE_NAME   = dc.TABLE_NAME
 AND fk.COLUMN_NAME  = dc.COLUMN_NAME
WHERE dc.RUN_ID = $run_id
  AND dc.CHANGE_TYPE = 'NEW_COLUMN'
  AND fk.COLUMN_NAME IS NULL
  AND NOT EXISTS (
        SELECT 1 FROM ORE_DETECTED_CHANGES nt
        WHERE nt.RUN_ID = dc.RUN_ID AND nt.CHANGE_TYPE = 'NEW_TABLE'
          AND nt.TABLE_SCHEMA = dc.TABLE_SCHEMA AND nt.TABLE_NAME = dc.TABLE_NAME
      );

-- -----------------------------------------------------------------------------
-- Rule: new FK column -> EDGE_TYPE (self-referencing FKs become a self-loop,
-- since NODE_TYPE_OF(table) = NODE_TYPE_OF(referenced table) in that case)
-- -----------------------------------------------------------------------------
-- NOTE: this rule can only propose an edge when BOTH endpoints are already
-- known node types (ONT_NODE_TYPES). If the FK's referenced table isn't
-- onboarded yet, this candidate is silently skipped -- a real system would
-- want to surface that as its own flagged case; out of scope for this demo,
-- and not a scenario the v1/v2 walkthrough exercises.
SET _TBL_NT = $ONTOLOGY_SCHEMA || '.ONT_NODE_TYPES';

INSERT INTO ORE_CLASSIFIED_CANDIDATES (
    RUN_ID, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
    OBJECT_KIND, RULE_APPLIED, PROPOSED_NAME, EDGE_FROM, EDGE_TO, RAW_DETAILS
)
SELECT
    dc.RUN_ID, dc.TABLE_SCHEMA, dc.TABLE_NAME, dc.COLUMN_NAME,
    'EDGE_TYPE', 'FK_TO_EDGE',
    REGEXP_REPLACE(fk.COLUMN_NAME, '_(ID|CODE)$', ''),
    nt_from.NODE_TYPE, nt_to.NODE_TYPE,
    OBJECT_CONSTRUCT(
        'fk_column', fk.COLUMN_NAME,
        'referenced_table', fk.REF_TABLE_SCHEMA || '.' || fk.REF_TABLE_NAME,
        'self_referencing', (fk.TABLE_SCHEMA = fk.REF_TABLE_SCHEMA AND fk.TABLE_NAME = fk.REF_TABLE_NAME)
    )
FROM ORE_DETECTED_CHANGES dc
JOIN FK_LOOKUP fk
  ON fk.TABLE_SCHEMA = dc.TABLE_SCHEMA
 AND fk.TABLE_NAME   = dc.TABLE_NAME
 AND fk.COLUMN_NAME  = dc.COLUMN_NAME
JOIN IDENTIFIER($_TBL_NT) nt_from
  ON nt_from.SOURCE_OBJECT = dc.TABLE_SCHEMA || '.' || dc.TABLE_NAME
JOIN IDENTIFIER($_TBL_NT) nt_to
  ON nt_to.SOURCE_OBJECT = fk.REF_TABLE_SCHEMA || '.' || fk.REF_TABLE_NAME
WHERE dc.RUN_ID = $run_id
  AND dc.CHANGE_TYPE = 'NEW_COLUMN'
  AND NOT EXISTS (
        SELECT 1 FROM ORE_DETECTED_CHANGES nt
        WHERE nt.RUN_ID = dc.RUN_ID AND nt.CHANGE_TYPE = 'NEW_TABLE'
          AND nt.TABLE_SCHEMA = dc.TABLE_SCHEMA AND nt.TABLE_NAME = dc.TABLE_NAME
      );

-- Sanity check
SELECT OBJECT_KIND, RULE_APPLIED, COUNT(*) AS CANDIDATE_COUNT
FROM ORE_CLASSIFIED_CANDIDATES
WHERE RUN_ID = $run_id
GROUP BY OBJECT_KIND, RULE_APPLIED
ORDER BY 1, 2;
