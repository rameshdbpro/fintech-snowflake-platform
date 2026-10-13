/* =====================================================================
   SNOWSIGHT PAGE 2 - PAYMENT TRENDS & CHANNEL PERFORMANCE
   Role FINTECH_ANALYST, warehouse WH_FINTECH_BI. One query = one chart.
   ===================================================================== */
USE ROLE FINTECH_ANALYST;
USE WAREHOUSE WH_FINTECH_BI;
USE DATABASE FINTECH_DEV;

SET start_date = '2026-04-01';
SET end_date   = '2026-09-30';
SET channel_group = '%';            -- UPI | CARD | WALLET | BANK_TRANSFER | % for all

-- [T1] Daily volume trend | Chart: Line | X: date_ist (bucket: day/week/month in chart panel)
--      | Y: payment_volume_inr, payment_volume_inr_7d_avg
SELECT date_ist, payment_volume_inr, payment_volume_inr_7d_avg
FROM DASHBOARD.VW_DAILY_PAYMENT_TREND
WHERE date_ist BETWEEN $start_date AND $end_date
ORDER BY date_ist;

-- [T2] Success vs failure rate | Chart: Line | X: date_ist | Y: success_rate_pct, failure_rate_pct
SELECT date_ist,
       ROUND(payment_success_rate * 100, 2) AS success_rate_pct,
       ROUND(payment_failure_rate * 100, 2) AS failure_rate_pct
FROM DASHBOARD.VW_DAILY_PAYMENT_TREND
WHERE date_ist BETWEEN $start_date AND $end_date
ORDER BY date_ist;

-- [T3] Days with the largest increase in failed payments | Chart: Bar | X: date_ist | Y: failed_change_vs_prior_day
SELECT date_ist, failed_transaction_count, failed_change_vs_prior_day
FROM DASHBOARD.VW_DAILY_PAYMENT_TREND
WHERE date_ist BETWEEN $start_date AND $end_date
ORDER BY failed_change_vs_prior_day DESC NULLS LAST
LIMIT 15;

-- [C1] Volume by channel per month | Chart: Bar (stacked) | X: month_start | Y: payment_volume_inr | Series: channel_code
SELECT month_start, channel_group, channel_code, payment_volume_inr
FROM DASHBOARD.VW_PAYMENT_CHANNEL_PERFORMANCE
WHERE month_start BETWEEN DATE_TRUNC('month', $start_date::DATE) AND $end_date
  AND channel_group LIKE $channel_group
ORDER BY month_start, channel_code;

-- [C2] Success rate heat grid | Chart: Heatgrid | X: month_start | Y: channel_code | Cell: success_rate_pct
SELECT month_start, channel_code, ROUND(payment_success_rate * 100, 2) AS success_rate_pct
FROM DASHBOARD.VW_PAYMENT_CHANNEL_PERFORMANCE
WHERE month_start BETWEEN DATE_TRUNC('month', $start_date::DATE) AND $end_date
ORDER BY month_start, channel_code;

-- [C3] Drill-down: failure reasons for one channel and month | Table
SET drill_channel = 'DEBIT_CARD';
SET drill_month   = '2026-06-01';
SELECT last_reason_code, COUNT(*) AS failed_attempts
FROM CORE.FACT_PAYMENT_ATTEMPT
WHERE is_valid_record AND is_failure
  AND channel_code = $drill_channel
  AND DATE_TRUNC('month', attempt_created_at_ist) = $drill_month::DATE
GROUP BY 1 ORDER BY 2 DESC;
