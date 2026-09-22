-- =============================================================================
-- 03_export_artifacts_for_review.sql
-- One row, one column: every generated artifact (template + AI-refined),
-- with its proposal context, packed into a single JSON array via TO_JSON.
-- Snowflake's JSON serialization escapes embedded quotes/newlines/etc.
-- correctly on its own -- no manual string-escaping needed.
--
-- Usage: run this, copy the single cell it returns, paste it into a .json
-- file. That file can be handed back for an external review of whether the
-- generated code looks right / has gaps -- not something this script does
-- itself, just prepares the export.
-- =============================================================================

SET DEMO_DB        = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

SELECT TO_JSON(
    ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'proposal_id',       p.PROPOSAL_ID,
            'final_name',        p.FINAL_NAME,
            'final_object_kind', p.FINAL_OBJECT_KIND,
            'edge_from',         p.EDGE_FROM,
            'edge_to',           p.EDGE_TO,
            'table_schema',      p.SOURCE_OBJECT:table_schema::VARCHAR,
            'table_name',        p.SOURCE_OBJECT:table_name::VARCHAR,
            'column_name',       p.SOURCE_OBJECT:column_name::VARCHAR,
            'artifact_id',       g.ARTIFACT_ID,
            'artifact_type',     g.ARTIFACT_TYPE,
            'dev_status',        g.DEV_STATUS,
            'template_sql',      g.TEMPLATE_SQL,
            'ai_refined_sql',    g.AI_REFINED_SQL,
            'ai_notes',          g.AI_NOTES
        )
    ) WITHIN GROUP (ORDER BY g.GENERATED_TS, g.PROPOSAL_ID, g.ARTIFACT_TYPE)
) AS ARTIFACTS_JSON
FROM ORE_GENERATED_ARTIFACTS g
JOIN ORE_CANDIDATE_PROPOSALS p ON p.PROPOSAL_ID = g.PROPOSAL_ID;
