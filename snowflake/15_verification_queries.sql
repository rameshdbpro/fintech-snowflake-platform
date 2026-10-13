/* =====================================================================
   15_VERIFICATION_QUERIES.SQL  -  end-to-end checks after deployment
   Run as FINTECH_OPS (or FINTECH_DEPLOYER in DEV) after:
     00-10 setup -> CALL generator -> 05 edge cases -> dbt seed/snapshot/build
     -> 11, 12, 13. Each query states its expected result.
   ===================================================================== */
USE DATABASE FINTECH_DEV;
USE WAREHOUSE WH_FINTECH_BI;

-- V01 Twelve RAW datasets populated (expect 12 rows, all ROW_COUNT > 0)
SELECT 'PAYMENTS' t, COUNT(*) ROW_COUNT FROM RAW.PAYMENTS UNION ALL
SELECT 'PAYMENT_STATUS_HISTORY', COUNT(*) FROM RAW.PAYMENT_STATUS_HISTORY UNION ALL
SELECT 'CUSTOMERS', COUNT(*) FROM RAW.CUSTOMERS UNION ALL
SELECT 'CUSTOMER_KYC_HISTORY', COUNT(*) FROM RAW.CUSTOMER_KYC_HISTORY UNION ALL
SELECT 'MERCHANTS', COUNT(*) FROM RAW.MERCHANTS UNION ALL
SELECT 'REFUNDS', COUNT(*) FROM RAW.REFUNDS UNION ALL
SELECT 'REFUND_STATUS_HISTORY', COUNT(*) FROM RAW.REFUND_STATUS_HISTORY UNION ALL
SELECT 'BANK_SETTLEMENTS', COUNT(*) FROM RAW.BANK_SETTLEMENTS UNION ALL
SELECT 'BANK_STATEMENT_TRANSACTIONS', COUNT(*) FROM RAW.BANK_STATEMENT_TRANSACTIONS UNION ALL
SELECT 'PAYMENT_CHANNELS', COUNT(*) FROM RAW.PAYMENT_CHANNELS UNION ALL
SELECT 'FRAUD_ALERTS', COUNT(*) FROM RAW.FRAUD_ALERTS UNION ALL
SELECT 'CHARGEBACKS', COUNT(*) FROM RAW.CHARGEBACKS;

-- V02 Reproducibility: same seed => same fingerprint. Run generator twice and compare.
SELECT HASH_AGG(SOURCE_SYSTEM, SOURCE_RECORD) AS payments_fingerprint FROM RAW.PAYMENTS WHERE BATCH_ID LIKE 'SYN-%';

-- V03 Source -> canonical control: generator truth vs canonical (expect 0 rows)
WITH truth AS (
    SELECT ROW_COUNT FROM AUDIT.CONTROL_TOTALS
    WHERE CONTROL_POINT = 'GENERATOR_TRUTH' AND OBJECT_NAME = 'DISTINCT_ATTEMPTS'
    QUALIFY ROW_NUMBER() OVER (ORDER BY CAPTURED_AT DESC) = 1
)
SELECT t.ROW_COUNT AS generated, c.n AS canonical_non_edge
FROM truth t,
     (SELECT COUNT(*) n FROM CANONICAL.CNL_PAYMENT_ATTEMPT WHERE source_transaction_id NOT LIKE 'EDGE%') c
WHERE t.ROW_COUNT <> c.n;

-- V04 Captured value control: generator truth vs facts per currency (expect 0 rows)
WITH truth AS (
    SELECT CURRENCY_CODE, AMOUNT_TOTAL FROM AUDIT.CONTROL_TOTALS
    WHERE CONTROL_POINT = 'GENERATOR_TRUTH' AND OBJECT_NAME = 'CAPTURED_ATTEMPTS'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CURRENCY_CODE ORDER BY CAPTURED_AT DESC) = 1
), facts AS (
    SELECT currency_code, SUM(attempt_amount) AS amt FROM CORE.FACT_PAYMENT_ATTEMPT
    WHERE is_valid_record AND attempt_status = 'CAPTURED' AND source_transaction_id NOT LIKE 'EDGE%'
    GROUP BY currency_code
)
SELECT * FROM truth t FULL OUTER JOIN facts f ON f.currency_code = t.CURRENCY_CODE
WHERE ABS(COALESCE(t.AMOUNT_TOTAL, 0) - COALESCE(f.amt, 0)) > 0.01;

-- V05 Provider ids collide across providers but canonical keys do not (expect >= 1 shared id, 0 key collisions)
SELECT COUNT(*) AS provider_ids_shared_across_providers
FROM (SELECT source_transaction_id FROM CANONICAL.CNL_PAYMENT_ATTEMPT GROUP BY 1 HAVING COUNT(DISTINCT source_system) > 1);
SELECT COUNT(*) - COUNT(DISTINCT canonical_attempt_id) AS key_collisions FROM CANONICAL.CNL_PAYMENT_ATTEMPT;

-- V06 Edge-case expectations (expect 0 rows; same logic as dbt test assert_edge_case_expected_outcomes)
SELECT * FROM DQ_FAILURES.ASSERT_EDGE_CASE_EXPECTED_OUTCOMES;

-- V07 Fan-out guard: daily mart volume = fact volume (expect 0 rows)
SELECT m.v AS mart, f.v AS fact
FROM (SELECT SUM(payment_volume_inr) v FROM MARTS.MART_PAYMENT_DAILY) m,
     (SELECT SUM(captured_amount_inr) v FROM CORE.FACT_PAYMENT_TRANSACTION WHERE is_captured) f
WHERE ABS(m.v - f.v) > 0.01;

-- V08 Gross volume is NOT equal to net bank settlement (expect difference > 0, explained by fees/GST/refunds/chargebacks/exceptions)
SELECT
  (SELECT SUM(captured_amount_inr) FROM CORE.FACT_PAYMENT_TRANSACTION WHERE is_captured)       AS gross_volume_inr,
  (SELECT SUM(fee_amount + tax_amount) FROM CORE.FACT_SETTLEMENT_EVENT WHERE currency_code = 'INR') AS fees_and_gst_inr,
  (SELECT SUM(net_amount) FROM CORE.FACT_SETTLEMENT_EVENT WHERE settlement_type = 'REFUND' AND currency_code = 'INR')     AS refund_debits_inr,
  (SELECT SUM(net_amount) FROM CORE.FACT_SETTLEMENT_EVENT WHERE settlement_type = 'CHARGEBACK' AND currency_code = 'INR') AS chargeback_debits_inr,
  (SELECT SUM(bank_net_amount) FROM MARTS.MART_BANK_RECONCILIATION WHERE currency_code = 'INR') AS bank_net_credits_inr;

-- V09 Reconciliation status distribution (expect mostly MATCHED; each exception type present)
SELECT recon_status, COUNT(*), SUM(expected_gross_inr), SUM(outstanding_gross_inr)
FROM MARTS.MART_SETTLEMENT_RECONCILIATION GROUP BY 1 ORDER BY 2 DESC;
SELECT recon_status, COUNT(*) FROM MARTS.MART_BANK_RECONCILIATION GROUP BY 1 ORDER BY 2 DESC;

-- V10 Exceptions are traceable to RAW (expect 0 rows: every attempt-level exception has its RAW row)
SELECT e.* FROM MARTS.MART_RECONCILIATION_EXCEPTIONS e
WHERE e.exception_category = 'PAYMENT_SETTLEMENT'
  AND NOT EXISTS (SELECT 1 FROM STAGING.STG_PAYMENTS s
                  WHERE s.source_system = e.source_system AND s.source_transaction_id = e.source_transaction_id);

-- V11 SCD2 point-in-time: fact rows use the risk rating valid at payment time (expect 0 rows)
SELECT f.attempt_key FROM CORE.FACT_PAYMENT_ATTEMPT f
JOIN CORE.DIM_CUSTOMER c ON c.customer_key = f.customer_key
WHERE f.customer_key <> MD5('UNKNOWN')
  AND NOT (f.attempt_created_at_utc >= c.valid_from AND f.attempt_created_at_utc < c.valid_to);

-- V12 Dashboard views return data (expect 4 rows with non-null volume)
SELECT * FROM DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS ORDER BY sort_order;

-- V13 Semantic view = dashboard (expect 0 rows) - see 12_semantic_view.sql consistency check
WITH sv AS (SELECT * FROM SEMANTIC_VIEW(SEMANTIC.SV_PAYMENTS METRICS txn.payment_volume_inr, txn.successful_payment_count, fa.fraud_alert_count)),
     dash AS (SELECT payment_volume_inr, successful_payment_count, fraud_alert_count
              FROM DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS WHERE period = 'ALL_TIME')
SELECT * FROM sv, dash
WHERE ABS(sv.payment_volume_inr - dash.payment_volume_inr) > 0.01
   OR sv.successful_payment_count <> dash.successful_payment_count
   OR sv.fraud_alert_count <> dash.fraud_alert_count;

-- V14 Masking works (run as FINTECH_ANALYST: names show initials only)
-- USE ROLE FINTECH_ANALYST; SELECT full_name, email, phone FROM CORE.DIM_CUSTOMER LIMIT 5;
-- Row access works (run as FINTECH_ANALYST_SOUTH: only SOUTH)
-- USE ROLE FINTECH_ANALYST_SOUTH; SELECT DISTINCT merchant_region FROM MARTS.MART_PAYMENT_DAILY;

-- V15 Last dbt run summary
SELECT RESOURCE_TYPE, STATUS, COUNT(*) FROM AUDIT.DBT_RUN_RESULTS
WHERE INVOCATION_ID = (SELECT INVOCATION_ID FROM AUDIT.DBT_RUN_RESULTS ORDER BY LOGGED_AT DESC LIMIT 1)
GROUP BY 1, 2 ORDER BY 1, 2;
