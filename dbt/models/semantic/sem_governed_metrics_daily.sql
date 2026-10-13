{#- GOVERNED METRIC BASE. Grain: date_ist x merchant_id x channel_code.
    Holds only ADDITIVE components (numerators / denominators). Ratios are
    always computed AFTER summing components (SUM(num)/SUM(den)), never by
    averaging daily ratios. Every dashboard view (DASHBOARD.VW_*) and the
    Snowflake semantic view use these same definitions; see
    CONFIG.METRIC_DEFINITION and docs/metrics.md. -#}
{{ config(post_hook=["{{ apply_row_access('RAP_MERCHANT_REGION', 'merchant_region') }}"]) }}

with daily as (
    select * from {{ ref('mart_payment_daily') }}
),

settlement as (
    select
        captured_date_ist                                   as date_ist,
        merchant_id,
        coalesce(channel_code, 'UNKNOWN')                   as channel_code,
        count_if(recon_status <> 'NOT_APPLICABLE')          as settleable_count,
        count_if(recon_status = 'MATCHED')                  as settlement_matched_count,
        sum(iff(recon_status in ('UNSETTLED', 'PENDING_SETTLEMENT', 'PARTIALLY_SETTLED', 'AMOUNT_MISMATCH'),
                outstanding_gross_inr, 0))                  as outstanding_settlement_inr,
        sum(expected_gross_inr)                             as expected_settlement_gross_inr,
        sum(settled_gross_inr)                              as settled_gross_inr
    from {{ ref('mart_settlement_reconciliation') }}
    group by 1, 2, 3
),

spine as (
    select date_ist, merchant_id, channel_code from daily
    union
    select date_ist, merchant_id, channel_code from settlement
)

select
    to_number(to_char(s.date_ist, 'YYYYMMDD'))           as date_key,
    s.date_ist,
    date_trunc('month', s.date_ist)                      as month_start,
    s.merchant_id,
    coalesce(d.merchant_name, m.merchant_name, 'Unknown merchant') as merchant_name,
    coalesce(d.merchant_region, m.region, 'UNKNOWN')     as merchant_region,
    s.channel_code,
    coalesce(d.channel_group, ch.channel_group, 'UNKNOWN') as channel_group,
    -- PAYMENT_ATTEMPT_COUNT
    coalesce(d.attempt_count, 0)                         as payment_attempt_count,
    -- PAYMENT_SUCCESS_RATE / FAILURE_RATE components (by transaction created date)
    coalesce(d.terminal_transaction_count, 0)            as terminal_transaction_count,
    coalesce(d.captured_transaction_count_by_created, 0) as captured_transaction_count_by_created,
    coalesce(d.failed_transaction_count, 0)              as failed_transaction_count,
    coalesce(d.transaction_count, 0)                     as transaction_count,
    -- PAYMENT_VOLUME / SUCCESSFUL_PAYMENT_COUNT / AVERAGE_TRANSACTION_VALUE (by capture date)
    coalesce(d.successful_payment_count, 0)              as successful_payment_count,
    coalesce(d.payment_volume_inr, 0)                    as payment_volume_inr,
    -- REFUND_AMOUNT / REFUND_RATE
    coalesce(d.refund_count, 0)                          as refund_count,
    coalesce(d.refund_amount_inr, 0)                     as refund_amount_inr,
    -- CHARGEBACK_AMOUNT / CHARGEBACK_RATE
    coalesce(d.chargeback_count, 0)                      as chargeback_count,
    coalesce(d.chargeback_amount_inr, 0)                 as chargeback_amount_inr,
    -- FRAUD_ALERT_COUNT
    coalesce(d.fraud_alert_count, 0)                     as fraud_alert_count,
    coalesce(d.high_severity_alert_count, 0)             as high_severity_alert_count,
    -- SETTLEMENT_MATCH_RATE / OUTSTANDING_SETTLEMENT_AMOUNT (by capture date)
    coalesce(st.settleable_count, 0)                     as settleable_count,
    coalesce(st.settlement_matched_count, 0)             as settlement_matched_count,
    coalesce(st.outstanding_settlement_inr, 0)           as outstanding_settlement_inr,
    coalesce(st.expected_settlement_gross_inr, 0)        as expected_settlement_gross_inr,
    coalesce(st.settled_gross_inr, 0)                    as settled_gross_inr
from spine s
left join daily d       on d.date_ist = s.date_ist and d.merchant_id = s.merchant_id and d.channel_code = s.channel_code
left join settlement st on st.date_ist = s.date_ist and st.merchant_id = s.merchant_id and st.channel_code = s.channel_code
left join {{ ref('dim_merchant') }} m on m.merchant_id = s.merchant_id and m.is_current
left join {{ ref('dim_payment_channel') }} ch on ch.channel_code = s.channel_code
where s.date_ist is not null
