-- Provider status events; duplicate event deliveries removed (first delivery kept).
select
    event_id,
    source_system,
    source_transaction_id,
    raw_status,
    event_ts_raw,
    reason_code,
    batch_id,
    source_file_name,
    ingested_at,
    {{ surrogate_key(['source_system', 'source_transaction_id']) }} as canonical_attempt_id
from {{ source('raw', 'payment_status_history') }}
qualify row_number() over (partition by source_system, event_id order by ingested_at) = 1
