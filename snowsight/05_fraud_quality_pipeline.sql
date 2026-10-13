/* =====================================================================
   SNOWSIGHT PAGE 5 - FRAUD MONITORING, DATA QUALITY, PIPELINE, RISK
   Fraud/risk pages: FINTECH_ANALYST. DQ/pipeline: FINTECH_OPS or ANALYST.
   ===================================================================== */
USE ROLE FINTECH_ANALYST;
USE WAREHOUSE WH_FINTECH_BI;
USE DATABASE FINTECH_DEV;

-- [F1] Alerts per day by severity | Chart: Bar (stacked) | X: alert_date_ist | Y: alert_count | Series: severity
SELECT alert_date_ist, severity, SUM(alert_count) AS alert_count
FROM DASHBOARD.VW_FRAUD_MONITORING_SUMMARY
GROUP BY 1, 2 ORDER BY 1, 2;

-- [F2] Rules: volume vs confirmation rate | Chart: Scatter | X: alert_count | Y: confirmation_rate_pct | label: rule_code
SELECT rule_code, alert_source, SUM(alert_count) AS alert_count,
       ROUND(DIV0(SUM(confirmed_fraud_count), SUM(alert_count)) * 100, 2) AS confirmation_rate_pct
FROM DASHBOARD.VW_FRAUD_MONITORING_SUMMARY GROUP BY 1, 2;

-- [F3] Drill-down: platform velocity alerts | Table
SELECT alert_at_ist, rule_code, customer_id, observed_value, threshold_value, severity
FROM CORE.FACT_FRAUD_ALERT WHERE alert_source = 'PLATFORM_RULE'
ORDER BY alert_at_ist DESC LIMIT 200;

-- [Q1] Data quality board | Chart: Table (sort by status) - colour FAIL rows using the table's cell formatting
SELECT check_source, check_name, target_object, check_type, severity, status, failing_rows, checked_at_utc
FROM DASHBOARD.VW_DATA_QUALITY_STATUS
ORDER BY DECODE(status, 'ERROR', 0, 'FAIL', 1, 'WARN', 2, 3), check_source;

-- [Q2] DQ status counts | Chart: Bar | X: status | Y: checks | Series: check_source
SELECT status, check_source, COUNT(*) AS checks
FROM DASHBOARD.VW_DATA_QUALITY_STATUS GROUP BY 1, 2;

-- [P1] Pipeline status | Chart: Table
SELECT component, job, step_type, step_count, succeeded, failed, warned, duration_seconds, last_run_utc
FROM DASHBOARD.VW_PIPELINE_EXECUTION_STATUS
ORDER BY (failed > 0) DESC, last_run_utc DESC;

-- [P2] Task history, last 24h (needs MONITOR on tasks -> run as FINTECH_OPS) | Table
-- USE ROLE FINTECH_OPS;
-- SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ATTEMPT_NUMBER, ERROR_MESSAGE
-- FROM TABLE(FINTECH_DEV.INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day,-1,CURRENT_TIMESTAMP())))
-- ORDER BY SCHEDULED_TIME DESC;

-- [K1] Customer risk transitions | Chart: Bar (stacked) | X: month_start | Y: customer_versions | Series: risk_change
SELECT month_start, risk_change, SUM(customer_versions) AS customer_versions
FROM DASHBOARD.VW_CUSTOMER_RISK_TRANSITIONS
GROUP BY 1, 2 ORDER BY 1, 2;
