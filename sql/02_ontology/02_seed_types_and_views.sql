-- =============================================================================
-- 02_seed_types_and_views.sql
-- Registers the v1 source objects as node/edge types, and creates the
-- per-type views that make accessing the graph more specific and less
-- generic than querying ONT_KG_NODE/ONT_KG_EDGE directly.
--
-- This is exactly what sql/05_codegen/01_generate_artifacts_proc.sql drafts
-- automatically for *newly approved* types later -- these first six node
-- types and five edge types are the pre-existing baseline, seeded by hand
-- once, the same way a real onboarding of an existing source would be.
-- =============================================================================

SET DEMO_DB         = 'ORE_DEMO_DB';
SET ONTOLOGY_SCHEMA = 'ORE_ONTOLOGY';
SET SRC_SCHEMA      = 'ORE_SRC';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($ONTOLOGY_SCHEMA);

-- SOURCE_OBJECT values below use TRIM($SRC_SCHEMA, '"'), not $SRC_SCHEMA
-- directly and not a hardcoded 'SRC' literal. Two things at once: (1) this
-- has to be the REAL schema name, not a hardcoded string, because
-- 02_classify_columns.sql / 03_classify_new_tables_proc.sql later match
-- SOURCE_OBJECT against TABLE_SCHEMA || '.' || TABLE_NAME as reported by
-- Snowflake itself -- a hardcoded 'SRC' would silently never match in an
-- environment where the schema isn't literally named that. (2) it must be
-- the UNQUOTED form even if your schema needs double-quoting to reference
-- (e.g. contains dots or @) -- same reasoning as ORE_SOURCE_SCOPE's
-- SCHEMA_PATTERN (see sql/02_ontology/01_ontology_core_ddl.sql): Snowflake
-- metadata (and hence TABLE_SCHEMA in ORE_DETECTED_CHANGES) stores schema
-- names without their quote characters.
--
-- -----------------------------------------------------------------------------
-- Node types
-- -----------------------------------------------------------------------------
INSERT INTO ONT_NODE_TYPES (NODE_TYPE, DISPLAY_NAME, DESCRIPTION, SOURCE_OBJECT) VALUES
    ('PROVIDER_PROFESSIONAL', 'Provider (Professional)', 'An individual healthcare professional.', TRIM($SRC_SCHEMA, '"') || '.SRC_PROVIDER_PROFESSIONAL'),
    ('PROVIDER_FACILITY',     'Provider (Facility)',     'A facility such as a clinic or hospital.', TRIM($SRC_SCHEMA, '"') || '.SRC_PROVIDER_FACILITY'),
    ('PRACTICE_LOCATION',     'Practice Location',       'A physical place where care is delivered.', TRIM($SRC_SCHEMA, '"') || '.SRC_PRACTICE_LOCATION'),
    ('ADDRESS',               'Address',                 'A postal address.', TRIM($SRC_SCHEMA, '"') || '.SRC_ADDRESS'),
    ('SPECIALTY',             'Specialty',                'A clinical specialty / taxonomy classification.', TRIM($SRC_SCHEMA, '"') || '.SRC_SPECIALTY'),
    ('LANGUAGE',              'Language',                 'A spoken/written language.', TRIM($SRC_SCHEMA, '"') || '.SRC_LANGUAGE');

CREATE OR REPLACE VIEW V_ONT_PROVIDER_PROFESSIONAL
COMMENT = 'Per-type view over ONT_KG_NODE for node type PROVIDER_PROFESSIONAL.'
AS
    SELECT NODE_SK, NODE_ID, PROPS FROM ONT_KG_NODE WHERE NODE_TYPE = 'PROVIDER_PROFESSIONAL';

CREATE OR REPLACE VIEW V_ONT_PROVIDER_FACILITY
COMMENT = 'Per-type view over ONT_KG_NODE for node type PROVIDER_FACILITY.'
AS
    SELECT NODE_SK, NODE_ID, PROPS FROM ONT_KG_NODE WHERE NODE_TYPE = 'PROVIDER_FACILITY';

CREATE OR REPLACE VIEW V_ONT_PRACTICE_LOCATION
COMMENT = 'Per-type view over ONT_KG_NODE for node type PRACTICE_LOCATION.'
AS
    SELECT NODE_SK, NODE_ID, PROPS FROM ONT_KG_NODE WHERE NODE_TYPE = 'PRACTICE_LOCATION';

CREATE OR REPLACE VIEW V_ONT_ADDRESS
COMMENT = 'Per-type view over ONT_KG_NODE for node type ADDRESS.'
AS
    SELECT NODE_SK, NODE_ID, PROPS FROM ONT_KG_NODE WHERE NODE_TYPE = 'ADDRESS';

CREATE OR REPLACE VIEW V_ONT_SPECIALTY
COMMENT = 'Per-type view over ONT_KG_NODE for node type SPECIALTY.'
AS
    SELECT NODE_SK, NODE_ID, PROPS FROM ONT_KG_NODE WHERE NODE_TYPE = 'SPECIALTY';

CREATE OR REPLACE VIEW V_ONT_LANGUAGE
COMMENT = 'Per-type view over ONT_KG_NODE for node type LANGUAGE.'
AS
    SELECT NODE_SK, NODE_ID, PROPS FROM ONT_KG_NODE WHERE NODE_TYPE = 'LANGUAGE';

-- -----------------------------------------------------------------------------
-- Edge types
-- -----------------------------------------------------------------------------
INSERT INTO ONT_EDGE_TYPES (EDGE_TYPE, DISPLAY_NAME, DESCRIPTION, FROM_NODE_TYPE, TO_NODE_TYPE, SOURCE_OBJECT) VALUES
    ('PROFESSIONAL_HAS_SPECIALTY',    'Professional has specialty',     'Scalar FK: SRC_PROVIDER_PROFESSIONAL.PRIMARY_SPECIALTY_CODE',  'PROVIDER_PROFESSIONAL', 'SPECIALTY',         TRIM($SRC_SCHEMA, '"') || '.SRC_PROVIDER_PROFESSIONAL'),
    ('LOCATION_HAS_ADDRESS',          'Location has address',           'Scalar FK: SRC_PRACTICE_LOCATION.ADDRESS_ID',                   'PRACTICE_LOCATION',     'ADDRESS',            TRIM($SRC_SCHEMA, '"') || '.SRC_PRACTICE_LOCATION'),
    ('FACILITY_HAS_ADDRESS',          'Facility has address',           'Scalar FK: SRC_PROVIDER_FACILITY.ADDRESS_ID',                   'PROVIDER_FACILITY',     'ADDRESS',            TRIM($SRC_SCHEMA, '"') || '.SRC_PROVIDER_FACILITY'),
    ('PROFESSIONAL_WORKS_AT_LOCATION','Professional works at location', 'Junction table: SRC_PROFESSIONAL_PRACTICE_LOCATION',           'PROVIDER_PROFESSIONAL', 'PRACTICE_LOCATION',  TRIM($SRC_SCHEMA, '"') || '.SRC_PROFESSIONAL_PRACTICE_LOCATION'),
    ('FACILITY_SERVES_LANGUAGE',      'Facility serves language',       'Junction table: SRC_FACILITY_LANGUAGE',                         'PROVIDER_FACILITY',     'LANGUAGE',           TRIM($SRC_SCHEMA, '"') || '.SRC_FACILITY_LANGUAGE');

CREATE OR REPLACE VIEW V_ONT_PROFESSIONAL_HAS_SPECIALTY
COMMENT = 'Per-type view over ONT_KG_EDGE for edge type PROFESSIONAL_HAS_SPECIALTY.'
AS
    SELECT e.EDGE_SK, src.NODE_ID AS PROVIDER_ID, dst.NODE_ID AS SPECIALTY_CODE, e.PROPS
    FROM ONT_KG_EDGE e JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK
    WHERE e.EDGE_TYPE = 'PROFESSIONAL_HAS_SPECIALTY';

CREATE OR REPLACE VIEW V_ONT_LOCATION_HAS_ADDRESS
COMMENT = 'Per-type view over ONT_KG_EDGE for edge type LOCATION_HAS_ADDRESS.'
AS
    SELECT e.EDGE_SK, src.NODE_ID AS LOCATION_ID, dst.NODE_ID AS ADDRESS_ID, e.PROPS
    FROM ONT_KG_EDGE e JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK
    WHERE e.EDGE_TYPE = 'LOCATION_HAS_ADDRESS';

CREATE OR REPLACE VIEW V_ONT_FACILITY_HAS_ADDRESS
COMMENT = 'Per-type view over ONT_KG_EDGE for edge type FACILITY_HAS_ADDRESS.'
AS
    SELECT e.EDGE_SK, src.NODE_ID AS FACILITY_ID, dst.NODE_ID AS ADDRESS_ID, e.PROPS
    FROM ONT_KG_EDGE e JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK
    WHERE e.EDGE_TYPE = 'FACILITY_HAS_ADDRESS';

CREATE OR REPLACE VIEW V_ONT_PROFESSIONAL_WORKS_AT_LOCATION
COMMENT = 'Per-type view over ONT_KG_EDGE for edge type PROFESSIONAL_WORKS_AT_LOCATION.'
AS
    SELECT e.EDGE_SK, src.NODE_ID AS PROVIDER_ID, dst.NODE_ID AS LOCATION_ID, e.PROPS
    FROM ONT_KG_EDGE e JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK
    WHERE e.EDGE_TYPE = 'PROFESSIONAL_WORKS_AT_LOCATION';

CREATE OR REPLACE VIEW V_ONT_FACILITY_SERVES_LANGUAGE
COMMENT = 'Per-type view over ONT_KG_EDGE for edge type FACILITY_SERVES_LANGUAGE.'
AS
    SELECT e.EDGE_SK, src.NODE_ID AS FACILITY_ID, dst.NODE_ID AS LANGUAGE_CODE, e.PROPS
    FROM ONT_KG_EDGE e JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK
    WHERE e.EDGE_TYPE = 'FACILITY_SERVES_LANGUAGE';
