{#- Canonical Refund. Grain: one row per refund_id. A payment can have many
    refunds (partial refunds); they are never joined to payments row-wise in
    marts, only aggregated per attempt first. -#}

with current_status as (
    select canonical_refund_id, canonical_status, status_category, event_timestamp_utc
    from {{ ref('cnl_refund_event') }}
    where is_known_status
    qualify row_number() over (partition by canonical_refund_id
                               order by is_terminal desc, event_timestamp_utc desc, status_rank desc) = 1
),

attempts as (
    select canonical_attempt_id, canonical_transaction_id, merchant_id, customer_id, channel_code,
           transaction_amount, currency_code as payment_currency_code, is_valid_record
    from {{ ref('cnl_payment_attempt') }}
)

select
    {{ surrogate_key(['r.refund_id']) }}              as canonical_refund_id,
    r.refund_id,
    r.source_system,
    r.source_transaction_id,
    r.canonical_attempt_id,
    a.canonical_transaction_id,
    a.merchant_id,
    a.customer_id,
    a.channel_code,
    r.refund_amount,
    r.currency_code,
    r.refund_type,
    r.refund_reason,
    coalesce(cs.canonical_status, 'REFUND_INITIATED') as refund_status,
    cs.status_category,
    cs.event_timestamp_utc                            as status_timestamp_utc,
    r.requested_at                                    as requested_at_utc,
    (a.canonical_attempt_id is not null)              as has_payment,
    (r.refund_amount is not null and r.refund_amount > 0) as is_valid_amount,
    (a.payment_currency_code = r.currency_code)       as currency_matches_payment,
    r.batch_id,
    r.ingested_at                                     as ingestion_timestamp_utc
from {{ ref('stg_refunds') }} r
left join attempts a       on a.canonical_attempt_id = r.canonical_attempt_id
left join current_status cs on cs.canonical_refund_id = {{ surrogate_key(['r.refund_id']) }}
