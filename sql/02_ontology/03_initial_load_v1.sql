-- =============================================================================
-- 03_initial_load_v1.sql
-- Populates ONT_KG_NODE / ONT_KG_EDGE from the v1 SRC_ source tables. This is
-- the manual, one-time equivalent of what a future apply step (sql/06_apply,
-- not built yet) would do for newly-approved types later on -- running the
-- population script that sql/05_codegen drafts for each approved proposal.
--
-- Runs with ONTOLOGY as the current schema (since it writes ONT_KG_NODE /
-- ONT_KG_EDGE) and reaches across into SRC_SCHEMA for source rows via
-- IDENTIFIER($_TBL) -- so this still works whether SRC and ONTOLOGY are two
-- schemas or, in a single-schema fallback, the same one.
--
-- IDENTIFIER() does not accept an expression (e.g. $SRC_SCHEMA || '.TABLE')
-- inline -- the concatenated name has to be precomputed into its own
-- variable first, then passed to IDENTIFIER() bare. _TBL is reused as a
-- scratch variable, re-SET immediately before each use -- fine since these
-- statements run strictly in sequence, never concurrently.
-- =============================================================================

SET DEMO_DB         = 'ORE_DEMO_DB';  
SET ONTOLOGY_SCHEMA = 'ORE_ONTOLOGY';
SET SRC_SCHEMA      = 'ORE_SRC';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($ONTOLOGY_SCHEMA);

-- -----------------------------------------------------------------------------
-- Nodes -- load in any order, no inter-node dependency
-- -----------------------------------------------------------------------------
SET _TBL = $SRC_SCHEMA || '.SRC_LANGUAGE';
INSERT INTO ONT_KG_NODE (NODE_ID, NODE_TYPE, PROPS, SOURCE_OBJECT)
SELECT TO_VARCHAR(LANGUAGE_CODE), 'LANGUAGE', OBJECT_CONSTRUCT(* EXCLUDE (LANGUAGE_CODE)), $_TBL
FROM IDENTIFIER($_TBL);

SET _TBL = $SRC_SCHEMA || '.SRC_SPECIALTY';
INSERT INTO ONT_KG_NODE (NODE_ID, NODE_TYPE, PROPS, SOURCE_OBJECT)
SELECT TO_VARCHAR(SPECIALTY_CODE), 'SPECIALTY', OBJECT_CONSTRUCT(* EXCLUDE (SPECIALTY_CODE)), $_TBL
FROM IDENTIFIER($_TBL);

SET _TBL = $SRC_SCHEMA || '.SRC_ADDRESS';
INSERT INTO ONT_KG_NODE (NODE_ID, NODE_TYPE, PROPS, SOURCE_OBJECT)
SELECT TO_VARCHAR(ADDRESS_ID), 'ADDRESS', OBJECT_CONSTRUCT(* EXCLUDE (ADDRESS_ID)), $_TBL
FROM IDENTIFIER($_TBL);

SET _TBL = $SRC_SCHEMA || '.SRC_PRACTICE_LOCATION';
INSERT INTO ONT_KG_NODE (NODE_ID, NODE_TYPE, PROPS, SOURCE_OBJECT)
SELECT TO_VARCHAR(LOCATION_ID), 'PRACTICE_LOCATION', OBJECT_CONSTRUCT(* EXCLUDE (LOCATION_ID)), $_TBL
FROM IDENTIFIER($_TBL);

SET _TBL = $SRC_SCHEMA || '.SRC_PROVIDER_PROFESSIONAL';
INSERT INTO ONT_KG_NODE (NODE_ID, NODE_TYPE, PROPS, SOURCE_OBJECT)
SELECT TO_VARCHAR(PROVIDER_ID), 'PROVIDER_PROFESSIONAL', OBJECT_CONSTRUCT(* EXCLUDE (PROVIDER_ID)), $_TBL
FROM IDENTIFIER($_TBL);

SET _TBL = $SRC_SCHEMA || '.SRC_PROVIDER_FACILITY';
INSERT INTO ONT_KG_NODE (NODE_ID, NODE_TYPE, PROPS, SOURCE_OBJECT)
SELECT TO_VARCHAR(FACILITY_ID), 'PROVIDER_FACILITY', OBJECT_CONSTRUCT(* EXCLUDE (FACILITY_ID)), $_TBL
FROM IDENTIFIER($_TBL);

-- -----------------------------------------------------------------------------
-- Edges -- scalar-FK-derived
-- -----------------------------------------------------------------------------
SET _TBL = $SRC_SCHEMA || '.SRC_PROVIDER_PROFESSIONAL';
INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)
SELECT 'PROFESSIONAL_HAS_SPECIALTY', src.NODE_SK, dst.NODE_SK, OBJECT_CONSTRUCT(), $_TBL
FROM IDENTIFIER($_TBL) p
JOIN ONT_KG_NODE src ON src.NODE_TYPE = 'PROVIDER_PROFESSIONAL' AND src.NODE_ID = TO_VARCHAR(p.PROVIDER_ID)
JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = 'SPECIALTY' AND dst.NODE_ID = p.PRIMARY_SPECIALTY_CODE
WHERE p.PRIMARY_SPECIALTY_CODE IS NOT NULL;

SET _TBL = $SRC_SCHEMA || '.SRC_PRACTICE_LOCATION';
INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)
SELECT 'LOCATION_HAS_ADDRESS', src.NODE_SK, dst.NODE_SK, OBJECT_CONSTRUCT(), $_TBL
FROM IDENTIFIER($_TBL) l
JOIN ONT_KG_NODE src ON src.NODE_TYPE = 'PRACTICE_LOCATION' AND src.NODE_ID = TO_VARCHAR(l.LOCATION_ID)
JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = 'ADDRESS' AND dst.NODE_ID = TO_VARCHAR(l.ADDRESS_ID);

SET _TBL = $SRC_SCHEMA || '.SRC_PROVIDER_FACILITY';
INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)
SELECT 'FACILITY_HAS_ADDRESS', src.NODE_SK, dst.NODE_SK, OBJECT_CONSTRUCT(), $_TBL
FROM IDENTIFIER($_TBL) f
JOIN ONT_KG_NODE src ON src.NODE_TYPE = 'PROVIDER_FACILITY' AND src.NODE_ID = TO_VARCHAR(f.FACILITY_ID)
JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = 'ADDRESS' AND dst.NODE_ID = TO_VARCHAR(f.ADDRESS_ID);

-- -----------------------------------------------------------------------------
-- Edges -- junction-table-derived
--
-- OBJECT_CONSTRUCT(j.* EXCLUDE (...)), not OBJECT_CONSTRUCT(* EXCLUDE (...)):
-- the latter expands to every column in scope across ALL joined tables (j,
-- src, dst), and since src/dst are both ONT_KG_NODE, their shared column
-- names (NODE_SK, NODE_ID, ...) collide -> "duplicate field key". Scoping to
-- j.* is also the semantically correct choice, not just the fix for that
-- error: an edge's PROPS should hold the edge's OWN attributes (junction
-- columns beyond the two FKs), not a denormalized copy of the endpoint
-- nodes' own fields -- those already live on the node rows themselves
-- (V_ONT_PROVIDER_PROFESSIONAL / V_ONT_PRACTICE_LOCATION), reachable by
-- following SRC_SK/DST_SK.
-- -----------------------------------------------------------------------------
SET _TBL = $SRC_SCHEMA || '.SRC_PROFESSIONAL_PRACTICE_LOCATION';
INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)
SELECT 'PROFESSIONAL_WORKS_AT_LOCATION', src.NODE_SK, dst.NODE_SK,
       OBJECT_CONSTRUCT(j.* EXCLUDE (PROVIDER_ID, LOCATION_ID)), $_TBL
FROM IDENTIFIER($_TBL) j
JOIN ONT_KG_NODE src ON src.NODE_TYPE = 'PROVIDER_PROFESSIONAL' AND src.NODE_ID = TO_VARCHAR(j.PROVIDER_ID)
JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = 'PRACTICE_LOCATION'     AND dst.NODE_ID = TO_VARCHAR(j.LOCATION_ID);

-- Same j.* EXCLUDE (...) reasoning as PROFESSIONAL_WORKS_AT_LOCATION above.
SET _TBL = $SRC_SCHEMA || '.SRC_FACILITY_LANGUAGE';
INSERT INTO ONT_KG_EDGE (EDGE_TYPE, SRC_SK, DST_SK, PROPS, SOURCE_OBJECT)
SELECT 'FACILITY_SERVES_LANGUAGE', src.NODE_SK, dst.NODE_SK,
       OBJECT_CONSTRUCT(j.* EXCLUDE (FACILITY_ID, LANGUAGE_CODE)), $_TBL
FROM IDENTIFIER($_TBL) j
JOIN ONT_KG_NODE src ON src.NODE_TYPE = 'PROVIDER_FACILITY' AND src.NODE_ID = TO_VARCHAR(j.FACILITY_ID)
JOIN ONT_KG_NODE dst ON dst.NODE_TYPE = 'LANGUAGE'           AND dst.NODE_ID = TO_VARCHAR(j.LANGUAGE_CODE);

-- Sanity checks -- the same row-count and orphan-edge checks a developer
-- should run manually after any load, confirming v1 loaded clean.
SELECT NODE_TYPE, COUNT(*) AS NODE_COUNT FROM ONT_KG_NODE GROUP BY NODE_TYPE ORDER BY 1;
SELECT EDGE_TYPE, COUNT(*) AS EDGE_COUNT FROM ONT_KG_EDGE GROUP BY EDGE_TYPE ORDER BY 1;
-- orphan-edge rate should be zero right after a fresh load
SELECT COUNT(*) AS ORPHAN_EDGES FROM ONT_KG_EDGE e
WHERE NOT EXISTS (SELECT 1 FROM ONT_KG_NODE n WHERE n.NODE_SK = e.SRC_SK)
   OR NOT EXISTS (SELECT 1 FROM ONT_KG_NODE n WHERE n.NODE_SK = e.DST_SK);
