-- Canonical Fraud Alert (vendor engine alerts). Platform rule alerts are added in int_customer_velocity.
select
    {{ surrogate_key(["'VENDOR'", 'f.alert_id']) }} as canonical_alert_id,
    f.alert_id,
    'VENDOR'                                      as alert_source,
    f.source_system,
    f.source_transaction_id,
    f.canonical_attempt_id,
    f.customer_id,
    f.rule_code,
    f.alert_score,
    f.alert_status,
    f.alert_ts                                    as alert_timestamp_utc,
    f.batch_id,
    f.ingested_at                                 as ingestion_timestamp_utc
from {{ ref('stg_fraud_alerts') }} f
