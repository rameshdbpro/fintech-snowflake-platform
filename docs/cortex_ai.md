# Snowflake Cortex Integration

All AI runs inside Snowflake. Nothing is sent to an external service by this project.

| Use case | Cortex capability | Object | Read/write |
|---|---|---|---|
| NL questions over governed metrics | Cortex Analyst (semantic view) | `SEMANTIC.SV_PAYMENTS` | read-only, caller's role |
| "Which dbt tests failed?", DQ exceptions | Cortex Analyst | `SEMANTIC.SV_PLATFORM_OPS` | read-only |
| One place to ask both | Snowflake Intelligence agent | `SEMANTIC.FINTECH_PAYMENTS_AGENT` | read-only |
| Explain reconciliation exceptions | `AI_COMPLETE` | `OPS.SP_EXPLAIN_RECON_EXCEPTIONS` → `AUDIT.AI_EXCEPTION_EXPLANATION` | writes text to AUDIT only |
| Data-quality failure summary | `AI_AGG` | ad-hoc query (13_cortex_ai.sql §2a) | read-only |
| Refund & chargeback trend narrative | `AI_COMPLETE` over governed monthly figures | §2b | read-only |
| "What does metric X mean?" | Cortex Search | `SEMANTIC.CSS_PLATFORM_DOCS` | read-only |

## Prerequisites (check before running 13_cortex_ai.sql)

- Account region supports the chosen model, or cross-region inference is enabled (`CORTEX_ENABLED_CROSS_REGION`) — a data-residency decision.
- `SNOWFLAKE.CORTEX_USER` database role granted to `FINTECH_AI_USER` (10_security_governance.sql).
- Semantic views available (`CREATE SEMANTIC VIEW`), and the agent object / Snowflake Intelligence enabled for the account.
- Model name: the scripts default to `mistral-large2`; substitute any model available to you
  (`SELECT AI_COMPLETE('<model>', 'ping')` to test).

## Guardrails

- **No writes:** FINTECH_AI_USER has only SELECT on SEMANTIC, DASHBOARD, MARTS, CORE (and CNL_EXCEPTIONS).
  Cortex Analyst executes generated SQL with that role, so it cannot modify anything.
- **Governed scope:** Analyst only sees the semantic views' logical tables and metrics; PII columns of DIM_CUSTOMER
  are not exposed as dimensions and are masked by policy anyway.
- **Bounded cost/time:** dedicated `WH_FINTECH_AI` (XSMALL, 120 s statement timeout, resource monitor
  RM_FINTECH_AI); batch explanations capped at 50 rows/call and logged to `AUDIT.CORTEX_USAGE_LOG`.
- **Numbers come from SQL:** prompts pass deterministic figures and forbid new calculations; explanations are stored
  separately from financial data and labelled as AI-generated in `VW_RECON_EXCEPTION_AI_EXPLANATIONS`.
- **SQL review:** Cortex Analyst returns its SQL; add correct answers as *verified queries* in the Cortex Analyst
  UI (they are then preferred for similar questions). Reference answers: `snowsight/06_cortex_fallback_questions.sql`.

## Example questions and the governed path they should take

| Question | Expected resolution |
|---|---|
| What was the payment success rate last month? | `txn.payment_success_rate` grouped by month of `txn.transaction_date`, previous full IST month |
| Which merchants have the highest settlement mismatch? | `rec.settlement_mismatch_inr` by `mer.merchant_name`, top N |
| Show refunds by payment channel and month. | `ref.refund_amount_inr` by `ch.channel_name`, month(`ref.refund_date`) |
| Which days had the highest increase in failed payments? | `txn.failed_payment_count` by `txn.transaction_date` with day-over-day delta |
| How much settlement remains outstanding? | `rec.outstanding_settlement_inr` |
| Explain these reconciliation exceptions. | `DASHBOARD.VW_RECON_EXCEPTION_AI_EXPLANATIONS` (after `CALL OPS.SP_EXPLAIN_RECON_EXCEPTIONS`) |
| Which dbt tests failed? | SV_PLATFORM_OPS: `tst.failed_test_count` by `tst.test_name` where `is_latest_run` |
| How did customer risk classifications change over time? | `cust.risk_rating` by period, or `DASHBOARD.VW_CUSTOMER_RISK_TRANSITIONS` |

## If Cortex is unavailable

Run `snowsight/06_cortex_fallback_questions.sql`: deterministic SQL answers to the same questions over the same views.
**These are not Cortex results** and are labelled as such. Skip `13_cortex_ai.sql` entirely; nothing else depends on it.
