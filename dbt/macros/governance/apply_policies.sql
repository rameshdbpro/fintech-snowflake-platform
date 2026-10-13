{#- Post-hook helpers. CREATE OR REPLACE drops policy assignments, so the
    policies are (re)attached after every build. The policies themselves are
    created by snowflake/10_security_governance.sql (deployer role). Turn off
    with --vars '{apply_governance_policies: false}' on accounts without
    Enterprise edition. -#}

{% macro _relation_kind() -%}
    {{ 'view' if config.get('materialized') == 'view' else 'table' }}
{%- endmacro %}

{% macro apply_masking(columns_to_policies) %}
  {%- if var('apply_governance_policies') and execute -%}
    {%- for col, policy in columns_to_policies.items() %}
      alter {{ _relation_kind() }} {{ this }} modify column {{ col }} set masking policy {{ target.database }}.GOVERNANCE.{{ policy }} force;
    {%- endfor %}
  {%- else -%}
    select 1
  {%- endif -%}
{% endmacro %}

{% macro apply_row_access(policy, column) %}
  {%- if var('apply_governance_policies') and execute -%}
    alter {{ _relation_kind() }} {{ this }} drop all row access policies;
    alter {{ _relation_kind() }} {{ this }} add row access policy {{ target.database }}.GOVERNANCE.{{ policy }} on ({{ column }});
  {%- else -%}
    select 1
  {%- endif -%}
{% endmacro %}
