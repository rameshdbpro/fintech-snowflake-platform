{#- 1:1 with RAW.PAYMENTS minus exact duplicate deliveries.
    Provider-specific keys -> provider-neutral column names (values kept
    as delivered, VARCHAR). Typing/normalisation happens in CANONICAL. -#}
with deduped as (
    select *
    from {{ source('raw', 'payments') }}
    -- identical payload re-sent (same hash): keep the first delivery
    qualify row_number() over (partition by record_hash order by ingested_at, raw_row_id) = 1
),

mapped as (
{%- set providers = var('payment_providers') %}
{%- for name, cfg in providers.items() %}
    select
        source_system,
        {{ provider_field(cfg, 'source_transaction_id') }} as source_transaction_id,
        {{ provider_field(cfg, 'merchant_order_id') }}     as merchant_order_id,
        {{ provider_field(cfg, 'merchant_id') }}           as merchant_id,
        {{ provider_field(cfg, 'customer_id') }}           as customer_id,
        {{ provider_field(cfg, 'amount') }}                as amount_raw,
        {{ provider_field(cfg, 'currency_code') }}         as currency_code_raw,
        {{ provider_field(cfg, 'status') }}                as status_raw,
        {{ provider_field(cfg, 'event_ts') }}              as event_ts_raw,
        {{ provider_field(cfg, 'channel_value') }}         as channel_value_raw,
        {{ provider_field(cfg, 'instrument_token') }}      as instrument_token,
        {{ provider_field(cfg, 'instrument_last4') }}      as instrument_last4,
        {{ provider_field(cfg, 'instrument_network') }}    as instrument_network,
        true                                               as is_mapped_provider,
        source_record, record_hash, raw_row_id, batch_id, source_file_name, ingested_at
    from deduped
    where source_system = '{{ name }}'
    union all
{%- endfor %}
    -- rows from a provider that has no mapping yet: kept, flagged, routed to exceptions
    select
        source_system,
        coalesce(get_ignore_case(source_record, 'id')::varchar, record_hash) as source_transaction_id,
        null, null, null, null, null, null, null, null, null, null, null,
        false as is_mapped_provider,
        source_record, record_hash, raw_row_id, batch_id, source_file_name, ingested_at
    from deduped
    where source_system not in ({% for name in providers %}'{{ name }}'{% if not loop.last %}, {% endif %}{% endfor %})
)

select
    *,
    -- provider ids are only unique WITHIN a provider
    {{ surrogate_key(['source_system', 'source_transaction_id']) }} as canonical_attempt_id,
    -- versions of the same attempt delivered with different payloads (corrections)
    row_number() over (partition by source_system, source_transaction_id
                       order by ingested_at desc, raw_row_id desc) as record_version_desc
from mapped
