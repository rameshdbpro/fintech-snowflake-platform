{#- Publishes the version-controlled provider mapping (dbt_project.yml
    vars.payment_providers) as a Snowflake table, so mapping metadata is
    queryable in Snowsight, by Cortex, and by the change-impact procedure.
    Grain: one row per (source_system, canonical_attribute). -#}
{{ config(materialized='table') }}

{%- set rows = [] -%}
{%- for provider, cfg in var('payment_providers').items() -%}
  {%- for attr, key in cfg['fields'].items() -%}
    {%- do rows.append({
        'source_system': provider,
        'canonical_entity': 'PAYMENT_ATTEMPT',
        'canonical_attribute': attr,
        'source_field': key,
        'timestamp_convention': cfg['timestamp_convention'],
        'source_timezone': cfg.get('source_timezone'),
        'amount_unit': cfg['amount_unit']
    }) -%}
  {%- endfor -%}
{%- endfor %}

select
    column1::varchar  as source_system,
    column2::varchar  as canonical_entity,
    column3::varchar  as canonical_attribute,
    column4::varchar  as source_field,
    column5::varchar  as timestamp_convention,
    column6::varchar  as source_timezone,
    column7::varchar  as amount_unit,
    (column4 is not null) as is_mapped,
    'dbt_project.yml:vars.payment_providers' as defined_in,
    'DEPLOYMENT'      as change_class
from values
{%- for r in rows %}
    ('{{ r.source_system }}', '{{ r.canonical_entity }}', '{{ r.canonical_attribute }}',
     {{ "'" ~ r.source_field ~ "'" if r.source_field else 'null' }},
     '{{ r.timestamp_convention }}',
     {{ "'" ~ r.source_timezone ~ "'" if r.source_timezone else 'null' }},
     '{{ r.amount_unit }}'){% if not loop.last %},{% endif %}
{%- endfor %}
