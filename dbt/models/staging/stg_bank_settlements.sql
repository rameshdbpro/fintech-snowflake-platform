-- Settlement report lines; a corrected re-delivery of the same line id replaces the earlier one.
select
    settlement_line_id,
    settlement_batch_id,
    source_system,
    source_transaction_id,
    merchant_id,
    upper(settlement_type) as settlement_type,
    coalesce(is_final_settlement, true) as is_final_settlement,
    gross_amount,
    fee_amount,
    tax_amount,
    net_amount,
    upper(currency_code) as currency_code,
    settlement_date,
    batch_id,
    ingested_at,
    iff(source_transaction_id is null, null,
        {{ surrogate_key(['source_system', 'source_transaction_id']) }}) as canonical_attempt_id
from {{ source('raw', 'bank_settlements') }}
qualify row_number() over (partition by settlement_line_id order by ingested_at desc) = 1
