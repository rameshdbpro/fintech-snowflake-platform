# Testing

## What was validated where this project was built (no Snowflake account available)

| Check | Tool | Result |
|---|---|---|
| dbt project parses (refs, sources, YAML tests, macros, snapshot, seeds) | `dbt parse` (dbt-core 1.12, dbt-snowflake 1.12) | pass |
| Every model, test, snapshot compiles to SQL (full-refresh **and** incremental branches) | `tools/offline_compile.py` (dbt-snowflake, connection stubbed) | pass |
| Compiled SQL is syntactically valid Snowflake SQL | sqlglot (snowflake dialect) over all compiled files | pass |
| Top-level statements of all `snowflake/*.sql` and `snowsight/*.sql` | `tools/validate_local.py` (sqlglot) | pass for statements sqlglot models; Snowflake-only DDL (procedures, tasks, policies, semantic views, agents, grants) reviewed by hand, **not** machine-validated |
| DML inside SQL procedures | sqlglot over extracted statements | parsed; dynamically built SQL strings checked by review only |
| Snowpark UDF logic | `snowpark/tests` (9 unit tests incl. edge-case batches, invalid dates, bad patterns) | pass |
| Deployed UDF code == tested code | `tools/build_snowpark_sql.py --check` | pass |
| Embedded Python (UDF + profiler procedure) compiles | `tools/validate_local.py` | pass |

**Not executed** (requires a Snowflake account): data generation, COPY, dbt run/tests against data,
tasks/alerts, policies, semantic views, Cortex, KPI values. Nothing in this repository claims those ran.

## End-to-end test in Snowflake

```bash
# 0. CI-side checks
python snowpark/tests/test_parse_bank_narrative.py
python tools/build_snowpark_sql.py --check
python tools/validate_local.py
```

```sql
-- 1. Setup (Snowsight Workspaces, run each file top to bottom with the roles noted in the file)
--    00 → 01 → 02 → 03 → 04 → 06 → 07 → 08 → 09 → 10 → 14
-- 2. Data
CALL FINTECH_DEV.OPS.SP_GENERATE_SYNTHETIC_DATA();      -- defaults: 50k orders, seed FINTECH-2026
--    then run 05_edge_cases.sql
```

```bash
# 3. Transform + test (developer machine or CI)
cd dbt && dbt seed && dbt snapshot && dbt build --exclude resource_type:snapshot
dbt source freshness
```

```sql
-- 4. Post-dbt objects: 11 → 12 → 13 (optional) → 16
-- 5. Verify: run 15_verification_queries.sql; every query states its expected result.
--    Key ones: V03/V04 control totals = 0 rows, V06 edge cases = 0 rows, V07 fan-out = 0 rows,
--    V13 semantic view = dashboard = 0 rows.
-- 6. Operations
EXECUTE TASK FINTECH_DEV.OPS.TSK_INGEST_CONTROLS;
SELECT * FROM FINTECH_DEV.DASHBOARD.VW_PIPELINE_EXECUTION_STATUS;
-- 7. Reproducibility: run the generator again with the same seed, re-run V02: same fingerprint.
-- 8. Change workflow: execute the worked example at the end of 14_change_management.sql
--    (two different users for submit/approve).
-- 9. Security: V14 as FINTECH_ANALYST and FINTECH_ANALYST_SOUTH.
```

## Test inventory

- **Generic YAML tests:** 168, including source tests (unique, not_null, relationships, accepted_values, non_negative,
  canonical_status_valid, scd2_valid_windows, amount_reconciles, row_count_matches).
- **Singular tests:** 7 (`dbt/tests/`).
- **Known-answer edge cases:** 27 expectations across 14 scenarios (`CONFIG.EXPECTED_TEST_OUTCOME`).
- **Runtime DQ rules:** 9 (`CONFIG.DQ_RULE`), extendable without deployment.
- **Verification queries:** 15 (`snowflake/15_verification_queries.sql`).
