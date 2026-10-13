/* =====================================================================
   NON-AI FALLBACK for the Cortex example questions.
   THIS IS NOT CORTEX. These are hand-written deterministic SQL answers over the
   same governed views, for accounts where Cortex Analyst / AI functions are
   unavailable, and as reference answers to validate Cortex output.
   ===================================================================== */
USE ROLE FINTECH_ANALYST;
USE WAREHOUSE WH_FINTECH_BI;
USE DATABASE FINTECH_DEV;

-- Q1 What was the payment success rate last month? ("last month" = previous full month
--    relative to the latest data date; replace anchor with CURRENT_DATE in production)
WITH a AS (SELECT DATE_TRUNC('month', MAX(date_ist)) AS this_month FROM SEMANTIC.SEM_GOVERNED_METRICS_DAILY)
SELECT DATEADD(month, -1, a.this_month) AS month,
       DIV0(SUM(m.captured_transaction_count_by_created), SUM(m.terminal_transaction_count)) AS payment_success_rate
FROM SEMANTIC.SEM_GOVERNED_METRICS_DAILY m, a
WHERE m.month_start = DATEADD(month, -1, a.this_month)
GROUP BY 1;

-- Q2 Which merchants have the highest settlement mismatch?
SELECT merchant_name, SUM(settlement_mismatch_inr) AS settlement_mismatch_inr
FROM DASHBOARD.VW_MERCHANT_PERFORMANCE GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

-- Q3 Show refunds by payment channel and month.
SELECT month_start, channel_code, SUM(refund_amount_inr) AS refund_amount_inr
FROM SEMANTIC.SEM_GOVERNED_METRICS_DAILY GROUP BY 1, 2 ORDER BY 1, 2;

-- Q4 Which days had the highest increase in failed payments?
SELECT date_ist, failed_transaction_count, failed_change_vs_prior_day
FROM DASHBOARD.VW_DAILY_PAYMENT_TREND ORDER BY failed_change_vs_prior_day DESC NULLS LAST LIMIT 10;

-- Q5 How much settlement remains outstanding?
SELECT SUM(outstanding_settlement_inr) AS outstanding_settlement_inr FROM SEMANTIC.SEM_GOVERNED_METRICS_DAILY;

-- Q6 Explain these reconciliation exceptions. (deterministic explanation = status definition + numbers)
SELECT exception_type, COUNT(*) AS items, SUM(exception_amount) AS total_difference,
       DECODE(exception_type,
         'UNSETTLED', 'Captured but no SALE settlement line after expected date + grace days.',
         'PARTIALLY_SETTLED', 'Provider sent a non-final partial settlement; remainder outstanding.',
         'AMOUNT_MISMATCH', 'Settled gross differs from captured amount beyond tolerance.',
         'OVER_SETTLED', 'Settled more than captured.',
         'UNMATCHED_SETTLEMENT', 'Settlement line references a payment we do not know.',
         'MISSING_BANK_CREDIT', 'Settlement batch never credited on the bank statement after grace.',
         'UNMATCHED_BANK_CREDIT', 'Bank credit references a batch the provider never reported.',
         'BATCH_AMOUNT_MISMATCH', 'Bank credit differs from batch net (e.g. bank charges).',
         'FEE_VARIANCE', 'Fee rate differs from the contracted MDR.',
         'UNIDENTIFIED_BANK_ENTRY', 'Bank line without settlement reference (interest, charges).',
         'See docs/reconciliation.md') AS meaning
FROM DASHBOARD.VW_RECON_EXCEPTION_DETAIL GROUP BY 1 ORDER BY 2 DESC;

-- Q7 Which dbt tests failed? (latest execution of each test)
SELECT test_name, status, failing_rows, message, run_at_utc
FROM SEMANTIC.VW_DBT_TEST_RESULTS WHERE is_latest_run AND status IN ('fail', 'error');

-- Q8 How did customer risk classifications change over time?
SELECT month_start, previous_risk_rating, risk_rating, risk_change, customer_versions
FROM DASHBOARD.VW_CUSTOMER_RISK_TRANSITIONS ORDER BY month_start, risk_change;
