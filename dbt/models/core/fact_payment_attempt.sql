{{
  config(
    materialized='incremental',
    unique_key='attempt_key',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    cluster_by=['attempt_date_key']
  )
}}
{#- FACT_PAYMENT_ATTEMPT
    Grain       : one row per provider payment attempt (source_system, source_transaction_id).
    PK          : attempt_key (= canonical_attempt_id)
    FKs         : transaction_key, customer_key (point-in-time SCD2), merchant_key (point-in-time),
                  channel_key, currency_key, attempt_date_key
    Measures    : attempt_amount, attempt_amount_inr, is_success, is_failure (additive flags)
    Degenerate  : source_system, source_transaction_id, merchant_order_id, last_reason_code
    Invalid attempts are INCLUDED with is_valid_record = false so attempt
    counts can be reconciled to RAW; every metric filters is_valid_record.
    Incremental : merges attempts whose canonical row changed (incl. late
                  status updates); unknown dimension members use the UNKNOWN key
                  and are repaired on the next run that touches the attempt. -#}

with attempts as (
    select *
    from {{ ref('cnl_payment_attempt') }}
    {% if is_incremental() %}
    where canonical_updated_at > (select coalesce(max(canonical_updated_at), '1900-01-01'::timestamp_ntz) from {{ this }})
    {% endif %}
),

fx as (
    select rate_month, currency_code, rate_to_inr from {{ ref('fx_rates_monthly') }}
),

customers as (select customer_key, customer_id, valid_from, valid_to from {{ ref('dim_customer') }}),
merchants as (select merchant_key, merchant_id, valid_from, valid_to from {{ ref('dim_merchant') }}),
channels  as (select channel_key, channel_code from {{ ref('dim_payment_channel') }}),
currencies as (select currency_key, currency_code from {{ ref('dim_currency') }})

select
    a.canonical_attempt_id                                   as attempt_key,
    a.canonical_transaction_id                               as transaction_key,
    coalesce(c.customer_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as customer_key,
    coalesce(m.merchant_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as merchant_key,
    coalesce(ch.channel_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as channel_key,
    coalesce(cu.currency_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as currency_key,
    to_number(to_char(to_date({{ to_reporting_tz('a.event_timestamp_utc') }}), 'YYYYMMDD')) as attempt_date_key,
    -- degenerate dimensions
    a.source_system,
    a.source_transaction_id,
    a.merchant_id,
    a.merchant_order_id,
    a.customer_id,
    a.channel_code,
    a.canonical_instrument_id,
    a.last_reason_code,
    -- status
    a.source_status,
    a.transaction_status                                     as attempt_status,
    a.status_category,
    a.is_terminal_status,
    (a.transaction_status = 'CAPTURED')                      as is_success,
    (a.transaction_status = 'FAILED')                        as is_failure,
    (a.transaction_status in ('REVERSED', 'VOIDED'))         as is_reversal,
    a.is_valid_record,
    -- measures
    a.transaction_amount                                     as attempt_amount,
    a.currency_code,
    fx.rate_to_inr                                           as fx_rate_to_inr,
    {{ to_inr('a.transaction_amount', 'fx.rate_to_inr') }}   as attempt_amount_inr,
    -- time
    a.event_timestamp_utc                                    as attempt_created_at_utc,
    {{ to_reporting_tz('a.event_timestamp_utc') }}           as attempt_created_at_ist,
    a.status_timestamp_utc,
    to_date({{ to_reporting_tz('a.status_timestamp_utc') }}) as status_date_ist,
    a.ingestion_timestamp_utc,
    a.canonical_updated_at
from attempts a
left join customers c
       on c.customer_id = a.customer_id
      and a.event_timestamp_utc >= c.valid_from and a.event_timestamp_utc < c.valid_to
left join merchants m
       on m.merchant_id = a.merchant_id
      and a.event_timestamp_utc >= m.valid_from and a.event_timestamp_utc < m.valid_to
left join channels ch   on ch.channel_code = a.channel_code
left join currencies cu on cu.currency_code = a.currency_code
left join fx
       on fx.currency_code = a.currency_code
      and fx.rate_month = date_trunc('month', to_date({{ to_reporting_tz('a.event_timestamp_utc') }}))
