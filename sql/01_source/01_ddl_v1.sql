-- =============================================================================
-- 01_ddl_v1.sql
-- "Week 0" source schema: a small HCLS provider-directory slice, already fully
-- mapped into the ontology layer (see sql/02_ontology). This is the baseline
-- the refresh engine will later diff a "week 1" schema change against.
--
-- Industry-specific column choices (NPI, taxonomy codes, etc.) are the only
-- HCLS-flavored part of this demo -- the refresh engine itself (02_ontology
-- onward) never assumes healthcare; it just walks INFORMATION_SCHEMA
-- metadata and, for FK/PK detail, SHOW PRIMARY KEYS / SHOW IMPORTED KEYS
-- (Snowflake has no INFORMATION_SCHEMA.KEY_COLUMN_USAGE).
--
-- All objects are prefixed SRC_ -- this lets the whole demo live in a single
-- shared schema (see sql/00_setup/00_create_sandbox.sql) if that's all you
-- have access to, with no naming collisions against the ONTOLOGY/CONTROL/APP
-- layers' own objects.
--
-- Table and column COMMENTs are more than documentation here: they're the
-- kind of source-side metadata a real classification/AI-review step would
-- read to ground its suggestions (e.g. sql/03_refresh_engine's AI pass),
-- so they're written the way a real source system's comments would be.
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB    = 'ORE_DEMO_DB';
SET SRC_SCHEMA = 'ORE_SRC';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($SRC_SCHEMA);

-- Reference / lookup style tables -------------------------------------------

CREATE OR REPLACE TABLE SRC_LANGUAGE (
    LANGUAGE_CODE   VARCHAR(10)   NOT NULL COMMENT 'Short code identifying the language (loosely ISO 639-1 style; not enforced in this demo).',
    LANGUAGE_NAME   VARCHAR(100)  NOT NULL COMMENT 'Human-readable language name.',
    CONSTRAINT PK_SRC_LANGUAGE PRIMARY KEY (LANGUAGE_CODE)
)
COMMENT = 'A spoken/written language a professional can communicate in or a facility can serve patients in.';

CREATE OR REPLACE TABLE SRC_SPECIALTY (
    SPECIALTY_CODE  VARCHAR(20)   NOT NULL COMMENT 'Internal short code for the specialty.',
    SPECIALTY_NAME  VARCHAR(200)  NOT NULL COMMENT 'Human-readable specialty name.',
    TAXONOMY_CODE   VARCHAR(20)            COMMENT 'External NUCC health care provider taxonomy code, if mapped.',
    CONSTRAINT PK_SRC_SPECIALTY PRIMARY KEY (SPECIALTY_CODE)
)
COMMENT = 'A clinical specialty a professional may practice in.';

CREATE OR REPLACE TABLE SRC_ADDRESS (
    ADDRESS_ID      NUMBER        NOT NULL COMMENT 'Surrogate primary key.',
    LINE1           VARCHAR(200)  NOT NULL COMMENT 'Street address, line 1.',
    LINE2           VARCHAR(200)           COMMENT 'Street address, line 2 (suite/unit); optional.',
    CITY            VARCHAR(100)  NOT NULL COMMENT 'City name.',
    STATE           VARCHAR(2)    NOT NULL COMMENT 'Two-letter US state code.',
    POSTAL_CODE     VARCHAR(10)   NOT NULL COMMENT 'Postal / ZIP code.',
    COUNTRY         VARCHAR(2)    NOT NULL DEFAULT 'US' COMMENT 'Two-letter ISO 3166-1 country code.',
    CONSTRAINT PK_SRC_ADDRESS PRIMARY KEY (ADDRESS_ID)
)
COMMENT = 'A physical postal address, referenced by practice locations and facilities.';

-- Node-shaped tables -----------------------------------------------------------

CREATE OR REPLACE TABLE SRC_PRACTICE_LOCATION (
    LOCATION_ID     NUMBER        NOT NULL COMMENT 'Surrogate primary key.',
    ADDRESS_ID      NUMBER        NOT NULL COMMENT 'FK to SRC_ADDRESS -- the physical address of this location.',
    LOCATION_NAME   VARCHAR(200)  NOT NULL COMMENT 'Display name of the practice location.',
    PHONE           VARCHAR(20)            COMMENT 'Main contact phone number for this location.',
    CONSTRAINT PK_SRC_PRACTICE_LOCATION PRIMARY KEY (LOCATION_ID),
    CONSTRAINT FK_SRC_LOCATION_ADDRESS FOREIGN KEY (ADDRESS_ID) REFERENCES SRC_ADDRESS (ADDRESS_ID)
)
COMMENT = 'A physical place where care is delivered; has exactly one address and may host multiple professionals.';

CREATE OR REPLACE TABLE SRC_PROVIDER_PROFESSIONAL (
    PROVIDER_ID             NUMBER        NOT NULL COMMENT 'Surrogate primary key.',
    NPI                     VARCHAR(10)   NOT NULL COMMENT 'National Provider Identifier (10-digit, type 1 -- individual).',
    FIRST_NAME              VARCHAR(100)  NOT NULL COMMENT 'Given name.',
    LAST_NAME               VARCHAR(100)  NOT NULL COMMENT 'Family name.',
    PRIMARY_SPECIALTY_CODE  VARCHAR(20)            COMMENT 'FK to SRC_SPECIALTY -- the professional''s primary specialty; nullable.',
    CONSTRAINT PK_SRC_PROVIDER_PROFESSIONAL PRIMARY KEY (PROVIDER_ID),
    CONSTRAINT FK_SRC_PROF_SPECIALTY FOREIGN KEY (PRIMARY_SPECIALTY_CODE) REFERENCES SRC_SPECIALTY (SPECIALTY_CODE)
)
COMMENT = 'An individual healthcare professional -- the "Provider" node type, professional subtype.';

CREATE OR REPLACE TABLE SRC_PROVIDER_FACILITY (
    FACILITY_ID     NUMBER        NOT NULL COMMENT 'Surrogate primary key.',
    ADDRESS_ID      NUMBER        NOT NULL COMMENT 'FK to SRC_ADDRESS -- the physical address of this facility.',
    FACILITY_NAME   VARCHAR(200)  NOT NULL COMMENT 'Display name of the facility.',
    FACILITY_NPI    VARCHAR(10)   NOT NULL COMMENT 'National Provider Identifier for the facility (10-digit, type 2 -- organizational).',
    FACILITY_TYPE   VARCHAR(50)   NOT NULL COMMENT 'Facility category, e.g. CLINIC, HOSPITAL, LAB.',
    CONSTRAINT PK_SRC_PROVIDER_FACILITY PRIMARY KEY (FACILITY_ID),
    CONSTRAINT FK_SRC_FACILITY_ADDRESS FOREIGN KEY (ADDRESS_ID) REFERENCES SRC_ADDRESS (ADDRESS_ID)
)
COMMENT = 'A facility such as a clinic or hospital -- the "Provider" node type, facility subtype.';

-- Junction (M:N) tables -- these already exist in v1 so the ontology has two
-- pre-existing edge types to compare v2's newly-detected junction against.

CREATE OR REPLACE TABLE SRC_PROFESSIONAL_PRACTICE_LOCATION (
    PROVIDER_ID     NUMBER        NOT NULL COMMENT 'FK to SRC_PROVIDER_PROFESSIONAL.',
    LOCATION_ID     NUMBER        NOT NULL COMMENT 'FK to SRC_PRACTICE_LOCATION.',
    CONSTRAINT PK_SRC_PROF_LOCATION PRIMARY KEY (PROVIDER_ID, LOCATION_ID),
    CONSTRAINT FK_SRC_PPL_PROVIDER FOREIGN KEY (PROVIDER_ID) REFERENCES SRC_PROVIDER_PROFESSIONAL (PROVIDER_ID),
    CONSTRAINT FK_SRC_PPL_LOCATION FOREIGN KEY (LOCATION_ID) REFERENCES SRC_PRACTICE_LOCATION (LOCATION_ID)
)
COMMENT = 'Junction: which professionals work at which practice locations (many-to-many).';

CREATE OR REPLACE TABLE SRC_FACILITY_LANGUAGE (
    FACILITY_ID     NUMBER        NOT NULL COMMENT 'FK to SRC_PROVIDER_FACILITY.',
    LANGUAGE_CODE   VARCHAR(10)   NOT NULL COMMENT 'FK to SRC_LANGUAGE.',
    CONSTRAINT PK_SRC_FACILITY_LANGUAGE PRIMARY KEY (FACILITY_ID, LANGUAGE_CODE),
    CONSTRAINT FK_SRC_FL_FACILITY FOREIGN KEY (FACILITY_ID) REFERENCES SRC_PROVIDER_FACILITY (FACILITY_ID),
    CONSTRAINT FK_SRC_FL_LANGUAGE FOREIGN KEY (LANGUAGE_CODE) REFERENCES SRC_LANGUAGE (LANGUAGE_CODE)
)
COMMENT = 'Junction: which languages a facility can serve patients in (many-to-many).';

-- Note on FK enforcement: Snowflake accepts FOREIGN KEY constraints but does
-- not enforce them. They're declared here anyway because 03_refresh_engine
-- reads them (via SHOW PRIMARY KEYS / SHOW IMPORTED KEYS, not
-- INFORMATION_SCHEMA -- Snowflake has no KEY_COLUMN_USAGE view) to classify
-- deltas. A real silver layer without declared constraints would need a
-- naming-convention fallback instead (e.g. a `<table>_ID` suffix matching
-- another table's PK) -- out of scope for this demo.
