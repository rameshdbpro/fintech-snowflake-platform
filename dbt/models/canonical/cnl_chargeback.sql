-- Canonical Chargeback. Grain: one row per chargeback_id (current state).
with mapping as (
    select source_status, canonical_status, status_category
    from {{ source('config', 'status_mapping') }}
    where status_domain = 'CHARGEBACK' and source_system = '*' and is_active
),

attempts as (
    select canonical_attempt_id, canonical_transaction_id, merchant_id, customer_id, channel_code
    from {{ ref('cnl_payment_attempt') }}
)

select
    {{ surrogate_key(['c.chargeback_id']) }} as canonical_chargeback_id,
    c.chargeback_id,
    c.source_system,
    c.source_transaction_id,
    c.canonical_attempt_id,
    a.canonical_transaction_id,
    a.merchant_id,
    a.customer_id,
    a.channel_code,
    c.chargeback_amount,
    c.currency_code,
    c.reason_code,
    c.chargeback_status                      as source_status,
    m.canonical_status,
    m.status_category,
    (m.canonical_status is not null)         as is_known_status,
    c.received_date,
    c.resolved_date,
    (a.canonical_attempt_id is not null)     as has_payment,
    c.batch_id,
    c.ingested_at                            as ingestion_timestamp_utc
from {{ ref('stg_chargebacks') }} c
left join mapping m  on m.source_status = c.chargeback_status
left join attempts a on a.canonical_attempt_id = c.canonical_attempt_id
