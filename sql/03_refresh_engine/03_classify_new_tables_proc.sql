-- =============================================================================
-- 03_classify_new_tables_proc.sql
-- Table-level classification: for each new table detected this run, walks a
-- three-question decision tree, implemented as a Snowflake Scripting stored
-- procedure since it needs real control flow, not a flat INSERT:
--
--   Q1: fewer than 2 FK columns?              -> NODE_TYPE   (FEW_FKS)
--   Q2: FKs don't make up (nearly) the PK?     -> NODE_TYPE   (FKS_NOT_IDENTITY)
--   Q3: no real attributes beyond the FKs?     -> EDGE_TYPE   (PURE_JUNCTION)
--   otherwise (FKs = the PK, but more remains) -> FLAGGED     (REIFIED_ENTITY?)
--
-- attr_count is computed as total_columns - pk_count -- this only means
-- "genuinely extra" once Q3 confirms the FKs already make up the whole PK,
-- which is exactly why it's checked last.
--
-- For the EDGE_TYPE and FLAGGED branches (both require the FKs to make up
-- the PK, i.e. exactly the "this pair of nodes" case), this proc also
-- resolves the two FK-referenced tables to their node types and records them
-- as EDGE_FROM/EDGE_TO -- even for FLAGGED, since "is this an edge between X
-- and Y, or a new node?" is easier for a reviewer to judge when X and Y are
-- shown. Simplification: only the first two FKs (ordered by column name) are
-- resolved this way -- a >2-FK junction/reified table isn't a scenario this
-- demo's rule needs to model precisely; a "regular" 2-FK junction is the
-- scope this covers.
--
-- Requires ORE_DETECTED_CHANGES and ORE_CLASSIFIED_CANDIDATES to already
-- exist (sql/02_ontology/01_ontology_core_ddl.sql), and ONT_NODE_TYPES to
-- have entries for whatever the new table's FKs reference (otherwise
-- EDGE_FROM/EDGE_TO are left NULL for that candidate -- same limitation as
-- 02_classify_columns.sql).
--
-- Run this after a detection script (01 or 01b) -- it always operates on the
-- most recent run in ORE_DETECTED_CHANGES, so nothing needs to be carried
-- over by hand.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB         = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA  = 'ORE_CONTROL';
SET ONTOLOGY_SCHEMA = 'ORE_ONTOLOGY';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

-- The procedure body below deliberately does NOT reference $DEMO_DB /
-- $ONTOLOGY_SCHEMA -- session variable ($var) substitution happens only for
-- the outer statement text, not for the string CONTENTS of a $$...$$ body,
-- so it can't reach in here. INFORMATION_SCHEMA.* is written unqualified by
-- database on purpose -- that resolves correctly against whatever database
-- is CURRENT at CALL time (i.e. $DEMO_DB, since the caller already did USE
-- DATABASE). But ONT_NODE_TYPES lives in a specific schema that may or may
-- not be the caller's current schema (CONTROL), so its schema name is passed
-- in as a real procedure argument (P_ONTOLOGY_SCHEMA) instead -- bind
-- parameters, unlike session variables, do work inside the body.
CREATE OR REPLACE PROCEDURE CLASSIFY_NEW_TABLES(P_RUN_ID VARCHAR, P_ONTOLOGY_SCHEMA VARCHAR)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    fk_count      INT;
    pk_count      INT;
    fk_in_pk      INT;
    total_cols    INT;
    attr_count    INT;
    v_object_kind VARCHAR;
    v_rule        VARCHAR;
    ref_table_1   VARCHAR;
    ref_table_2   VARCHAR;
    edge_from     VARCHAR;
    edge_to       VARCHAR;
    -- IDENTIFIER() does not accept an expression (e.g. :P_ONTOLOGY_SCHEMA ||
    -- '.ONT_NODE_TYPES') inline -- precomputed into this variable instead,
    -- then passed to IDENTIFIER() bare.
    v_ont_node_types_tbl VARCHAR;
    -- A cursor's query cannot resolve a procedure argument via :P_RUN_ID
    -- inline in the DECLARE -- Snowflake Scripting requires a `?`
    -- placeholder here instead, with the actual value supplied via
    -- OPEN c USING (...) below.
    c CURSOR FOR
        SELECT TABLE_SCHEMA, TABLE_NAME
        FROM ORE_DETECTED_CHANGES
        WHERE RUN_ID = ? AND CHANGE_TYPE = 'NEW_TABLE';
BEGIN
    -- Snowflake has no INFORMATION_SCHEMA.KEY_COLUMN_USAGE -- that's a
    -- standard ANSI view in Postgres/MySQL/SQL Server, not something
    -- Snowflake exposes. Its mechanism for FK/PK column-level detail is the
    -- SHOW PRIMARY KEYS / SHOW IMPORTED KEYS commands instead, consumed via
    -- TABLE(RESULT_SCAN(LAST_QUERY_ID())) to turn their output into a
    -- queryable result set. Captured once here (for the whole database)
    -- into temp tables, then filtered per table inside the loop below,
    -- rather than re-running SHOW per iteration. SHOW command output
    -- columns come back lowercase and need double-quoting to reference
    -- exactly -- see
    -- https://docs.snowflake.com/en/sql-reference/sql/show-primary-keys and
    -- https://docs.snowflake.com/en/sql-reference/sql/show-imported-keys
    -- for the full column list.
    SHOW PRIMARY KEYS IN DATABASE;
    CREATE OR REPLACE TEMPORARY TABLE TMP_PK AS
    SELECT "schema_name" AS TABLE_SCHEMA, "table_name" AS TABLE_NAME, "column_name" AS COLUMN_NAME
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    SHOW IMPORTED KEYS IN DATABASE;
    CREATE OR REPLACE TEMPORARY TABLE TMP_FK AS
    SELECT
        "fk_schema_name" AS TABLE_SCHEMA, "fk_table_name" AS TABLE_NAME, "fk_column_name" AS COLUMN_NAME,
        "pk_schema_name" AS REF_TABLE_SCHEMA, "pk_table_name" AS REF_TABLE_NAME
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    OPEN c USING (P_RUN_ID);
    FOR rec IN c DO
        -- Materialize the cursor row's fields into their own scalar
        -- variables up front, and use :v_tbl_schema/:v_tbl_name (not
        -- rec.TABLE_SCHEMA/rec.TABLE_NAME directly) in every query below --
        -- more reliable for bind resolution in Snowflake Scripting than
        -- referencing cursor-row fields inline.
        LET v_tbl_schema VARCHAR := rec.TABLE_SCHEMA;
        LET v_tbl_name   VARCHAR := rec.TABLE_NAME;

        -- Q1 input: how many distinct columns participate in a FOREIGN KEY?
        SELECT COUNT(DISTINCT COLUMN_NAME) INTO :fk_count
        FROM TMP_FK
        WHERE TABLE_SCHEMA = :v_tbl_schema AND TABLE_NAME = :v_tbl_name;

        -- Q2 input: how many columns make up the PRIMARY KEY?
        SELECT COUNT(*) INTO :pk_count
        FROM TMP_PK
        WHERE TABLE_SCHEMA = :v_tbl_schema AND TABLE_NAME = :v_tbl_name;

        -- Q2 input: of those PK columns, how many are also FK columns?
        SELECT COUNT(*) INTO :fk_in_pk
        FROM TMP_PK pk
        JOIN (SELECT DISTINCT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME FROM TMP_FK) fk
          ON fk.TABLE_SCHEMA = pk.TABLE_SCHEMA AND fk.TABLE_NAME = pk.TABLE_NAME AND fk.COLUMN_NAME = pk.COLUMN_NAME
        WHERE pk.TABLE_SCHEMA = :v_tbl_schema AND pk.TABLE_NAME = :v_tbl_name;

        -- Q3 input: total column count (attr_count = total - pk)
        SELECT COUNT(*) INTO :total_cols
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = :v_tbl_schema AND TABLE_NAME = :v_tbl_name;

        attr_count := total_cols - pk_count;

        IF (fk_count < 2) THEN
            v_object_kind := 'NODE_TYPE';
            v_rule        := 'FEW_FKS';
        ELSEIF (fk_in_pk < pk_count) THEN
            v_object_kind := 'NODE_TYPE';
            v_rule        := 'FKS_NOT_IDENTITY';
        ELSEIF (attr_count <= 1) THEN
            v_object_kind := 'EDGE_TYPE';
            v_rule        := 'PURE_JUNCTION';
        ELSE
            v_object_kind := 'FLAGGED';
            v_rule        := 'REIFIED_ENTITY?';
        END IF;

        -- Reset every per-row output before deciding whether to populate it
        -- this iteration -- these are procedure-level variables that
        -- otherwise persist across loop iterations. (ref_table_1/2 previously
        -- were NOT reset here, only assigned inside the IF below -- a
        -- NODE_TYPE row following an EDGE_TYPE/FLAGGED row would have
        -- inherited the prior row's ref_table_1/2 into its RAW_DETAILS.)
        edge_from   := NULL;
        edge_to     := NULL;
        ref_table_1 := NULL;
        ref_table_2 := NULL;

        -- Only worth resolving the node pair when the FKs make up the PK --
        -- i.e. we got past Q2 into EDGE_TYPE or FLAGGED.
        IF (v_object_kind IN ('EDGE_TYPE', 'FLAGGED')) THEN
            CREATE OR REPLACE TEMPORARY TABLE TMP_FK_REFS AS
            SELECT
                REF_TABLE_SCHEMA || '.' || REF_TABLE_NAME AS REF_TABLE,
                ROW_NUMBER() OVER (ORDER BY COLUMN_NAME) AS RN
            FROM TMP_FK
            WHERE TABLE_SCHEMA = :v_tbl_schema AND TABLE_NAME = :v_tbl_name;

            SELECT REF_TABLE INTO :ref_table_1 FROM TMP_FK_REFS WHERE RN = 1;
            SELECT REF_TABLE INTO :ref_table_2 FROM TMP_FK_REFS WHERE RN = 2;

            v_ont_node_types_tbl := :P_ONTOLOGY_SCHEMA || '.ONT_NODE_TYPES';

            SELECT NODE_TYPE INTO :edge_from
            FROM IDENTIFIER(:v_ont_node_types_tbl) WHERE SOURCE_OBJECT = :ref_table_1;
            SELECT NODE_TYPE INTO :edge_to
            FROM IDENTIFIER(:v_ont_node_types_tbl) WHERE SOURCE_OBJECT = :ref_table_2;
        END IF;

        -- INSERT ... SELECT here, not INSERT ... VALUES -- more reliable for
        -- bind-variable resolution in Snowflake Scripting than VALUES(...).
        INSERT INTO ORE_CLASSIFIED_CANDIDATES (
            RUN_ID, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
            OBJECT_KIND, RULE_APPLIED, PROPOSED_NAME, EDGE_FROM, EDGE_TO, RAW_DETAILS
        )
        SELECT
            :P_RUN_ID, :v_tbl_schema, :v_tbl_name, NULL,
            :v_object_kind, :v_rule, REGEXP_REPLACE(:v_tbl_name, '^SRC_', ''),
            :edge_from, :edge_to,
            OBJECT_CONSTRUCT(
                'fk_count', :fk_count, 'pk_count', :pk_count, 'fk_in_pk', :fk_in_pk,
                'total_columns', :total_cols, 'attr_count', :attr_count,
                'ref_table_1', :ref_table_1, 'ref_table_2', :ref_table_2
            );
    END FOR;
    RETURN 'OK';
END;
$$;

SET run_id = (SELECT RUN_ID FROM ORE_DETECTED_CHANGES ORDER BY DETECTED_TS DESC LIMIT 1);

CALL CLASSIFY_NEW_TABLES($run_id, $ONTOLOGY_SCHEMA);

-- Sanity check
SELECT TABLE_NAME, OBJECT_KIND, RULE_APPLIED, PROPOSED_NAME, EDGE_FROM, EDGE_TO, RAW_DETAILS
FROM ORE_CLASSIFIED_CANDIDATES
WHERE RUN_ID = $run_id AND COLUMN_NAME IS NULL
ORDER BY TABLE_NAME;
