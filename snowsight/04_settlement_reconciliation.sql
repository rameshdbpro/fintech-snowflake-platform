/* =====================================================================
   SNOWSIGHT PAGE 4 - SETTLEMENT & BANK RECONCILIATION
   ===================================================================== */
USE ROLE FINTECH_ANALYST;
USE WAREHOUSE WH_FINTECH_BI;
USE DATABASE FINTECH_DEV;

-- [S1] Scorecards: match rate + outstanding | Chart: Scorecard
SELECT ROUND(DIV0(SUM(IFF(recon_status = 'MATCHED', item_count, 0)),
                  SUM(IFF(recon_status <> 'NOT_APPLICABLE', item_count, 0))) * 100, 2) AS settlement_match_rate_pct,
       SUM(outstanding_amount_inr) AS outstanding_settlement_inr
FROM DASHBOARD.VW_SETTLEMENT_RECONCILIATION_SUMMARY
WHERE recon_level = 'PAYMENT_TO_SETTLEMENT';

-- [S2] Status mix by month | Chart: Bar (stacked) | X: month_start | Y: item_count | Series: recon_status
SELECT month_start, recon_status, item_count
FROM DASHBOARD.VW_SETTLEMENT_RECONCILIATION_SUMMARY
WHERE recon_level = 'PAYMENT_TO_SETTLEMENT' AND recon_status <> 'NOT_APPLICABLE'
ORDER BY month_start, recon_status;

-- [S3] Batch-to-bank status | Chart: Bar | X: recon_status | Y: item_count
SELECT recon_status, SUM(item_count) AS batches, SUM(absolute_difference_inr) AS absolute_difference
FROM DASHBOARD.VW_SETTLEMENT_RECONCILIATION_SUMMARY
WHERE recon_level = 'BATCH_TO_BANK'
GROUP BY 1 ORDER BY 2 DESC;

-- [S4] Exception aging | Chart: Bar (stacked) | X: age_bucket | Y: exceptions | Series: severity
SELECT age_bucket, severity, COUNT(*) AS exceptions, SUM(ABS(exception_amount)) AS abs_amount
FROM DASHBOARD.VW_RECON_EXCEPTION_DETAIL
GROUP BY 1, 2 ORDER BY 1, 2;

-- [S5] Drill-down: open exceptions of a type | Table
SET exception_type = 'AMOUNT_MISMATCH';   -- UNSETTLED | PARTIALLY_SETTLED | UNMATCHED_SETTLEMENT | MISSING_BANK_CREDIT | ...
SELECT *
FROM DASHBOARD.VW_RECON_EXCEPTION_DETAIL
WHERE exception_type = $exception_type
ORDER BY ABS(exception_amount) DESC LIMIT 200;

-- [S6] Drill-down: one payment end to end (attempt -> settlement lines -> batch -> bank)
SET src = 'PROV_B';
SET txn = 'EDGE-B-0007';
SELECT 'ATTEMPT' AS layer, attempt_status AS status, attempt_amount AS amount, NULL AS batch, attempt_created_at_ist::VARCHAR AS at
FROM CORE.FACT_PAYMENT_ATTEMPT WHERE source_system = $src AND source_transaction_id = $txn
UNION ALL
SELECT 'SETTLEMENT_LINE', settlement_type || IFF(is_final_settlement, '', ' (partial)'), gross_amount, settlement_batch_id, settlement_date::VARCHAR
FROM CORE.FACT_SETTLEMENT_EVENT WHERE source_system = $src AND source_transaction_id = $txn
UNION ALL
SELECT 'RECON', recon_status, gross_difference, NULL, recon_as_of_date::VARCHAR
FROM MARTS.MART_SETTLEMENT_RECONCILIATION WHERE source_system = $src AND source_transaction_id = $txn
UNION ALL
SELECT 'BATCH_TO_BANK', b.recon_status, b.difference, b.settlement_batch_id, b.first_value_date::VARCHAR
FROM MARTS.MART_BANK_RECONCILIATION b
WHERE b.settlement_batch_id IN (SELECT settlement_batch_id FROM CORE.FACT_SETTLEMENT_EVENT
                                WHERE source_system = $src AND source_transaction_id = $txn);

-- [S7] AI explanations, if generated (Cortex; see 13_cortex_ai.sql) | Table
SELECT exception_type, severity, entity_key, exception_amount, ai_explanation, ai_model
FROM DASHBOARD.VW_RECON_EXCEPTION_AI_EXPLANATIONS ORDER BY ai_generated_at_utc DESC LIMIT 50;
