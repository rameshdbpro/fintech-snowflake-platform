# FinTech Payments Platform — Snowflake-native

Payment analytics, settlement & bank reconciliation, and fraud monitoring for UPI, cards, wallets and bank
transfers from three providers with different schemas — built with **Snowflake SQL, dbt, Snowpark, Cortex,
semantic views and Snowsight**. No Streamlit, no web app, no DuckDB, no Python runtime needed to operate it.
All data is synthetic. The platform is analytical only: it never authorises, initiates or alters payments.

> **Dashboard note (important):** Snowflake removed Snowsight *Legacy Dashboards* (creation disabled
> 20 Apr 2026, removal from 22 Jun 2026); the official replacement is Streamlit, which is excluded here.
> Visuals are therefore **Snowsight Workspaces query charts** (one documented chart per query) plus
> **Snowflake Intelligence** over semantic views. See `docs/dashboards_snowsight.md`.

## Repository

```
snowflake/            ordered SQL deployment scripts (run in Snowsight Workspaces or via Snowflake CLI)
  00_account_setup.sql            roles, warehouses, DEV/TEST/PROD databases, schemas
  01_raw_tables.sql               12 RAW datasets + provider CSV landing tables
  02_config_tables.sql            status mappings, tolerances, fraud thresholds, DQ rules, metric registry...
  03_audit_tables.sql             ingestion / DQ / dbt / change / AI audit tables
  04_synthetic_data_generator.sql deterministic SQL generator (configurable volume, dates, seed)
  05_edge_cases.sql               14 controlled scenarios + 27 expected outcomes
  06_file_ingestion.sql           file formats, stage, header validation, COPY, rejects, landing promotion
  07_ingestion_controls_and_dq.sql stream-driven controls, control totals, duplicates, runtime DQ rules
  08_snowpark.sql                 Snowpark Python UDF (bank narrative parser) + profiler procedure (+ SQL fallbacks)
  09_streams_tasks.sql            streams, task graph with finalizer, alerts, optional EXECUTE DBT PROJECT
  10_security_governance.sql      RBAC, masking, row access, tags, service users, audit & retention
  11_dashboard_views.sql          DASHBOARD.VW_* views for charts
  12_semantic_view.sql            SV_PAYMENTS, SV_PLATFORM_OPS semantic views
  13_cortex_ai.sql                AI_COMPLETE explanations, AI_AGG, Snowflake Intelligence agent, Cortex Search
  14_change_management.sql        config change workflow: validate, impact, preview, approve, apply, verify, rollback
  15_verification_queries.sql     end-to-end checks with expected results
  16_cost_monitoring.sql          resource monitors, cost & performance queries
dbt/                  dbt-snowflake project: 55 models, 1 snapshot, 2 seeds, 175 tests
snowsight/            one SQL file per dashboard page; chart settings documented per query
snowpark/             UDF handler source + unit tests (CI)
deploy/               deploy.sh (Snowflake CLI) and CI pipeline example
tools/                build_snowpark_sql.py, validate_local.py (CI/dev only)
docs/                 architecture, canonical model, dimensional model, metrics, reconciliation,
                      dashboards, Cortex, operations, security, change management, cost, testing, sample KPIs
```

## Prerequisites

| Need | Notes |
|---|---|
| Snowflake account | Enterprise edition or higher for masking/row access/tags (Standard: see docs/security.md) |
| Roles | ACCOUNTADMIN once (account grants, resource monitors, optional e-mail integration), SECURITYADMIN, SYSADMIN |
| Anaconda terms accepted | only for Snowpark Python (08); otherwise use the SQL fallbacks |
| Cortex | region/model availability, `SNOWFLAKE.CORTEX_USER`; semantic views; Snowflake Intelligence enabled (optional) |
| Developer / CI machine | Python 3.10+, `pip install dbt-snowflake` (1.9+), optional `snowflake-cli`; key-pair auth for service users |

## Quick start

1. **Setup** — in Snowsight Workspaces, run `snowflake/00` → `01` → `02` → `03` → `04` → `06` → `07` → `08` → `09` → `10` → `14`
   (each file declares the role it needs; replace FINTECH_DEV for TEST/PROD). Or: `ENV_DB=FINTECH_DEV deploy/deploy.sh setup`.
2. **Data** — `CALL FINTECH_DEV.OPS.SP_GENERATE_SYNTHETIC_DATA();` then run `05_edge_cases.sql`.
   Volumes/dates/seed are parameters: `CALL OPS.SP_GENERATE_SYNTHETIC_DATA(50000, 1000, 1000000, '2026-01-01', '2026-09-30', 'MY-SEED', TRUE);`
   External CSVs: Snowsight *Data → Add Data → Load files into a stage* (`OPS.STG_INBOUND/payments/prov_a/`), then
   `CALL OPS.SP_LOAD_STAGE_PATH('payments/prov_a/', 'FILE-001'); CALL OPS.SP_PROMOTE_LANDING_PAYMENTS('PROV_A', 'FILE-001');`
3. **Transform** — from your machine/CI:
   ```bash
   cd dbt && cp profiles.yml.example ~/.dbt/profiles.yml
   export SNOWFLAKE_ACCOUNT=... SNOWFLAKE_USER=... SNOWFLAKE_PRIVATE_KEY_PATH=...
   dbt seed && dbt snapshot && dbt build --exclude resource_type:snapshot
   ```
   Flags: `--vars '{apply_governance_policies: false}'` (no Enterprise), `--vars '{use_snowpark_narrative_parser: false}'` (no Python UDFs),
   `--vars '{recon_as_of_date: "2026-10-01"}'` (deterministic reconciliation).
4. **Serve** — run `11` → `12` → `13` (optional) → `16`.
5. **Verify** — `15_verification_queries.sql` (every query states its expected result).
6. **Use** — upload `snowsight/*.sql` to Workspaces and build the charts listed in `docs/dashboards_snowsight.md`;
   ask questions in Cortex Analyst / Snowflake Intelligence (`docs/cortex_ai.md`).

## What runs where

| Inside Snowflake (routine operation) | Outside Snowflake (development / deployment only) |
|---|---|
| Generator, COPY, procedures, Snowpark UDF/procedure, streams, tasks, alerts, all model SQL, policies, semantic views, Cortex, Snowsight charts | dbt Core (compiles & submits SQL), Snowflake CLI deploy script, CI unit tests |

dbt Core is not executed by Snowflake unless you opt into *dbt Projects on Snowflake* (`EXECUTE DBT PROJECT`, optional block in `09`).

## Design highlights

- **Canonical layer**: provider fields mapped from `vars.payment_providers`; statuses from `CONFIG.STATUS_MAPPING`; unknown values become exceptions, never disappear; provider ids namespaced by `source_system`. Onboarding a provider = config + one YAML block (docs/canonical_model.md).
- **Dimensional core**: 6 facts at explicit grains, SCD2 customer (KYC/risk) and merchant, UNKNOWN members, point-in-time joins, incremental merges with look-back for late data.
- **No inflated totals**: one-to-many facts are aggregated before joining; enforced by control-total tests.
- **Two-level reconciliation**: payment↔settlement and batch↔bank with documented formulas, tolerances and statuses; gross ≠ net is explicit.
- **One metric definition**: dashboards and Cortex use the same formulas; a test proves it.
- **Config changes with four-eyes control**, impact analysis from the dbt lineage, KPI before/after and rollback.

## Known limitations / not verified in a live account

This project was built without access to a Snowflake account. Verified locally: dbt parse and full offline
compilation (full and incremental branches), SQL syntax of compiled models and of the scripts' standard
statements, Snowpark handler unit tests (see docs/testing.md). **Not executed:** any statement against Snowflake.
Items most likely to need adjustment to your account or the current docs:

1. Workspaces chart availability and options (Legacy Dashboards are gone; see dashboards doc).
2. `CREATE AGENT` specification format and Snowflake Intelligence visibility setup (13); semantic view DDL details such as `AI_SQL_GENERATION` (12).
3. Cortex model names/regions (`mistral-large2` default) and `AI_COMPLETE` named-argument form.
4. Snowflake Scripting details in procedures (bind variables in CTAS were avoided by design; review on first run).
5. `IDENTIFIER($DB_NAME)` in GRANT statements — replace with the literal database name if your account rejects it.
6. The Snowpark profiler's DataFrame schema inference when writing to `AUDIT.DATA_PROFILE`.
7. FX rates are synthetic.

## License / data

Synthetic data only; names, e-mails (`@example.invalid`), phone numbers and PAN-like values are generated.
