{#- on-run-end: publish the dbt DAG (node -> parents) into
    AUDIT.DBT_MODEL_LINEAGE. OPS.SP_ANALYZE_CHANGE_IMPACT walks this table
    recursively to list downstream models/metrics affected by a change. -#}
{% macro log_model_lineage() %}
  {%- if execute and flags.WHICH in ('run', 'build') -%}
    {%- set rows = [] -%}
    {%- for node in graph.nodes.values() if node.resource_type in ('model', 'snapshot', 'seed') -%}
      {%- set mat = node.config.materialized or 'n/a' -%}
      {%- set parents = node.depends_on.nodes if node.depends_on else [] -%}
      {%- if parents | length == 0 -%}
        {%- do rows.append("('" ~ invocation_id ~ "','" ~ node.name ~ "','" ~ node.resource_type ~ "','"
              ~ (node.schema | upper) ~ "','" ~ mat ~ "',null,null)") -%}
      {%- endif -%}
      {%- for p in parents -%}
        {%- set ptype = p.split('.')[0] -%}
        {%- set pname = p.split('.')[-1] -%}
        {%- do rows.append("('" ~ invocation_id ~ "','" ~ node.name ~ "','" ~ node.resource_type ~ "','"
              ~ (node.schema | upper) ~ "','" ~ mat ~ "','" ~ pname ~ "','" ~ ptype ~ "')") -%}
      {%- endfor -%}
    {%- endfor -%}
    {%- if rows | length > 0 -%}
      {%- do run_query("delete from " ~ target.database ~ ".AUDIT.DBT_MODEL_LINEAGE") -%}
      {%- do run_query("insert into " ~ target.database ~ ".AUDIT.DBT_MODEL_LINEAGE "
            ~ "(invocation_id, node_name, resource_type, schema_name, materialization, parent_name, parent_type) values "
            ~ (rows | join(','))) -%}
    {%- endif -%}
  {%- endif -%}
  select 1
{% endmacro %}
