select
    refund_event_id,
    refund_id,
    upper(refund_status) as refund_status,
    event_ts,
    batch_id,
    ingested_at
from {{ source('raw', 'refund_status_history') }}
qualify row_number() over (partition by refund_event_id order by ingested_at) = 1
