{#- Canonical Payment Transaction (the merchant's payment intent / order).
    Grain: one row per (merchant_id, merchant_order_id) across ALL providers
    and retries. Only valid attempts participate.
    Final status precedence: CAPTURED > REVERSED > VOIDED > in-progress > FAILED. -#}

with attempts as (
    select *
    from {{ ref('cnl_payment_attempt') }}
    where is_valid_record
),

ranked as (
    select
        a.*,
        case a.transaction_status
            when 'CAPTURED'   then 1
            when 'REVERSED'   then 2
            when 'VOIDED'     then 3
            when 'AUTHORIZED' then 4
            when 'PENDING'    then 5
            when 'CREATED'    then 6
            when 'FAILED'     then 7
            else 9
        end as status_precedence
    from attempts a
),

deciding_attempt as (
    -- the attempt that determines the outcome: best status, then latest
    select *
    from ranked
    qualify row_number() over (partition by canonical_transaction_id
                               order by status_precedence, event_timestamp_utc desc) = 1
),

rollup as (
    select
        canonical_transaction_id,
        count(*)                                                     as attempt_count,
        count_if(transaction_status = 'FAILED')                      as failed_attempt_count,
        count_if(transaction_status = 'CAPTURED')                    as captured_attempt_count,
        count(distinct source_system)                                as provider_count,
        sum(iff(transaction_status = 'CAPTURED', transaction_amount, 0)) as captured_amount,
        min(event_timestamp_utc)                                     as first_attempt_at_utc,
        max(event_timestamp_utc)                                     as last_attempt_at_utc,
        min(iff(transaction_status = 'CAPTURED', status_timestamp_utc, null)) as first_captured_at_utc,
        max(ingestion_timestamp_utc)                                 as last_ingestion_timestamp_utc
    from attempts
    group by canonical_transaction_id
)

select
    d.canonical_transaction_id,
    d.merchant_id,
    d.merchant_order_id,
    d.customer_id,
    d.canonical_attempt_id                                as deciding_attempt_id,
    d.source_system                                       as deciding_source_system,
    d.source_transaction_id                               as deciding_source_transaction_id,
    d.channel_code,
    d.channel_group,
    d.currency_code,
    d.transaction_status                                  as final_status,
    d.status_category                                     as final_status_category,
    d.is_terminal_status                                  as is_terminal,
    r.attempt_count,
    r.failed_attempt_count,
    r.captured_attempt_count,
    r.provider_count,
    (r.captured_attempt_count > 1)                        as is_multiple_capture,
    d.transaction_amount                                  as requested_amount,
    r.captured_amount,
    r.first_attempt_at_utc,
    r.last_attempt_at_utc,
    r.first_captured_at_utc,
    r.last_ingestion_timestamp_utc
from deciding_attempt d
join rollup r on r.canonical_transaction_id = d.canonical_transaction_id
