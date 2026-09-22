-- =============================================================================
-- 01_record_decision_proc.sql
-- RECORD_DECISION -- the one place a BA's Approve/Reject/Defer decision gets
-- written. Updates ORE_CANDIDATE_PROPOSALS and inserts the corresponding
-- ORE_DECISION_AUDIT_LOG row together (a Snowflake procedure call is
-- implicitly one transaction, so both happen or neither does). The future
-- Control Plane app calls this -- it never writes STATUS/decision fields
-- directly itself, same "app just calls the procedure" principle already
-- used for codegen.
--
-- Also accepts an optional FINAL_NAME / FINAL_OBJECT_KIND edit, applied in
-- the same call as the decision -- matches the natural UI flow (a BA edits
-- the proposed name/kind, then clicks Approve/Reject/Defer) without needing
-- a separate "save my edits" round trip.
--
-- Closes three gaps identified before this app was scoped:
--   - DECIDED_BY comes from CURRENT_USER() (the app's real Snowflake
--     session identity), never a free-text field a BA could type anything
--     into.
--   - An APPROVED decision is rejected unless FINAL_OBJECT_KIND (after
--     applying any requested edit) is actually one of ATTRIBUTE/NODE_TYPE/
--     EDGE_TYPE -- guards against approving a FLAGGED proposal that never
--     got an AI review (so FINAL_OBJECT_KIND would still be NULL) before
--     it reaches codegen, which is a worse place to discover the problem.
--   - FINAL_NAME/FINAL_OBJECT_KIND edits are rejected outright once
--     ORE_GENERATED_ARTIFACTS already has rows for this proposal, so a
--     rename can never silently drift out of sync with code already drafted
--     against the old name.
--
-- Only proposals currently PENDING or DEFERRED can be decided -- APPROVED/
-- REJECTED is treated as final for that specific proposal row (matching
-- 05_persist_candidates.sql's own dedup logic, which never resurfaces an
-- already-APPROVED/REJECTED fingerprint; if the same underlying change is
-- detected again later, the pipeline creates a new proposal row, it doesn't
-- reopen this one).
--
-- Returns 'OK' on success, or a string starting with 'ERROR: ' describing
-- what went wrong -- no RAISE/exception block, consistent with every other
-- procedure in this project, so the caller (the app) just checks the
-- returned string rather than needing to catch a SQL exception.
--
-- Every procedure argument (P_*) is copied into a local variable via
-- SELECT ... INTO right at the top, and everything downstream (IF
-- conditions, RETURN) only touches those locals -- never a bare P_*
-- reference outside an actual SQL statement. This keeps bind-variable
-- resolution consistent throughout the procedure. Existence/duplicate
-- checks use COUNT(*) rather than relying on SELECT ... INTO's behavior
-- when a query matches zero rows, for the same reason.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB        = 'ORE_DEMO_DB';
SET CONTROL_SCHEMA = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($CONTROL_SCHEMA);

CREATE OR REPLACE PROCEDURE RECORD_DECISION(
    P_PROPOSAL_ID       VARCHAR,
    P_STATUS            VARCHAR,  -- 'APPROVED' | 'REJECTED' | 'DEFERRED'
    P_RATIONALE         VARCHAR,  -- nullable
    P_FINAL_NAME        VARCHAR,  -- nullable -- pass NULL to leave unchanged
    P_FINAL_OBJECT_KIND VARCHAR   -- nullable -- pass NULL to leave unchanged
)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_found          INT;
    v_current_status VARCHAR;
    v_current_name   VARCHAR;
    v_current_kind   VARCHAR;
    v_new_name       VARCHAR;
    v_new_kind       VARCHAR;
    v_status         VARCHAR;
    v_req_name       VARCHAR;
    v_req_kind       VARCHAR;
    v_artifact_count INT;
    v_decided_ts     TIMESTAMP_NTZ;
    v_msg            VARCHAR;
BEGIN
    -- Copy every argument into a local up front (see the header comment).
    SELECT UPPER(:P_STATUS), :P_FINAL_NAME, UPPER(:P_FINAL_OBJECT_KIND)
    INTO :v_status, :v_req_name, :v_req_kind;

    IF (v_status NOT IN ('APPROVED', 'REJECTED', 'DEFERRED')) THEN
        SELECT 'ERROR: P_STATUS must be APPROVED, REJECTED, or DEFERRED -- got ''' || :P_STATUS || '''.' INTO :v_msg;
        RETURN v_msg;
    END IF;

    SELECT COUNT(*) INTO :v_found FROM ORE_CANDIDATE_PROPOSALS WHERE PROPOSAL_ID = :P_PROPOSAL_ID;
    IF (v_found = 0) THEN
        SELECT 'ERROR: no proposal found with PROPOSAL_ID ' || :P_PROPOSAL_ID || '.' INTO :v_msg;
        RETURN v_msg;
    END IF;

    SELECT STATUS, FINAL_NAME, FINAL_OBJECT_KIND INTO :v_current_status, :v_current_name, :v_current_kind
    FROM ORE_CANDIDATE_PROPOSALS WHERE PROPOSAL_ID = :P_PROPOSAL_ID;

    IF (v_current_status NOT IN ('PENDING', 'DEFERRED')) THEN
        SELECT 'ERROR: proposal ' || :P_PROPOSAL_ID || ' is already ' || :v_current_status ||
               ' -- only PENDING or DEFERRED proposals can be decided.' INTO :v_msg;
        RETURN v_msg;
    END IF;

    -- Reject edits outright once codegen has already run for this proposal,
    -- rather than silently accepting or silently ignoring them.
    SELECT COUNT(*) INTO :v_artifact_count FROM ORE_GENERATED_ARTIFACTS WHERE PROPOSAL_ID = :P_PROPOSAL_ID;
    IF (v_artifact_count > 0 AND (v_req_name IS NOT NULL OR v_req_kind IS NOT NULL)) THEN
        SELECT 'ERROR: cannot change FINAL_NAME/FINAL_OBJECT_KIND -- code has already been generated for proposal ' ||
               :P_PROPOSAL_ID || '.' INTO :v_msg;
        RETURN v_msg;
    END IF;

    SELECT COALESCE(:v_req_name, :v_current_name), COALESCE(:v_req_kind, :v_current_kind)
    INTO :v_new_name, :v_new_kind;

    IF (v_status = 'APPROVED' AND (v_new_kind IS NULL OR v_new_kind NOT IN ('ATTRIBUTE', 'NODE_TYPE', 'EDGE_TYPE'))) THEN
        SELECT 'ERROR: cannot approve proposal ' || :P_PROPOSAL_ID || ' -- FINAL_OBJECT_KIND is ''' ||
               COALESCE(:v_new_kind, '(null)') || ''', not one of ATTRIBUTE/NODE_TYPE/EDGE_TYPE. ' ||
               'If this came from a FLAGGED candidate, it likely never got an AI recommendation -- pick a final kind before approving.'
        INTO :v_msg;
        RETURN v_msg;
    END IF;

    SELECT CURRENT_TIMESTAMP() INTO :v_decided_ts;

    UPDATE ORE_CANDIDATE_PROPOSALS
    SET STATUS = :v_status,
        DECIDED_BY = CURRENT_USER(),
        DECIDED_TS = :v_decided_ts,
        RATIONALE = :P_RATIONALE,
        FINAL_NAME = :v_new_name,
        FINAL_OBJECT_KIND = :v_new_kind
    WHERE PROPOSAL_ID = :P_PROPOSAL_ID;

    INSERT INTO ORE_DECISION_AUDIT_LOG (PROPOSAL_ID, STATUS, DECIDED_BY, DECIDED_TS, RATIONALE)
    SELECT :P_PROPOSAL_ID, :v_status, CURRENT_USER(), :v_decided_ts, :P_RATIONALE;

    RETURN 'OK';
END;
$$;

-- -----------------------------------------------------------------------------
-- Manual test -- substitute a real PROPOSAL_ID of your own (find one via
-- SELECT PROPOSAL_ID, FINAL_NAME, STATUS FROM ORE_CANDIDATE_PROPOSALS WHERE STATUS = 'PENDING';)
-- -----------------------------------------------------------------------------
-- CALL RECORD_DECISION('<paste a PENDING proposal_id>', 'DEFERRED', 'Testing RECORD_DECISION.', NULL, NULL);

-- Sanity check
SELECT PROPOSAL_ID, FINAL_NAME, FINAL_OBJECT_KIND, STATUS, DECIDED_BY, DECIDED_TS, RATIONALE
FROM ORE_CANDIDATE_PROPOSALS
ORDER BY DECIDED_TS DESC NULLS LAST
LIMIT 10;

SELECT * FROM ORE_DECISION_AUDIT_LOG ORDER BY DECIDED_TS DESC LIMIT 10;
