{#- FACT_REFUND
    Grain      : one row per refund (many refunds per payment allowed).
    PK         : refund_key
    FKs        : attempt_key, transaction_key, customer_key, merchant_key, channel_key, currency_key,
                 refund_date_key (requested date, IST)
    Measures   : refund_amount, refund_amount_inr, is_processed
    Degenerate : refund_id, refund_type, refund_reason, source_transaction_id -#}

with r as (select * from {{ ref('cnl_refund') }}),
fx as (select rate_month, currency_code, rate_to_inr from {{ ref('fx_rates_monthly') }}),
customers  as (select customer_key, customer_id, valid_from, valid_to from {{ ref('dim_customer') }}),
merchants  as (select merchant_key, merchant_id, valid_from, valid_to from {{ ref('dim_merchant') }}),
channels   as (select channel_key, channel_code from {{ ref('dim_payment_channel') }}),
currencies as (select currency_key, currency_code from {{ ref('dim_currency') }})

select
    r.canonical_refund_id                                         as refund_key,
    r.canonical_attempt_id                                        as attempt_key,
    r.canonical_transaction_id                                    as transaction_key,
    coalesce(c.customer_key, {{ surrogate_key(["'UNKNOWN'"]) }})  as customer_key,
    coalesce(m.merchant_key, {{ surrogate_key(["'UNKNOWN'"]) }})  as merchant_key,
    coalesce(ch.channel_key, {{ surrogate_key(["'UNKNOWN'"]) }})  as channel_key,
    coalesce(cu.currency_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as currency_key,
    to_number(to_char(to_date({{ to_reporting_tz('r.requested_at_utc') }}), 'YYYYMMDD')) as refund_date_key,
    r.refund_id,
    r.source_system,
    r.source_transaction_id,
    r.merchant_id,
    r.channel_code,
    r.refund_type,
    r.refund_reason,
    r.refund_status,
    (r.refund_status = 'REFUND_PROCESSED')                        as is_processed,
    r.has_payment,
    r.currency_code,
    r.refund_amount,
    fx.rate_to_inr                                                as fx_rate_to_inr,
    {{ to_inr('r.refund_amount', 'fx.rate_to_inr') }}             as refund_amount_inr,
    r.requested_at_utc,
    to_date({{ to_reporting_tz('r.requested_at_utc') }})          as refund_requested_date_ist,
    r.status_timestamp_utc
from r
left join customers c  on c.customer_id = r.customer_id and r.requested_at_utc >= c.valid_from and r.requested_at_utc < c.valid_to
left join merchants m  on m.merchant_id = r.merchant_id and r.requested_at_utc >= m.valid_from and r.requested_at_utc < m.valid_to
left join channels ch   on ch.channel_code = r.channel_code
left join currencies cu on cu.currency_code = r.currency_code
left join fx on fx.currency_code = r.currency_code
            and fx.rate_month = date_trunc('month', to_date({{ to_reporting_tz('r.requested_at_utc') }}))
