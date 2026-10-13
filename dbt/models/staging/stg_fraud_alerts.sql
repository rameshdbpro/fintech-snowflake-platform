select
    alert_id,
    source_system,
    source_transaction_id,
    customer_id,
    rule_code,
    alert_score,
    upper(alert_status) as alert_status,
    alert_ts,
    batch_id,
    ingested_at,
    iff(source_transaction_id is null, null,
        {{ surrogate_key(['source_system', 'source_transaction_id']) }}) as canonical_attempt_id
from {{ source('raw', 'fraud_alerts') }}
qualify row_number() over (partition by alert_id order by ingested_at desc) = 1
