/* =====================================================================
   13_CORTEX_AI.SQL  -  Snowflake Cortex integration (in-account AI only)

   Prerequisites (verify in YOUR account before running)
   * Region/model availability: SELECT AI_COMPLETE('<model>', 'ping');
     If a model is not in your region, an ACCOUNTADMIN can enable cross-region
     inference:  ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
     (review data-residency policy first).
   * Role FINTECH_AI_USER holds SNOWFLAKE.CORTEX_USER (10_security_governance.sql).
   * Semantic views from 12_semantic_view.sql.
   * Function names used: AI_COMPLETE, AI_AGG (Cortex AISQL). Older accounts:
     SNOWFLAKE.CORTEX.COMPLETE / SNOWFLAKE.CORTEX.SUMMARIZE are equivalents.

   Guardrails
   * AI never writes financial data: FINTECH_AI_USER has SELECT-only grants;
     generated explanations go to AUDIT.AI_EXCEPTION_EXPLANATION, never to marts.
   * Cortex Analyst only generates SQL over SEMANTIC.SV_* (governed metrics) and
     runs it with the caller's read-only role on WH_FINTECH_AI
     (STATEMENT_TIMEOUT_IN_SECONDS = 120; resource monitor in 16_cost_monitoring.sql).
   * Every number in an AI explanation is copied from deterministic SQL columns
     passed into the prompt; prompts instruct the model not to compute new figures.
   * Batch AI calls are capped (P_MAX_ROWS <= 50) and logged to AUDIT.CORTEX_USAGE_LOG.
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE WAREHOUSE WH_FINTECH_AI;
USE SCHEMA OPS;

------------------------------------------------------------------ 1. exception explanations
CREATE OR REPLACE PROCEDURE OPS.SP_EXPLAIN_RECON_EXCEPTIONS(P_MAX_ROWS NUMBER, P_MODEL VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Cortex AI_COMPLETE explanations for open reconciliation exceptions (stored in AUDIT, read-only use)'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_rows  NUMBER;
    v_limit NUMBER DEFAULT LEAST(GREATEST(COALESCE(P_MAX_ROWS, 20), 1), 50);
BEGIN
    INSERT INTO AUDIT.AI_EXCEPTION_EXPLANATION (EXCEPTION_ID, EXCEPTION_TYPE, MODEL_NAME, EXPLANATION)
    WITH todo AS (
        SELECT e.*
        FROM MARTS.MART_RECONCILIATION_EXCEPTIONS e
        WHERE e.severity IN ('HIGH', 'MEDIUM')
          AND NOT EXISTS (SELECT 1 FROM AUDIT.AI_EXCEPTION_EXPLANATION x WHERE x.EXCEPTION_ID = e.exception_id)
        QUALIFY ROW_NUMBER() OVER (ORDER BY ABS(COALESCE(e.exception_amount_inr, e.exception_amount)) DESC NULLS LAST) <= :v_limit
    )
    SELECT exception_id, exception_type, :P_MODEL,
           AI_COMPLETE(
             model => :P_MODEL,
             prompt => 'You are a payments reconciliation analyst. Explain in at most 3 short sentences what this '
                    || 'exception most likely means and the next operational check to perform. Use ONLY the numbers '
                    || 'given; do not calculate new amounts. Exception: '
                    || TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(
                         'category', exception_category, 'type', exception_type, 'severity', severity,
                         'age_days', age_days, 'currency', currency_code, 'difference', exception_amount,
                         'expected', expected_gross, 'settled_or_bank', settled_gross,
                         'provider', source_system, 'batch', settlement_batch_id, 'detail', detail))
                    || ' Status definitions: UNSETTLED = captured but no settlement after the expected date plus grace; '
                    || 'AMOUNT_MISMATCH = settled gross differs beyond tolerance; PARTIALLY_SETTLED = provider sent a '
                    || 'non-final partial line; UNMATCHED_SETTLEMENT = settlement line without a known payment; '
                    || 'MISSING_BANK_CREDIT = batch never credited by the bank after grace; UNMATCHED_BANK_CREDIT = bank '
                    || 'credit references an unknown batch; FEE_VARIANCE = fee rate differs from contract.',
             model_parameters => {'temperature': 0, 'max_tokens': 220}
           )::VARCHAR
    FROM todo;
    v_rows := SQLROWCOUNT;
    INSERT INTO AUDIT.CORTEX_USAGE_LOG (USE_CASE, MODEL_NAME, INPUT_ROWS)
    VALUES ('RECON_EXCEPTION_EXPLANATION', :P_MODEL, :v_rows);
    RETURN OBJECT_CONSTRUCT('explained', v_rows, 'model', P_MODEL);
END;
$$;
GRANT USAGE ON PROCEDURE OPS.SP_EXPLAIN_RECON_EXCEPTIONS(NUMBER, VARCHAR) TO ROLE FINTECH_OPS;

-- Invoke:  CALL OPS.SP_EXPLAIN_RECON_EXCEPTIONS(20, 'mistral-large2');
-- Read:    SELECT x.EXPLANATION, e.* FROM AUDIT.AI_EXCEPTION_EXPLANATION x
--          JOIN MARTS.MART_RECONCILIATION_EXCEPTIONS e ON e.exception_id = x.EXCEPTION_ID
--          ORDER BY x.GENERATED_AT DESC;

-- Read-only view so analysts / AI users can see explanations next to the facts
CREATE OR REPLACE VIEW DASHBOARD.VW_RECON_EXCEPTION_AI_EXPLANATIONS
COMMENT = 'AI-generated text (Cortex AI_COMPLETE). Figures come from deterministic columns, not from the text.'
AS
SELECT e.exception_id, e.exception_category, e.exception_type, e.severity, e.age_days,
       e.entity_key, e.exception_amount, e.currency_code, e.detail,
       x.EXPLANATION AS ai_explanation, x.MODEL_NAME AS ai_model, x.GENERATED_AT AS ai_generated_at_utc
FROM MARTS.MART_RECONCILIATION_EXCEPTIONS e
JOIN AUDIT.AI_EXCEPTION_EXPLANATION x ON x.EXCEPTION_ID = e.exception_id;
GRANT SELECT ON VIEW DASHBOARD.VW_RECON_EXCEPTION_AI_EXPLANATIONS TO ROLE FINTECH_ANALYST;
GRANT SELECT ON VIEW DASHBOARD.VW_RECON_EXCEPTION_AI_EXPLANATIONS TO ROLE FINTECH_AI_USER;

------------------------------------------------------------------ 2. ad-hoc AI queries (run as FINTECH_AI_USER)
-- 2a. Data quality failure summary (AI_AGG reduces many rows into one summary)
-- USE ROLE FINTECH_AI_USER; USE WAREHOUSE WH_FINTECH_AI;
-- SELECT AI_AGG(
--          check_source || ' | ' || check_name || ' | ' || status || ' | failing_rows=' || COALESCE(TO_VARCHAR(failing_rows), 'n/a')
--          || ' | ' || COALESCE(details, ''),
--          'Summarise these data quality results for an operations lead: what failed, how severe, and what to check first. Do not invent numbers.')
--        AS dq_summary
-- FROM DASHBOARD.VW_DATA_QUALITY_STATUS
-- WHERE status IN ('FAIL', 'WARN', 'ERROR');

-- 2b. Refund and chargeback trend narrative over governed monthly figures
-- SELECT AI_COMPLETE(
--          model => 'mistral-large2',
--          prompt => 'Describe the trend in refunds and chargebacks month by month in 4 bullet points. '
--                 || 'Only use these figures (INR): ' || TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY month_start)),
--          model_parameters => {'temperature': 0, 'max_tokens': 300}) AS narrative
-- FROM (SELECT month_start, SUM(refund_amount_inr) AS refund_amount_inr, SUM(chargeback_amount_inr) AS chargeback_amount_inr,
--              DIV0(SUM(refund_amount_inr), SUM(payment_volume_inr)) AS refund_rate,
--              DIV0(SUM(chargeback_count), SUM(successful_payment_count)) AS chargeback_rate
--       FROM DASHBOARD.VW_REFUND_AND_CHARGEBACK_SUMMARY GROUP BY month_start);

-- 2c. Merchant exploration: use Cortex Analyst (section 3) - the model writes SQL
--     against SEMANTIC.SV_PAYMENTS, it does not see or compute raw data itself.

------------------------------------------------------------------ 3. Cortex Analyst / Snowflake Intelligence
-- Natural-language analytics over SEMANTIC.SV_PAYMENTS and SEMANTIC.SV_PLATFORM_OPS.
-- Option A (Snowsight UI, no code): AI & ML > Cortex Analyst > select SEMANTIC.SV_PAYMENTS
--   > Playground: ask questions, inspect generated SQL, add good ones as verified queries.
-- Option B (Snowflake Intelligence): create an agent with both semantic views as
--   Cortex Analyst tools, then ask in Snowsight > AI & ML > Snowflake Intelligence.
--   SQL form below; syntax per CREATE AGENT docs at time of writing - verify in your
--   account (the Snowsight "Create agent" wizard produces the same object).
CREATE OR REPLACE AGENT SEMANTIC.FINTECH_PAYMENTS_AGENT
  COMMENT = 'Read-only analytics agent over governed payment metrics'
  PROFILE = '{"display_name": "FinTech Payments Analyst"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  instructions:
    response: "Answer with governed metrics only. State the metric name, period and grouping used. All money is INR. If a question needs data outside the semantic views, say so instead of guessing."
    orchestration: "Use payments_metrics for payments, refunds, chargebacks, settlement and fraud. Use platform_ops for dbt tests and data-quality exceptions."
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "payments_metrics"
        description: "Governed payment, refund, chargeback, settlement reconciliation and fraud metrics."
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "platform_ops"
        description: "dbt test results and canonical integration exceptions."
  tool_resources:
    payments_metrics:
      semantic_view: "FINTECH_DEV.SEMANTIC.SV_PAYMENTS"
      execution_environment:
        type: "warehouse"
        warehouse: "WH_FINTECH_AI"
    platform_ops:
      semantic_view: "FINTECH_DEV.SEMANTIC.SV_PLATFORM_OPS"
      execution_environment:
        type: "warehouse"
        warehouse: "WH_FINTECH_AI"
  $$;
GRANT USAGE ON AGENT SEMANTIC.FINTECH_PAYMENTS_AGENT TO ROLE FINTECH_AI_USER;
-- To surface it in Snowflake Intelligence, follow the account's Snowflake
-- Intelligence setup (agent object placement / visibility) in current docs.

-- Example questions (with the governed metric each should resolve to)
--   What was the payment success rate last month?          -> txn.payment_success_rate by transaction_date
--   Which merchants have the highest settlement mismatch?  -> rec.settlement_mismatch_inr by mer.merchant_name
--   Show refunds by payment channel and month.             -> ref.refund_amount_inr by ch.channel_name, month(refund_date)
--   Which days had the highest increase in failed payments?-> txn.failed_payment_count by transaction_date (+ day-over-day)
--   How much settlement remains outstanding?               -> rec.outstanding_settlement_inr
--   Which dbt tests failed?                                -> tst.failed_test_count by test_name, is_latest_run
--   How did customer risk classifications change over time? -> cust.risk_rating x txn.transaction_date, or
--                                                             DASHBOARD.VW_CUSTOMER_RISK_TRANSITIONS
--   Explain these reconciliation exceptions.               -> DASHBOARD.VW_RECON_EXCEPTION_AI_EXPLANATIONS

------------------------------------------------------------------ 4. Cortex Search over platform documentation (optional)
-- Justified for "what does <metric/status> mean?" questions: indexes metric
-- definitions, status meanings and model grains that already live in CONFIG.
CREATE OR REPLACE VIEW SEMANTIC.VW_PLATFORM_DOCS AS
SELECT 'METRIC' AS doc_type, METRIC_NAME AS doc_key,
       METRIC_NAME || ': ' || BUSINESS_MEANING || '. Model: ' || AUTHORITATIVE_MODEL || '. Grain: ' || GRAIN ||
       '. Numerator: ' || COALESCE(NUMERATOR, '-') || '. Denominator: ' || COALESCE(DENOMINATOR, '-') ||
       '. Filters: ' || COALESCE(FILTERS, '-') || '. Date: ' || REPORTING_TIMESTAMP || ' (' || TIMEZONE || '). Currency: ' ||
       CURRENCY_TREATMENT || '. Retries: ' || RETRY_HANDLING || '. Reversals: ' || REVERSAL_TREATMENT || '. Owner: ' || OWNER AS content
FROM CONFIG.METRIC_DEFINITION
UNION ALL
SELECT 'STATUS', STATUS_DOMAIN || ':' || CANONICAL_STATUS, STATUS_DOMAIN || ' status ' || CANONICAL_STATUS || ': ' || DESCRIPTION
FROM CONFIG.CANONICAL_STATUS
UNION ALL
SELECT 'MODEL', MODEL_NAME, MODEL_NAME || ' (' || LAYER || '): grain ' || GRAIN || '; business key ' || BUSINESS_KEY ||
       '; materialization ' || MATERIALIZATION
FROM CONFIG.MODEL_REGISTRY;

CREATE OR REPLACE CORTEX SEARCH SERVICE SEMANTIC.CSS_PLATFORM_DOCS
  ON content
  ATTRIBUTES doc_type
  WAREHOUSE = WH_FINTECH_AI
  TARGET_LAG = '1 day'
  AS SELECT content, doc_type, doc_key FROM SEMANTIC.VW_PLATFORM_DOCS;
GRANT USAGE ON CORTEX SEARCH SERVICE SEMANTIC.CSS_PLATFORM_DOCS TO ROLE FINTECH_AI_USER;
-- Test: SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('FINTECH_DEV.SEMANTIC.CSS_PLATFORM_DOCS',
--         '{"query": "how is settlement match rate calculated", "columns": ["content","doc_key"], "limit": 3}');

------------------------------------------------------------------ 5. usage monitoring
-- SELECT * FROM AUDIT.CORTEX_USAGE_LOG ORDER BY LOGGED_AT DESC;
-- SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY ORDER BY START_TIME DESC LIMIT 100;
-- SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY ORDER BY START_TIME DESC LIMIT 100;
