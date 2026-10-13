# fintech_payments (dbt-snowflake)

Transformation project for the FinTech payments platform. dbt Core runs **outside** Snowflake
(your laptop or a CI runner); it compiles Jinja to SQL and sends that SQL to Snowflake, where all
compute happens. Snowflake does not run dbt Core by itself. (Optional alternative: deploy this
folder as a Snowflake *dbt Project* object and run it with `EXECUTE DBT PROJECT` — see
`../snowflake/09_streams_tasks.sql`. That feature must be available in your account.)

## Layers

| Folder | Schema | Materialization | Purpose |
|---|---|---|---|
| `models/staging` | STAGING | view | 1:1 with RAW, dedup, provider keys → neutral names |
| `models/canonical` | CANONICAL | table / incremental | provider-agnostic entities, status/amount/timestamp normalisation, exceptions |
| `models/intermediate` | INTERMEDIATE | view / table | pre-aggregations that prevent fan-out, platform fraud rules |
| `models/core` | CORE | table / incremental | facts and dimensions (SCD2 customer & merchant) |
| `models/marts` | MARTS | table | business marts and reconciliation |
| `models/semantic` | SEMANTIC | view | governed additive metric base for dashboards |
| `snapshots` | SNAPSHOTS | snapshot | merchant SCD2 |
| `seeds` | STAGING | seed | currency, synthetic FX |

## Setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install "dbt-snowflake>=1.9"
cp profiles.yml.example ~/.dbt/profiles.yml        # values come from env vars only
export SNOWFLAKE_ACCOUNT=myorg-myacct SNOWFLAKE_USER=SVC_DBT_DEV
export SNOWFLAKE_PRIVATE_KEY_PATH=~/.ssh/svc_dbt_dev.p8
dbt debug
```

## Run order

```bash
dbt seed                                  # currency + FX
dbt snapshot                              # merchant history (run before core)
dbt build --exclude resource_type:snapshot   # models + tests in DAG order
dbt source freshness
dbt docs generate && dbt docs serve       # lineage + documentation site (local)
```

Deterministic reconciliation for test runs: `dbt build --vars '{recon_as_of_date: "2026-10-01"}'`.
Without Enterprise edition (no masking / row access policies):
`--vars '{apply_governance_policies: false}'`.
Without the Snowpark UDF: `--vars '{use_snowpark_narrative_parser: false}'`.

## Incremental models, late data, corrections, backfills

| Model | unique_key | Late-arriving / correction handling |
|---|---|---|
| `cnl_payment_event` | canonical_event_id | re-reads `incremental_lookback_days` (default 3) of ingestion |
| `cnl_payment_attempt` | canonical_attempt_id | re-processes every attempt with a new payload **or** new status event in the window; status resolved by event time |
| `fact_payment_attempt` | attempt_key | merges rows whose canonical row changed |
| `fact_settlement_event` | settlement_event_key | window on ingestion + re-link lines whose payment arrived late |

- **Backfill a period / after a mapping change:** `dbt build -s cnl_payment_event+ --full-refresh`
- **Events older than the look-back window:** raise the window for one run:
  `dbt build -s cnl_payment_event+ --vars '{incremental_lookback_days: 30}'`
- Financial rules are deterministic: no `current_timestamp` in calculations except the documented
  `recon_as_of_date()` default.

## Tests

- Generic YAML tests: unique, not_null, relationships (FK), accepted_values, plus custom
  `non_negative`, `amount_reconciles` (control totals / fan-out guards), `row_count_matches`,
  `scd2_valid_windows`, `canonical_status_valid` (`macros/tests/generic_tests.sql`).
- Singular tests (`tests/`): edge-case known answers, raw→canonical control, transaction volume
  not inflated, ratio bounds, FX uniqueness, velocity window guard, refunds ≤ capture (warn).
- Failures are stored in schema `DQ_FAILURES` and every result is logged to `AUDIT.DBT_RUN_RESULTS`
  and `AUDIT.DQ_RESULTS` by the `on-run-end` hook.

## CI/CD (example)

```yaml
# .github/workflows/dbt.yml (excerpt)
- run: pip install dbt-snowflake
- run: dbt deps && dbt seed --target test && dbt snapshot --target test
- run: dbt build --target test --vars '{recon_as_of_date: "2026-10-01"}'
# promote: same commit, --target prod, executed by a deploy job with prod secrets
```
