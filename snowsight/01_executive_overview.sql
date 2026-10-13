/* =====================================================================
   SNOWSIGHT PAGE 1 - EXECUTIVE OVERVIEW
   Open in Snowsight > Projects > Workspaces > (upload or paste this file).
   Role: FINTECH_ANALYST   Warehouse: WH_FINTECH_BI
   Each query below is one chart. Run it, then in the results pane select
   "Chart" and apply the settings in its header. Re-running refreshes the chart
   from live Snowflake data (no cache besides Snowflake's result cache).
   Filters: edit the SET statements (session variables) and re-run.
   ===================================================================== */
USE ROLE FINTECH_ANALYST;
USE WAREHOUSE WH_FINTECH_BI;
USE DATABASE FINTECH_DEV;

SET period = 'LAST_30_DAYS';        -- LAST_30_DAYS | PREV_30_DAYS | MONTH_TO_DATE | ALL_TIME

-- [E1] Scorecards  | Chart: Scorecard (one per column) | value columns below
SELECT payment_volume_inr,
       ROUND(payment_success_rate * 100, 2)   AS payment_success_rate_pct,
       ROUND(settlement_match_rate * 100, 2)  AS settlement_match_rate_pct,
       outstanding_settlement_inr,
       ROUND(refund_rate * 100, 2)            AS refund_rate_pct,
       fraud_alert_count
FROM DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS
WHERE period = $period;

-- [E2] Period comparison | Chart: Bar | X: period (order by sort_order) | Y: payment_volume_inr
SELECT period, sort_order, payment_volume_inr, successful_payment_count,
       ROUND(payment_success_rate * 100, 2) AS payment_success_rate_pct
FROM DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS
WHERE period IN ('LAST_30_DAYS', 'PREV_30_DAYS')
ORDER BY sort_order;

-- [E3] Governed metric definitions | Table view
SELECT metric_name, business_meaning, authoritative_model, grain, numerator, denominator,
       reporting_timestamp, currency_treatment, retry_handling, reversal_treatment, owner
FROM DASHBOARD.VW_METRIC_DEFINITIONS ORDER BY metric_name;
