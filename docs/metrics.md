# Governed Metrics and Semantic Layer

One definition, three consumers:

```
CONFIG.METRIC_DEFINITION  (registry, documentation, impact analysis, Cortex Search)
        │
        ├── SEMANTIC.SEM_GOVERNED_METRICS_DAILY (dbt) ──► DASHBOARD.VW_*  ──► Snowsight charts
        │        additive components only; ratios computed after summing
        │
        └── SEMANTIC.SV_PAYMENTS (Snowflake semantic view) ──► Cortex Analyst / Snowflake Intelligence
                 same formulas over the same facts/marts
```

Consistency is tested, not assumed: dbt tests `semantic_volume_equals_daily_mart`, `semantic_outstanding_equals_recon`,
and verification query **V13** compares the semantic view with `VW_EXECUTIVE_PAYMENT_KPIS`.

## Common rules

- **Timezone:** reporting dates are IST (`Asia/Kolkata`); storage is UTC.
- **Currency:** metrics are in INR using monthly FX at the event month; transaction currency kept on facts.
- **Ratios:** `SUM(numerator) / SUM(denominator)` at the requested grain (`DIV0` → 0 when denominator is 0). Never average ratios.
- **Validity:** only `is_valid_record` attempts participate; invalid ones are reported in `CNL_EXCEPTIONS`.

## Definitions

| Metric | Business meaning | Authoritative model | Grain | Numerator | Denominator | Filters | Reporting date | Retries | Reversals | Owner |
|---|---|---|---|---|---|---|---|---|---|---|
| Payment Volume | Value of captured payments | FACT_PAYMENT_TRANSACTION | transaction | Σ captured_amount_inr | – | final_status = CAPTURED | captured_date_ist | counted once per order | excluded | Payments Product |
| Payment Attempt Count | Provider attempts | FACT_PAYMENT_ATTEMPT | attempt | COUNT(*) | – | is_valid_record | attempt date | every retry counts | reversed attempts still attempts | Payments Product |
| Successful Payment Count | Orders ending captured | FACT_PAYMENT_TRANSACTION | transaction | COUNT CAPTURED | – | CAPTURED | captured_date_ist | collapsed | excluded | Payments Product |
| Payment Success Rate | Share of terminal orders captured | FACT_PAYMENT_TRANSACTION | transaction | COUNT CAPTURED | COUNT terminal | exclude CREATED/PENDING/AUTHORIZED | transaction_date_ist | a retry that succeeds = success | in denominator only | Payments Product |
| Payment Failure Rate | Share of terminal orders failed | FACT_PAYMENT_TRANSACTION | transaction | COUNT FAILED | COUNT terminal | as above | transaction_date_ist | transaction-level | neither success nor failure | Payments Product |
| Average Transaction Value | Captured value per successful order | FACT_PAYMENT_TRANSACTION | transaction | Payment Volume | Successful Payment Count | CAPTURED | captured_date_ist | collapsed | excluded | Payments Product |
| Refund Amount | Processed refunds | FACT_REFUND | refund | Σ refund_amount_inr | – | REFUND_PROCESSED, has_payment | refund_requested_date_ist | n/a | REFUND_REVERSED excluded | Finance Ops |
| Refund Rate | Refund value vs volume | FACT_REFUND / FACT_PAYMENT_TRANSACTION | month × slice | Refund Amount | Payment Volume | aggregated separately | each on its own date | n/a | see components | Finance Ops |
| Chargeback Amount | Chargebacks lost by merchants | FACT_CHARGEBACK | chargeback | Σ chargeback_amount_inr | – | CB_LOST (LOST/ACCEPTED) | received_date | n/a | WON excluded | Risk |
| Chargeback Rate | Chargebacks per successful order | FACT_CHARGEBACK / FACT_PAYMENT_TRANSACTION | month × slice | COUNT chargebacks received | Successful Payment Count | aggregated separately | received_date / captured_date | n/a | n/a | Risk |
| Settlement Match Rate | Settleable attempts fully matched | MART_SETTLEMENT_RECONCILIATION | attempt | COUNT MATCHED | COUNT ≠ NOT_APPLICABLE | valid attempts | captured_date_ist | only the capturing attempt is settleable | NOT_APPLICABLE | Finance Ops |
| Outstanding Settlement Amount | Captured value not yet settled (gross) | MART_SETTLEMENT_RECONCILIATION | attempt | Σ max(expected − settled, 0) in INR | – | UNSETTLED, PENDING_SETTLEMENT, PARTIALLY_SETTLED, AMOUNT_MISMATCH | captured_date_ist | – | excluded | Finance Ops |
| Fraud Alert Count | Alerts raised | FACT_FRAUD_ALERT | alert | COUNT(*) | – | all statuses, vendor + platform rules | alert_date_ist | – | – | Risk |

Refund Rate and Chargeback Rate are deliberately **not** semantic-view metrics: numerator and denominator
live on different facts with different reporting dates. They are provided by `DASHBOARD.VW_*` / marts and as
verified queries for Cortex Analyst.

## dbt semantic models vs Snowflake semantic views vs BI semantic models

| | dbt semantic models (MetricFlow) | Snowflake semantic views | BI tool semantic models |
|---|---|---|---|
| Where defined | YAML in the dbt project | Schema object in Snowflake (`CREATE SEMANTIC VIEW`) | Inside the BI tool |
| Who evaluates | MetricFlow compiles metric queries (dbt Semantic Layer / dbt Cloud API) | Snowflake (`SEMANTIC_VIEW(...)` SQL, Cortex Analyst) | The BI engine |
| Native Cortex Analyst support | No | **Yes** | No |
| Governance | Git + CI | Snowflake RBAC on the object | Tool permissions |
| Used here | **No** (optional; would add the dbt Cloud semantic layer as another runtime) | **Yes**: SV_PAYMENTS, SV_PLATFORM_OPS | No (no external BI by requirement) |

The dbt layer here provides the *governed additive base* (`sem_governed_metrics_daily`) and tests; Snowflake
semantic views provide the *metric vocabulary* for AI. If MetricFlow is adopted later, define it over the same
CORE facts with the formulas above and keep the V13-style consistency test.
