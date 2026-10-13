{#- FACT_PAYMENT_TRANSACTION (accumulating snapshot of a payment intent)
    Grain       : one row per (merchant_id, merchant_order_id) - all retries and providers collapsed.
    PK          : transaction_key
    FKs         : customer_key, merchant_key (point-in-time at first attempt), channel_key,
                  currency_key, transaction_date_key (first attempt, IST), captured_date_key
    Measures    : captured_amount, captured_amount_inr, requested_amount, attempt_count, failed_attempt_count
    Degenerate  : merchant_order_id, deciding_source_system, deciding_source_transaction_id
    Refunds, settlements and chargebacks are NOT joined here (one-to-many);
    marts aggregate them separately to the reporting grain. -#}

with t as (
    select * from {{ ref('cnl_payment_transaction') }}
),

fx as (select rate_month, currency_code, rate_to_inr from {{ ref('fx_rates_monthly') }}),
customers  as (select customer_key, customer_id, valid_from, valid_to from {{ ref('dim_customer') }}),
merchants  as (select merchant_key, merchant_id, valid_from, valid_to from {{ ref('dim_merchant') }}),
channels   as (select channel_key, channel_code from {{ ref('dim_payment_channel') }}),
currencies as (select currency_key, currency_code from {{ ref('dim_currency') }})

select
    t.canonical_transaction_id                                   as transaction_key,
    coalesce(c.customer_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as customer_key,
    coalesce(m.merchant_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as merchant_key,
    coalesce(ch.channel_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as channel_key,
    coalesce(cu.currency_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as currency_key,
    to_number(to_char(to_date({{ to_reporting_tz('t.first_attempt_at_utc') }}), 'YYYYMMDD')) as transaction_date_key,
    iff(t.first_captured_at_utc is null, null,
        to_number(to_char(to_date({{ to_reporting_tz('t.first_captured_at_utc') }}), 'YYYYMMDD'))) as captured_date_key,
    -- degenerate
    t.merchant_id,
    t.merchant_order_id,
    t.customer_id,
    t.channel_code,
    t.channel_group,
    t.deciding_attempt_id                                        as deciding_attempt_key,
    t.deciding_source_system,
    t.deciding_source_transaction_id,
    -- status
    t.final_status,
    t.final_status_category,
    t.is_terminal,
    (t.final_status = 'CAPTURED')                                as is_captured,
    (t.final_status = 'FAILED')                                  as is_failed,
    (t.final_status in ('REVERSED', 'VOIDED'))                   as is_reversed,
    t.is_multiple_capture,
    -- measures
    t.attempt_count,
    t.failed_attempt_count,
    t.captured_attempt_count,
    t.provider_count,
    t.currency_code,
    t.requested_amount,
    t.captured_amount,
    fx.rate_to_inr                                               as fx_rate_to_inr,
    {{ to_inr('t.requested_amount', 'fx.rate_to_inr') }}         as requested_amount_inr,
    {{ to_inr('t.captured_amount', 'fx.rate_to_inr') }}          as captured_amount_inr,
    -- time
    t.first_attempt_at_utc,
    {{ to_reporting_tz('t.first_attempt_at_utc') }}              as transaction_created_at_ist,
    to_date({{ to_reporting_tz('t.first_attempt_at_utc') }})     as transaction_date_ist,
    t.first_captured_at_utc,
    to_date({{ to_reporting_tz('t.first_captured_at_utc') }})    as captured_date_ist,
    t.last_attempt_at_utc,
    t.last_ingestion_timestamp_utc
from t
left join customers c
       on c.customer_id = t.customer_id
      and t.first_attempt_at_utc >= c.valid_from and t.first_attempt_at_utc < c.valid_to
left join merchants m
       on m.merchant_id = t.merchant_id
      and t.first_attempt_at_utc >= m.valid_from and t.first_attempt_at_utc < m.valid_to
left join channels ch   on ch.channel_code = t.channel_code
left join currencies cu on cu.currency_code = t.currency_code
left join fx
       on fx.currency_code = t.currency_code
      and fx.rate_month = date_trunc('month', to_date({{ to_reporting_tz('t.first_attempt_at_utc') }}))
