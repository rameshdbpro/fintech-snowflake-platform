{#- on-run-end: persist every node result (models, tests, seeds, snapshots)
    into AUDIT.DBT_RUN_RESULTS so Snowsight / Cortex can answer
    "which dbt tests failed?" from Snowflake data, not from CI logs. -#}
{% macro log_dbt_results(results) %}
  {%- if execute and results | length > 0 -%}
    {%- set rows = [] -%}
    {%- for r in results -%}
      {%- set msg = (r.message or '') | string | replace("\\", "\\\\") | replace("'", "''") | truncate(3900, True, '') -%}
      {%- set rows_affected = r.adapter_response.get('rows_affected', 'null') if r.adapter_response else 'null' -%}
      {%- do rows.append(
          "('" ~ invocation_id ~ "','" ~ (flags.WHICH or 'unknown') ~ "','" ~ target.name ~ "','"
          ~ r.node.unique_id ~ "','" ~ r.node.name ~ "','" ~ r.node.resource_type ~ "','"
          ~ r.status ~ "'," ~ (r.failures if r.failures is not none else 'null') ~ ","
          ~ (rows_affected if rows_affected is not none else 'null') ~ ","
          ~ (r.execution_time or 0) ~ ",'" ~ msg ~ "')"
      ) -%}
    {%- endfor -%}
    {%- set sql -%}
      insert into {{ target.database }}.AUDIT.DBT_RUN_RESULTS
        (invocation_id, dbt_command, target_name, node_unique_id, node_name, resource_type,
         status, failures, rows_affected, execution_seconds, message)
      values {{ rows | join(',\n') }}
    {%- endset -%}
    {%- do run_query(sql) -%}
    {%- set dq -%}
      insert into {{ target.database }}.AUDIT.DQ_RESULTS
        (dq_run_id, rule_id, check_source, target_object, rule_type, severity, status, failing_rows, details)
      select invocation_id, node_name, 'DBT_TEST', node_unique_id, 'DBT_TEST', 'ERROR',
             case status when 'pass' then 'PASS' when 'warn' then 'WARN' when 'fail' then 'FAIL' else 'ERROR' end,
             failures, message
      from {{ target.database }}.AUDIT.DBT_RUN_RESULTS
      where invocation_id = '{{ invocation_id }}' and resource_type = 'test'
    {%- endset -%}
    {%- do run_query(dq) -%}
  {%- endif -%}
  select 1
{% endmacro %}
