-- =============================================================================
-- 03_ddl_v2_delta.sql
-- "Week 1" schema changes. Do NOT run this until you've run the full refresh
-- cycle once against v1 (sql/02_ontology + an initial 03_refresh_engine pass
-- with zero deltas) so you have a clean baseline to diff from.
--
-- This single script exercises all four classification cases the engine handles:
--
--   1. New scalar column on an existing mapped table
--        -> SRC_PROVIDER_PROFESSIONAL.NPI_DEACTIVATION_DATE
--        -> expect: ATTRIBUTE candidate (added to PROVIDER_PROFESSIONAL's PROPS)
--
--   2. New FK column, self-referencing (hierarchy)
--        -> SRC_PROVIDER_PROFESSIONAL.SUPERVISING_PROVIDER_ID -> SRC_PROVIDER_PROFESSIONAL
--        -> expect: EDGE_TYPE candidate, self-loop ("supervises")
--
--   3. New table shaped like a pure junction (M:N, composite PK = both FKs,
--      at most one extra attribute)
--        -> SRC_PROFESSIONAL_LANGUAGE (PROVIDER_ID, LANGUAGE_CODE, PROFICIENCY_LEVEL)
--        -> expect: EDGE_TYPE candidate, auto-classified, no human needed
--           (mirrors the SRC_FACILITY_LANGUAGE edge type that already exists)
--
--   4. New table whose composite PK is (nearly) all FKs, but which carries
--      *real* attributes beyond those FKs -- the reified-entity judgment call
--        -> SRC_PROFESSIONAL_LOCATION_ASSIGNMENT
--           (PROVIDER_ID, LOCATION_ID, SCHEDULE_START_DATE, SCHEDULE_END_DATE,
--            DAYS_OF_WEEK, IS_ON_CALL)
--        -> expect: FLAGGED candidate -- "is this just a richer version of
--           PROFESSIONAL_PRACTICE_LOCATION, or a new ON_CALL_ASSIGNMENT node?"
--           This is the one case the decision tree can't resolve on its own;
--           it's meant to reach the BA/AI review step, not be auto-approved.
-- =============================================================================

SET DEMO_DB    = 'ORE_DEMO_DB';
SET SRC_SCHEMA = 'ORE_SRC';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($SRC_SCHEMA);

-- 1. New scalar column ---------------------------------------------------------
ALTER TABLE SRC_PROVIDER_PROFESSIONAL ADD COLUMN NPI_DEACTIVATION_DATE DATE
    COMMENT 'Date this provider''s NPI was deactivated in the NPPES registry, if applicable.';

-- 2. New self-referencing FK ---------------------------------------------------
ALTER TABLE SRC_PROVIDER_PROFESSIONAL ADD COLUMN SUPERVISING_PROVIDER_ID NUMBER
    COMMENT 'FK to SRC_PROVIDER_PROFESSIONAL -- the supervising provider, for professionals practicing under supervision (e.g. residents, NPs/PAs in some states). Nullable; self-referencing.';
ALTER TABLE SRC_PROVIDER_PROFESSIONAL
    ADD CONSTRAINT FK_SRC_PROF_SUPERVISOR FOREIGN KEY (SUPERVISING_PROVIDER_ID)
    REFERENCES SRC_PROVIDER_PROFESSIONAL (PROVIDER_ID);

-- 3. New pure-junction table ----------------------------------------------------
CREATE OR REPLACE TABLE SRC_PROFESSIONAL_LANGUAGE (
    PROVIDER_ID         NUMBER        NOT NULL COMMENT 'FK to SRC_PROVIDER_PROFESSIONAL.',
    LANGUAGE_CODE       VARCHAR(10)   NOT NULL COMMENT 'FK to SRC_LANGUAGE.',
    PROFICIENCY_LEVEL   VARCHAR(20)            COMMENT 'Self-reported proficiency, e.g. NATIVE, FLUENT, CONVERSATIONAL.',
    CONSTRAINT PK_SRC_PROFESSIONAL_LANGUAGE PRIMARY KEY (PROVIDER_ID, LANGUAGE_CODE),
    CONSTRAINT FK_SRC_PL_PROVIDER FOREIGN KEY (PROVIDER_ID) REFERENCES SRC_PROVIDER_PROFESSIONAL (PROVIDER_ID),
    CONSTRAINT FK_SRC_PL_LANGUAGE FOREIGN KEY (LANGUAGE_CODE) REFERENCES SRC_LANGUAGE (LANGUAGE_CODE)
)
COMMENT = 'Junction: which languages a professional can communicate with patients in (many-to-many). New in v2 -- mirrors the pre-existing SRC_FACILITY_LANGUAGE edge.';

-- 4. New table -- FKs make up the PK, but real attributes remain -> FLAG -------
CREATE OR REPLACE TABLE SRC_PROFESSIONAL_LOCATION_ASSIGNMENT (
    PROVIDER_ID          NUMBER        NOT NULL COMMENT 'FK to SRC_PROVIDER_PROFESSIONAL.',
    LOCATION_ID          NUMBER        NOT NULL COMMENT 'FK to SRC_PRACTICE_LOCATION.',
    SCHEDULE_START_DATE  DATE          NOT NULL COMMENT 'Date this coverage assignment begins.',
    SCHEDULE_END_DATE    DATE                   COMMENT 'Date this coverage assignment ends; NULL if open-ended.',
    DAYS_OF_WEEK         VARCHAR(50)            COMMENT 'Comma-separated days this assignment applies to, e.g. MON,WED,FRI.',
    IS_ON_CALL           BOOLEAN       DEFAULT FALSE COMMENT 'TRUE if this assignment is on-call coverage rather than a regular schedule.',
    CONSTRAINT PK_SRC_PROF_LOCATION_ASSIGNMENT PRIMARY KEY (PROVIDER_ID, LOCATION_ID),
    CONSTRAINT FK_SRC_PLA_PROVIDER FOREIGN KEY (PROVIDER_ID) REFERENCES SRC_PROVIDER_PROFESSIONAL (PROVIDER_ID),
    CONSTRAINT FK_SRC_PLA_LOCATION FOREIGN KEY (LOCATION_ID) REFERENCES SRC_PRACTICE_LOCATION (LOCATION_ID)
)
COMMENT = 'New in v2: a professional''s scheduled coverage (regular or on-call) at a practice location. Deliberately ambiguous vs. SRC_PROFESSIONAL_PRACTICE_LOCATION for the classification demo -- same node pair, but with real attributes beyond the FKs.';

-- Optional sample data for the new objects, so the ontology views have
-- something to show once these are approved and loaded.
INSERT INTO SRC_PROFESSIONAL_LANGUAGE (PROVIDER_ID, LANGUAGE_CODE, PROFICIENCY_LEVEL) VALUES
    (1, 'EN', 'NATIVE'), (1, 'ES', 'FLUENT'), (2, 'EN', 'NATIVE'), (3, 'EN', 'NATIVE'), (3, 'ZH', 'CONVERSATIONAL');

INSERT INTO SRC_PROFESSIONAL_LOCATION_ASSIGNMENT
    (PROVIDER_ID, LOCATION_ID, SCHEDULE_START_DATE, SCHEDULE_END_DATE, DAYS_OF_WEEK, IS_ON_CALL) VALUES
    (1, 1, '2026-01-01', NULL, 'MON,TUE,WED,THU,FRI', FALSE),
    (3, 3, '2026-01-01', NULL, 'MON,WED,FRI',          TRUE);

UPDATE SRC_PROVIDER_PROFESSIONAL SET SUPERVISING_PROVIDER_ID = 1 WHERE PROVIDER_ID = 2;
