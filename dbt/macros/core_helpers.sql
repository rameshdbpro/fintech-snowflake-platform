{#- ======================================================================
    Core helper macros
    ====================================================================== -#}

{#- Use the custom schema name verbatim (STAGING, CORE, ...) instead of
    dbt's default <target_schema>_<custom>. Environment isolation comes from
    the DATABASE (FINTECH_DEV / FINTECH_TEST / FINTECH_PROD). -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema | upper }}
    {%- else -%}
        {{ custom_schema_name | trim | upper }}
    {%- endif -%}
{%- endmacro %}


{#- Deterministic surrogate key: MD5 over '|'-joined, null-safe values.
    Inputs are always namespaced (e.g. source_system + provider id) because
    provider identifiers are NOT globally unique. -#}
{% macro surrogate_key(columns) -%}
    md5(
    {%- for col in columns %}
        coalesce(cast({{ col }} as varchar), '~null~'){% if not loop.last %} || '|' ||{% endif %}
    {%- endfor %}
    )
{%- endmacro %}


{#- UTC timestamp -> reporting timezone (wall clock) -#}
{% macro to_reporting_tz(ts_utc) -%}
    convert_timezone('UTC', '{{ var("reporting_timezone") }}', {{ ts_utc }})
{%- endmacro %}


{#- Reconciliation as-of date (var override for deterministic tests) -#}
{% macro recon_as_of_date() -%}
    {%- if var('recon_as_of_date') -%}
        to_date('{{ var("recon_as_of_date") }}')
    {%- else -%}
        to_date(convert_timezone('{{ var("reporting_timezone") }}', current_timestamp()))
    {%- endif -%}
{%- endmacro %}


{#- Fully qualified OPS object in the target database -#}
{% macro ops_object(name) -%}
    {{ target.database }}.{{ var('ops_schema') }}.{{ name }}
{%- endmacro %}


{#- Amount in INR using monthly FX (fx CTE / join alias passed in) -#}
{% macro to_inr(amount_col, rate_col) -%}
    round({{ amount_col }} * coalesce({{ rate_col }}, 1), 2)
{%- endmacro %}
