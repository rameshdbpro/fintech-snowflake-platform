/* =====================================================================
   16_COST_MONITORING.SQL  -  resource monitors, cost and performance queries
   ===================================================================== */

------------------------------------------------------------------ 1. resource monitors (ACCOUNTADMIN)
USE ROLE ACCOUNTADMIN;
CREATE RESOURCE MONITOR IF NOT EXISTS RM_FINTECH_PLATFORM
  WITH CREDIT_QUOTA = 100 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 90 PERCENT DO SUSPEND
           ON 100 PERCENT DO SUSPEND_IMMEDIATE;
CREATE RESOURCE MONITOR IF NOT EXISTS RM_FINTECH_AI
  WITH CREDIT_QUOTA = 10 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE WH_FINTECH_LOAD      SET RESOURCE_MONITOR = RM_FINTECH_PLATFORM;
ALTER WAREHOUSE WH_FINTECH_TRANSFORM SET RESOURCE_MONITOR = RM_FINTECH_PLATFORM;
ALTER WAREHOUSE WH_FINTECH_BI        SET RESOURCE_MONITOR = RM_FINTECH_PLATFORM;
ALTER WAREHOUSE WH_FINTECH_AI        SET RESOURCE_MONITOR = RM_FINTECH_AI;
-- NOTE: resource monitors cover warehouse compute. Cortex AI function token
-- charges are billed separately: monitor them with section 3c.

------------------------------------------------------------------ 2. sizing guidance
-- Default volumes (~57k attempts) run comfortably on XSMALL/SMALL.
-- Scale up WH_FINTECH_TRANSFORM only if dbt full refreshes spill to remote
-- storage (Query Profile: "Bytes spilled to remote storage" > 0):
--   ALTER WAREHOUSE WH_FINTECH_TRANSFORM SET WAREHOUSE_SIZE = 'MEDIUM';   -- for the backfill
--   ... dbt build --full-refresh ...
--   ALTER WAREHOUSE WH_FINTECH_TRANSFORM SET WAREHOUSE_SIZE = 'SMALL';
-- Concurrency (many dashboard users) -> multi-cluster on WH_FINTECH_BI (Enterprise):
--   ALTER WAREHOUSE WH_FINTECH_BI SET MIN_CLUSTER_COUNT = 1 MAX_CLUSTER_COUNT = 3 SCALING_POLICY = 'STANDARD';

------------------------------------------------------------------ 3. monitoring queries (FINTECH_OPS)
USE ROLE FINTECH_OPS;
-- 3a. Credits by warehouse, last 30 days
SELECT WAREHOUSE_NAME, ROUND(SUM(CREDITS_USED), 2) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME > DATEADD(day, -30, CURRENT_TIMESTAMP()) AND WAREHOUSE_NAME LIKE 'WH_FINTECH%'
GROUP BY 1 ORDER BY 2 DESC;

-- 3b. Most expensive dbt models (query_tag set in profiles.yml)
SELECT QUERY_TAG, REGEXP_SUBSTR(QUERY_TEXT, 'create or replace (transient )?table ([^ ]+)', 1, 1, 'ie', 2) AS model_relation,
       COUNT(*) AS runs, ROUND(AVG(TOTAL_ELAPSED_TIME) / 1000, 1) AS avg_seconds,
       ROUND(AVG(BYTES_SCANNED) / POWER(1024, 3), 2) AS avg_gb_scanned,
       MAX(BYTES_SPILLED_TO_REMOTE_STORAGE) AS max_remote_spill
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TAG LIKE 'dbt_fintech%' AND START_TIME > DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2 ORDER BY avg_seconds DESC NULLS LAST LIMIT 20;

-- 3c. Cortex AI spend (tokens/credits) by function and model
SELECT FUNCTION_NAME, MODEL_NAME, SUM(TOKENS) AS tokens, ROUND(SUM(TOKEN_CREDITS), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
WHERE START_TIME > DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2 ORDER BY credits DESC;

-- 3d. Pruning check on clustered incremental facts (partitions scanned vs total)
--     Clustering is declared only on the two large, date-filtered incremental facts
--     (FACT_PAYMENT_ATTEMPT, FACT_SETTLEMENT_EVENT) and canonical event tables. Keep it only if
--     SYSTEM$CLUSTERING_INFORMATION shows benefit at your volume; below ~1 TB it is often not worth
--     the reclustering credits - remove cluster_by in dbt then.
SELECT SYSTEM$CLUSTERING_INFORMATION('CORE.FACT_PAYMENT_ATTEMPT');
SELECT QUERY_ID, PARTITIONS_SCANNED, PARTITIONS_TOTAL, TOTAL_ELAPSED_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TEXT ILIKE '%FACT_PAYMENT_ATTEMPT%' AND START_TIME > DATEADD(day, -1, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC LIMIT 20;

-- 3e. Automatic clustering credits (to decide if clustering pays off)
SELECT TABLE_NAME, ROUND(SUM(CREDITS_USED), 3) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
WHERE START_TIME > DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY 1 ORDER BY 2 DESC;

-- 3f. Task + serverless costs
SELECT NAME, STATE, COUNT(*) AS runs, AVG(DATEDIFF(second, QUERY_START_TIME, COMPLETED_TIME)) AS avg_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE SCHEDULED_TIME > DATEADD(day, -7, CURRENT_TIMESTAMP()) AND DATABASE_NAME LIKE 'FINTECH%'
GROUP BY 1, 2 ORDER BY runs DESC;
-- Root task has a WHEN SYSTEM$STREAM_HAS_DATA condition: when no new data arrives,
-- the condition is evaluated without starting the warehouse (no compute for skipped runs).
