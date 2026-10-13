/* =====================================================================
   11_DASHBOARD_VIEWS.SQL  -  views designed for Snowsight charts
   Run AFTER the first successful dbt build (views reference dbt models).

   Rules
   * KPIs read SEMANTIC.SEM_GOVERNED_METRICS_DAILY (additive components) and
     compute ratios as SUM(numerator)/SUM(denominator) => same definitions as
     the semantic view used by Cortex Analyst (12_semantic_view.sql).
   * Relative periods are anchored on the latest date present in the data
     (KPI_ANCHOR_DATE), not CURRENT_DATE, so the synthetic history always shows
     populated "last 30 days" tiles. Switch to CURRENT_DATE for production.
   * Row access policies on the underlying marts still apply to the querying
     role (regional analysts see only their regions).
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE SCHEMA DASHBOARD;

-- 1. Executive KPIs: one row per period ---------------------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS
COMMENT = 'Governed KPIs for LAST_30_DAYS, PREV_30_DAYS, MONTH_TO_DATE and ALL_TIME'
AS
WITH anchor AS (
    SELECT MAX(date_ist) AS kpi_anchor_date FROM SEMANTIC.SEM_GOVERNED_METRICS_DAILY
),
periods AS (
    SELECT 'LAST_30_DAYS' AS period, 1 AS sort_order, kpi_anchor_date - 29 AS start_date, kpi_anchor_date AS end_date FROM anchor
    UNION ALL SELECT 'PREV_30_DAYS', 2, kpi_anchor_date - 59, kpi_anchor_date - 30 FROM anchor
    UNION ALL SELECT 'MONTH_TO_DATE', 3, DATE_TRUNC('month', kpi_anchor_date), kpi_anchor_date FROM anchor
    UNION ALL SELECT 'ALL_TIME', 4, '1900-01-01'::DATE, kpi_anchor_date FROM anchor
)
SELECT
    p.period, p.sort_order, p.start_date, p.end_date,
    SUM(m.payment_volume_inr)                                                AS payment_volume_inr,
    SUM(m.payment_attempt_count)                                             AS payment_attempt_count,
    SUM(m.successful_payment_count)                                          AS successful_payment_count,
    DIV0(SUM(m.captured_transaction_count_by_created), SUM(m.terminal_transaction_count)) AS payment_success_rate,
    DIV0(SUM(m.failed_transaction_count), SUM(m.terminal_transaction_count)) AS payment_failure_rate,
    DIV0(SUM(m.payment_volume_inr), SUM(m.successful_payment_count))         AS average_transaction_value_inr,
    SUM(m.refund_amount_inr)                                                 AS refund_amount_inr,
    DIV0(SUM(m.refund_amount_inr), SUM(m.payment_volume_inr))                AS refund_rate,
    SUM(m.chargeback_amount_inr)                                             AS chargeback_amount_inr,
    DIV0(SUM(m.chargeback_count), SUM(m.successful_payment_count))           AS chargeback_rate,
    DIV0(SUM(m.settlement_matched_count), SUM(m.settleable_count))           AS settlement_match_rate,
    SUM(m.outstanding_settlement_inr)                                        AS outstanding_settlement_inr,
    SUM(m.fraud_alert_count)                                                 AS fraud_alert_count
FROM periods p
LEFT JOIN SEMANTIC.SEM_GOVERNED_METRICS_DAILY m
       ON m.date_ist BETWEEN p.start_date AND p.end_date
GROUP BY p.period, p.sort_order, p.start_date, p.end_date;

-- 2. Daily trend (+ day-over-day change in failed payments) --------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_DAILY_PAYMENT_TREND AS
WITH d AS (
    SELECT date_ist,
           SUM(payment_attempt_count)                    AS payment_attempt_count,
           SUM(transaction_count)                        AS transaction_count,
           SUM(successful_payment_count)                 AS successful_payment_count,
           SUM(failed_transaction_count)                 AS failed_transaction_count,
           SUM(terminal_transaction_count)               AS terminal_transaction_count,
           SUM(captured_transaction_count_by_created)    AS captured_transaction_count_by_created,
           SUM(payment_volume_inr)                       AS payment_volume_inr,
           SUM(refund_amount_inr)                        AS refund_amount_inr,
           SUM(fraud_alert_count)                        AS fraud_alert_count
    FROM SEMANTIC.SEM_GOVERNED_METRICS_DAILY
    GROUP BY date_ist
)
SELECT d.*,
       DIV0(captured_transaction_count_by_created, terminal_transaction_count) AS payment_success_rate,
       DIV0(failed_transaction_count, terminal_transaction_count)              AS payment_failure_rate,
       failed_transaction_count - LAG(failed_transaction_count) OVER (ORDER BY date_ist) AS failed_change_vs_prior_day,
       AVG(payment_volume_inr) OVER (ORDER BY date_ist ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS payment_volume_inr_7d_avg,
       DAYNAME(date_ist) AS day_name
FROM d;

-- 3. Channel performance (month x channel) ------------------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_PAYMENT_CHANNEL_PERFORMANCE AS
SELECT month_start, channel_group, channel_code,
       SUM(payment_attempt_count)                                                   AS payment_attempt_count,
       SUM(successful_payment_count)                                                AS successful_payment_count,
       SUM(payment_volume_inr)                                                      AS payment_volume_inr,
       DIV0(SUM(captured_transaction_count_by_created), SUM(terminal_transaction_count)) AS payment_success_rate,
       DIV0(SUM(failed_transaction_count), SUM(terminal_transaction_count))         AS payment_failure_rate,
       DIV0(SUM(payment_volume_inr), SUM(successful_payment_count))                 AS average_transaction_value_inr,
       DIV0(SUM(refund_amount_inr), SUM(payment_volume_inr))                        AS refund_rate,
       DIV0(SUM(payment_attempt_count) - SUM(transaction_count), SUM(transaction_count)) AS retries_per_transaction
FROM SEMANTIC.SEM_GOVERNED_METRICS_DAILY
GROUP BY month_start, channel_group, channel_code;

-- 4. Merchant performance (month x merchant, ranked) ---------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_MERCHANT_PERFORMANCE AS
SELECT mp.*,
       RANK() OVER (PARTITION BY month_start ORDER BY payment_volume_inr DESC)       AS volume_rank_in_month,
       RANK() OVER (PARTITION BY month_start ORDER BY settlement_mismatch_inr DESC)  AS mismatch_rank_in_month
FROM MARTS.MART_MERCHANT_PERFORMANCE mp;

-- 5. Refunds and chargebacks ----------------------------------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_REFUND_AND_CHARGEBACK_SUMMARY AS
SELECT month_start, channel_group, merchant_region,
       successful_payment_count, payment_volume_inr,
       refund_count, refund_amount_inr, refund_rate,
       chargeback_count, chargeback_lost_count, chargeback_amount_inr, chargeback_rate
FROM MARTS.MART_REFUND_CHARGEBACK_MONTHLY;

-- 6. Settlement reconciliation summary (both levels) ---------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_SETTLEMENT_RECONCILIATION_SUMMARY AS
SELECT 'PAYMENT_TO_SETTLEMENT'                          AS recon_level,
       DATE_TRUNC('month', captured_date_ist)            AS month_start,
       recon_status,
       COUNT(*)                                          AS item_count,
       SUM(expected_gross_inr)                           AS expected_amount_inr,
       SUM(settled_gross_inr)                            AS settled_amount_inr,
       SUM(outstanding_gross_inr)                        AS outstanding_amount_inr,
       SUM(ABS(gross_difference) * COALESCE(fx_rate_to_inr, 1)) AS absolute_difference_inr,
       COUNT_IF(is_timing_difference)                    AS timing_difference_count,
       COUNT_IF(is_fee_variance)                         AS fee_variance_count
FROM MARTS.MART_SETTLEMENT_RECONCILIATION
GROUP BY 1, 2, 3
UNION ALL
SELECT 'BATCH_TO_BANK',
       DATE_TRUNC('month', COALESCE(settlement_date, first_value_date)),
       recon_status,
       COUNT(*),
       SUM(batch_net_amount),          -- batch currency (INR batches dominate; USD shown separately in drill-down)
       SUM(bank_net_amount),
       SUM(IFF(recon_status IN ('MISSING_BANK_CREDIT','PENDING_BANK_CREDIT'), batch_net_amount, 0)),
       SUM(ABS(difference)),
       COUNT_IF(timing_difference_days > 0),
       NULL
FROM MARTS.MART_BANK_RECONCILIATION
GROUP BY 1, 2, 3;

-- 6b. Drill-down: exception detail (open items with source keys) -----------------
CREATE OR REPLACE VIEW DASHBOARD.VW_RECON_EXCEPTION_DETAIL AS
SELECT exception_id, exception_category, exception_type, severity, age_bucket, age_days,
       entity_key, source_system, source_transaction_id, merchant_id, settlement_batch_id,
       currency_code, exception_amount, exception_amount_inr, expected_gross, settled_gross,
       reference_date, detail
FROM MARTS.MART_RECONCILIATION_EXCEPTIONS;

-- 7. Data quality status ----------------------------------------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_DATA_QUALITY_STATUS AS
WITH latest_rules AS (
    SELECT * FROM AUDIT.DQ_RESULTS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_SOURCE, RULE_ID ORDER BY CHECKED_AT DESC) = 1
)
SELECT CHECK_SOURCE AS check_source, RULE_ID AS check_name, TARGET_OBJECT AS target_object,
       RULE_TYPE AS check_type, SEVERITY AS severity, STATUS AS status,
       FAILING_ROWS AS failing_rows, OBSERVED_VALUE AS observed_value, THRESHOLD AS threshold,
       LEFT(DETAILS, 500) AS details, CHECKED_AT AS checked_at_utc
FROM latest_rules
UNION ALL
SELECT 'CANONICAL_EXCEPTION', exception_type, entity, 'INTEGRATION', severity,
       IFF(COUNT(*) > 0, 'FAIL', 'PASS'), COUNT(*), TO_VARCHAR(COUNT(*)), '0',
       'see CANONICAL.CNL_EXCEPTIONS', MAX(detected_at_utc)
FROM CANONICAL.CNL_EXCEPTIONS
GROUP BY exception_type, entity, severity
UNION ALL
SELECT 'INGESTION', TARGET_TABLE, TARGET_TABLE, 'REJECTED_ROWS', 'WARN',
       IFF(SUM(ROWS_REJECTED) > 0, 'WARN', 'PASS'), SUM(ROWS_REJECTED), TO_VARCHAR(SUM(ROWS_LOADED)), '0',
       'rows loaded / rejected (7d)', MAX(FINISHED_AT)
FROM AUDIT.INGESTION_LOG
WHERE FINISHED_AT > DATEADD(day, -7, SYSDATE())
GROUP BY TARGET_TABLE;

-- 8. Pipeline execution status ------------------------------------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_PIPELINE_EXECUTION_STATUS AS
WITH last_dbt AS (
    SELECT INVOCATION_ID
    FROM AUDIT.DBT_RUN_RESULTS
    QUALIFY ROW_NUMBER() OVER (ORDER BY LOGGED_AT DESC) = 1
)
SELECT 'DBT' AS component, r.DBT_COMMAND || ' (' || r.TARGET_NAME || ')' AS job,
       r.RESOURCE_TYPE AS step_type,
       COUNT(*) AS step_count,
       COUNT_IF(r.STATUS IN ('success', 'pass')) AS succeeded,
       COUNT_IF(r.STATUS IN ('error', 'fail')) AS failed,
       COUNT_IF(r.STATUS = 'warn') AS warned,
       ROUND(SUM(r.EXECUTION_SECONDS), 1) AS duration_seconds,
       MAX(r.LOGGED_AT) AS last_run_utc
FROM AUDIT.DBT_RUN_RESULTS r JOIN last_dbt l ON l.INVOCATION_ID = r.INVOCATION_ID
GROUP BY 1, 2, 3
UNION ALL
SELECT 'PROCEDURE', PROCEDURE_NAME, STEP, COUNT(*),
       COUNT_IF(STATUS = 'SUCCESS'), COUNT_IF(STATUS = 'FAILED'), COUNT_IF(STATUS = 'WARN'),
       NULL, MAX(LOGGED_AT)
FROM AUDIT.PROCEDURE_LOG
WHERE LOGGED_AT > DATEADD(day, -1, SYSDATE())
GROUP BY PROCEDURE_NAME, STEP
UNION ALL
SELECT 'INGESTION', TARGET_TABLE, LOAD_METHOD, COUNT(*),
       COUNT_IF(STATUS = 'SUCCESS'), COUNT_IF(STATUS = 'FAILED'), COUNT_IF(STATUS = 'PARTIAL'),
       NULL, MAX(FINISHED_AT)
FROM AUDIT.INGESTION_LOG
WHERE FINISHED_AT > DATEADD(day, -1, SYSDATE())
GROUP BY TARGET_TABLE, LOAD_METHOD;

-- 9. Fraud monitoring ----------------------------------------------------------------
CREATE OR REPLACE VIEW DASHBOARD.VW_FRAUD_MONITORING_SUMMARY AS
SELECT alert_date_ist, alert_source, rule_code, severity,
       SUM(alert_count)                 AS alert_count,
       SUM(confirmed_fraud_count)       AS confirmed_fraud_count,
       DIV0(SUM(confirmed_fraud_count), SUM(alert_count)) AS confirmation_rate,
       SUM(IFF(alert_status = 'OPEN', alert_count, 0)) AS open_alert_count,
       MAX(distinct_customers)          AS max_distinct_customers_in_slice,
       AVG(avg_alert_score)             AS avg_alert_score
FROM MARTS.MART_FRAUD_DAILY
GROUP BY alert_date_ist, alert_source, rule_code, severity;

-- 10. Customer risk transitions (supports "how did risk change over time") -------
CREATE OR REPLACE VIEW DASHBOARD.VW_CUSTOMER_RISK_TRANSITIONS AS
SELECT DATE_TRUNC('month', effective_date) AS month_start,
       previous_risk_rating, risk_rating, risk_change,
       COUNT(*) AS customer_versions
FROM MARTS.MART_CUSTOMER_RISK_HISTORY
WHERE effective_date IS NOT NULL
GROUP BY 1, 2, 3, 4;

-- 11. Governed metric definitions (read-only copy of CONFIG.METRIC_DEFINITION) -----
CREATE OR REPLACE VIEW DASHBOARD.VW_METRIC_DEFINITIONS AS
SELECT METRIC_NAME AS metric_name, BUSINESS_MEANING AS business_meaning, AUTHORITATIVE_MODEL AS authoritative_model,
       GRAIN AS grain, NUMERATOR AS numerator, DENOMINATOR AS denominator, FILTERS AS filters,
       REPORTING_TIMESTAMP AS reporting_timestamp, TIMEZONE AS timezone, CURRENCY_TREATMENT AS currency_treatment,
       RETRY_HANDLING AS retry_handling, REVERSAL_TREATMENT AS reversal_treatment, OWNER AS owner, VERSION AS version
FROM CONFIG.METRIC_DEFINITION;

-- Grants (views are owned by FINTECH_DEPLOYER => owner's rights on AUDIT/CANONICAL)
GRANT SELECT ON ALL VIEWS IN SCHEMA DASHBOARD TO ROLE FINTECH_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA DASHBOARD TO ROLE FINTECH_ANALYST_SOUTH;
GRANT SELECT ON ALL VIEWS IN SCHEMA DASHBOARD TO ROLE FINTECH_ANALYST_NORTH;
GRANT SELECT ON ALL VIEWS IN SCHEMA DASHBOARD TO ROLE FINTECH_AI_USER;
GRANT SELECT ON ALL VIEWS IN SCHEMA DASHBOARD TO ROLE FINTECH_OPS;
