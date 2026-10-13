{#- Daily payment mart. Grain: date_ist x merchant_id x channel_code.
    FAN-OUT SAFE: each fact is aggregated to this grain independently and
    the aggregates are joined on the grain keys (never fact-to-fact).
    Dates: attempts/transactions by creation date, volume by capture date,
    refunds by request date, chargebacks by received date, alerts by alert date. -#}
{{ config(post_hook=["{{ apply_row_access('RAP_MERCHANT_REGION', 'merchant_region') }}"]) }}

with attempts as (
    select to_date(attempt_created_at_ist) as date_ist, merchant_id, coalesce(channel_code, 'UNKNOWN') as channel_code,
           count(*)                         as attempt_count,
           count_if(is_success)             as successful_attempt_count,
           count_if(is_failure)             as failed_attempt_count
    from {{ ref('fact_payment_attempt') }}
    where is_valid_record
    group by 1, 2, 3
),

txn_created as (
    select transaction_date_ist as date_ist, merchant_id, coalesce(channel_code, 'UNKNOWN') as channel_code,
           count(*)                         as transaction_count,
           count_if(is_terminal)            as terminal_transaction_count,
           count_if(is_captured)            as captured_transaction_count_by_created,
           count_if(is_failed)              as failed_transaction_count,
           count_if(is_reversed)            as reversed_transaction_count,
           sum(attempt_count - 1)           as retry_count
    from {{ ref('fact_payment_transaction') }}
    group by 1, 2, 3
),

txn_captured as (
    select captured_date_ist as date_ist, merchant_id, coalesce(channel_code, 'UNKNOWN') as channel_code,
           count(*)                         as successful_payment_count,
           sum(captured_amount_inr)         as payment_volume_inr
    from {{ ref('fact_payment_transaction') }}
    where is_captured
    group by 1, 2, 3
),

refunds as (
    select refund_requested_date_ist as date_ist, merchant_id, coalesce(channel_code, 'UNKNOWN') as channel_code,
           count_if(is_processed)                          as refund_count,
           sum(iff(is_processed, refund_amount_inr, 0))    as refund_amount_inr
    from {{ ref('fact_refund') }}
    where has_payment
    group by 1, 2, 3
),

chargebacks as (
    select received_date as date_ist, merchant_id, coalesce(channel_code, 'UNKNOWN') as channel_code,
           count(*)                                        as chargeback_count,
           count_if(is_lost)                               as chargeback_lost_count,
           sum(iff(is_lost, chargeback_amount_inr, 0))     as chargeback_amount_inr
    from {{ ref('fact_chargeback') }}
    group by 1, 2, 3
),

alerts as (
    select f.alert_date_ist as date_ist, coalesce(f.merchant_id, 'UNKNOWN') as merchant_id,
           coalesce(a.channel_code, 'UNKNOWN') as channel_code,
           count(*)                                        as fraud_alert_count,
           count_if(f.severity = 'HIGH')                   as high_severity_alert_count
    from {{ ref('fact_fraud_alert') }} f
    left join {{ ref('fact_payment_attempt') }} a on a.attempt_key = f.attempt_key
    group by 1, 2, 3
),

spine as (
    select date_ist, merchant_id, channel_code from attempts
    union select date_ist, merchant_id, channel_code from txn_created
    union select date_ist, merchant_id, channel_code from txn_captured
    union select date_ist, merchant_id, channel_code from refunds
    union select date_ist, merchant_id, channel_code from chargebacks
    union select date_ist, merchant_id, channel_code from alerts
),

merchant_current as (
    select merchant_id, merchant_name, merchant_category, region
    from {{ ref('dim_merchant') }} where is_current
),

channel as (
    select channel_code, channel_name, channel_group from {{ ref('dim_payment_channel') }}
)

select
    to_number(to_char(s.date_ist, 'YYYYMMDD'))                 as date_key,
    s.date_ist,
    s.merchant_id,
    coalesce(m.merchant_name, 'Unknown merchant')              as merchant_name,
    coalesce(m.merchant_category, 'UNKNOWN')                   as merchant_category,
    coalesce(m.region, 'UNKNOWN')                              as merchant_region,
    s.channel_code,
    coalesce(ch.channel_name, 'Unknown channel')               as channel_name,
    coalesce(ch.channel_group, 'UNKNOWN')                      as channel_group,
    coalesce(a.attempt_count, 0)                               as attempt_count,
    coalesce(a.successful_attempt_count, 0)                    as successful_attempt_count,
    coalesce(a.failed_attempt_count, 0)                        as failed_attempt_count,
    coalesce(tc.transaction_count, 0)                          as transaction_count,
    coalesce(tc.terminal_transaction_count, 0)                 as terminal_transaction_count,
    coalesce(tc.captured_transaction_count_by_created, 0)      as captured_transaction_count_by_created,
    coalesce(tc.failed_transaction_count, 0)                   as failed_transaction_count,
    coalesce(tc.reversed_transaction_count, 0)                 as reversed_transaction_count,
    coalesce(tc.retry_count, 0)                                as retry_count,
    coalesce(tp.successful_payment_count, 0)                   as successful_payment_count,
    coalesce(tp.payment_volume_inr, 0)                         as payment_volume_inr,
    coalesce(r.refund_count, 0)                                as refund_count,
    coalesce(r.refund_amount_inr, 0)                           as refund_amount_inr,
    coalesce(c.chargeback_count, 0)                            as chargeback_count,
    coalesce(c.chargeback_lost_count, 0)                       as chargeback_lost_count,
    coalesce(c.chargeback_amount_inr, 0)                       as chargeback_amount_inr,
    coalesce(al.fraud_alert_count, 0)                          as fraud_alert_count,
    coalesce(al.high_severity_alert_count, 0)                  as high_severity_alert_count
from spine s
left join attempts a       on a.date_ist = s.date_ist  and a.merchant_id = s.merchant_id  and a.channel_code = s.channel_code
left join txn_created tc   on tc.date_ist = s.date_ist and tc.merchant_id = s.merchant_id and tc.channel_code = s.channel_code
left join txn_captured tp  on tp.date_ist = s.date_ist and tp.merchant_id = s.merchant_id and tp.channel_code = s.channel_code
left join refunds r        on r.date_ist = s.date_ist  and r.merchant_id = s.merchant_id  and r.channel_code = s.channel_code
left join chargebacks c    on c.date_ist = s.date_ist  and c.merchant_id = s.merchant_id  and c.channel_code = s.channel_code
left join alerts al        on al.date_ist = s.date_ist and al.merchant_id = s.merchant_id and al.channel_code = s.channel_code
left join merchant_current m on m.merchant_id = s.merchant_id
left join channel ch       on ch.channel_code = s.channel_code
where s.date_ist is not null
