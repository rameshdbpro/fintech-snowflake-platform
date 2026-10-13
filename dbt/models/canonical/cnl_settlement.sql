{#- Canonical Settlement. Grain: one row per provider settlement report line.
    Several lines can exist per payment (partial settlements, refund and
    chargeback debits). Lines without a known payment are kept and flagged. -#}

with attempts as (
    select canonical_attempt_id, canonical_transaction_id
    from {{ ref('cnl_payment_attempt') }}
)

select
    {{ surrogate_key(['s.settlement_line_id']) }} as canonical_settlement_id,
    s.settlement_line_id,
    s.settlement_batch_id,
    s.source_system,
    s.source_transaction_id,
    s.canonical_attempt_id,
    a.canonical_transaction_id,
    s.merchant_id,
    s.settlement_type,
    s.is_final_settlement,
    s.gross_amount,
    s.fee_amount,
    s.tax_amount,
    s.net_amount,
    -- arithmetic integrity of the provider line itself
    (abs(s.gross_amount - s.fee_amount - s.tax_amount - s.net_amount) <= 0.01) as is_line_balanced,
    s.currency_code,
    s.settlement_date,
    (a.canonical_attempt_id is not null)          as is_matched_to_payment,
    s.batch_id,
    s.ingested_at                                 as ingestion_timestamp_utc
from {{ ref('stg_bank_settlements') }} s
left join attempts a on a.canonical_attempt_id = s.canonical_attempt_id
