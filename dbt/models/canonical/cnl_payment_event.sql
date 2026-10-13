{{
  config(
    materialized='incremental',
    unique_key='canonical_event_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    cluster_by=['to_date(event_timestamp_utc)']
  )
}}
{#- Canonical Payment Event (status history).
    Grain: one row per provider status event OR per payment-record status
    snapshot (the record itself carries a status at its event time).
    Status mapping is looked up in CONFIG.STATUS_MAPPING at build time, so a
    mapping change takes effect on the next build (full refresh of this
    model recommended: dbt build -s cnl_payment_event+ --full-refresh). -#}

with status_events as (
    select
        source_system,
        source_transaction_id,
        canonical_attempt_id,
        'STATUS_EVENT'                                     as event_source,
        event_id                                           as source_event_id,
        raw_status                                         as source_status,
        event_ts_raw,
        {{ parse_provider_timestamp_by_source('event_ts_raw') }} as event_timestamp_utc,
        reason_code,
        batch_id,
        ingested_at
    from {{ ref('stg_payment_status_history') }}
    {% if is_incremental() %}
    where ingested_at > (select dateadd(day, -{{ var('incremental_lookback_days') }}, max(ingestion_timestamp_utc)) from {{ this }})
    {% endif %}
),

record_snapshots as (
    select
        source_system,
        source_transaction_id,
        canonical_attempt_id,
        'PAYMENT_RECORD'                                   as event_source,
        'REC-' || record_hash                              as source_event_id,
        status_raw                                         as source_status,
        event_ts_raw,
        {{ parse_provider_timestamp_by_source('event_ts_raw') }} as event_timestamp_utc,
        null                                               as reason_code,
        batch_id,
        ingested_at
    from {{ ref('stg_payments') }}
    where is_mapped_provider
    {% if is_incremental() %}
      and ingested_at > (select dateadd(day, -{{ var('incremental_lookback_days') }}, max(ingestion_timestamp_utc)) from {{ this }})
    {% endif %}
),

unioned as (
    select * from status_events
    union all
    select * from record_snapshots
),

mapping as (
    select source_system, source_status, canonical_status, status_category, is_terminal, status_rank
    from {{ source('config', 'status_mapping') }}
    where status_domain = 'PAYMENT' and is_active
)

select
    {{ surrogate_key(['u.source_system', 'u.source_event_id']) }} as canonical_event_id,
    u.canonical_attempt_id,
    u.source_system,
    u.source_transaction_id,
    u.event_source,
    u.source_event_id,
    u.source_status,                                   -- original value preserved
    m.canonical_status,                                -- NULL => unknown status (exception)
    m.status_category,
    coalesce(m.is_terminal, false)                     as is_terminal,
    coalesce(m.status_rank, 0)                         as status_rank,
    (m.canonical_status is not null)                   as is_known_status,
    u.event_ts_raw,
    u.event_timestamp_utc,
    u.reason_code,
    u.batch_id,
    u.ingested_at                                      as ingestion_timestamp_utc,
    current_timestamp()::timestamp_ntz                 as canonical_updated_at
from unioned u
left join mapping m
  on m.source_system = u.source_system
 and m.source_status = u.source_status
