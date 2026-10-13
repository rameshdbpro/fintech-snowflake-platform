{#- ======================================================================
    Metadata-driven provider mapping.
    Everything provider specific is read from var('payment_providers') in
    dbt_project.yml; models only call these macros. Adding PROV_D = config.
    ====================================================================== -#}

{#- Value of one canonical field from the VARIANT payload, as VARCHAR.
    Missing mapping (null) => NULL literal. Keys read case-insensitively so
    synthetic (lowercase) and CSV-landed (UPPERCASE) payloads both work. -#}
{% macro provider_field(provider_cfg, canonical_field, payload_col='source_record') -%}
    {%- set key = provider_cfg['fields'].get(canonical_field) -%}
    {%- if key -%}
        get_ignore_case({{ payload_col }}, '{{ key }}')::varchar
    {%- else -%}
        cast(null as varchar)
    {%- endif -%}
{%- endmacro %}


{#- Provider timestamp (VARCHAR) -> UTC TIMESTAMP_NTZ. Unparseable => NULL
    (caught as INVALID_TIMESTAMP exception downstream). -#}
{% macro parse_provider_timestamp(expr, provider_cfg) -%}
    {%- set conv = provider_cfg['timestamp_convention'] -%}
    {%- if conv == 'LOCAL_TZ' -%}
        convert_timezone('{{ provider_cfg["source_timezone"] }}', 'UTC',
                         try_to_timestamp_ntz({{ expr }}, '{{ provider_cfg["timestamp_format"] }}'))::timestamp_ntz(9)
    {%- elif conv == 'EPOCH_MS' -%}
        to_timestamp_ntz(try_to_number({{ expr }}), 3)
    {%- elif conv == 'ISO8601_TZ' -%}
        convert_timezone('UTC', try_to_timestamp_tz({{ expr }}))::timestamp_ntz(9)
    {%- else -%}
        {{ exceptions.raise_compiler_error("Unknown timestamp_convention '" ~ conv ~ "'") }}
    {%- endif -%}
{%- endmacro %}


{#- Same conversion selected at runtime by a source_system column (used
    for tables like PAYMENT_STATUS_HISTORY that mix providers). -#}
{% macro parse_provider_timestamp_by_source(expr, source_col='source_system') -%}
    case {{ source_col }}
    {%- for name, cfg in var('payment_providers').items() %}
        when '{{ name }}' then {{ parse_provider_timestamp(expr, cfg) }}
    {%- endfor %}
    end
{%- endmacro %}


{#- Provider amount (VARCHAR) -> NUMBER in MAJOR units. minor_units_col
    comes from the currency seed (e.g. INR 2, JPY 0). -#}
{% macro provider_amount_to_major(expr, provider_cfg, minor_units_col) -%}
    {%- if provider_cfg['amount_unit'] == 'MINOR' -%}
        (try_to_decimal({{ expr }}, 38, 0) / power(10, coalesce({{ minor_units_col }}, 2)))::number(18,2)
    {%- else -%}
        try_to_decimal({{ expr }}, 18, 2)
    {%- endif -%}
{%- endmacro %}

{% macro provider_amount_to_major_by_source(expr, minor_units_col, source_col='source_system') -%}
    case {{ source_col }}
    {%- for name, cfg in var('payment_providers').items() %}
        when '{{ name }}' then {{ provider_amount_to_major(expr, cfg, minor_units_col) }}
    {%- endfor %}
    end
{%- endmacro %}


{#- Bank narrative -> settlement batch reference.
    Snowpark UDF (configurable ordered patterns, named groups, date
    validation) or a pure-SQL fallback with the same three bank formats. -#}
{% macro parse_settlement_ref(narrative_col, bank_code_col, patterns_col='p.patterns') -%}
    {%- if var('use_snowpark_narrative_parser') -%}
        {{ ops_object('PARSE_BANK_NARRATIVE') }}({{ narrative_col }}, {{ bank_code_col }}, {{ patterns_col }}):settlement_ref::varchar
    {%- else -%}
        coalesce(
            'SB-' || regexp_substr({{ narrative_col }}, 'SETTL\\s+SB-([A-Z]{2})-([0-9]{8})', 1, 1, 'e', 1)
                  || '-' || regexp_substr({{ narrative_col }}, 'SETTL\\s+SB-([A-Z]{2})-([0-9]{8})', 1, 1, 'e', 2),
            'SB-' || regexp_substr({{ narrative_col }}, '/SETTLEMENT/SB([A-Z]{2})([0-9]{8})/', 1, 1, 'e', 1)
                  || '-' || regexp_substr({{ narrative_col }}, '/SETTLEMENT/SB([A-Z]{2})([0-9]{8})/', 1, 1, 'e', 2),
            'SB-' || regexp_substr({{ narrative_col }}, 'ref:SB_([A-Z]{2})_([0-9]{8})', 1, 1, 'e', 1)
                  || '-' || regexp_substr({{ narrative_col }}, 'ref:SB_([A-Z]{2})_([0-9]{8})', 1, 1, 'e', 2)
        )
    {%- endif -%}
{%- endmacro %}
