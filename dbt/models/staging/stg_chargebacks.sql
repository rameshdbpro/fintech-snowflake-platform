-- Chargeback status progresses OPEN -> WON/LOST; the latest delivery is current.
select
    chargeback_id,
    source_system,
    source_transaction_id,
    chargeback_amount,
    upper(currency_code)     as currency_code,
    reason_code,
    upper(chargeback_status) as chargeback_status,
    received_date,
    resolved_date,
    batch_id,
    ingested_at,
    {{ surrogate_key(['source_system', 'source_transaction_id']) }} as canonical_attempt_id
from {{ source('raw', 'chargebacks') }}
qualify row_number() over (partition by chargeback_id order by ingested_at desc) = 1
