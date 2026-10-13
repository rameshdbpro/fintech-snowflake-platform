/* =====================================================================
   12_SEMANTIC_VIEW.SQL  -  governed semantic layer for Cortex Analyst
   Run AFTER dbt build. Requires semantic views (CREATE SEMANTIC VIEW) in
   your account; verify: SHOW SEMANTIC VIEWS IN ACCOUNT LIMIT 1;

   Same formulas as SEMANTIC.SEM_GOVERNED_METRICS_DAILY / DASHBOARD.VW_*:
     payment_success_rate  = captured txns / terminal txns   (by transaction date)
     payment_volume_inr    = SUM(captured_amount_inr) of CAPTURED txns (by captured date)
     settlement_match_rate = MATCHED / (all except NOT_APPLICABLE)
   Each fact exposes its OWN reporting date as a dimension (no shared date
   dimension) so the model cannot pick the wrong date for a metric.
   Ratio metrics that span two facts (refund rate, chargeback rate) are NOT
   defined here on purpose: their numerator and denominator use different
   reporting dates; they are answered from DASHBOARD views / verified queries.
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE SCHEMA SEMANTIC;

CREATE OR REPLACE SEMANTIC VIEW SEMANTIC.SV_PAYMENTS
  TABLES (
    txn AS CORE.FACT_PAYMENT_TRANSACTION PRIMARY KEY (TRANSACTION_KEY)
      WITH SYNONYMS = ('payments', 'transactions', 'orders')
      COMMENT = 'One row per merchant payment order; retries and providers collapsed',
    att AS CORE.FACT_PAYMENT_ATTEMPT PRIMARY KEY (ATTEMPT_KEY)
      WITH SYNONYMS = ('payment attempts', 'retries')
      COMMENT = 'One row per provider payment attempt',
    ref AS CORE.FACT_REFUND PRIMARY KEY (REFUND_KEY)
      WITH SYNONYMS = ('refunds')
      COMMENT = 'One row per refund (partial refunds are separate rows)',
    cb AS CORE.FACT_CHARGEBACK PRIMARY KEY (CHARGEBACK_KEY)
      WITH SYNONYMS = ('chargebacks', 'disputes'),
    rec AS MARTS.MART_SETTLEMENT_RECONCILIATION PRIMARY KEY (ATTEMPT_KEY)
      WITH SYNONYMS = ('settlement reconciliation', 'settlements')
      COMMENT = 'One row per captured or settled payment attempt with reconciliation status',
    fa AS CORE.FACT_FRAUD_ALERT PRIMARY KEY (FRAUD_ALERT_KEY)
      WITH SYNONYMS = ('fraud alerts', 'suspicious activity'),
    mer AS CORE.DIM_MERCHANT PRIMARY KEY (MERCHANT_KEY)
      WITH SYNONYMS = ('merchants', 'sellers'),
    ch AS CORE.DIM_PAYMENT_CHANNEL PRIMARY KEY (CHANNEL_KEY)
      WITH SYNONYMS = ('payment channels', 'payment methods'),
    cust AS CORE.DIM_CUSTOMER PRIMARY KEY (CUSTOMER_KEY)
      WITH SYNONYMS = ('customers', 'risk profile')
      COMMENT = 'Point-in-time customer KYC/risk version (PII columns intentionally not exposed)'
  )
  RELATIONSHIPS (
    txn_to_merchant AS txn (MERCHANT_KEY) REFERENCES mer,
    txn_to_channel  AS txn (CHANNEL_KEY)  REFERENCES ch,
    txn_to_customer AS txn (CUSTOMER_KEY) REFERENCES cust,
    att_to_merchant AS att (MERCHANT_KEY) REFERENCES mer,
    att_to_channel  AS att (CHANNEL_KEY)  REFERENCES ch,
    ref_to_merchant AS ref (MERCHANT_KEY) REFERENCES mer,
    ref_to_channel  AS ref (CHANNEL_KEY)  REFERENCES ch,
    cb_to_merchant  AS cb (MERCHANT_KEY)  REFERENCES mer,
    cb_to_channel   AS cb (CHANNEL_KEY)   REFERENCES ch,
    rec_to_attempt  AS rec (ATTEMPT_KEY)  REFERENCES att,
    fa_to_merchant  AS fa (MERCHANT_KEY)  REFERENCES mer,
    fa_to_customer  AS fa (CUSTOMER_KEY)  REFERENCES cust
  )
  FACTS (
    txn.captured_amount_inr AS CAPTURED_AMOUNT_INR COMMENT = 'Captured value in INR (monthly FX)',
    txn.attempt_count       AS ATTEMPT_COUNT,
    att.attempt_amount_inr  AS ATTEMPT_AMOUNT_INR,
    ref.refund_amount_inr   AS REFUND_AMOUNT_INR,
    cb.chargeback_amount_inr AS CHARGEBACK_AMOUNT_INR,
    rec.outstanding_gross_inr AS OUTSTANDING_GROSS_INR,
    rec.gross_difference_inr AS ROUND(ABS(GROSS_DIFFERENCE) * COALESCE(FX_RATE_TO_INR, 1), 2)
  )
  DIMENSIONS (
    txn.transaction_date AS TRANSACTION_DATE_IST
      WITH SYNONYMS = ('payment date', 'order date') COMMENT = 'IST date the payment was first attempted. Use for success/failure rates.',
    txn.captured_date AS CAPTURED_DATE_IST
      COMMENT = 'IST date the payment was captured. Use for payment volume and successful payment count.',
    txn.final_status AS FINAL_STATUS
      COMMENT = 'CAPTURED, FAILED, REVERSED, VOIDED, PENDING, AUTHORIZED, CREATED',
    txn.provider AS DECIDING_SOURCE_SYSTEM WITH SYNONYMS = ('payment provider', 'gateway'),
    att.attempt_date AS TO_DATE(ATTEMPT_CREATED_AT_IST),
    att.attempt_status AS ATTEMPT_STATUS,
    att.provider AS SOURCE_SYSTEM,
    att.failure_reason AS LAST_REASON_CODE,
    ref.refund_date AS REFUND_REQUESTED_DATE_IST,
    ref.refund_status AS REFUND_STATUS,
    ref.refund_reason AS REFUND_REASON,
    cb.chargeback_received_date AS RECEIVED_DATE,
    cb.chargeback_status AS CANONICAL_STATUS,
    cb.chargeback_reason_code AS REASON_CODE,
    rec.settlement_captured_date AS CAPTURED_DATE_IST,
    rec.recon_status AS RECON_STATUS
      WITH SYNONYMS = ('settlement status', 'reconciliation status')
      COMMENT = 'MATCHED, PENDING_SETTLEMENT, UNSETTLED, PARTIALLY_SETTLED, AMOUNT_MISMATCH, OVER_SETTLED, SETTLED_NOT_CAPTURED, NOT_APPLICABLE',
    fa.alert_date AS ALERT_DATE_IST,
    fa.rule_code AS RULE_CODE,
    fa.severity AS SEVERITY,
    fa.alert_source AS ALERT_SOURCE,
    mer.merchant_id AS MERCHANT_ID,
    mer.merchant_name AS MERCHANT_NAME WITH SYNONYMS = ('merchant', 'seller name'),
    mer.merchant_category AS MERCHANT_CATEGORY,
    mer.merchant_region AS REGION WITH SYNONYMS = ('region', 'zone'),
    ch.channel_name AS CHANNEL_NAME WITH SYNONYMS = ('payment method'),
    ch.channel_group AS CHANNEL_GROUP COMMENT = 'UPI, CARD, WALLET, BANK_TRANSFER',
    cust.risk_rating AS RISK_RATING COMMENT = 'Customer risk rating valid at the time of the event',
    cust.kyc_level AS KYC_LEVEL,
    cust.customer_segment AS CUSTOMER_SEGMENT
  )
  METRICS (
    txn.payment_volume_inr AS SUM(IFF(txn.IS_CAPTURED, txn.CAPTURED_AMOUNT_INR, 0))
      WITH SYNONYMS = ('payment volume', 'GMV', 'TPV', 'captured value')
      COMMENT = 'Governed PAYMENT_VOLUME (INR). Group by captured_date.',
    txn.successful_payment_count AS SUM(IFF(txn.IS_CAPTURED, 1, 0))
      COMMENT = 'Governed SUCCESSFUL_PAYMENT_COUNT',
    txn.payment_success_rate AS DIV0(SUM(IFF(txn.IS_CAPTURED, 1, 0)), SUM(IFF(txn.IS_TERMINAL, 1, 0)))
      WITH SYNONYMS = ('success rate', 'approval rate')
      COMMENT = 'Governed PAYMENT_SUCCESS_RATE: captured / terminal transactions, by transaction_date',
    txn.payment_failure_rate AS DIV0(SUM(IFF(txn.IS_FAILED, 1, 0)), SUM(IFF(txn.IS_TERMINAL, 1, 0)))
      WITH SYNONYMS = ('failure rate', 'decline rate'),
    txn.failed_payment_count AS SUM(IFF(txn.IS_FAILED, 1, 0)),
    txn.average_transaction_value_inr AS DIV0(SUM(IFF(txn.IS_CAPTURED, txn.CAPTURED_AMOUNT_INR, 0)), SUM(IFF(txn.IS_CAPTURED, 1, 0)))
      WITH SYNONYMS = ('ATV', 'average ticket size'),
    att.payment_attempt_count AS SUM(IFF(att.IS_VALID_RECORD, 1, 0))
      WITH SYNONYMS = ('attempts'),
    ref.refund_amount_inr AS SUM(IFF(ref.IS_PROCESSED, ref.REFUND_AMOUNT_INR, 0))
      WITH SYNONYMS = ('refund value', 'refunds amount'),
    ref.refund_count AS SUM(IFF(ref.IS_PROCESSED, 1, 0)),
    cb.chargeback_amount_inr AS SUM(IFF(cb.IS_LOST, cb.CHARGEBACK_AMOUNT_INR, 0))
      COMMENT = 'Governed CHARGEBACK_AMOUNT: lost chargebacks only',
    cb.chargeback_count AS COUNT(cb.CHARGEBACK_KEY),
    rec.settlement_match_rate AS DIV0(SUM(IFF(rec.RECON_STATUS = 'MATCHED', 1, 0)),
                                      SUM(IFF(rec.RECON_STATUS <> 'NOT_APPLICABLE', 1, 0)))
      WITH SYNONYMS = ('match rate', 'reconciliation rate'),
    rec.outstanding_settlement_inr AS SUM(IFF(rec.RECON_STATUS IN ('UNSETTLED', 'PENDING_SETTLEMENT', 'PARTIALLY_SETTLED', 'AMOUNT_MISMATCH'),
                                              rec.OUTSTANDING_GROSS_INR, 0))
      WITH SYNONYMS = ('outstanding settlement', 'unsettled amount'),
    rec.settlement_mismatch_inr AS SUM(IFF(rec.RECON_STATUS IN ('AMOUNT_MISMATCH', 'OVER_SETTLED'),
                                           ROUND(ABS(rec.GROSS_DIFFERENCE) * COALESCE(rec.FX_RATE_TO_INR, 1), 2), 0))
      WITH SYNONYMS = ('settlement mismatch'),
    fa.fraud_alert_count AS COUNT(fa.FRAUD_ALERT_KEY)
      WITH SYNONYMS = ('fraud alerts', 'alerts')
  )
  COMMENT = 'Governed payments metrics (FinTech platform). Read-only analytical layer; not the system of record.'
  AI_SQL_GENERATION 'All money is INR. Use captured_date for payment volume, successful payment count and average transaction value; use transaction_date for success and failure rates; refund_date for refunds; chargeback_received_date for chargebacks; settlement_captured_date for settlement metrics; alert_date for fraud. "Last month" means the previous full calendar month in IST. Never sum ratio metrics; compute them per requested grouping. Always add LIMIT 1000 to detail queries.';

-- Privileges (AI users and analysts query; nobody can write through it)
GRANT SELECT ON SEMANTIC VIEW SEMANTIC.SV_PAYMENTS TO ROLE FINTECH_AI_USER;
GRANT SELECT ON SEMANTIC VIEW SEMANTIC.SV_PAYMENTS TO ROLE FINTECH_ANALYST;
GRANT REFERENCES ON SEMANTIC VIEW SEMANTIC.SV_PAYMENTS TO ROLE FINTECH_AI_USER;

-- Platform-operations semantic view ("Which dbt tests failed?") ------------
CREATE OR REPLACE VIEW SEMANTIC.VW_DBT_TEST_RESULTS
COMMENT = 'dbt test outcomes from AUDIT (owner rights, read-only)'
AS
SELECT INVOCATION_ID AS invocation_id, NODE_NAME AS test_name, STATUS AS status, FAILURES AS failing_rows,
       LEFT(MESSAGE, 500) AS message, LOGGED_AT AS run_at_utc, TO_DATE(LOGGED_AT) AS run_date,
       ROW_NUMBER() OVER (PARTITION BY NODE_NAME ORDER BY LOGGED_AT DESC) = 1 AS is_latest_run
FROM AUDIT.DBT_RUN_RESULTS
WHERE RESOURCE_TYPE = 'test';

CREATE OR REPLACE SEMANTIC VIEW SEMANTIC.SV_PLATFORM_OPS
  TABLES (
    tst AS SEMANTIC.VW_DBT_TEST_RESULTS
      WITH SYNONYMS = ('dbt tests', 'data tests', 'test results'),
    exc AS CANONICAL.CNL_EXCEPTIONS PRIMARY KEY (EXCEPTION_ID)
      WITH SYNONYMS = ('data quality exceptions', 'integration exceptions')
  )
  DIMENSIONS (
    tst.test_name AS TEST_NAME,
    tst.status AS STATUS COMMENT = 'pass, fail, warn, error',
    tst.run_date AS RUN_DATE,
    tst.is_latest_run AS IS_LATEST_RUN COMMENT = 'TRUE for the most recent execution of each test',
    tst.message AS MESSAGE,
    exc.exception_type AS EXCEPTION_TYPE,
    exc.severity AS SEVERITY,
    exc.source_system AS SOURCE_SYSTEM
  )
  METRICS (
    tst.failed_test_count AS SUM(IFF(tst.STATUS IN ('fail', 'error'), 1, 0)) WITH SYNONYMS = ('failed tests'),
    tst.failing_rows AS SUM(COALESCE(tst.FAILING_ROWS, 0)),
    exc.exception_count AS COUNT(exc.EXCEPTION_ID)
  )
  COMMENT = 'Data platform health: dbt tests and integration exceptions'
  AI_SQL_GENERATION 'For "which tests failed" filter is_latest_run = TRUE and status in (fail, error).';

GRANT SELECT ON VIEW SEMANTIC.VW_DBT_TEST_RESULTS TO ROLE FINTECH_AI_USER;
GRANT SELECT ON VIEW SEMANTIC.VW_DBT_TEST_RESULTS TO ROLE FINTECH_ANALYST;
GRANT USAGE ON SCHEMA CANONICAL TO ROLE FINTECH_AI_USER;
GRANT SELECT ON TABLE CANONICAL.CNL_EXCEPTIONS TO ROLE FINTECH_AI_USER;   -- no PII in this table
GRANT USAGE ON SCHEMA CANONICAL TO ROLE FINTECH_ANALYST;
GRANT SELECT ON TABLE CANONICAL.CNL_EXCEPTIONS TO ROLE FINTECH_ANALYST;
GRANT SELECT ON SEMANTIC VIEW SEMANTIC.SV_PLATFORM_OPS TO ROLE FINTECH_AI_USER;
GRANT SELECT ON SEMANTIC VIEW SEMANTIC.SV_PLATFORM_OPS TO ROLE FINTECH_ANALYST;

/* ------------------------------------------------------------------------
   Querying semantic views directly with SQL (no AI involved)
   ------------------------------------------------------------------------ */
-- Payment success rate by month:
-- SELECT * FROM SEMANTIC_VIEW(SEMANTIC.SV_PAYMENTS
--     DIMENSIONS DATE_TRUNC('month', txn.transaction_date) AS month
--     METRICS txn.payment_success_rate, txn.payment_failure_rate)
-- ORDER BY month;
-- Settlement mismatch by merchant (top 10):
-- SELECT * FROM SEMANTIC_VIEW(SEMANTIC.SV_PAYMENTS
--     DIMENSIONS mer.merchant_name
--     METRICS rec.settlement_mismatch_inr, rec.settlement_match_rate)
-- ORDER BY settlement_mismatch_inr DESC LIMIT 10;

/* ------------------------------------------------------------------------
   Consistency check: semantic view vs dashboard view (must return 0 rows)
   ------------------------------------------------------------------------ */
-- WITH sv AS (SELECT * FROM SEMANTIC_VIEW(SEMANTIC.SV_PAYMENTS METRICS txn.payment_volume_inr, rec.outstanding_settlement_inr, fa.fraud_alert_count)),
--      dash AS (SELECT payment_volume_inr, outstanding_settlement_inr, fraud_alert_count
--               FROM DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS WHERE period = 'ALL_TIME')
-- SELECT * FROM sv, dash
-- WHERE ABS(sv.payment_volume_inr - dash.payment_volume_inr) > 0.01
--    OR ABS(sv.outstanding_settlement_inr - dash.outstanding_settlement_inr) > 0.01
--    OR sv.fraud_alert_count <> dash.fraud_alert_count;
