-- Canonical Bank Statement Transaction. Grain: one row per bank statement line.
select
    {{ surrogate_key(['bank_txn_id']) }} as canonical_bank_txn_id,
    bank_txn_id,
    bank_code,
    bank_account_token,
    value_date,
    posting_ts                         as posting_timestamp_utc,
    dr_cr,
    amount,
    signed_amount,
    currency_code,
    narrative,
    parsed_settlement_ref,
    (parsed_settlement_ref is not null) as has_settlement_ref,
    batch_id,
    ingested_at                        as ingestion_timestamp_utc
from {{ ref('stg_bank_statement_transactions') }}
