select
    refund_id,
    source_system,
    source_transaction_id,
    refund_amount,
    upper(currency_code) as currency_code,
    upper(refund_type)   as refund_type,
    refund_reason,
    requested_at,
    batch_id,
    ingested_at,
    {{ surrogate_key(['source_system', 'source_transaction_id']) }} as canonical_attempt_id
from {{ source('raw', 'refunds') }}
qualify row_number() over (partition by refund_id order by ingested_at desc) = 1
