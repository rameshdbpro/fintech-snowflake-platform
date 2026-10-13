#!/usr/bin/env bash
# CI/CD deployment of the Snowflake objects with Snowflake CLI (`snow`).
# This is DEPLOYMENT tooling (runs on a CI runner or developer machine), not
# part of routine platform operation. Everything it runs executes in Snowflake.
#
# Prereqs: pip install snowflake-cli ; a connection named by $SNOW_CONNECTION
# configured with key-pair auth for the SVC_DEPLOY user (no passwords in files).
#
# Usage:  ENV_DB=FINTECH_TEST ./deploy/deploy.sh [setup|data|post_dbt|all]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${ENV_DB:-FINTECH_DEV}"
CONN="${SNOW_CONNECTION:-fintech_deploy}"
STAGE="${1:-all}"

run() {   # replace the DB_NAME session variable default, then execute the file
  local f="$1"
  echo ">> $f  (database=$DB)"
  sed "s/SET DB_NAME = 'FINTECH_DEV';/SET DB_NAME = '${DB}';/" "$ROOT/snowflake/$f" \
    | sed "s/FINTECH_DEV\\.SEMANTIC/${DB}.SEMANTIC/g" \
    | snow sql --connection "$CONN" --stdin
}

python "$ROOT/tools/build_snowpark_sql.py" --check   # deployed UDF == unit-tested source

if [[ "$STAGE" == "setup" || "$STAGE" == "all" ]]; then
  run 00_account_setup.sql          # needs SECURITYADMIN + SYSADMIN on the deploy user
  run 01_raw_tables.sql
  run 02_config_tables.sql
  run 03_audit_tables.sql
  run 04_synthetic_data_generator.sql
  run 06_file_ingestion.sql
  run 07_ingestion_controls_and_dq.sql
  run 08_snowpark.sql               # skip if Python UDFs unavailable (see file header)
  run 09_streams_tasks.sql
  run 10_security_governance.sql    # needs ACCOUNTADMIN for account-level grants
  run 14_change_management.sql
fi

if [[ "$STAGE" == "data" || "$STAGE" == "all" ]]; then
  echo "CALL OPS.SP_GENERATE_SYNTHETIC_DATA();" | snow sql --connection "$CONN" --database "$DB" --stdin
  run 05_edge_cases.sql
fi

if [[ "$STAGE" == "all" ]]; then
  ( cd "$ROOT/dbt" && dbt seed --target "${DBT_TARGET:-dev}" \
      && dbt snapshot --target "${DBT_TARGET:-dev}" \
      && dbt build --target "${DBT_TARGET:-dev}" --exclude resource_type:snapshot )
fi

if [[ "$STAGE" == "post_dbt" || "$STAGE" == "all" ]]; then
  run 11_dashboard_views.sql
  run 12_semantic_view.sql          # requires semantic views in the account
  run 13_cortex_ai.sql              # requires Cortex in region; safe to skip
  run 16_cost_monitoring.sql        # ACCOUNTADMIN section for resource monitors
  run 15_verification_queries.sql
fi
echo "done: $STAGE on $DB"
