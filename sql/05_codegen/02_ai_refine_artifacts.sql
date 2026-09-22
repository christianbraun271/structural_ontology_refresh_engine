-- =============================================================================
-- 02_ai_refine_artifacts.sql
-- REFINE_ARTIFACTS() -- one AI_COMPLETE call per not-yet-refined artifact,
-- asking for ONLY a one-sentence description/comment string -- never the
-- whole SQL text back. We splice that string into the template ourselves,
-- with our own quote escaping. AI_REFINED_SQL is written; TEMPLATE_SQL is
-- never touched, so a developer can compare both (same AI_RATIONALE-vs-
-- RATIONALE pattern used everywhere else in this project).
--
-- Wrapped in a stored procedure (previously a plain script) so the Control
-- Plane app can call it -- specifically, right after GENERATE_ARTIFACTS, as
-- one "Generate Code" action. The underlying SQL logic is UNCHANGED from the
-- version already tested and confirmed working; only how it gets its
-- variables changed, since session SET variables don't reach inside a
-- $$...$$ procedure body (same lesson learned building every other
-- procedure here). $DEMO_DB is no longer needed at all -- CURRENT_DATABASE()
-- gives the caller's current database directly, which is correct since the
-- app already calls session.use_database(DEMO_DB) at startup.
--
-- REDESIGNED (before being turned into a procedure) after reviewing a real
-- run's output found real bugs, not just rough edges, in an earlier "give
-- the model the whole SQL and ask it to only touch cosmetics" approach:
--   - Every EDGE_TYPE population script came back with SRC_SK/DST_SK renamed
--     to invented names (e.g. PROVIDER_SK) that don't exist in ONT_KG_EDGE --
--     100% of that artifact type would have failed to execute.
--   - Several VIEW_DDL comments came back with an unescaped apostrophe
--     ("a professional's scheduled coverage") -- a SQL syntax error.
--   - View column renames (SRC_ID/DST_ID -> real names) were backwards
--     relative to the actual join direction in several cases.
-- The fix isn't a better-worded prompt asking the model not to do these
-- things -- that was already tried. It's removing the opportunity
-- structurally, same philosophy as the CODEGEN_HEADER fix:
--   - POPULATION_SCRIPT artifacts are never sent to the model at all. There
--     is nothing legitimate for it to improve there -- no TODO, no
--     placeholder name -- SRC_SK/DST_SK are the actual required column
--     names of ONT_KG_EDGE/ONT_KG_NODE and must never be renamed. Excluding
--     this artifact type makes that whole bug class structurally impossible
--     rather than merely less likely.
--   - Every other artifact type is asked for exactly one field -- a plain
--     description string -- via a response_format schema with no field for
--     a SQL rewrite, a column rename, or anything else to go into. Whatever
--     the model returns is escaped by us (doubling any embedded single
--     quote) before being spliced into the exact known slot in TEMPLATE_SQL
--     (the 'TODO -- add a business description.' literal, or the
--     auto-generated view COMMENT sentence). Column names (SRC_ID/DST_ID)
--     are left exactly as the template produced them -- renaming them
--     safely would need per-artifact ground-truth extraction the current
--     schema doesn't support yet (a deferred, separate piece of work).
--
-- Idempotent / cost-aware: only processes rows where AI_REFINED_SQL IS NULL.
--
-- Uses AI_COMPLETE with a JSON response_format, per
-- https://docs.snowflake.com/en/sql-reference/functions/ai_complete. The
-- REGEXP_REPLACE call for view comments matches a whole known sentence,
-- rather than just stripping a suffix like elsewhere in this project. The
-- WITH-CTE-inside-UPDATE-FROM subquery here runs inside a procedure body,
-- the same construct 03_refresh_engine/04_ai_review_candidates.sql uses at
-- the top level of a script.
--
-- Run this (or CALL REFINE_ARTIFACTS() directly) after
-- 01_generate_artifacts_proc.sql has populated ORE_GENERATED_ARTIFACTS --
-- not run-scoped like the refresh-engine scripts (ORE_GENERATED_ARTIFACTS
-- has no RUN_ID; it's keyed by PROPOSAL_ID), so this just processes every
-- not-yet-refined artifact across every proposal.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB        = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

-- -----------------------------------------------------------------------------
-- Seed ORE_APP_CONFIG defaults (only if not already set -- usually already
-- seeded by earlier scripts by this point; kept here too so this script is
-- runnable standalone). Left as top-level statements, not inside the
-- procedure -- matches how 01_generate_artifacts_proc.sql seeds
-- CODEGEN_HEADER outside its own procedure.
-- -----------------------------------------------------------------------------
INSERT INTO ORE_APP_CONFIG (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
SELECT
    'AI_MODEL', 'llama3.1-70b',
    'Cortex model used by AI_COMPLETE for classification review and code-gen refinement. Swap for another Cortex-supported model depending on your account''s region/entitlements -- see https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql for the current list.'
WHERE NOT EXISTS (SELECT 1 FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL');

INSERT INTO ORE_APP_CONFIG (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
SELECT
    'INDUSTRY_CONTEXT',
    'This data models a healthcare provider directory (HCLS domain): individual professionals and facilities, ' ||
    'the practice locations and addresses they are associated with, clinical specialties, and languages spoken. ' ||
    'Relevant external standards, if applicable: NPI (National Provider Identifier), NUCC Health Care Provider ' ||
    'Taxonomy codes for specialties, and FHIR resource shapes (e.g. Practitioner, Organization, Location, ' ||
    'PractitionerRole) as a general reference point for how these concepts are usually modeled. Note any such ' ||
    'standard mapping only if genuinely relevant -- do not force a mapping that doesn''t fit.',
    'Short domain description injected into AI prompts. Swap this value for a different industry to re-target the same engine.'
WHERE NOT EXISTS (SELECT 1 FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'INDUSTRY_CONTEXT');

CREATE OR REPLACE PROCEDURE REFINE_ARTIFACTS()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_ai_model         VARCHAR;
    v_industry_context VARCHAR;
    v_tbl_tables       VARCHAR;
    v_tbl_columns      VARCHAR;
BEGIN
    SELECT CONFIG_VALUE INTO :v_ai_model FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL';
    SELECT CONFIG_VALUE INTO :v_industry_context FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'INDUSTRY_CONTEXT';
    SELECT CURRENT_DATABASE() || '.INFORMATION_SCHEMA.TABLES'  INTO :v_tbl_tables;
    SELECT CURRENT_DATABASE() || '.INFORMATION_SCHEMA.COLUMNS' INTO :v_tbl_columns;

    -- Step 1: POPULATION_SCRIPT artifacts get no AI call at all -- there is
    -- nothing in them for the model to legitimately improve, and asking
    -- anyway is exactly what produced the SRC_SK/DST_SK bug. AI_REFINED_SQL
    -- is simply a copy of TEMPLATE_SQL.
    UPDATE ORE_GENERATED_ARTIFACTS
    SET
        AI_REFINED_SQL = TEMPLATE_SQL,
        AI_NOTES        = 'No AI refinement attempted for population scripts -- SRC_SK/DST_SK are the actual required ONT_KG_EDGE/ONT_KG_NODE column names and must not be renamed; there is no other placeholder in this artifact type to improve.'
    WHERE ARTIFACT_TYPE = 'POPULATION_SCRIPT'
      AND AI_REFINED_SQL IS NULL;

    -- Step 2: every other artifact type -- ask for ONE description string
    -- only, splice it into the exact known slot ourselves (escaping
    -- embedded single quotes before splicing, never trusting the model to
    -- have escaped them).
    UPDATE ORE_GENERATED_ARTIFACTS g
    SET
        AI_REFINED_SQL =
            CASE
                WHEN g.TEMPLATE_SQL LIKE '%TODO -- add a business description.%' THEN
                    REPLACE(g.TEMPLATE_SQL, 'TODO -- add a business description.', ai.ESCAPED_DESCRIPTION)
                WHEN g.TEMPLATE_SQL LIKE '%Per-type view over%' THEN
                    REGEXP_REPLACE(
                        g.TEMPLATE_SQL,
                        'Per-type view over ONT_KG_(NODE|EDGE) for (node|edge) type [A-Za-z_0-9]+\.',
                        ai.ESCAPED_DESCRIPTION
                    )
                ELSE g.TEMPLATE_SQL  -- shouldn't happen given known template shapes; safe no-op fallback
            END,
        AI_NOTES = 'AI-provided one-sentence description spliced into the template; nothing else in the SQL was touched.'
    FROM (
        WITH PROMPT_INPUT AS (
            SELECT
                g.ARTIFACT_ID,
                'You are writing ONE short, plain-English sentence describing a DRAFT ontology artifact produced by ' ||
                'a template-based code generator. Respond with ONLY that sentence -- no SQL, no formatting, no other ' ||
                'commentary.' || CHR(10) || CHR(10) ||
                'INDUSTRY CONTEXT:' || CHR(10) || :v_industry_context || CHR(10) || CHR(10) ||
                'ARTIFACT CONTEXT:' || CHR(10) ||
                '- Artifact type: ' || g.ARTIFACT_TYPE || CHR(10) ||
                '- Belongs to: ' || p.FINAL_OBJECT_KIND || ' named ' || p.FINAL_NAME || CHR(10) ||
                '- Edge endpoints (if applicable): ' || COALESCE(p.EDGE_FROM, '(n/a)') || ' -> ' || COALESCE(p.EDGE_TO, '(n/a)') || CHR(10) ||
                '- Source object: ' || p.SOURCE_OBJECT:table_schema::VARCHAR || '.' || p.SOURCE_OBJECT:table_name::VARCHAR ||
                    COALESCE('.' || p.SOURCE_OBJECT:column_name::VARCHAR, '') || CHR(10) ||
                '- Table comment: ' || COALESCE(st.COMMENT, '(none)') || CHR(10) ||
                '- Column comment: ' || COALESCE(sc.COMMENT, '(n/a)') || CHR(10) || CHR(10) ||
                'FOR REFERENCE, the draft SQL this description belongs to (do NOT return any part of this back -- it ' ||
                'is shown only so your sentence is grounded in what the artifact actually does):' || CHR(10) ||
                '-----' || CHR(10) ||
                g.TEMPLATE_SQL || CHR(10) ||
                '-----' || CHR(10) || CHR(10) ||
                'TASK: Write one sentence for the "description" field: if this is a view, describe what it shows; ' ||
                'otherwise describe what the type/attribute represents in business terms. Ground it in the context ' ||
                'above. Respond ONLY with the requested JSON.'
                    AS PROMPT_TEXT
            FROM ORE_GENERATED_ARTIFACTS g
            JOIN ORE_CANDIDATE_PROPOSALS p ON p.PROPOSAL_ID = g.PROPOSAL_ID
            LEFT JOIN IDENTIFIER(:v_tbl_tables) st
              ON st.TABLE_SCHEMA = p.SOURCE_OBJECT:table_schema::VARCHAR AND st.TABLE_NAME = p.SOURCE_OBJECT:table_name::VARCHAR
            LEFT JOIN IDENTIFIER(:v_tbl_columns) sc
              ON sc.TABLE_SCHEMA = p.SOURCE_OBJECT:table_schema::VARCHAR AND sc.TABLE_NAME = p.SOURCE_OBJECT:table_name::VARCHAR
             AND sc.COLUMN_NAME = p.SOURCE_OBJECT:column_name::VARCHAR
            WHERE g.ARTIFACT_TYPE <> 'POPULATION_SCRIPT'
              AND g.AI_REFINED_SQL IS NULL
        ),
        AI_RESPONSE AS (
            SELECT
                ARTIFACT_ID,
                PARSE_JSON(
                    AI_COMPLETE(
                        model => :v_ai_model,
                        prompt => PROMPT_TEXT,
                        response_format => {
                            'type': 'json',
                            'schema': {
                                'type': 'object',
                                'properties': {
                                    'description': {'type': 'string'}
                                },
                                'required': ['description']
                            }
                        }
                    )
                ) AS RESP
            FROM PROMPT_INPUT
        )
        SELECT
            ARTIFACT_ID,
            -- Double any embedded single quote ourselves -- never rely on
            -- the model to have escaped it. This is what actually closes
            -- the unescaped-apostrophe syntax-error bug, not the prompt
            -- wording.
            REPLACE(RESP:description::VARCHAR, '''', '''''') AS ESCAPED_DESCRIPTION
        FROM AI_RESPONSE
    ) ai
    WHERE g.ARTIFACT_ID = ai.ARTIFACT_ID;

    RETURN 'OK';
END;
$$;

CALL REFINE_ARTIFACTS();

-- Sanity check
SELECT
    g.ARTIFACT_ID, p.FINAL_NAME, p.FINAL_OBJECT_KIND, g.ARTIFACT_TYPE,
    g.TEMPLATE_SQL, g.AI_REFINED_SQL, g.AI_NOTES
FROM ORE_GENERATED_ARTIFACTS g
JOIN ORE_CANDIDATE_PROPOSALS p ON p.PROPOSAL_ID = g.PROPOSAL_ID
ORDER BY g.GENERATED_TS, g.PROPOSAL_ID, g.ARTIFACT_TYPE;
