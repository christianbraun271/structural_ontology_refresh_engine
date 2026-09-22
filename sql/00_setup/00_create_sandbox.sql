-- =============================================================================
-- 00_create_sandbox.sql
--
-- Two ways this can go, depending on what your role can actually do:
--
--   SCENARIO A -- you can CREATE DATABASE / CREATE SCHEMA:
--     Uncomment the "OPTIONAL: CREATE" block below and run it once. It
--     creates an isolated database + four schemas so nothing in this demo
--     can ever touch an object outside of it.
--
--   SCENARIO B -- you were handed a fixed, already-existing database and
--   schema(s) (the assumed default -- most real orgs work this way):
--     Leave the CREATE block commented out. Just fill in the CONFIGURATION
--     section below with the names you were given, and run that section.
--
-- Either way, every script in this project (from here on) starts with the
-- same CONFIGURATION block, then does:
--     USE DATABASE  IDENTIFIER($DEMO_DB);
--     USE WAREHOUSE IDENTIFIER($DEMO_WH);
--     USE SCHEMA    IDENTIFIER($<whichever>_SCHEMA);
-- and is schema-agnostic after that -- no hardcoded database/schema names
-- appear anywhere past this point. If your database or schema names differ
-- from the defaults below, change them here; nothing else needs to change.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- CONFIGURATION -- runnable. Edit these to match your account, then run.
-- -----------------------------------------------------------------------------
SET DEMO_DB          = 'ORE_DEMO_DB'; -- existing DB, or the one created below
SET SRC_SCHEMA       = 'ORE_SRC';                -- simulated source / silver layer tables
SET ONTOLOGY_SCHEMA  = 'ORE_ONTOLOGY';           -- node/edge type dictionary + instance tables + views
SET CONTROL_SCHEMA   = 'ORE_CONTROL';            -- refresh-engine state: detection, classification, proposals, audit
SET APP_SCHEMA       = 'APP';                    -- control-plane Streamlit app

-- No CREATE WAREHOUSE in this project -- reuse a warehouse you already have
-- access to. Put its name here.
SET DEMO_WH = '<YOUR_EXISTING_WAREHOUSE>';        -- e.g. 'COMPUTE_WH'


-- -----------------------------------------------------------------------------
-- OPTIONAL: CREATE -- only if your role has CREATE DATABASE / CREATE SCHEMA.
-- Leave commented out under Scenario B (the assumed default). If you do have
-- the privilege and want an isolated sandbox, select and run this block once.
-- -----------------------------------------------------------------------------
/*
CREATE DATABASE IF NOT EXISTS IDENTIFIER($DEMO_DB)
  COMMENT = 'Sandbox for the ontology refresh engine demo. Safe to drop entirely.';

USE DATABASE IDENTIFIER($DEMO_DB);

CREATE SCHEMA IF NOT EXISTS IDENTIFIER($SRC_SCHEMA)      COMMENT = 'Simulated source / silver layer tables';
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($ONTOLOGY_SCHEMA) COMMENT = 'Node/edge type dictionary, instance tables, and generated views';
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($CONTROL_SCHEMA)  COMMENT = 'Refresh-engine control tables: detection, classification, proposals, audit';
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($APP_SCHEMA)      COMMENT = 'Streamlit-in-Snowflake control plane app';
*/


-- -----------------------------------------------------------------------------
-- RUNNABLE -- applies under both scenarios. Assumes DEMO_DB and the four
-- schemas above already exist (either because you just created them, or
-- because they were handed to you).
-- -----------------------------------------------------------------------------
USE DATABASE  IDENTIFIER($DEMO_DB);
USE WAREHOUSE IDENTIFIER($DEMO_WH);
USE SCHEMA    IDENTIFIER($SRC_SCHEMA);


-- -----------------------------------------------------------------------------
-- Detection path: this project assumes INFORMATION_SCHEMA-only access (no
-- ACCOUNT_USAGE / IMPORTED PRIVILEGES grant). See
-- sql/03_refresh_engine/01_detect_information_schema.sql -- it's real-time
-- and needs nothing beyond ordinary SELECT on INFORMATION_SCHEMA for schemas
-- you can already see, at the cost of maintaining its own fingerprint
-- snapshot table (INFORMATION_SCHEMA has no change history of its own).
--
-- sql/03_refresh_engine/01b_detect_account_usage.sql is kept as an optional
-- upgrade path, not the default this demo relies on. Switching to it later
-- would need, once, from a role that already has it (typically ACCOUNTADMIN):
--
--   GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <your_role>;
--
-- The benefit: native CREATED/DELETED history per object, so no snapshot
-- table to maintain and dropped objects don't just silently vanish -- at the
-- cost of up to ~3hrs of latency on that history.



