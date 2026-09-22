-- =============================================================================
-- 01_ontology_core_ddl.sql
-- The derived-ontology layer (ONT_ prefix, in the ONTOLOGY schema) and the
-- refresh engine's own control tables (ORE_ prefix -- "Ontology Refresh
-- Engine" -- in the CONTROL schema). This DDL is completely industry-agnostic
-- -- nothing here mentions providers, addresses, etc. The HCLS shape only
-- shows up in the seed data in 02_seed_types_and_views.sql.
--
-- Prefixes (ONT_ / ORE_, and SRC_ from sql/01_source) exist so every layer of
-- this demo can share a single schema without name collisions, if that's the
-- environment you're working in (see sql/00_setup/00_create_sandbox.sql).
-- =============================================================================

-- Config -- same variables defined in sql/00_setup/00_create_sandbox.sql.
-- Re-declared here so this script is runnable on its own in a fresh session.
SET DEMO_DB         = 'ORE_DEMO_DB';
SET ONTOLOGY_SCHEMA = 'ORE_ONTOLOGY';
SET CONTROL_SCHEMA  = 'ORE_CONTROL';

USE DATABASE IDENTIFIER($DEMO_DB);

-- =============================================================================
-- ONTOLOGY schema: dictionary + instance tables (ONT_ prefix)
-- =============================================================================
USE SCHEMA IDENTIFIER($ONTOLOGY_SCHEMA);

CREATE OR REPLACE TABLE ONT_NODE_TYPES (
    NODE_TYPE       VARCHAR(100)  NOT NULL COMMENT 'Unique type name, e.g. PROVIDER_PROFESSIONAL. Matches KG_NODE.NODE_TYPE and the corresponding V_ONT_<node_type> view.',
    DISPLAY_NAME    VARCHAR(200)  NOT NULL COMMENT 'Human-readable name shown to business users, e.g. "Provider (Professional)".',
    DESCRIPTION     VARCHAR(1000)          COMMENT 'Free-text description of what this node type represents.',
    SOURCE_OBJECT   VARCHAR(500)  NOT NULL COMMENT 'Fully-qualified source table this type is populated from, e.g. SRC.SRC_PROVIDER_PROFESSIONAL.',
    CREATED_TS      TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this type was registered in the ontology.',
    CREATED_BY      VARCHAR(100)  NOT NULL DEFAULT CURRENT_USER() COMMENT 'Who/what registered this type -- a developer for hand-seeded types, or the apply step for engine-approved ones.',
    CONSTRAINT PK_ONT_NODE_TYPES PRIMARY KEY (NODE_TYPE)
)
COMMENT = 'Dictionary of node types in the derived ontology -- one row per distinct "kind of thing" (e.g. Provider, Address, Specialty).';

CREATE OR REPLACE TABLE ONT_EDGE_TYPES (
    EDGE_TYPE       VARCHAR(100)  NOT NULL COMMENT 'Unique type name, e.g. PROFESSIONAL_HAS_SPECIALTY. Matches KG_EDGE.EDGE_TYPE and the corresponding V_ONT_<edge_type> view.',
    DISPLAY_NAME    VARCHAR(200)  NOT NULL COMMENT 'Human-readable name shown to business users, e.g. "Professional has specialty".',
    DESCRIPTION     VARCHAR(1000)          COMMENT 'Free-text description of what this relationship represents.',
    FROM_NODE_TYPE  VARCHAR(100)  NOT NULL COMMENT 'FK to ONT_NODE_TYPES -- the relationship''s source/subject node type.',
    TO_NODE_TYPE    VARCHAR(100)  NOT NULL COMMENT 'FK to ONT_NODE_TYPES -- the relationship''s target/object node type.',
    SOURCE_OBJECT   VARCHAR(500)  NOT NULL COMMENT 'Fully-qualified source table this edge is populated from -- an FK column''s table, or a junction table.',
    CREATED_TS      TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this type was registered in the ontology.',
    CREATED_BY      VARCHAR(100)  NOT NULL DEFAULT CURRENT_USER() COMMENT 'Who/what registered this type -- a developer for hand-seeded types, or the apply step for engine-approved ones.',
    CONSTRAINT PK_ONT_EDGE_TYPES PRIMARY KEY (EDGE_TYPE),
    CONSTRAINT FK_ONT_EDGE_FROM FOREIGN KEY (FROM_NODE_TYPE) REFERENCES ONT_NODE_TYPES (NODE_TYPE),
    CONSTRAINT FK_ONT_EDGE_TO   FOREIGN KEY (TO_NODE_TYPE)   REFERENCES ONT_NODE_TYPES (NODE_TYPE)
)
COMMENT = 'Dictionary of edge types in the derived ontology -- one row per distinct kind of relationship between two node types.';

CREATE OR REPLACE TABLE ONT_KG_NODE (
    NODE_SK         NUMBER        NOT NULL AUTOINCREMENT COMMENT 'Surrogate key, internal to the ontology layer. What KG_EDGE.SRC_SK/DST_SK point to.',
    NODE_ID         VARCHAR(200)  NOT NULL COMMENT 'The node''s natural/business key from its source table, stringified (e.g. "1" for PROVIDER_ID = 1).',
    NODE_TYPE       VARCHAR(100)  NOT NULL COMMENT 'FK to ONT_NODE_TYPES.',
    PROPS           VARIANT                COMMENT 'Every non-key source column for this instance, as a JSON object. New scalar source columns land here without a DDL change.',
    SOURCE_OBJECT   VARCHAR(500)  NOT NULL COMMENT 'Fully-qualified source table this row was loaded from.',
    LOAD_TS         TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this row was last loaded/refreshed.',
    CONSTRAINT PK_ONT_KG_NODE PRIMARY KEY (NODE_SK),
    CONSTRAINT FK_ONT_NODE_TYPE FOREIGN KEY (NODE_TYPE) REFERENCES ONT_NODE_TYPES (NODE_TYPE),
    -- Snowflake has no CREATE INDEX for standard tables, so this documents
    -- intent only -- like every other constraint in this project besides
    -- NOT NULL, it is NOT enforced. Load scripts (e.g. 03_initial_load_v1.sql
    -- and any future incremental load) are responsible for not inserting a
    -- duplicate (NODE_TYPE, NODE_ID) themselves.
    CONSTRAINT UQ_ONT_KG_NODE_NATURAL_KEY UNIQUE (NODE_TYPE, NODE_ID)
)
COMMENT = 'Instance table: one row per node (entity) across every node type in the ontology.';

CREATE OR REPLACE TABLE ONT_KG_EDGE (
    EDGE_SK         NUMBER        NOT NULL AUTOINCREMENT COMMENT 'Surrogate key, internal to the ontology layer.',
    EDGE_TYPE       VARCHAR(100)  NOT NULL COMMENT 'FK to ONT_EDGE_TYPES.',
    SRC_SK          NUMBER        NOT NULL COMMENT 'FK to ONT_KG_NODE.NODE_SK -- the relationship''s source/subject node.',
    DST_SK          NUMBER        NOT NULL COMMENT 'FK to ONT_KG_NODE.NODE_SK -- the relationship''s target/object node.',
    PROPS           VARIANT                COMMENT 'Edge-level attributes, as a JSON object -- e.g. a junction table''s columns beyond the two FKs.',
    SOURCE_OBJECT   VARCHAR(500)  NOT NULL COMMENT 'Fully-qualified source table this row was loaded from.',
    LOAD_TS         TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this row was last loaded/refreshed.',
    CONSTRAINT PK_ONT_KG_EDGE PRIMARY KEY (EDGE_SK),
    CONSTRAINT FK_ONT_EDGE_TYPE FOREIGN KEY (EDGE_TYPE) REFERENCES ONT_EDGE_TYPES (EDGE_TYPE),
    CONSTRAINT FK_ONT_EDGE_SRC  FOREIGN KEY (SRC_SK)    REFERENCES ONT_KG_NODE (NODE_SK),
    CONSTRAINT FK_ONT_EDGE_DST  FOREIGN KEY (DST_SK)    REFERENCES ONT_KG_NODE (NODE_SK)
)
COMMENT = 'Instance table: one row per edge (relationship) across every edge type in the ontology.';

-- Triples: a generic (subject, predicate, object) view over ONT_KG_NODE /
-- ONT_KG_EDGE. Implemented as a view here (cheap to keep in sync for a demo);
-- a higher-volume deployment might materialize this instead.
CREATE OR REPLACE VIEW V_ONT_TRIPLES
COMMENT = 'Generic (subject, predicate, object) triples view flattening both node attributes and edges -- the most generic possible way to query the graph, as opposed to the per-type V_ONT_* views.'
AS
    -- attribute triples: one row per property on a node
    SELECT
        n.NODE_TYPE || ':' || n.NODE_ID   AS SUBJECT,
        f.KEY                             AS PREDICATE,
        f.VALUE::VARCHAR                  AS OBJECT,
        'ATTRIBUTE'                       AS TRIPLE_KIND
    FROM ONT_KG_NODE n,
         LATERAL FLATTEN(input => n.PROPS) f
    UNION ALL
    -- relationship triples: one row per edge
    SELECT
        src.NODE_TYPE || ':' || src.NODE_ID AS SUBJECT,
        e.EDGE_TYPE                          AS PREDICATE,
        dst.NODE_TYPE || ':' || dst.NODE_ID  AS OBJECT,
        'EDGE'                                AS TRIPLE_KIND
    FROM ONT_KG_EDGE e
    JOIN ONT_KG_NODE src ON src.NODE_SK = e.SRC_SK
    JOIN ONT_KG_NODE dst ON dst.NODE_SK = e.DST_SK;

-- =============================================================================
-- CONTROL schema: refresh-engine state (ORE_ prefix = "Ontology Refresh Engine")
-- =============================================================================
USE SCHEMA IDENTIFIER($CONTROL_SCHEMA);

-- Only needed by the INFORMATION_SCHEMA detection path (01b) -- a maintained
-- snapshot to diff the live schema against, since INFORMATION_SCHEMA itself
-- has no history. Not needed by the ACCOUNT_USAGE path (01), which has
-- native CREATED/DELETED timestamps.
CREATE OR REPLACE TABLE ORE_SCHEMA_FINGERPRINT (
    TABLE_SCHEMA    VARCHAR(200)  NOT NULL COMMENT 'Source schema name at snapshot time.',
    TABLE_NAME      VARCHAR(200)  NOT NULL COMMENT 'Source table name at snapshot time.',
    COLUMN_NAME     VARCHAR(200)  NOT NULL COMMENT 'Source column name at snapshot time.',
    DATA_TYPE       VARCHAR(100)  NOT NULL COMMENT 'Source column data type at snapshot time -- compared to the live value to detect TYPE_CHANGED.',
    SNAPSHOT_TS     TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this fingerprint row was last refreshed.',
    CONSTRAINT PK_ORE_SCHEMA_FINGERPRINT PRIMARY KEY (TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME)
)
COMMENT = 'Last-known-state snapshot of the source schema, maintained by the INFORMATION_SCHEMA detection path (01b) since INFORMATION_SCHEMA has no built-in change history.';

-- Only needed by the ACCOUNT_USAGE detection path (01) -- a one-row watermark
-- recording when we last looked, so that run can ask ACCOUNT_USAGE "what
-- changed since then?" instead of maintaining a full snapshot. Not needed by
-- the INFORMATION_SCHEMA path (01b), whose "memory" is ORE_SCHEMA_FINGERPRINT
-- itself (a full snapshot, not a point in time).
CREATE OR REPLACE TABLE ORE_REFRESH_CONTROL (
    LAST_RUN_TS     TIMESTAMP_NTZ NOT NULL COMMENT 'Timestamp of the last successful ACCOUNT_USAGE-based detection run. Defaults to 1970-01-01 (i.e. "no prior run") until the first run completes, so the first run treats the entire current source schema as new -- see 01b_detect_account_usage.sql for how that first-run behavior should be handled.'
)
COMMENT = 'Single-row watermark for the ACCOUNT_USAGE detection path (01) -- "when did we last look", as opposed to ORE_SCHEMA_FINGERPRINT''s "what did we last see" for the INFORMATION_SCHEMA path (01b).';

-- Scopes detection to only the tables that are actually "source" tables --
-- necessary because in a single-shared-schema deployment (Scenario B in
-- sql/00_setup/00_create_sandbox.sql), SRC_/ONT_/ORE_ objects all live
-- together, and without this, the engine would try to detect "changes" on
-- its own ontology and control tables. In a properly schema-separated
-- deployment (Scenario A) this is a harmless no-op layered under the
-- existing TABLE_SCHEMA scoping in 01/01b, since ONT_/ORE_ objects are never
-- in the source schema to begin with -- but it's the same mechanism a real
-- deployment would use to exclude staging/temp tables from a source schema
-- it doesn't fully control, so it's not purely a workaround.
--
-- Matching: a table is in scope if it matches at least one INCLUDE row
-- (SCHEMA_PATTERN and TABLE_PATTERN both LIKE-matched) and no EXCLUDE row --
-- EXCLUDE always wins. Multiple INCLUDE rows are OR'd together, so multiple
-- source schemas are supported by adding one INCLUDE row per schema (e.g.
-- SCHEMA_PATTERN = 'BILLING_SRC', TABLE_PATTERN = '%') with no code change.
--
-- FUTURE EXTENSION -- multiple source DATABASES: this table only scopes
-- schema + table name because INFORMATION_SCHEMA is always scoped to the
-- current database in Snowflake, so 01b can only ever see one database at a
-- time regardless of what's configured here. Supporting multiple source
-- databases would mean either (a) running 01b once per database, or (b)
-- switching to the ACCOUNT_USAGE path (01), which is account-wide and
-- already has a TABLE_CATALOG column -- at which point a CATALOG_PATTERN
-- column could be added here the same way SCHEMA_PATTERN/TABLE_PATTERN work
-- today. Not implemented in this demo (single source database throughout).
CREATE OR REPLACE TABLE ORE_SOURCE_SCOPE (
    SCOPE_ID        NUMBER        NOT NULL AUTOINCREMENT COMMENT 'Surrogate key.',
    FILTER_TYPE     VARCHAR(10)   NOT NULL COMMENT 'INCLUDE or EXCLUDE. EXCLUDE always wins over INCLUDE when both match the same object.',
    SCHEMA_PATTERN  VARCHAR(200)  NOT NULL DEFAULT '%' COMMENT 'LIKE pattern matched against TABLE_SCHEMA, e.g. ''%'' (any schema) or ''BILLING_SRC'' (one specific schema). Use the UNQUOTED schema name even if referencing it elsewhere requires double quotes (e.g. a name containing dots or @) -- INFORMATION_SCHEMA/ACCOUNT_USAGE store TABLE_SCHEMA without surrounding quotes, so a quoted value here would never match.',
    TABLE_PATTERN   VARCHAR(200)  NOT NULL DEFAULT '%' COMMENT 'LIKE pattern matched against TABLE_NAME, e.g. ''SRC_%'' (the demo''s source-table naming convention) or ''%'' (any table in the matched schema).',
    DESCRIPTION     VARCHAR(500)           COMMENT 'Why this row exists, e.g. "demo: only SRC_-prefixed tables are real sources when sharing one schema".',
    CREATED_TS      TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this scope row was added.',
    CONSTRAINT PK_ORE_SOURCE_SCOPE PRIMARY KEY (SCOPE_ID)
    -- No CHECK constraint on FILTER_TYPE -- Snowflake's constraint support is
    -- limited to NOT NULL/UNIQUE/PRIMARY KEY/FOREIGN KEY (the latter three
    -- unenforced, same as elsewhere in this schema); valid values ('INCLUDE',
    -- 'EXCLUDE') are documented in the column comment above instead.
)
COMMENT = 'Configurable INCLUDE/EXCLUDE patterns defining which tables the refresh engine treats as source tables to watch. Seeded by sql/03_refresh_engine/00_seed_baseline.sql; edit directly (or via a future Control Plane admin screen) to change scope without touching detection SQL.';

CREATE OR REPLACE TABLE ORE_APP_CONFIG (
    CONFIG_KEY    VARCHAR(100)  NOT NULL COMMENT 'Config key. Seeded keys: AI_MODEL (which Cortex model AI_COMPLETE calls use), INDUSTRY_CONTEXT (see below).',
    CONFIG_VALUE  VARCHAR(4000) NOT NULL COMMENT 'Config value. For INDUSTRY_CONTEXT: a short paragraph describing the domain and any relevant external standards, injected into the AI review prompt (sql/03_refresh_engine/04_ai_review_candidates.sql) so its suggestions can be grounded in domain knowledge without hardcoding any one industry into the engine itself -- this single value is what you''d change to retarget the same engine at a different industry.',
    DESCRIPTION   VARCHAR(500)           COMMENT 'What this key controls.',
    UPDATED_TS    TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this value was last changed.',
    CONSTRAINT PK_ORE_APP_CONFIG PRIMARY KEY (CONFIG_KEY)
)
COMMENT = 'Small key-value configuration table for the refresh engine. Seeded on first use by sql/03_refresh_engine/04_ai_review_candidates.sql; edit directly to change the AI model or retarget the industry context.';

CREATE OR REPLACE TABLE ORE_DETECTED_CHANGES (
    RUN_ID          VARCHAR(36)   NOT NULL COMMENT 'Identifies which detection run produced this row.',
    TABLE_SCHEMA    VARCHAR(200)  NOT NULL COMMENT 'Source schema the change was detected in.',
    TABLE_NAME      VARCHAR(200)  NOT NULL COMMENT 'Source table the change was detected in.',
    COLUMN_NAME     VARCHAR(200)           COMMENT 'Source column affected; NULL for whole-table-level changes (CHANGE_TYPE = NEW_TABLE).',
    DATA_TYPE       VARCHAR(100)           COMMENT 'Column data type, where applicable.',
    CHANGE_TYPE     VARCHAR(30)   NOT NULL COMMENT 'One of NEW_COLUMN, DROPPED_COLUMN, TYPE_CHANGED, NEW_TABLE.',
    DETECTED_TS     TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this change was detected.'
)
COMMENT = 'Raw output of the weekly schema crawl (sql/03_refresh_engine/01* detection scripts) -- every column/table-level delta found, before classification.';

CREATE OR REPLACE TABLE ORE_CLASSIFIED_CANDIDATES (
    CANDIDATE_ID         VARCHAR(36)   NOT NULL DEFAULT UUID_STRING() COMMENT 'Surrogate key for this classified candidate.',
    RUN_ID               VARCHAR(36)   NOT NULL COMMENT 'FK (logical) to ORE_DETECTED_CHANGES.RUN_ID -- which detection run this came from.',
    TABLE_SCHEMA         VARCHAR(200)  NOT NULL COMMENT 'Source schema of the underlying change.',
    TABLE_NAME           VARCHAR(200)  NOT NULL COMMENT 'Source table of the underlying change.',
    COLUMN_NAME          VARCHAR(200)           COMMENT 'Source column of the underlying change; NULL for table-level candidates.',
    OBJECT_KIND          VARCHAR(20)   NOT NULL COMMENT 'The rule engine''s classification: ATTRIBUTE, EDGE_TYPE, NODE_TYPE, or FLAGGED (needs human judgment).',
    RULE_APPLIED         VARCHAR(50)   NOT NULL COMMENT 'Which rule fired, e.g. COLUMN_TO_ATTRIBUTE, FK_TO_EDGE, PURE_JUNCTION, FEW_FKS, FKS_NOT_IDENTITY, REIFIED_ENTITY?.',
    PROPOSED_NAME        VARCHAR(200)           COMMENT 'Proposed node/edge type name, e.g. PROFESSIONAL_LANGUAGE.',
    EDGE_FROM            VARCHAR(200)           COMMENT 'For EDGE_TYPE candidates: the proposed FROM_NODE_TYPE.',
    EDGE_TO              VARCHAR(200)           COMMENT 'For EDGE_TYPE candidates: the proposed TO_NODE_TYPE.',
    RAW_DETAILS          VARIANT                COMMENT 'Everything the rule engine used to reach its decision (FK counts, PK columns, etc.), for audit/debug.',
    -- filled in by 04_ai_review_candidates.sql -- see that script for the
    -- AI_COMPLETE response_format this maps onto
    AI_AGREES_WITH_RULE  BOOLEAN                COMMENT 'Whether the AI review pass agreed with the rule engine''s OBJECT_KIND.',
    AI_RECOMMENDED_KIND  VARCHAR(20)            COMMENT 'The AI review pass''s own recommended OBJECT_KIND, which may differ from the rule engine''s.',
    AI_CONFIDENCE        FLOAT                  COMMENT 'The AI review pass''s confidence in its recommendation, 0-1.',
    AI_RATIONALE         VARCHAR(2000)          COMMENT 'The AI review pass''s free-text reasoning, shown to the BA during review.',
    AI_INDUSTRY_NOTE     VARCHAR(2000)          COMMENT 'Any industry-standard-vocabulary grounding the AI pass could offer (e.g. a matching FHIR resource or NUCC taxonomy concept).',
    CLASSIFIED_TS        TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When classification (rule + AI) completed for this candidate.'
)
COMMENT = 'Output of the classification step (sql/03_refresh_engine/02-04) -- each detected change turned into a typed candidate, with both the rule engine''s and the AI review pass''s opinions attached.';

CREATE OR REPLACE TABLE ORE_CANDIDATE_PROPOSALS (
    PROPOSAL_ID          VARCHAR(36)   NOT NULL COMMENT 'Surrogate key for this proposal -- what the BA review UI and audit log key off of.',
    FINGERPRINT_KEY      VARCHAR(64)   NOT NULL COMMENT 'Stable hash of (table, column) -- lets the same delta be recognized across multiple weekly runs so it isn''t re-proposed after a decision.',
    OBJECT_KIND          VARCHAR(20)   NOT NULL COMMENT 'ATTRIBUTE, EDGE_TYPE, NODE_TYPE, or FLAGGED, carried over from ORE_CLASSIFIED_CANDIDATES -- the rule engine''s original classification. Never edited after insert; FINAL_OBJECT_KIND is what a BA actually decides on.',
    FINAL_OBJECT_KIND    VARCHAR(20)            COMMENT 'What the BA actually approves, editable in the Control Plane app. Defaults at insert time to OBJECT_KIND, except for FLAGGED proposals (not directly actionable -- codegen needs ATTRIBUTE/NODE_TYPE/EDGE_TYPE) which default to AI_RECOMMENDED_KIND instead, still requiring explicit BA confirmation before approval. Codegen reads this column, never OBJECT_KIND.',
    RULE_APPLIED         VARCHAR(50)   NOT NULL COMMENT 'Which rule fired; carried over from ORE_CLASSIFIED_CANDIDATES.',
    PROPOSED_NAME        VARCHAR(200)           COMMENT 'Proposed node/edge type name -- the rule/AI-suggested name. Never edited after insert; FINAL_NAME is what a BA actually chooses.',
    FINAL_NAME           VARCHAR(200)           COMMENT 'What the BA actually approves as the artifact name, editable in the Control Plane app. Defaults at insert time to PROPOSED_NAME. Codegen reads this column, never PROPOSED_NAME.',
    EDGE_FROM            VARCHAR(200)           COMMENT 'For EDGE_TYPE proposals: the proposed FROM_NODE_TYPE.',
    EDGE_TO              VARCHAR(200)           COMMENT 'For EDGE_TYPE proposals: the proposed TO_NODE_TYPE.',
    SOURCE_OBJECT        VARIANT       NOT NULL COMMENT 'Full candidate row (rule + AI output), for display in the Control Plane review UI without needing a join.',
    AI_AGREES_WITH_RULE  BOOLEAN                COMMENT 'Carried over from ORE_CLASSIFIED_CANDIDATES.',
    AI_RECOMMENDED_KIND  VARCHAR(20)            COMMENT 'Carried over from ORE_CLASSIFIED_CANDIDATES.',
    AI_CONFIDENCE        FLOAT                  COMMENT 'Carried over from ORE_CLASSIFIED_CANDIDATES.',
    AI_RATIONALE         VARCHAR(2000)          COMMENT 'Carried over from ORE_CLASSIFIED_CANDIDATES.',
    AI_INDUSTRY_NOTE     VARCHAR(2000)          COMMENT 'Carried over from ORE_CLASSIFIED_CANDIDATES.',
    STATUS               VARCHAR(20)   NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING, APPROVED, REJECTED, or DEFERRED. Only PENDING proposals are shown for review; DEFERRED resurfaces next cycle.',
    DECIDED_BY           VARCHAR(100)           COMMENT 'The BA (or other reviewer) who made the decision.',
    DECIDED_TS           TIMESTAMP_NTZ          COMMENT 'When the decision was made.',
    RATIONALE            VARCHAR(2000)          COMMENT 'The reviewer''s own comment explaining their decision -- distinct from AI_RATIONALE.',
    DETECTED_TS           TIMESTAMP_NTZ NOT NULL COMMENT 'When the underlying change was first detected.',
    CONSTRAINT PK_ORE_CANDIDATE_PROPOSALS PRIMARY KEY (PROPOSAL_ID)
)
COMMENT = 'The human review queue: one row per candidate ontology change awaiting (or having received) a business decision. Backs the Control Plane app.';

CREATE OR REPLACE TABLE ORE_DECISION_AUDIT_LOG (
    LOG_ID        NUMBER        NOT NULL AUTOINCREMENT COMMENT 'Surrogate key.',
    PROPOSAL_ID   VARCHAR(36)   NOT NULL COMMENT 'FK (logical) to ORE_CANDIDATE_PROPOSALS.PROPOSAL_ID.',
    STATUS        VARCHAR(20)   NOT NULL COMMENT 'The decision recorded: APPROVED, REJECTED, or DEFERRED.',
    DECIDED_BY    VARCHAR(100)  NOT NULL COMMENT 'Who made the decision.',
    DECIDED_TS    TIMESTAMP_NTZ NOT NULL COMMENT 'When the decision was made.',
    RATIONALE     VARCHAR(2000)          COMMENT 'The reviewer''s comment explaining the decision.',
    CONSTRAINT PK_ORE_DECISION_AUDIT_LOG PRIMARY KEY (LOG_ID)
)
COMMENT = 'Append-only audit trail of every BA decision -- actor, timestamp, rationale -- kept even though ORE_CANDIDATE_PROPOSALS also stores the latest decision, so a later re-decision doesn''t erase history.';

CREATE OR REPLACE TABLE ORE_GENERATED_ARTIFACTS (
    ARTIFACT_ID       VARCHAR(36)   NOT NULL DEFAULT UUID_STRING() COMMENT 'Surrogate key.',
    PROPOSAL_ID       VARCHAR(36)   NOT NULL COMMENT 'FK to ORE_CANDIDATE_PROPOSALS -- the approved proposal this artifact implements.',
    ARTIFACT_TYPE     VARCHAR(30)   NOT NULL COMMENT 'One of NODE_TYPE_DDL, EDGE_TYPE_DDL, VIEW_DDL, POPULATION_SCRIPT, DICTIONARY_ENTRY.',
    TEMPLATE_SQL      VARCHAR(16000) NOT NULL COMMENT 'What the template-based generator produced (sql/05_codegen/01) -- the deterministic first draft.',
    AI_REFINED_SQL    VARCHAR(16000)          COMMENT 'What the AI refine pass proposed instead (sql/05_codegen/02) -- a developer compares this against TEMPLATE_SQL, not a replacement taken on faith.',
    AI_NOTES          VARCHAR(2000)           COMMENT 'The AI refine pass''s explanation of what it changed and why.',
    DEV_STATUS        VARCHAR(20)   NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT (just generated), REVIEWED (a developer looked at it), or APPLIED (run against ONT_ tables).',
    GENERATED_TS      TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this artifact was generated.',
    CONSTRAINT PK_ORE_GENERATED_ARTIFACTS PRIMARY KEY (ARTIFACT_ID),
    CONSTRAINT FK_ORE_ARTIFACT_PROPOSAL FOREIGN KEY (PROPOSAL_ID) REFERENCES ORE_CANDIDATE_PROPOSALS (PROPOSAL_ID)
)
COMMENT = 'Developer review queue: draft DDL/DML for each approved proposal, staged for manual review and apply -- never executed automatically (sql/06_apply).';
