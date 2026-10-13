-- depends_on: {{ ref('cnl_payment_attempt') }}
{{
  config(
    materialized='incremental',
    unique_key='settlement_event_key',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    cluster_by=['settlement_date_key']
  )
}}
{#- FACT_SETTLEMENT_EVENT
    Grain      : one row per provider settlement line (SALE, REFUND, CHARGEBACK, ADJUSTMENT).
    PK         : settlement_event_key
    FKs        : attempt_key (nullable when unmatched), merchant_key, currency_key, settlement_date_key
    Measures   : gross_amount, fee_amount, tax_amount, net_amount (+ _inr)
    Degenerate : settlement_line_id, settlement_batch_id, settlement_type, is_final_settlement
    Incremental: settlement lines can be corrected (same line id re-sent). Re-read the
                 look-back window of ingestion and MERGE on the line key. Lines whose
                 payment arrives later are re-linked because the window includes
                 payments that were (re)ingested in the window. -#}

{% set lookback = var('incremental_lookback_days') %}

with s as (
    select *
    from {{ ref('cnl_settlement') }}
    {% if is_incremental() %}
    where ingestion_timestamp_utc > (select dateadd(day, -{{ lookback }}, max(ingestion_timestamp_utc)) from {{ this }})
       or canonical_attempt_id in (
            select canonical_attempt_id from {{ ref('cnl_payment_attempt') }}
            where ingestion_timestamp_utc > (select dateadd(day, -{{ lookback }}, max(ingestion_timestamp_utc)) from {{ this }}))
    {% endif %}
),

fx as (select rate_month, currency_code, rate_to_inr from {{ ref('fx_rates_monthly') }}),
merchants  as (select merchant_key, merchant_id, valid_from, valid_to from {{ ref('dim_merchant') }}),
currencies as (select currency_key, currency_code from {{ ref('dim_currency') }})

select
    s.canonical_settlement_id                                     as settlement_event_key,
    s.canonical_attempt_id                                        as attempt_key,
    s.canonical_transaction_id                                    as transaction_key,
    coalesce(m.merchant_key, {{ surrogate_key(["'UNKNOWN'"]) }})  as merchant_key,
    coalesce(cu.currency_key, {{ surrogate_key(["'UNKNOWN'"]) }}) as currency_key,
    to_number(to_char(s.settlement_date, 'YYYYMMDD'))             as settlement_date_key,
    s.settlement_line_id,
    s.settlement_batch_id,
    s.source_system,
    s.source_transaction_id,
    s.merchant_id,
    s.settlement_type,
    s.is_final_settlement,
    s.is_matched_to_payment,
    s.is_line_balanced,
    s.currency_code,
    s.gross_amount,
    s.fee_amount,
    s.tax_amount,
    s.net_amount,
    fx.rate_to_inr                                                as fx_rate_to_inr,
    {{ to_inr('s.gross_amount', 'fx.rate_to_inr') }}              as gross_amount_inr,
    {{ to_inr('s.net_amount', 'fx.rate_to_inr') }}                as net_amount_inr,
    s.settlement_date,
    s.ingestion_timestamp_utc
from s
left join merchants m
       on m.merchant_id = s.merchant_id
      and s.settlement_date::timestamp_ntz >= m.valid_from and s.settlement_date::timestamp_ntz < m.valid_to
left join currencies cu on cu.currency_code = s.currency_code
left join fx on fx.currency_code = s.currency_code and fx.rate_month = date_trunc('month', s.settlement_date)
