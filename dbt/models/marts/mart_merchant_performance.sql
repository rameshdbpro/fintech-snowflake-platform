{#- Monthly merchant scorecard. Grain: month x merchant_id.
    Payment/refund/chargeback measures roll up from mart_payment_daily
    (already fan-out safe); settlement measures aggregate the recon mart
    to the same grain separately, then join on (month, merchant). -#}
{{ config(post_hook=["{{ apply_row_access('RAP_MERCHANT_REGION', 'merchant_region') }}"]) }}

with daily as (
    select
        date_trunc('month', date_ist)                       as month_start,
        merchant_id,
        any_value(merchant_name)                            as merchant_name,
        any_value(merchant_category)                        as merchant_category,
        any_value(merchant_region)                          as merchant_region,
        sum(attempt_count)                                  as attempt_count,
        sum(transaction_count)                              as transaction_count,
        sum(terminal_transaction_count)                     as terminal_transaction_count,
        sum(captured_transaction_count_by_created)          as captured_transaction_count_by_created,
        sum(failed_transaction_count)                       as failed_transaction_count,
        sum(successful_payment_count)                       as successful_payment_count,
        sum(payment_volume_inr)                             as payment_volume_inr,
        sum(refund_count)                                   as refund_count,
        sum(refund_amount_inr)                              as refund_amount_inr,
        sum(chargeback_count)                               as chargeback_count,
        sum(chargeback_amount_inr)                          as chargeback_amount_inr,
        sum(fraud_alert_count)                              as fraud_alert_count
    from {{ ref('mart_payment_daily') }}
    group by 1, 2
),

settlement as (
    select
        date_trunc('month', captured_date_ist)              as month_start,
        merchant_id,
        count_if(recon_status <> 'NOT_APPLICABLE')          as settleable_count,
        count_if(recon_status = 'MATCHED')                  as matched_count,
        count_if(recon_status in ('AMOUNT_MISMATCH', 'OVER_SETTLED', 'PARTIALLY_SETTLED', 'UNSETTLED')) as exception_count,
        sum(outstanding_gross_inr)                          as outstanding_settlement_inr,
        sum(iff(recon_status in ('AMOUNT_MISMATCH', 'OVER_SETTLED'),
                abs(gross_difference) * coalesce(fx_rate_to_inr, 1), 0)) as settlement_mismatch_inr
    from {{ ref('mart_settlement_reconciliation') }}
    group by 1, 2
)

select
    d.month_start,
    d.merchant_id,
    d.merchant_name,
    d.merchant_category,
    d.merchant_region,
    d.attempt_count,
    d.transaction_count,
    d.successful_payment_count,
    d.payment_volume_inr,
    div0(d.payment_volume_inr, d.successful_payment_count)                 as average_transaction_value_inr,
    div0(d.captured_transaction_count_by_created, d.terminal_transaction_count) as payment_success_rate,
    div0(d.failed_transaction_count, d.terminal_transaction_count)          as payment_failure_rate,
    d.refund_count,
    d.refund_amount_inr,
    div0(d.refund_amount_inr, d.payment_volume_inr)                         as refund_rate,
    d.chargeback_count,
    d.chargeback_amount_inr,
    div0(d.chargeback_count, d.successful_payment_count)                    as chargeback_rate,
    d.fraud_alert_count,
    coalesce(s.settleable_count, 0)                                         as settleable_count,
    coalesce(s.matched_count, 0)                                            as matched_count,
    div0(s.matched_count, s.settleable_count)                               as settlement_match_rate,
    coalesce(s.exception_count, 0)                                          as settlement_exception_count,
    coalesce(s.outstanding_settlement_inr, 0)                               as outstanding_settlement_inr,
    coalesce(s.settlement_mismatch_inr, 0)                                  as settlement_mismatch_inr
from daily d
left join settlement s on s.month_start = d.month_start and s.merchant_id = d.merchant_id
