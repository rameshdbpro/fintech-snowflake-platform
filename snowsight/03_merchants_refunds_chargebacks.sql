/* =====================================================================
   SNOWSIGHT PAGE 3 - MERCHANTS, REFUNDS, CHARGEBACKS
   ===================================================================== */
USE ROLE FINTECH_ANALYST;
USE WAREHOUSE WH_FINTECH_BI;
USE DATABASE FINTECH_DEV;

SET report_month = '2026-09-01';
SET region = '%';                    -- NORTH | SOUTH | EAST | WEST | %

-- [M1] Top merchants by volume | Chart: Bar (horizontal) | X: payment_volume_inr | Y: merchant_name
SELECT merchant_name, merchant_region, payment_volume_inr,
       ROUND(payment_success_rate * 100, 2) AS success_rate_pct
FROM DASHBOARD.VW_MERCHANT_PERFORMANCE
WHERE month_start = $report_month::DATE AND merchant_region LIKE $region
ORDER BY payment_volume_inr DESC LIMIT 15;

-- [M2] Merchants with the highest settlement mismatch | Chart: Bar | X: merchant_name | Y: settlement_mismatch_inr
SELECT merchant_name, settlement_mismatch_inr, settlement_exception_count,
       ROUND(settlement_match_rate * 100, 2) AS match_rate_pct
FROM DASHBOARD.VW_MERCHANT_PERFORMANCE
WHERE month_start = $report_month::DATE AND merchant_region LIKE $region
ORDER BY settlement_mismatch_inr DESC LIMIT 15;

-- [M3] Risk/quality scatter | Chart: Scatter | X: refund_rate_pct | Y: chargeback_rate_pct | size/label: merchant_name
SELECT merchant_name, ROUND(refund_rate * 100, 3) AS refund_rate_pct,
       ROUND(chargeback_rate * 100, 3) AS chargeback_rate_pct, payment_volume_inr
FROM DASHBOARD.VW_MERCHANT_PERFORMANCE
WHERE month_start = $report_month::DATE AND successful_payment_count >= 20;

-- [R1] Refunds by channel and month | Chart: Bar (grouped) | X: month_start | Y: refund_amount_inr | Series: channel_group
SELECT month_start, channel_group, SUM(refund_amount_inr) AS refund_amount_inr,
       DIV0(SUM(refund_amount_inr), SUM(payment_volume_inr)) AS refund_rate
FROM DASHBOARD.VW_REFUND_AND_CHARGEBACK_SUMMARY
WHERE merchant_region LIKE $region
GROUP BY 1, 2 ORDER BY 1, 2;

-- [R2] Chargeback trend | Chart: Line | X: month_start | Y: chargeback_amount_inr, chargeback_count
SELECT month_start, SUM(chargeback_count) AS chargeback_count, SUM(chargeback_lost_count) AS lost_count,
       SUM(chargeback_amount_inr) AS chargeback_amount_inr,
       DIV0(SUM(chargeback_count), SUM(successful_payment_count)) AS chargeback_rate
FROM DASHBOARD.VW_REFUND_AND_CHARGEBACK_SUMMARY
GROUP BY 1 ORDER BY 1;

-- [R3] Drill-down: refunds of one merchant | Table
SET drill_merchant = 'M00001';
SELECT refund_id, source_system, source_transaction_id, refund_type, refund_reason, refund_status,
       refund_amount, currency_code, refund_requested_date_ist
FROM CORE.FACT_REFUND WHERE merchant_id = $drill_merchant ORDER BY refund_requested_date_ist DESC LIMIT 200;
