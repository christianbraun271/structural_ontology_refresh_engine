-- =============================================================================
-- 01_generate_artifacts_proc.sql
-- Template-based codegen: for each APPROVED proposal that hasn't been
-- generated yet, drafts the DDL/DML text an approved ontology change needs,
-- and stages it in ORE_GENERATED_ARTIFACTS.TEMPLATE_SQL for later developer
-- review -- nothing here is ever executed against ONT_* tables.
--
-- This is the template half only -- the AI refine pass (sql/05_codegen/02)
-- runs afterward, on top of what this produces. Reads FINAL_NAME /
-- FINAL_OBJECT_KIND (what the BA actually approved), never PROPOSED_NAME /
-- OBJECT_KIND (the original rule/AI suggestion).
--
-- To test against a specific proposal without going through the Control
-- Plane app, approve it directly:
--   UPDATE ORE_CANDIDATE_PROPOSALS
--   SET STATUS = 'APPROVED', DECIDED_BY = CURRENT_USER(), DECIDED_TS = CURRENT_TIMESTAMP()
--   WHERE PROPOSAL_ID = '<paste the PROPOSAL_ID you want to test>';
--
-- All three loops below use DECLARE ... CURSOR + OPEN [USING (...)] + FOR var
-- IN cursor DO, the same pattern used in CLASSIFY_NEW_TABLES -- not the
-- inline `FOR var IN (SELECT ...) DO` form, which fails inside a stored
-- procedure body with an "invalid identifier" error on the cursor row's
-- fields. The two FK-lookup cursors take `?` placeholders since they need
-- different TABLE_SCHEMA/TABLE_NAME each outer-loop iteration, opened fresh
-- via OPEN ... USING (...) each time they're needed. Every cursor-row field
-- used in a later query is first copied into its own LET variable.
-- INSERT ... SELECT is used throughout, never INSERT ... VALUES.
--
-- Every artifact's text is built via `SELECT <concatenation> INTO :var;`
-- (colon-prefixing every variable, local or argument alike), never a bare
-- `var := <concatenation>;` -- consistent with 03/04, and this script has
-- far more string-building than either of those.
--
-- c_fk_junction/c_fk_bundle are opened fresh via OPEN ... USING(...) each
-- time they're needed and rely on the FOR loop's auto-close-on-completion
-- rather than an explicit CLOSE. This has been exercised with one
-- junction-derived edge and one bundled-node case per run; a batch
-- containing multiple NODE_TYPE or junction-EDGE_TYPE proposals in the same
-- call would open each cursor more than once, which hasn't been
-- specifically exercised -- add an explicit CLOSE per cursor if that turns
-- out to need it.
--
-- SCOPE / what this does NOT handle (explicit skips, not silent gaps -- see
-- the "unsupported" branch below, which drafts a placeholder saying so):
--   - A column-level proposal (ATTRIBUTE's origin) whose FINAL_OBJECT_KIND
--     was changed to NODE_TYPE or EDGE_TYPE by a BA override. Promoting a
--     single column into its own node/edge is a materially different shape
--     of change (e.g. it would need its own population script reading from
--     the column's parent table) -- draft this one by hand for now.
--   - An EDGE_TYPE proposal whose EDGE_FROM/EDGE_TO somehow ended up NULL
--     (shouldn't happen given how 02/03 populate them, but checked anyway).
--
-- Every table/edge that becomes a NODE_TYPE also gets one bundled EDGE_TYPE
-- per FK column found on its source table (via SHOW IMPORTED KEYS, not
-- RAW_DETAILS -- re-derived fresh here rather than trusted from
-- classification time, so this works regardless of when/how the proposal
-- was classified). Without this, a promoted table would be an orphaned node
-- with no path back to what it used to relate. Skips any FK whose
-- referenced table isn't a known node type yet -- same limitation noted in
-- 02_classify_columns.sql.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB         = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA  = 'ORE_CONTROL';
SET ONTOLOGY_SCHEMA = 'ORE_ONTOLOGY';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

-- -----------------------------------------------------------------------------
-- Seed the codegen header template (only if not already set)
-- -----------------------------------------------------------------------------
INSERT INTO ORE_APP_CONFIG (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
SELECT
    'CODEGEN_HEADER',
    '-- =============================================================================' || CHR(10) ||
    '-- AUTO-GENERATED DRAFT -- produced by the Ontology Refresh Engine, not reviewed' || CHR(10) ||
    '-- by anyone yet. A developer must read this before any of it touches ONT_* tables.' || CHR(10) ||
    '-- =============================================================================',
    'Text prepended to every generated SQL artifact (sql/05_codegen). Edit this one value to change the styling/branding of generated drafts without touching the codegen procedure itself.'
WHERE NOT EXISTS (SELECT 1 FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'CODEGEN_HEADER');

-- -----------------------------------------------------------------------------
-- The procedure body does NOT reference $DEMO_DB/$ONTOLOGY_SCHEMA -- session
-- variables don't reach inside a $$...$$ body (see 03_classify_new_tables_proc.sql
-- for why). INFORMATION_SCHEMA.* stays unqualified by database, resolving
-- against whatever the caller's current database is; ONT_NODE_TYPES' schema
-- is passed in as a real argument instead.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GENERATE_ARTIFACTS(P_ONTOLOGY_SCHEMA VARCHAR)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_header            VARCHAR;
    v_final_name        VARCHAR;
    v_final_kind        VARCHAR;
    v_edge_from         VARCHAR;
    v_edge_to           VARCHAR;
    v_table_schema      VARCHAR;
    v_table_name        VARCHAR;
    v_column_name       VARCHAR;
    v_source_obj        VARCHAR;   -- '<schema>.<table>', for SOURCE_OBJECT columns
    v_display_name      VARCHAR;
    v_node_type_of      VARCHAR;   -- for ATTRIBUTE: which node type the column's table maps to
    v_pk_exclude_list   VARCHAR;   -- e.g. 'PROVIDER_ID, LOCATION_ID' for OBJECT_CONSTRUCT(* EXCLUDE (...))
    v_node_id_expr      VARCHAR;   -- e.g. 'PROVIDER_ID || ''_'' || LOCATION_ID' for NODE_ID
    v_sql               VARCHAR;   -- scratch: the artifact text being built
    v_ont_node_types_tbl VARCHAR;
    v_edge_name         VARCHAR;
    v_ref_node_type     VARCHAR;
    v_skip_reason       VARCHAR;
    -- Named, DECLAREd cursors -- not the inline `FOR var IN (SELECT ...) DO`
    -- form, which fails inside a stored procedure body (see header comment).
    -- The two FK cursors take `?` placeholders since they need different
    -- TABLE_SCHEMA/TABLE_NAME each outer-loop iteration -- opened fresh via
    -- OPEN ... USING(...) each time they're needed, same as CLASSIFY_NEW_TABLES
    -- opened its one cursor with P_RUN_ID.
    c_proposals CURSOR FOR
        SELECT
            p.PROPOSAL_ID,
            p.FINAL_OBJECT_KIND,
            p.FINAL_NAME,
            p.EDGE_FROM,
            p.EDGE_TO,
            p.SOURCE_OBJECT:table_schema::VARCHAR AS TABLE_SCHEMA,
            p.SOURCE_OBJECT:table_name::VARCHAR   AS TABLE_NAME,
            p.SOURCE_OBJECT:column_name::VARCHAR  AS COLUMN_NAME
        FROM ORE_CANDIDATE_PROPOSALS p
        WHERE p.STATUS = 'APPROVED'
          AND NOT EXISTS (SELECT 1 FROM ORE_GENERATED_ARTIFACTS g WHERE g.PROPOSAL_ID = p.PROPOSAL_ID);
    c_fk_junction CURSOR FOR
        SELECT COLUMN_NAME, ROW_NUMBER() OVER (ORDER BY COLUMN_NAME) AS RN
        FROM TMP_FK WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?;
    c_fk_bundle CURSOR FOR
        SELECT COLUMN_NAME, REF_TABLE_SCHEMA, REF_TABLE_NAME
        FROM TMP_FK WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY COLUMN_NAME;
BEGIN
    -- Same SHOW-based PK/FK capture as 03_classify_new_tables_proc.sql (no
    -- INFORMATION_SCHEMA.KEY_COLUMN_USAGE -- Snowflake doesn't have it).
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

    SELECT CONFIG_VALUE INTO :v_header FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'CODEGEN_HEADER';
    SELECT :P_ONTOLOGY_SCHEMA || '.ONT_NODE_TYPES' INTO :v_ont_node_types_tbl;

    OPEN c_proposals;
    FOR rec IN c_proposals DO
        LET v_proposal_id  VARCHAR := rec.PROPOSAL_ID;
        LET v_final_kind_l VARCHAR := rec.FINAL_OBJECT_KIND;
        LET v_final_name_l VARCHAR := rec.FINAL_NAME;
        LET v_edge_from_l  VARCHAR := rec.EDGE_FROM;
        LET v_edge_to_l    VARCHAR := rec.EDGE_TO;
        LET v_tbl_schema_l VARCHAR := rec.TABLE_SCHEMA;
        LET v_tbl_name_l   VARCHAR := rec.TABLE_NAME;
        LET v_col_name_l   VARCHAR := rec.COLUMN_NAME;

        v_final_kind   := v_final_kind_l;
        v_final_name   := v_final_name_l;
        v_edge_from    := v_edge_from_l;
        v_edge_to      := v_edge_to_l;
        v_table_schema := v_tbl_schema_l;
        v_table_name   := v_tbl_name_l;
        v_column_name  := v_col_name_l;

        SELECT :v_table_schema || '.' || :v_table_name INTO :v_source_obj;
        SELECT INITCAP(REPLACE(:v_final_name, '_', ' ')) INTO :v_display_name;

        v_skip_reason := NULL;
        IF (v_final_kind = 'ATTRIBUTE' AND v_column_name IS NULL) THEN
            v_skip_reason := 'FINAL_OBJECT_KIND is ATTRIBUTE but this proposal has no COLUMN_NAME -- inconsistent state, skipping.';
        ELSEIF (v_final_kind = 'NODE_TYPE' AND v_column_name IS NOT NULL) THEN
            v_skip_reason := 'Promoting a single column to its own NODE_TYPE is not supported by this codegen pass yet -- draft by hand.';
        ELSEIF (v_final_kind = 'EDGE_TYPE' AND (v_edge_from IS NULL OR v_edge_to IS NULL)) THEN
            v_skip_reason := 'EDGE_TYPE proposal is missing EDGE_FROM/EDGE_TO -- cannot draft an edge without both endpoints.';
        ELSEIF (v_final_kind NOT IN ('ATTRIBUTE', 'NODE_TYPE', 'EDGE_TYPE')) THEN
            SELECT 'FINAL_OBJECT_KIND is ''' || :v_final_kind || ''' -- not an actionable kind (did you forget to resolve a FLAGGED proposal before approving it?).'
            INTO :v_skip_reason;
        END IF;

        IF (v_skip_reason IS NOT NULL) THEN
            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'DICTIONARY_ENTRY',
                   :v_header || CHR(10) || CHR(10) || '-- MANUAL WORK NEEDED: ' || :v_skip_reason;

        -- =====================================================================
        -- ATTRIBUTE: no DDL needed -- PROPS already captures it. Documentation
        -- only.
        -- =====================================================================
        ELSEIF (v_final_kind = 'ATTRIBUTE') THEN
            SELECT NODE_TYPE INTO :v_node_type_of
            FROM IDENTIFIER(:v_ont_node_types_tbl) WHERE SOURCE_OBJECT = :v_source_obj;

            SELECT
                :v_header || CHR(10) || CHR(10) ||
                '-- New attribute -- documentation only, no DDL. PROPS on the ' || COALESCE(:v_node_type_of, '<UNKNOWN NODE TYPE -- source table not yet mapped>') ||
                ' node type auto-captures ' || :v_column_name || ' the next time its population script runs.' || CHR(10) ||
                '-- Dictionary entry:' || CHR(10) ||
                '--   Attribute name : ' || :v_final_name || CHR(10) ||
                '--   Node type      : ' || COALESCE(:v_node_type_of, '(unknown)') || CHR(10) ||
                '--   Source column  : ' || :v_source_obj || '.' || :v_column_name || CHR(10) ||
                '--   Description    : TODO -- add a business description.'
            INTO :v_sql;

            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'DICTIONARY_ENTRY', :v_sql;

        -- =====================================================================
        -- EDGE_TYPE (scalar-FK-derived, column-level: v_column_name IS NOT NULL)
        -- or (junction-table-derived, table-level: v_column_name IS NULL)
        -- =====================================================================
        ELSEIF (v_final_kind = 'EDGE_TYPE') THEN
            -- EDGE_TYPE_DDL
            SELECT
                :v_header || CHR(10) || CHR(10) ||
                'INSERT INTO ONT_EDGE_TYPES (EDGE_TYPE, DISPLAY_NAME, DESCRIPTION, FROM_NODE_TYPE, TO_NODE_TYPE, SOURCE_OBJECT)' || CHR(10) ||
                'VALUES (' || CHR(10) ||
                '    ''' || :v_final_name || ''', ''' || :v_display_name || ''', ''TODO -- add a business description.'',' || CHR(10) ||
                '    ''' || :v_edge_from || ''', ''' || :v_edge_to || ''', ''' || :v_source_obj || '''' || CHR(10) ||
                ');'
            INTO :v_sql;
            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'EDGE_TYPE_DDL', :v_sql;

            -- VIEW_DDL
            SELECT
                :v_header || CHR(10) || CHR(10) ||
                'CREATE OR REPLACE VIEW V_ONT_' || :v_final_name || CHR(10) ||
                'COMMENT = ''Per-type view over ONT_KG_EDGE for edge type ' || :v_final_name || '.''' || CHR(10) ||
                'AS' || CHR(10) ||
                '    SELECT e.EDGE_SK, src.NODE_ID AS SRC_ID, dst.NODE_ID AS DST_ID, e.PROPS' || CHR(10) ||
                '    FROM ONT_KG_EDGE e' || CHR(10) ||
                '    JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK' || CHR(10) ||
                '    JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK' || CHR(10) ||
                '    WHERE e.EDGE_TYPE = ''' || :v_final_name || ''';' || CHR(10) ||
                '-- TODO: SRC_ID/DST_ID are generic placeholders -- rename to match the natural' || CHR(10) ||
                '-- key columns (e.g. PROVIDER_ID, LOCATION_ID) once you know the real names.'
            INTO :v_sql;
            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'VIEW_DDL', :v_sql;

            -- POPULATION_SCRIPT -- shape depends on where the edge comes from
            IF (v_column_name IS NOT NULL) THEN
                -- Scalar-FK-derived: an existing, already-loaded table gained a
                -- new FK column. Re-join it against itself via that column.
                SELECT LISTAGG(COLUMN_NAME, ' || ''_'' || ') WITHIN GROUP (ORDER BY COLUMN_NAME) INTO :v_node_id_expr
                FROM TMP_PK WHERE TABLE_SCHEMA = :v_table_schema AND TABLE_NAME = :v_table_name;

                SELECT
                    :v_header || CHR(10) || CHR(10) ||
                    '-- Scalar-FK-derived edge: ' || :v_column_name || ' on ' || :v_source_obj ||
                    ' is the new FK column (self-referencing if FROM/TO node types match).' || CHR(10) ||
                    'INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)' || CHR(10) ||
                    'SELECT ''' || :v_final_name || ''', src.NODE_SK, dst.NODE_SK, OBJECT_CONSTRUCT(), ''' || :v_source_obj || '''' || CHR(10) ||
                    'FROM ' || :v_source_obj || ' p' || CHR(10) ||
                    'JOIN ONT_KG_NODE src ON src.NODE_TYPE = ''' || :v_edge_from || ''' AND src.NODE_ID = (' || :v_node_id_expr || ')' || CHR(10) ||
                    'JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = ''' || :v_edge_to   || ''' AND dst.NODE_ID = TO_VARCHAR(p.' || :v_column_name || ')' || CHR(10) ||
                    'WHERE p.' || :v_column_name || ' IS NOT NULL;'
                INTO :v_sql;
            ELSE
                -- Junction-table-derived: a brand-new table with (at least) two
                -- FK columns. Use the two lowest-alphabetical FK columns as the
                -- FROM/TO join keys, matching how 03_classify_new_tables_proc.sql
                -- picked ref_table_1/ref_table_2.
                LET v_fk_col_1 VARCHAR := NULL;
                LET v_fk_col_2 VARCHAR := NULL;
                OPEN c_fk_junction USING (v_table_schema, v_table_name);
                FOR fk_rec IN c_fk_junction DO
                    LET v_rn INT := fk_rec.RN;
                    LET v_col VARCHAR := fk_rec.COLUMN_NAME;
                    IF (v_rn = 1) THEN
                        v_fk_col_1 := v_col;
                    ELSEIF (v_rn = 2) THEN
                        v_fk_col_2 := v_col;
                    END IF;
                END FOR;

                SELECT
                    :v_header || CHR(10) || CHR(10) ||
                    '-- Junction-table-derived edge: ' || :v_source_obj || ' is a brand-new table.' || CHR(10) ||
                    '-- Verify ' || COALESCE(:v_fk_col_1, '<FK COLUMN 1 NOT FOUND>') || ' -> ' || :v_edge_from ||
                    ' and ' || COALESCE(:v_fk_col_2, '<FK COLUMN 2 NOT FOUND>') || ' -> ' || :v_edge_to || ' match before running.' || CHR(10) ||
                    'INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)' || CHR(10) ||
                    'SELECT ''' || :v_final_name || ''', src.NODE_SK, dst.NODE_SK,' || CHR(10) ||
                    '       OBJECT_CONSTRUCT(j.* EXCLUDE (' || COALESCE(:v_fk_col_1, '<?>') || ', ' || COALESCE(:v_fk_col_2, '<?>') || ')), ''' || :v_source_obj || '''' || CHR(10) ||
                    'FROM ' || :v_source_obj || ' j' || CHR(10) ||
                    'JOIN ONT_KG_NODE src ON src.NODE_TYPE = ''' || :v_edge_from || ''' AND src.NODE_ID = TO_VARCHAR(j.' || COALESCE(:v_fk_col_1, '<?>') || ')' || CHR(10) ||
                    'JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = ''' || :v_edge_to   || ''' AND dst.NODE_ID = TO_VARCHAR(j.' || COALESCE(:v_fk_col_2, '<?>') || ');'
                INTO :v_sql;
            END IF;
            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'POPULATION_SCRIPT', :v_sql;

        -- =====================================================================
        -- NODE_TYPE (always table-level: v_column_name IS NULL)
        -- =====================================================================
        ELSEIF (v_final_kind = 'NODE_TYPE') THEN
            SELECT LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_NAME) INTO :v_pk_exclude_list
            FROM TMP_PK WHERE TABLE_SCHEMA = :v_table_schema AND TABLE_NAME = :v_table_name;

            SELECT LISTAGG(COLUMN_NAME, ' || ''_'' || ') WITHIN GROUP (ORDER BY COLUMN_NAME) INTO :v_node_id_expr
            FROM TMP_PK WHERE TABLE_SCHEMA = :v_table_schema AND TABLE_NAME = :v_table_name;

            -- NODE_TYPE_DDL
            SELECT
                :v_header || CHR(10) || CHR(10) ||
                'INSERT INTO ONT_NODE_TYPES (NODE_TYPE, DISPLAY_NAME, DESCRIPTION, SOURCE_OBJECT)' || CHR(10) ||
                'VALUES (''' || :v_final_name || ''', ''' || :v_display_name || ''', ''TODO -- add a business description.'', ''' || :v_source_obj || ''');'
            INTO :v_sql;
            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'NODE_TYPE_DDL', :v_sql;

            -- VIEW_DDL
            SELECT
                :v_header || CHR(10) || CHR(10) ||
                'CREATE OR REPLACE VIEW V_ONT_' || :v_final_name || CHR(10) ||
                'COMMENT = ''Per-type view over ONT_KG_NODE for node type ' || :v_final_name || '.''' || CHR(10) ||
                'AS' || CHR(10) ||
                '    SELECT NODE_SK, NODE_ID, PROPS FROM ONT_KG_NODE WHERE NODE_TYPE = ''' || :v_final_name || ''';'
            INTO :v_sql;
            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'VIEW_DDL', :v_sql;

            -- POPULATION_SCRIPT -- NODE_ID is the PK column(s) concatenated (a
            -- single column collapses to just that column; a composite PK
            -- made of what used to be FK columns is exactly the reified-entity
            -- case this was built for).
            SELECT
                :v_header || CHR(10) || CHR(10) ||
                'INSERT INTO ONT_KG_NODE (NODE_ID, NODE_TYPE, PROPS, SOURCE_OBJECT)' || CHR(10) ||
                'SELECT (' || :v_node_id_expr || '), ''' || :v_final_name || ''', OBJECT_CONSTRUCT(* EXCLUDE (' || :v_pk_exclude_list || ')), ''' || :v_source_obj || '''' || CHR(10) ||
                'FROM ' || :v_source_obj || ';'
            INTO :v_sql;
            INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
            SELECT :v_proposal_id, 'POPULATION_SCRIPT', :v_sql;

            -- Bundled edges: one per FK column on this table, back to whatever
            -- it used to reference, so the new node isn't orphaned. Skips any
            -- FK whose referenced table isn't a known node type yet (same
            -- limitation as 02_classify_columns.sql).
            OPEN c_fk_bundle USING (v_table_schema, v_table_name);
            FOR fk_rec IN c_fk_bundle DO
                LET v_fk_col_b     VARCHAR := fk_rec.COLUMN_NAME;
                LET v_ref_schema_b VARCHAR := fk_rec.REF_TABLE_SCHEMA;
                LET v_ref_table_b  VARCHAR := fk_rec.REF_TABLE_NAME;

                v_ref_node_type := NULL;
                SELECT NODE_TYPE INTO :v_ref_node_type
                FROM IDENTIFIER(:v_ont_node_types_tbl) WHERE SOURCE_OBJECT = :v_ref_schema_b || '.' || :v_ref_table_b;

                IF (v_ref_node_type IS NOT NULL) THEN
                    SELECT :v_final_name || '_' || REGEXP_REPLACE(:v_fk_col_b, '_(ID|CODE)$', '') INTO :v_edge_name;

                    SELECT
                        :v_header || CHR(10) || CHR(10) ||
                        '-- Bundled edge: keeps ' || :v_final_name || ' connected to ' || :v_ref_node_type ||
                        ' now that ' || :v_fk_col_b || ' is no longer a plain FK column.' || CHR(10) ||
                        'INSERT INTO ONT_EDGE_TYPES (EDGE_TYPE, DISPLAY_NAME, DESCRIPTION, FROM_NODE_TYPE, TO_NODE_TYPE, SOURCE_OBJECT)' || CHR(10) ||
                        'VALUES (''' || :v_edge_name || ''', ''' || INITCAP(REPLACE(:v_edge_name, '_', ' ')) || ''', ''TODO -- add a business description.'', ''' ||
                        :v_final_name || ''', ''' || :v_ref_node_type || ''', ''' || :v_source_obj || ''');'
                    INTO :v_sql;
                    INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
                    SELECT :v_proposal_id, 'EDGE_TYPE_DDL', :v_sql;

                    SELECT
                        :v_header || CHR(10) || CHR(10) ||
                        'CREATE OR REPLACE VIEW V_ONT_' || :v_edge_name || CHR(10) ||
                        'COMMENT = ''Per-type view over ONT_KG_EDGE for edge type ' || :v_edge_name || '.''' || CHR(10) ||
                        'AS' || CHR(10) ||
                        '    SELECT e.EDGE_SK, src.NODE_ID AS SRC_ID, dst.NODE_ID AS DST_ID, e.PROPS' || CHR(10) ||
                        '    FROM ONT_KG_EDGE e' || CHR(10) ||
                        '    JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK' || CHR(10) ||
                        '    JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK' || CHR(10) ||
                        '    WHERE e.EDGE_TYPE = ''' || :v_edge_name || ''';'
                    INTO :v_sql;
                    INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
                    SELECT :v_proposal_id, 'VIEW_DDL', :v_sql;

                    -- v_node_id_expr (e.g. PROVIDER_ID || '_' || LOCATION_ID) uses
                    -- bare column names, which is fine here even with the source
                    -- table aliased as j -- ONT_KG_NODE (src/dst) has no columns
                    -- with those names, so they resolve unambiguously to j's.
                    SELECT
                        :v_header || CHR(10) || CHR(10) ||
                        'INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)' || CHR(10) ||
                        'SELECT ''' || :v_edge_name || ''', src.NODE_SK, dst.NODE_SK, OBJECT_CONSTRUCT(), ''' || :v_source_obj || '''' || CHR(10) ||
                        'FROM ' || :v_source_obj || ' j' || CHR(10) ||
                        'JOIN ONT_KG_NODE src ON src.NODE_TYPE = ''' || :v_final_name || ''' AND src.NODE_ID = (' || :v_node_id_expr || ')' || CHR(10) ||
                        'JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = ''' || :v_ref_node_type || ''' AND dst.NODE_ID = TO_VARCHAR(j.' || :v_fk_col_b || ');'
                    INTO :v_sql;
                    INSERT INTO ORE_GENERATED_ARTIFACTS (PROPOSAL_ID, ARTIFACT_TYPE, TEMPLATE_SQL)
                    SELECT :v_proposal_id, 'POPULATION_SCRIPT', :v_sql;
                END IF;
            END FOR;
        END IF;
    END FOR;
    RETURN 'OK';
END;
$$;

CALL GENERATE_ARTIFACTS($ONTOLOGY_SCHEMA);

-- Sanity check
SELECT g.PROPOSAL_ID, p.FINAL_NAME, p.FINAL_OBJECT_KIND, g.ARTIFACT_TYPE, g.DEV_STATUS, g.TEMPLATE_SQL
FROM ORE_GENERATED_ARTIFACTS g
JOIN ORE_CANDIDATE_PROPOSALS p ON p.PROPOSAL_ID = g.PROPOSAL_ID
ORDER BY g.GENERATED_TS, g.PROPOSAL_ID, g.ARTIFACT_TYPE;
