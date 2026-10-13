{{
  config(
    materialized='incremental',
    unique_key='canonical_attempt_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    cluster_by=['to_date(event_timestamp_utc)']
  )
}}
{#- Canonical Payment Attempt.
    Grain: one row per provider attempt = (source_system, source_transaction_id).
    Current status = latest TERMINAL known event, else latest known event,
    ordered by EVENT time (not ingestion time) -> late/out-of-order events
    resolve correctly. Invalid rows are kept with is_valid_record = false and
    surface in CNL_EXCEPTIONS; they are excluded from financial facts.

    Incremental: re-processes every attempt that received a new payload OR a
    new status event within the look-back window (late-arriving updates). -#}

{% set lookback = var('incremental_lookback_days') %}

with
{% if is_incremental() %}
changed_attempts as (
    select canonical_attempt_id from {{ ref('stg_payments') }}
    where ingested_at > (select dateadd(day, -{{ lookback }}, max(ingestion_timestamp_utc)) from {{ this }})
    union
    select canonical_attempt_id from {{ ref('cnl_payment_event') }}
    where ingestion_timestamp_utc > (select dateadd(day, -{{ lookback }}, max(ingestion_timestamp_utc)) from {{ this }})
),
{% endif %}

payments as (
    select p.*
    from {{ ref('stg_payments') }} p
    where p.record_version_desc = 1
      and p.is_mapped_provider
    {% if is_incremental() %}
      and p.canonical_attempt_id in (select canonical_attempt_id from changed_attempts)
    {% endif %}
),

versions as (
    select canonical_attempt_id, count(*) as delivered_versions
    from {{ ref('stg_payments') }}
    group by 1
),

currency as (
    select currency_code, minor_units, is_active from {{ ref('currency') }}
),

channels as (
    select source_system, provider_channel_value, channel_code, channel_group, instrument_type
    from {{ ref('stg_payment_channels') }}
),

current_status as (
    select canonical_attempt_id, canonical_status, status_category, is_terminal,
           event_timestamp_utc as status_timestamp_utc
    from {{ ref('cnl_payment_event') }}
    where is_known_status
      {% if is_incremental() %}
      and canonical_attempt_id in (select canonical_attempt_id from changed_attempts)
      {% endif %}
    qualify row_number() over (
        partition by canonical_attempt_id
        order by is_terminal desc, event_timestamp_utc desc, status_rank desc) = 1
),

failure_reason as (
    select canonical_attempt_id, reason_code
    from {{ ref('cnl_payment_event') }}
    where reason_code is not null
    qualify row_number() over (partition by canonical_attempt_id order by event_timestamp_utc desc) = 1
),

record_status as (
    -- status carried on the payment record itself (to detect unknown codes)
    select canonical_attempt_id, is_known_status as record_status_known
    from {{ ref('cnl_payment_event') }}
    where event_source = 'PAYMENT_RECORD'
    qualify row_number() over (partition by canonical_attempt_id order by ingestion_timestamp_utc desc) = 1
),

typed as (
    select
        p.canonical_attempt_id,
        p.source_system,
        p.source_transaction_id,
        p.merchant_id,
        p.merchant_order_id,
        p.customer_id,
        {{ surrogate_key(['p.merchant_id', 'p.merchant_order_id']) }} as canonical_transaction_id,
        -- amounts: original string preserved, canonical in major units NUMBER(18,2)
        p.amount_raw,
        {{ provider_amount_to_major_by_source('p.amount_raw', 'cur.minor_units', 'p.source_system') }} as transaction_amount,
        upper(p.currency_code_raw)                         as currency_code,
        p.status_raw                                       as source_status,
        cs.canonical_status                                as transaction_status,
        cs.status_category,
        coalesce(cs.is_terminal, false)                    as is_terminal_status,
        cs.status_timestamp_utc,
        p.event_ts_raw,
        {{ parse_provider_timestamp_by_source('p.event_ts_raw', 'p.source_system') }} as event_timestamp_utc,
        p.channel_value_raw,
        ch.channel_code,
        ch.channel_group,
        ch.instrument_type,
        iff(p.instrument_token is null, null,
            {{ surrogate_key(['p.source_system', 'p.instrument_token']) }}) as canonical_instrument_id,
        p.instrument_last4,
        p.instrument_network,
        fr.reason_code                                     as last_reason_code,
        v.delivered_versions,
        cur.currency_code is not null and cur.is_active    as is_valid_currency,
        coalesce(rs.record_status_known, false) and cs.canonical_status is not null as is_known_status,
        p.batch_id,
        p.source_file_name,
        p.ingested_at                                      as ingestion_timestamp_utc
    from payments p
    left join currency cur       on cur.currency_code = upper(p.currency_code_raw)
    left join channels ch        on ch.source_system = p.source_system and ch.provider_channel_value = p.channel_value_raw
    left join current_status cs  on cs.canonical_attempt_id = p.canonical_attempt_id
    left join failure_reason fr  on fr.canonical_attempt_id = p.canonical_attempt_id
    left join record_status rs   on rs.canonical_attempt_id = p.canonical_attempt_id
    left join versions v         on v.canonical_attempt_id = p.canonical_attempt_id
)

select
    *,
    (transaction_amount is not null and transaction_amount > 0)     as is_valid_amount,
    (event_timestamp_utc is not null)                               as is_valid_timestamp,
    (channel_code is not null)                                      as is_known_channel,
    (merchant_id is not null and merchant_order_id is not null)     as has_business_key,
    (transaction_amount is not null and transaction_amount > 0
        and is_valid_currency and is_known_status
        and event_timestamp_utc is not null
        and merchant_id is not null and merchant_order_id is not null) as is_valid_record,
    current_timestamp()::timestamp_ntz                              as canonical_updated_at
from typed
