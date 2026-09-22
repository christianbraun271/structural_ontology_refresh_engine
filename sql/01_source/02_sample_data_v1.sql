-- =============================================================================
-- 02_sample_data_v1.sql
-- Small synthetic sample set -- enough rows to make the ontology views and
-- initial load visibly non-empty, not a realistic-volume dataset.
-- =============================================================================

SET DEMO_DB    = 'ORE_DEMO_DB';
SET SRC_SCHEMA = 'ORE_SRC';

USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA   IDENTIFIER($SRC_SCHEMA);

INSERT INTO SRC_LANGUAGE (LANGUAGE_CODE, LANGUAGE_NAME) VALUES
    ('EN', 'English'),
    ('ES', 'Spanish'),
    ('ZH', 'Mandarin Chinese'),
    ('VI', 'Vietnamese');

INSERT INTO SRC_SPECIALTY (SPECIALTY_CODE, SPECIALTY_NAME, TAXONOMY_CODE) VALUES
    ('IM',   'Internal Medicine',       '207R00000X'),
    ('PEDS', 'Pediatrics',              '208000000X'),
    ('CARD', 'Cardiovascular Disease',  '207RC0000X'),
    ('FM',   'Family Medicine',         '207Q00000X');

INSERT INTO SRC_ADDRESS (ADDRESS_ID, LINE1, LINE2, CITY, STATE, POSTAL_CODE, COUNTRY) VALUES
    (1, '100 Market St',   NULL,      'San Francisco', 'CA', '94105', 'US'),
    (2, '250 Riverside Dr', 'Suite 4', 'Austin',        'TX', '78701', 'US'),
    (3, '77 Elm Ave',      NULL,      'Chicago',        'IL', '60601', 'US');

INSERT INTO SRC_PRACTICE_LOCATION (LOCATION_ID, ADDRESS_ID, LOCATION_NAME, PHONE) VALUES
    (1, 1, 'Market Street Internal Medicine', '415-555-0101'),
    (2, 2, 'Riverside Family Clinic',         '512-555-0102'),
    (3, 3, 'Elm Avenue Cardiology',           '312-555-0103');

INSERT INTO SRC_PROVIDER_PROFESSIONAL (PROVIDER_ID, NPI, FIRST_NAME, LAST_NAME, PRIMARY_SPECIALTY_CODE) VALUES
    (1, '1000000001', 'Amara',  'Okafor',   'IM'),
    (2, '1000000002', 'Daniel', 'Reyes',    'FM'),
    (3, '1000000003', 'Priya',  'Natarajan','CARD'),
    (4, '1000000004', 'Jonas',  'Weber',    'PEDS');

INSERT INTO SRC_PROVIDER_FACILITY (FACILITY_ID, ADDRESS_ID, FACILITY_NAME, FACILITY_NPI, FACILITY_TYPE) VALUES
    (1, 1, 'Market Street Clinic',  '2000000001', 'CLINIC'),
    (2, 3, 'Elm Avenue Cardiology Center', '2000000002', 'CLINIC');

INSERT INTO SRC_PROFESSIONAL_PRACTICE_LOCATION (PROVIDER_ID, LOCATION_ID) VALUES
    (1, 1), (2, 2), (3, 3), (4, 1);

INSERT INTO SRC_FACILITY_LANGUAGE (FACILITY_ID, LANGUAGE_CODE) VALUES
    (1, 'EN'), (1, 'ES'), (2, 'EN'), (2, 'ZH');
