-- =============================================================================
-- 05_persist_candidates.sql
-- The one gate that decides what a human ever sees: takes this run's
-- reviewed candidates and inserts them into
-- ORE_CANDIDATE_PROPOSALS -- the BA review queue -- deduped against anything
-- already decided or already pending, via a stable content hash
-- (FINGERPRINT_KEY) rather than a surrogate ID, so the same delta detected
-- again next cycle maps back to the same logical proposal instead of piling
-- up duplicates.
--
-- Detect (01/01b) and classify (02/03/04) don't look at decision status at
-- all -- this script is the only place that does.
--
-- Also seeds FINAL_NAME/FINAL_OBJECT_KIND -- the BA-editable columns the
-- Control Plane app writes to, and what codegen reads (never PROPOSED_NAME/
-- OBJECT_KIND directly, which stay as the original rule/AI suggestion for
-- audit purposes). FINAL_NAME defaults to PROPOSED_NAME; FINAL_OBJECT_KIND
-- defaults to OBJECT_KIND, except FLAGGED candidates (not directly
-- actionable) default to AI_RECOMMENDED_KIND instead.
--
-- Run this after 04_ai_review_candidates.sql -- it always operates on the
-- most recent run, so nothing needs to be carried over by hand.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB        = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

SET run_id = (SELECT RUN_ID FROM ORE_DETECTED_CHANGES ORDER BY DETECTED_TS DESC LIMIT 1);

INSERT INTO ORE_CANDIDATE_PROPOSALS (
    PROPOSAL_ID, FINGERPRINT_KEY, OBJECT_KIND, FINAL_OBJECT_KIND, RULE_APPLIED, PROPOSED_NAME, FINAL_NAME,
    EDGE_FROM, EDGE_TO, SOURCE_OBJECT,
    AI_AGREES_WITH_RULE, AI_RECOMMENDED_KIND, AI_CONFIDENCE, AI_RATIONALE, AI_INDUSTRY_NOTE,
    STATUS, DETECTED_TS
)
SELECT
    UUID_STRING(),
    SHA2(cc.TABLE_SCHEMA || '.' || cc.TABLE_NAME || '.' || COALESCE(cc.COLUMN_NAME, ''), 256),
    cc.OBJECT_KIND,
    -- FLAGGED isn't directly actionable for codegen -- default to the AI's
    -- recommendation instead (still just a default; the BA can change it).
    -- Everything else defaults to the rule engine's own classification.
    CASE WHEN cc.OBJECT_KIND = 'FLAGGED' THEN cc.AI_RECOMMENDED_KIND ELSE cc.OBJECT_KIND END,
    cc.RULE_APPLIED,
    cc.PROPOSED_NAME,
    cc.PROPOSED_NAME,  -- FINAL_NAME defaults to PROPOSED_NAME, BA edits from there
    cc.EDGE_FROM,
    cc.EDGE_TO,
    OBJECT_CONSTRUCT(
        'candidate_id',         cc.CANDIDATE_ID,
        'run_id',                cc.RUN_ID,
        'table_schema',          cc.TABLE_SCHEMA,
        'table_name',            cc.TABLE_NAME,
        'column_name',           cc.COLUMN_NAME,
        'object_kind',           cc.OBJECT_KIND,
        'rule_applied',          cc.RULE_APPLIED,
        'proposed_name',         cc.PROPOSED_NAME,
        'edge_from',             cc.EDGE_FROM,
        'edge_to',               cc.EDGE_TO,
        'raw_details',           cc.RAW_DETAILS,
        'ai_agrees_with_rule',   cc.AI_AGREES_WITH_RULE,
        'ai_recommended_kind',   cc.AI_RECOMMENDED_KIND,
        'ai_confidence',         cc.AI_CONFIDENCE,
        'ai_rationale',          cc.AI_RATIONALE,
        'ai_industry_note',      cc.AI_INDUSTRY_NOTE
    ),
    cc.AI_AGREES_WITH_RULE,
    cc.AI_RECOMMENDED_KIND,
    cc.AI_CONFIDENCE,
    cc.AI_RATIONALE,
    cc.AI_INDUSTRY_NOTE,
    'PENDING',
    dc.DETECTED_TS
FROM ORE_CLASSIFIED_CANDIDATES cc
JOIN ORE_DETECTED_CHANGES dc
  ON dc.RUN_ID = cc.RUN_ID
 AND dc.TABLE_SCHEMA = cc.TABLE_SCHEMA
 AND dc.TABLE_NAME = cc.TABLE_NAME
 AND EQUAL_NULL(dc.COLUMN_NAME, cc.COLUMN_NAME)
WHERE cc.RUN_ID = $run_id
  AND NOT EXISTS (   -- already reviewed (approved/rejected) in an earlier cycle? don't resurface
        SELECT 1 FROM ORE_CANDIDATE_PROPOSALS p
        WHERE p.FINGERPRINT_KEY = SHA2(cc.TABLE_SCHEMA || '.' || cc.TABLE_NAME || '.' || COALESCE(cc.COLUMN_NAME, ''), 256)
          AND p.STATUS IN ('APPROVED', 'REJECTED')
      )
  AND NOT EXISTS (   -- already sitting in the queue from an earlier cycle? don't duplicate
        SELECT 1 FROM ORE_CANDIDATE_PROPOSALS p
        WHERE p.FINGERPRINT_KEY = SHA2(cc.TABLE_SCHEMA || '.' || cc.TABLE_NAME || '.' || COALESCE(cc.COLUMN_NAME, ''), 256)
          AND p.STATUS = 'PENDING'
      );

-- Sanity check -- this is the BA's review queue
SELECT
    PROPOSAL_ID, OBJECT_KIND, FINAL_OBJECT_KIND, RULE_APPLIED, PROPOSED_NAME, FINAL_NAME, EDGE_FROM, EDGE_TO,
    AI_AGREES_WITH_RULE, AI_RECOMMENDED_KIND, AI_CONFIDENCE, STATUS, DETECTED_TS
FROM ORE_CANDIDATE_PROPOSALS
WHERE STATUS = 'PENDING'
ORDER BY DETECTED_TS;
