# Architecture Change Management

## What lives where

| Metadata | Store | Change class |
|---|---|---|
| Source systems | `CONFIG.SOURCE_SYSTEM` | runtime |
| Status mappings | `CONFIG.STATUS_MAPPING` | **runtime** (next dbt build) |
| Reconciliation tolerances | `CONFIG.RECON_TOLERANCE` | **runtime** (next dbt build) |
| Fraud thresholds | `CONFIG.FRAUD_THRESHOLD` | **runtime** (next dbt build); window length is code |
| Runtime DQ rules | `CONFIG.DQ_RULE` | **runtime** (immediate, next task run) |
| Row access mapping | `CONFIG.ROW_ACCESS_MAP` | **runtime** (immediate) |
| Bank narrative patterns | `CONFIG.BANK_NARRATIVE_PATTERN` | runtime (next dbt build) |
| Canonical attribute mappings / source mappings | `dbt_project.yml` `vars.payment_providers` → published as `CANONICAL.CFG_SOURCE_ATTRIBUTE_MAPPING` | deployment |
| Business keys, fact grains, materialisations | dbt model code; documented in `CONFIG.MODEL_REGISTRY` | deployment |
| Model dependencies | dbt `ref()` graph → `AUDIT.DBT_MODEL_LINEAGE` (auto) | deployment |
| Relationships | dbt `relationships` tests + semantic view DDL | deployment |
| DQ tests on models | dbt YAML / tests | deployment |
| Metric definitions | `CONFIG.METRIC_DEFINITION` (registry) + dbt semantic base + semantic view DDL | deployment (formula) |
| Config → model/metric impact | `CONFIG.CONFIG_IMPACT_MAP` | runtime |

A table cannot restructure dbt models: structural changes are Git commits, reviewed, tested in CI on
FINTECH_TEST, then deployed. The change-request procedure **rejects** such requests with that guidance.

## Runtime workflow (procedures in `snowflake/14_change_management.sql`)

| Step | Procedure | What happens |
|---|---|---|
| 1 Validate | `SP_SUBMIT_CHANGE`, `SP_VALIDATE_CHANGE` | type-specific rules (allowed canonical statuses, numeric ranges, existing tables/columns, code-fixed parameters) |
| 2 Impact | inside validate | config table → direct models/metrics (`CONFIG_IMPACT_MAP`) → recursive downstream models (`AUDIT.DBT_MODEL_LINEAGE`) + the exact `dbt build -s ...` command |
| 3 Generate SQL | inside validate | MERGE/UPDATE text and its **rollback SQL** stored on the request |
| 4 Preview | `SP_PREVIEW_CHANGE` | before image, after payload, SQL, rollback SQL, impact |
| 5 Approve | `SP_APPROVE_CHANGE` | only FINTECH_CONFIG_APPROVER can call it; approver ≠ requester |
| 6 Deploy | `SP_APPLY_CHANGE` | KPI BEFORE snapshot, executes exactly the approved SQL in a transaction |
| 7 Test | CI/dev runs the returned `dbt build -s ...` (tests included) | |
| 8 Compare | `SP_VERIFY_CHANGE`, `CONFIG.VW_CHANGE_KPI_COMPARISON` | KPI AFTER snapshot, deltas, failed tests in last dbt run |
| 9 Audit | every step | `AUDIT.CHANGE_LOG` |
| 10 Rollback | `SP_ROLLBACK_CHANGE` | stored rollback SQL, then rebuild; Time Travel (`AT (OFFSET => ...)`) for inspection |

Worked example (a new provider status code): bottom of `14_change_management.sql`.

## Deployment workflow (code changes)

1. Branch → edit dbt models / vars / SQL scripts.
2. PR → CI: unit tests (Snowpark handler), `build_snowpark_sql.py --check`, `dbt parse`, then `dbt build` on FINTECH_TEST with a fixed `recon_as_of_date`.
3. Compare KPIs TEST vs PROD (`VW_EXECUTIVE_PAYMENT_KPIS`) in the PR.
4. Merge → protected `production` environment approval → `deploy/deploy.sh` + `dbt build --target prod`.
5. Rollback: revert the commit and redeploy; for data, `--full-refresh` of affected models or Time Travel `UNDROP`/`CLONE ... AT`.
