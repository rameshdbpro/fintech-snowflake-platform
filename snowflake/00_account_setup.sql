/* =====================================================================
   00_ACCOUNT_SETUP.SQL
   Roles, warehouses, databases and schemas for the FinTech platform.
   Run as: SECURITYADMIN (roles/grants) + SYSADMIN (objects).
   Idempotent: safe to re-run.

   Environment separation: one database per environment
     FINTECH_DEV, FINTECH_TEST, FINTECH_PROD
   Every later script starts with:  SET DB_NAME = 'FINTECH_DEV';
   ===================================================================== */

------------------------------------------------------------------------
-- 1. ROLES  (functional roles; access roles are granted in 10_security)
------------------------------------------------------------------------
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS FINTECH_DEPLOYER      COMMENT = 'Owns all platform objects. Used only by CI/CD deployments. Never used interactively for analysis.';
CREATE ROLE IF NOT EXISTS FINTECH_LOADER        COMMENT = 'Loads files into LANDING/RAW. No read on curated layers.';
CREATE ROLE IF NOT EXISTS FINTECH_TRANSFORMER   COMMENT = 'dbt execution role. Reads RAW/CONFIG, builds STAGING..MARTS.';
CREATE ROLE IF NOT EXISTS FINTECH_OPS           COMMENT = 'Operates tasks/procedures, reads AUDIT and DQ.';
CREATE ROLE IF NOT EXISTS FINTECH_ANALYST       COMMENT = 'Read-only on MARTS, DASHBOARD, SEMANTIC. PII masked.';
CREATE ROLE IF NOT EXISTS FINTECH_KYC_OFFICER   COMMENT = 'Analyst + unmasked KYC/PII columns.';
CREATE ROLE IF NOT EXISTS FINTECH_AI_USER       COMMENT = 'Cortex Analyst / Intelligence users. Read-only semantic layer.';
CREATE ROLE IF NOT EXISTS FINTECH_CONFIG_APPROVER COMMENT = 'Approves configuration change requests (four-eyes).';

-- Role hierarchy: everything rolls up to SYSADMIN so admins can manage it.
GRANT ROLE FINTECH_LOADER          TO ROLE FINTECH_DEPLOYER;
GRANT ROLE FINTECH_TRANSFORMER     TO ROLE FINTECH_DEPLOYER;
GRANT ROLE FINTECH_OPS             TO ROLE FINTECH_DEPLOYER;
GRANT ROLE FINTECH_ANALYST         TO ROLE FINTECH_KYC_OFFICER;
GRANT ROLE FINTECH_ANALYST         TO ROLE FINTECH_OPS;
GRANT ROLE FINTECH_ANALYST         TO ROLE FINTECH_CONFIG_APPROVER;
GRANT ROLE FINTECH_DEPLOYER        TO ROLE SYSADMIN;
GRANT ROLE FINTECH_KYC_OFFICER     TO ROLE SYSADMIN;
GRANT ROLE FINTECH_AI_USER         TO ROLE SYSADMIN;
GRANT ROLE FINTECH_CONFIG_APPROVER TO ROLE SYSADMIN;

------------------------------------------------------------------------
-- 2. WAREHOUSES  (workload separation; all auto-suspend aggressively)
------------------------------------------------------------------------
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS WH_FINTECH_LOAD
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'COPY INTO, synthetic generation, ingestion controls';
CREATE WAREHOUSE IF NOT EXISTS WH_FINTECH_TRANSFORM
  WAREHOUSE_SIZE = 'SMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'dbt builds, Snowpark procedures';
CREATE WAREHOUSE IF NOT EXISTS WH_FINTECH_BI
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Snowsight Workspaces charts and dashboard views';
CREATE WAREHOUSE IF NOT EXISTS WH_FINTECH_AI
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 120
  COMMENT = 'Cortex Analyst / Intelligence generated SQL. Short timeout caps runaway queries.';

GRANT OWNERSHIP ON WAREHOUSE WH_FINTECH_LOAD      TO ROLE FINTECH_DEPLOYER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON WAREHOUSE WH_FINTECH_TRANSFORM TO ROLE FINTECH_DEPLOYER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON WAREHOUSE WH_FINTECH_BI        TO ROLE FINTECH_DEPLOYER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON WAREHOUSE WH_FINTECH_AI        TO ROLE FINTECH_DEPLOYER COPY CURRENT GRANTS;

------------------------------------------------------------------------
-- 3. DATABASES + SCHEMAS (one DB per environment)
------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS FINTECH_DEV  DATA_RETENTION_TIME_IN_DAYS = 1  COMMENT = 'Development';
CREATE DATABASE IF NOT EXISTS FINTECH_TEST DATA_RETENTION_TIME_IN_DAYS = 1  COMMENT = 'CI / integration test';
CREATE DATABASE IF NOT EXISTS FINTECH_PROD DATA_RETENTION_TIME_IN_DAYS = 7  COMMENT = 'Production analytics (not system of record)';

GRANT OWNERSHIP ON DATABASE FINTECH_DEV  TO ROLE FINTECH_DEPLOYER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE FINTECH_TEST TO ROLE FINTECH_DEPLOYER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE FINTECH_PROD TO ROLE FINTECH_DEPLOYER COPY CURRENT GRANTS;

USE ROLE FINTECH_DEPLOYER;

-- Change this per environment, then re-run the block below.
SET DB_NAME = 'FINTECH_DEV';
USE DATABASE IDENTIFIER($DB_NAME);

CREATE SCHEMA IF NOT EXISTS LANDING      WITH MANAGED ACCESS COMMENT = 'Provider-shaped CSV landing tables (all VARCHAR)';
CREATE SCHEMA IF NOT EXISTS RAW          WITH MANAGED ACCESS COMMENT = 'Immutable raw source tables (12 datasets)';
CREATE SCHEMA IF NOT EXISTS CONFIG       WITH MANAGED ACCESS COMMENT = 'Runtime metadata: mappings, tolerances, thresholds, DQ rules';
CREATE SCHEMA IF NOT EXISTS AUDIT        WITH MANAGED ACCESS COMMENT = 'Ingestion, dbt, task, DQ and change audit logs';
CREATE SCHEMA IF NOT EXISTS OPS          WITH MANAGED ACCESS COMMENT = 'Procedures, UDFs, streams, tasks';
CREATE SCHEMA IF NOT EXISTS STAGING      WITH MANAGED ACCESS COMMENT = 'dbt: 1:1 typed + deduplicated sources';
CREATE SCHEMA IF NOT EXISTS CANONICAL    WITH MANAGED ACCESS COMMENT = 'dbt: provider-agnostic canonical entities';
CREATE SCHEMA IF NOT EXISTS INTERMEDIATE WITH MANAGED ACCESS COMMENT = 'dbt: business logic building blocks';
CREATE SCHEMA IF NOT EXISTS CORE         WITH MANAGED ACCESS COMMENT = 'dbt: facts and dimensions';
CREATE SCHEMA IF NOT EXISTS MARTS        WITH MANAGED ACCESS COMMENT = 'dbt: business marts and reconciliation';
CREATE SCHEMA IF NOT EXISTS SEMANTIC     WITH MANAGED ACCESS COMMENT = 'Governed metric views + semantic views (Cortex Analyst)';
CREATE SCHEMA IF NOT EXISTS DASHBOARD    WITH MANAGED ACCESS COMMENT = 'VW_* views consumed by Snowsight charts';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE   WITH MANAGED ACCESS COMMENT = 'Masking / row access policies and tags';
CREATE SCHEMA IF NOT EXISTS SNAPSHOTS    WITH MANAGED ACCESS COMMENT = 'dbt snapshots (SCD2)';
CREATE SCHEMA IF NOT EXISTS DQ_FAILURES  WITH MANAGED ACCESS COMMENT = 'dbt --store-failures output';

-- Audit and governance data should survive accidental drops longer.
ALTER SCHEMA AUDIT  SET DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER SCHEMA CONFIG SET DATA_RETENTION_TIME_IN_DAYS = 7;
