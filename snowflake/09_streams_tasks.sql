/* =====================================================================
   09_STREAMS_TASKS.SQL  -  operational orchestration inside Snowflake

   Division of labour (no technology does another's job):
     Streams  : detect NEW rows in append-only RAW tables (CDC trigger only).
     Tasks    : run SQL/Snowpark procedures on a schedule / when streams have data.
     Alerts   : condition-based monitoring (dbt freshness, exception spikes).
     dbt      : the transformation DAG + tests (runs from CI, or optionally as a
                Snowflake dbt Project object; see section 5). Tasks do NOT
                re-implement dbt's dependency graph.

   Task graph (root -> children -> finalizer)
     TSK_INGEST_CONTROLS (root, every 15 min, only if a RAW stream has data)
        ├── TSK_DQ_RULES        (CONFIG.DQ_RULE runtime checks)
        └── TSK_PROFILE_RAW     (Snowpark profiler on RAW.PAYMENTS)
     TSK_GRAPH_FINALIZER (FINALIZE: runs even when a child fails)
   Recovery: TASK_AUTO_RETRY_ATTEMPTS=2 on the root, SUSPEND_TASK_AFTER_NUM_FAILURES=3.
   Procedures are idempotent (controls only process uncontrolled batches;
   stream offsets advance only on COMMIT), so re-running is always safe:
     EXECUTE TASK OPS.TSK_INGEST_CONTROLS;
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE SCHEMA OPS;

------------------------------------------------------------------ 1. streams
-- APPEND_ONLY: RAW is insert-only; cheaper than standard streams.
CREATE STREAM IF NOT EXISTS OPS.STRM_RAW_PAYMENTS        ON TABLE RAW.PAYMENTS APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS OPS.STRM_RAW_PAYMENT_STATUS  ON TABLE RAW.PAYMENT_STATUS_HISTORY APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS OPS.STRM_RAW_SETTLEMENTS     ON TABLE RAW.BANK_SETTLEMENTS APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS OPS.STRM_RAW_BANK_STATEMENT  ON TABLE RAW.BANK_STATEMENT_TRANSACTIONS APPEND_ONLY = TRUE;
-- Streams go stale if not consumed within the table's retention (+ MAX_DATA_EXTENSION_TIME_IN_DAYS).
-- Monitor: SHOW STREAMS IN SCHEMA OPS;  -> STALE_AFTER column.

------------------------------------------------------------------ 2. procedures used by tasks
CREATE OR REPLACE PROCEDURE OPS.SP_TASK_GRAPH_SUMMARY()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Finalizer: records the outcome of the current task graph run and notifies on failure.'
AS
$$
DECLARE
    v_group  VARCHAR;
    v_failed NUMBER DEFAULT 0;
    v_dqfail NUMBER DEFAULT 0;
    v_msg    VARCHAR;
BEGIN
    v_group := (SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'));
    v_failed := (SELECT COUNT(*) FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
                    SCHEDULED_TIME_RANGE_START => DATEADD(hour, -2, CURRENT_TIMESTAMP())))
                 WHERE RUN_ID IS NOT NULL AND GRAPH_RUN_GROUP_ID = :v_group AND STATE = 'FAILED');
    v_dqfail := (SELECT COUNT(*) FROM AUDIT.DQ_RESULTS
                 WHERE CHECK_SOURCE = 'RUNTIME_RULE' AND STATUS IN ('FAIL','ERROR')
                   AND CHECKED_AT > DATEADD(minute, -30, SYSDATE()));
    v_msg := 'graph_run=' || COALESCE(v_group, 'n/a') || ' failed_tasks=' || v_failed || ' dq_failures=' || v_dqfail;
    INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, MESSAGE)
    VALUES ('SP_TASK_GRAPH_SUMMARY', :v_group, 'FINALIZE', IFF(:v_failed + :v_dqfail = 0, 'SUCCESS', 'WARN'), :v_msg);

    -- Email only if the (optional) notification integration exists - see section 4.
    IF (v_failed + v_dqfail > 0) THEN
        BEGIN
            CALL SYSTEM$SEND_EMAIL('FINTECH_EMAIL_INT', 'fintech-ops@example.com',
                                   'FinTech pipeline: failures detected', :v_msg);
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, MESSAGE)
                VALUES ('SP_TASK_GRAPH_SUMMARY', :v_group, 'NOTIFY', 'WARN', 'email not sent: ' || :SQLERRM);
        END;
    END IF;
    RETURN OBJECT_CONSTRUCT('graph_run', v_group, 'failed_tasks', v_failed, 'dq_failures', v_dqfail);
END;
$$;

------------------------------------------------------------------ 3. task graph
CREATE OR REPLACE TASK OPS.TSK_INGEST_CONTROLS
  WAREHOUSE = WH_FINTECH_LOAD
  SCHEDULE = 'USING CRON */15 * * * * Asia/Kolkata'
  TASK_AUTO_RETRY_ATTEMPTS = 2
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  USER_TASK_TIMEOUT_MS = 1800000
  COMMENT = 'Root: ingestion controls when new RAW data arrives'
WHEN SYSTEM$STREAM_HAS_DATA('OPS.STRM_RAW_PAYMENTS')
  OR SYSTEM$STREAM_HAS_DATA('OPS.STRM_RAW_PAYMENT_STATUS')
  OR SYSTEM$STREAM_HAS_DATA('OPS.STRM_RAW_SETTLEMENTS')
  OR SYSTEM$STREAM_HAS_DATA('OPS.STRM_RAW_BANK_STATEMENT')
AS
  CALL OPS.SP_RUN_INGESTION_CONTROLS();

CREATE OR REPLACE TASK OPS.TSK_DQ_RULES
  WAREHOUSE = WH_FINTECH_LOAD
  COMMENT = 'Runtime DQ rules on RAW (CONFIG.DQ_RULE)'
  AFTER OPS.TSK_INGEST_CONTROLS
AS
  CALL OPS.SP_RUN_DQ_RULES();

CREATE OR REPLACE TASK OPS.TSK_PROFILE_RAW
  WAREHOUSE = WH_FINTECH_TRANSFORM
  COMMENT = 'Snowpark profiling of RAW.PAYMENTS'
  AFTER OPS.TSK_INGEST_CONTROLS
AS
  CALL OPS.SP_PROFILE_TABLE('RAW.PAYMENTS', 'TASK_PROFILE');   -- PROFILED_AT distinguishes runs

CREATE OR REPLACE TASK OPS.TSK_GRAPH_FINALIZER
  WAREHOUSE = WH_FINTECH_LOAD
  FINALIZE = OPS.TSK_INGEST_CONTROLS
  COMMENT = 'Always runs at the end of the graph; logs outcome and notifies'
AS
  CALL OPS.SP_TASK_GRAPH_SUMMARY();

-- Resume children/finalizer first, then the root.
ALTER TASK OPS.TSK_GRAPH_FINALIZER RESUME;
ALTER TASK OPS.TSK_PROFILE_RAW     RESUME;
ALTER TASK OPS.TSK_DQ_RULES        RESUME;
ALTER TASK OPS.TSK_INGEST_CONTROLS RESUME;

------------------------------------------------------------------ 4. alerts + notification (optional)
-- One-time, ACCOUNTADMIN (recipients must be verified Snowflake user emails):
-- USE ROLE ACCOUNTADMIN;
-- CREATE NOTIFICATION INTEGRATION IF NOT EXISTS FINTECH_EMAIL_INT
--   TYPE = EMAIL ENABLED = TRUE ALLOWED_RECIPIENTS = ('fintech-ops@example.com');
-- GRANT USAGE ON INTEGRATION FINTECH_EMAIL_INT TO ROLE FINTECH_DEPLOYER;

-- dbt has not completed a successful build in 26h (dbt runs outside Snowflake,
-- so freshness is checked from the audit rows its on-run-end hook writes).
CREATE OR REPLACE ALERT OPS.ALRT_DBT_STALE
  WAREHOUSE = WH_FINTECH_LOAD
  SCHEDULE = 'USING CRON 15 * * * * Asia/Kolkata'
  IF (EXISTS (
      SELECT 1
      FROM (SELECT MAX(LOGGED_AT) AS last_ok FROM AUDIT.DBT_RUN_RESULTS
            WHERE RESOURCE_TYPE = 'model' AND STATUS = 'success')
      WHERE last_ok IS NULL OR last_ok < DATEADD(hour, -26, SYSDATE())))
  THEN
    INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, STEP, STATUS, MESSAGE)
    VALUES ('ALRT_DBT_STALE', 'ALERT', 'WARN', 'No successful dbt model build in the last 26 hours');

-- Reconciliation exceptions jumped (> 2x the trailing 7-day daily average)
CREATE OR REPLACE ALERT OPS.ALRT_RECON_SPIKE
  WAREHOUSE = WH_FINTECH_LOAD
  SCHEDULE = 'USING CRON 0 9 * * * Asia/Kolkata'
  IF (EXISTS (
      WITH d AS (SELECT reference_date, COUNT(*) AS n FROM MARTS.MART_RECONCILIATION_EXCEPTIONS
                 WHERE reference_date >= CURRENT_DATE - 8 GROUP BY 1)
      SELECT 1 FROM d
      WHERE reference_date = CURRENT_DATE - 1
        AND n > 2 * (SELECT AVG(n) FROM d WHERE reference_date < CURRENT_DATE - 1)))
  THEN
    INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, STEP, STATUS, MESSAGE)
    VALUES ('ALRT_RECON_SPIKE', 'ALERT', 'WARN', 'Reconciliation exceptions above 2x 7-day average');

ALTER ALERT OPS.ALRT_DBT_STALE RESUME;
ALTER ALERT OPS.ALRT_RECON_SPIKE RESUME;

------------------------------------------------------------------ 5. OPTIONAL: dbt inside Snowflake
-- Only if "dbt Projects on Snowflake" is available in your account/region.
-- This is a different execution host for the SAME dbt project; CI remains the
-- source of truth for code. Requires the project to be deployed as an object
-- (Snowsight Workspaces > dbt project > Deploy, or `snow dbt deploy`).
-- CREATE OR ALTER TASK OPS.TSK_DBT_BUILD
--   WAREHOUSE = WH_FINTECH_TRANSFORM
--   SCHEDULE = 'USING CRON 30 2 * * * Asia/Kolkata'
-- AS
--   EXECUTE DBT PROJECT OPS.FINTECH_PAYMENTS_DBT ARGS = 'build --target prod';

------------------------------------------------------------------ 6. monitoring queries
-- Task runs (last 24h), failures first:
-- SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE, ATTEMPT_NUMBER
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day,-1,CURRENT_TIMESTAMP())))
-- ORDER BY (STATE = 'FAILED') DESC, SCHEDULED_TIME DESC;
-- Graph structure: SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_DEPENDENTS('OPS.TSK_INGEST_CONTROLS', RECURSIVE => TRUE));
-- Alert history:   SELECT * FROM TABLE(INFORMATION_SCHEMA.ALERT_HISTORY()) ORDER BY SCHEDULED_TIME DESC;
