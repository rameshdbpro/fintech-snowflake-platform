{#- FACT_CHARGEBACK
    Grain      : one row per chargeback (current state).
    PK         : chargeback_key
    FKs        : attempt_key, transaction_key, customer_key, merchant_key, currency_key, received_date_key
    Measures   : chargeback_amount, chargeback_amount_inr, is_lost
    Degenerate : chargeback_id, reason_code -#}

with c as (select * from {{ ref('cnl_chargeback') }}),
fx as (select rate_month, currency_code, rate_to_inr from {{ ref('fx_rates_monthly') }}),
customers  as (select customer_key, customer_id, valid_from, valid_to from {{ ref('dim_customer') }}),
merchants  as (select merchant_key, merchant_id, valid_from, valid_to from {{ ref('dim_merchant') }}),
currencies as (select currency_key, currency_code from {{ ref('dim_currency') }}),
channels   as (select channel_key, channel_code from {{ ref('dim_payment_channel') }})

select
    c.canonical_chargeback_id                                      as chargeback_key,
    c.canonical_attempt_id                                         as attempt_key,
    c.canonical_transaction_id                                     as transaction_key,
    coalesce(cu_.customer_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as customer_key,
    coalesce(m.merchant_key, {{ surrogate_key(["'UNKNOWN'"]) }})   as merchant_key,
    coalesce(ch.channel_key, {{ surrogate_key(["'UNKNOWN'"]) }})   as channel_key,
    coalesce(cur.currency_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as currency_key,
    to_number(to_char(c.received_date, 'YYYYMMDD'))                as received_date_key,
    c.chargeback_id,
    c.source_system,
    c.source_transaction_id,
    c.merchant_id,
    c.channel_code,
    c.reason_code,
    c.source_status,
    c.canonical_status,
    (c.canonical_status = 'CB_LOST')                               as is_lost,
    (c.canonical_status = 'CB_OPEN')                               as is_open,
    c.currency_code,
    c.chargeback_amount,
    fx.rate_to_inr                                                 as fx_rate_to_inr,
    {{ to_inr('c.chargeback_amount', 'fx.rate_to_inr') }}          as chargeback_amount_inr,
    c.received_date,
    c.resolved_date,
    datediff(day, c.received_date, coalesce(c.resolved_date, {{ recon_as_of_date() }})) as days_open
from c
left join customers cu_ on cu_.customer_id = c.customer_id
                       and c.received_date::timestamp_ntz >= cu_.valid_from and c.received_date::timestamp_ntz < cu_.valid_to
left join merchants m   on m.merchant_id = c.merchant_id
                       and c.received_date::timestamp_ntz >= m.valid_from and c.received_date::timestamp_ntz < m.valid_to
left join currencies cur on cur.currency_code = c.currency_code
left join channels ch    on ch.channel_code = c.channel_code
left join fx on fx.currency_code = c.currency_code and fx.rate_month = date_trunc('month', c.received_date)
