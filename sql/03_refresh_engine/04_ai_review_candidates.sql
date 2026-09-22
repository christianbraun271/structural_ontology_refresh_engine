-- =============================================================================
-- 04_ai_review_candidates.sql
-- One AI_COMPLETE call per not-yet-reviewed candidate from the current run,
-- combining two things in a single pass (per the plan: refine/correct the
-- rule engine's output, and lightly ground it in industry knowledge):
--   - sanity-checks and, if warranted, corrects the rule engine's OBJECT_KIND
--     (the rule engine can't see things like undeclared FKs or judge a
--     genuinely ambiguous reified-entity case the way a reviewer could)
--   - notes any relevant industry-standard vocabulary mapping, using the
--     configurable INDUSTRY_CONTEXT value from ORE_APP_CONFIG -- NOT a
--     hardcoded HCLS prompt. Swapping that one config value is how this same
--     script targets a different industry; nothing else here is HCLS-specific.
--
-- Writes into the AI_* columns already reserved for this on
-- ORE_CLASSIFIED_CANDIDATES -- doesn't touch RULE_APPLIED/OBJECT_KIND
-- themselves, so the rule engine's original opinion is always still visible
-- for comparison (05_persist_candidates.sql carries both forward for the BA
-- to see side by side).
--
-- Idempotent / cost-aware: only processes rows where AI_RECOMMENDED_KIND IS
-- NULL, so re-running this script doesn't re-call the model on candidates
-- already reviewed.
--
-- Uses AI_COMPLETE with a JSON response_format to get structured output
-- back directly -- see
-- https://docs.snowflake.com/en/sql-reference/functions/ai_complete for the
-- full argument reference.
--
-- IDENTIFIER() does not accept an expression (e.g. $DEMO_DB || '.SCHEMA.TABLE')
-- inline -- each concatenated name is precomputed into its own variable
-- first, then passed to IDENTIFIER() bare (see _TBL_TABLES / _TBL_COLUMNS).
--
-- Run this after classification (02 + 03) has populated
-- ORE_CLASSIFIED_CANDIDATES for the run -- it always operates on the most
-- recent run, so nothing needs to be carried over by hand.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB        = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

-- -----------------------------------------------------------------------------
-- Seed ORE_APP_CONFIG defaults (only if not already set -- see header of
-- sql/02_ontology/01_ontology_core_ddl.sql for what these keys do). Edit
-- these rows directly any time to change the model or retarget the industry.
-- -----------------------------------------------------------------------------
INSERT INTO ORE_APP_CONFIG (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
SELECT
    'AI_MODEL', 'llama3.1-70b',
    'Cortex model used by AI_COMPLETE for classification review (this script) and, later, code-gen refinement. Swap for another Cortex-supported model depending on your account''s region/entitlements -- see https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql for the current list.'
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
    'Short domain description injected into AI review prompts. Swap this value for a different industry to re-target the same engine -- this is the only industry-specific piece of the classification pipeline.'
WHERE NOT EXISTS (SELECT 1 FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'INDUSTRY_CONTEXT');

SET ai_model         = (SELECT CONFIG_VALUE FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL');
SET industry_context = (SELECT CONFIG_VALUE FROM ORE_APP_CONFIG WHERE CONFIG_KEY = 'INDUSTRY_CONTEXT');
SET run_id           = (SELECT RUN_ID FROM ORE_DETECTED_CHANGES ORDER BY DETECTED_TS DESC LIMIT 1);

-- IDENTIFIER() does not accept an expression (e.g. $DEMO_DB || '.SCHEMA.TABLE')
-- inline -- each concatenated name is precomputed into its own variable
-- first, then passed to IDENTIFIER() bare.
SET _TBL_TABLES  = $DEMO_DB || '.INFORMATION_SCHEMA.TABLES';
SET _TBL_COLUMNS = $DEMO_DB || '.INFORMATION_SCHEMA.COLUMNS';

-- -----------------------------------------------------------------------------
-- Build one prompt per not-yet-reviewed candidate, call AI_COMPLETE, parse
-- the structured response, and write it back.
-- -----------------------------------------------------------------------------
UPDATE ORE_CLASSIFIED_CANDIDATES cc
SET
    AI_AGREES_WITH_RULE = ai.AGREES_WITH_RULE,
    AI_RECOMMENDED_KIND = ai.RECOMMENDED_KIND,
    AI_CONFIDENCE        = ai.CONFIDENCE,
    AI_RATIONALE          = ai.RATIONALE,
    AI_INDUSTRY_NOTE       = ai.INDUSTRY_NOTE
FROM (
    WITH PROMPT_INPUT AS (
        SELECT
            cc.CANDIDATE_ID,
            'You are reviewing one proposed change to a data ontology (a node/edge-type graph model ' ||
            'derived from a relational schema). A rule engine already produced a first-draft classification; ' ||
            'your job is to sanity-check it and improve it.' || CHR(10) || CHR(10) ||
            'INDUSTRY CONTEXT:' || CHR(10) || $industry_context || CHR(10) || CHR(10) ||
            'RULE-BASED PROPOSAL:' || CHR(10) ||
            '- Source object: ' || cc.TABLE_SCHEMA || '.' || cc.TABLE_NAME ||
                COALESCE('.' || cc.COLUMN_NAME, '') || CHR(10) ||
            '- Rule-based classification: ' || cc.OBJECT_KIND || ' (rule applied: ' || cc.RULE_APPLIED || ')' || CHR(10) ||
            '- Proposed name: ' || COALESCE(cc.PROPOSED_NAME, '(none)') || CHR(10) ||
            '- Proposed edge endpoints: ' || COALESCE(cc.EDGE_FROM, '(n/a)') || ' -> ' || COALESCE(cc.EDGE_TO, '(n/a)') || CHR(10) ||
            '- Rule engine details (JSON): ' || TO_VARCHAR(cc.RAW_DETAILS) || CHR(10) || CHR(10) ||
            'SOURCE METADATA (author-written comments on the actual source table/column, if any):' || CHR(10) ||
            '- Table comment: ' || COALESCE(st.COMMENT, '(none)') || CHR(10) ||
            '- Column comment: ' || COALESCE(sc.COMMENT, '(n/a -- this is a table-level candidate)') || CHR(10) || CHR(10) ||
            'TASK:' || CHR(10) ||
            'Decide whether you agree with the rule-based classification above. If you disagree, say what it ' ||
            'should be instead and why -- common reasons include: the rule engine cannot see undeclared foreign ' ||
            'keys, may misjudge a genuinely ambiguous reified-entity case, or a source comment reveals context ' ||
            'the raw schema shape doesn''t.' || CHR(10) || CHR(10) ||
            'GUARDRAIL -- recommending a new node/entity type: do not recommend NODE_TYPE for a column or ' ||
            'table just because it represents a meaningful business concept. Only recommend NODE_TYPE when at ' ||
            'least one of these actually holds: (a) it would carry multiple attributes of its own beyond just ' ||
            'identifying its parent, (b) it is independently identifiable with its own lifecycle -- it can be ' ||
            'created, updated, or retired separately from its parent -- or (c) it corresponds to a recognized ' ||
            'industry-standard entity (name the standard in industry_note if so; a vague thematic resemblance ' ||
            'to a standard does not count). A single scalar column that just describes an attribute of its ' ||
            'parent (a date, a status, a code) stays an ATTRIBUTE even when that attribute is domain-significant.' ||
            CHR(10) || CHR(10) ||
            'CONFIDENCE: calibrate it to the strength of the concrete evidence you actually have, not to how ' ||
            'plausible your reasoning sounds in the abstract. Do not default to a similar number across ' ||
            'different candidates -- differentiate based on the evidence for each one specifically:' || CHR(10) ||
            '  - 0.85-1.0: an explicit source comment, constraint, or unambiguous structural signal directly supports your recommendation.' || CHR(10) ||
            '  - 0.5-0.84: your recommendation is a reasonable inference, but not directly stated in the metadata.' || CHR(10) ||
            '  - below 0.5: your recommendation is speculative or only loosely supported.' || CHR(10) || CHR(10) ||
            'If the industry context above suggests a more standard name or a relevant external vocabulary/' ||
            'standard mapping, say so in industry_note -- otherwise leave industry_note as an empty string. ' ||
            'Respond ONLY with the requested JSON.'
                AS PROMPT_TEXT
        FROM ORE_CLASSIFIED_CANDIDATES cc
        LEFT JOIN IDENTIFIER($_TBL_TABLES) st
          ON st.TABLE_SCHEMA = cc.TABLE_SCHEMA AND st.TABLE_NAME = cc.TABLE_NAME
        LEFT JOIN IDENTIFIER($_TBL_COLUMNS) sc
          ON sc.TABLE_SCHEMA = cc.TABLE_SCHEMA AND sc.TABLE_NAME = cc.TABLE_NAME AND sc.COLUMN_NAME = cc.COLUMN_NAME
        WHERE cc.RUN_ID = $run_id
          AND cc.AI_RECOMMENDED_KIND IS NULL
    ),
    AI_RESPONSE AS (
        SELECT
            CANDIDATE_ID,
            PARSE_JSON(
                AI_COMPLETE(
                    model => $ai_model,
                    prompt => PROMPT_TEXT,
                    response_format => {
                        'type': 'json',
                        'schema': {
                            'type': 'object',
                            'properties': {
                                'agrees_with_rule':        {'type': 'boolean'},
                                'recommended_object_kind': {'type': 'string', 'enum': ['ATTRIBUTE', 'EDGE_TYPE', 'NODE_TYPE', 'FLAGGED']},
                                'confidence':              {'type': 'number'},
                                'rationale':               {'type': 'string'},
                                'industry_note':           {'type': 'string'}
                            },
                            'required': ['agrees_with_rule', 'recommended_object_kind', 'confidence', 'rationale', 'industry_note']
                        }
                    }
                )
            ) AS RESP
        FROM PROMPT_INPUT
    )
    SELECT
        CANDIDATE_ID,
        RESP:agrees_with_rule::BOOLEAN        AS AGREES_WITH_RULE,
        RESP:recommended_object_kind::VARCHAR AS RECOMMENDED_KIND,
        RESP:confidence::FLOAT                AS CONFIDENCE,
        RESP:rationale::VARCHAR               AS RATIONALE,
        RESP:industry_note::VARCHAR           AS INDUSTRY_NOTE
    FROM AI_RESPONSE
) ai
WHERE cc.CANDIDATE_ID = ai.CANDIDATE_ID;

-- Sanity check
SELECT
    TABLE_NAME, COLUMN_NAME, OBJECT_KIND AS RULE_KIND, AI_RECOMMENDED_KIND,
    AI_AGREES_WITH_RULE, AI_CONFIDENCE, AI_RATIONALE, AI_INDUSTRY_NOTE
FROM ORE_CLASSIFIED_CANDIDATES
WHERE RUN_ID = $run_id
ORDER BY TABLE_NAME, COLUMN_NAME;
