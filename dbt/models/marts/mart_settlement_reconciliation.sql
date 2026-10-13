{#- PAYMENT <-> SETTLEMENT reconciliation (level 1)
    Grain: one row per valid payment attempt that is settleable (CAPTURED),
           was reversed/voided, or has settlement lines.

    Formulas
      expected_gross   = attempt_amount if attempt_status = CAPTURED else 0
      settled_gross    = SUM(gross of SALE lines for the attempt)        (int_settlement_by_attempt)
      gross_difference = expected_gross - settled_gross
      tolerance        = GREATEST(abs_tolerance, expected_gross * pct_tolerance)  (CONFIG.RECON_TOLERANCE)
      expected_settlement_date = captured_date_ist + merchant settlement_cycle_days
      fee_rate_actual  = sale_fee / settled_gross   vs contracted merchant fee_pct
      expected_net     = expected_gross - ROUND(expected_gross*fee_pct,2) - GST(18% of fee)
    Refund and chargeback debits are reported (refund_net, chargeback_net)
    but do NOT reduce the sale match: they reconcile at batch level.

    Status (first match wins)
      NOT_APPLICABLE        not captured (reversed/voided) and nothing settled
      SETTLED_NOT_CAPTURED  not captured but SALE lines exist
      PENDING_SETTLEMENT    nothing settled, still inside expected date + grace (timing)
      UNSETTLED             nothing settled after expected date + grace
      MATCHED               |gross_difference| <= tolerance
      PARTIALLY_SETTLED     settled < expected and provider flagged a non-final line
      OVER_SETTLED          settled > expected
      AMOUNT_MISMATCH       otherwise -#}
{{ config(post_hook=["{{ apply_row_access('RAP_MERCHANT_REGION', 'merchant_region') }}"]) }}

with attempts as (
    select *
    from {{ ref('fact_payment_attempt') }}
    where is_valid_record
),

sett as (select * from {{ ref('int_settlement_by_attempt') }}),
refunds as (select * from {{ ref('int_refund_totals_by_attempt') }}),

merchants as (
    select merchant_key, merchant_id, merchant_name, region, settlement_cycle_days, fee_pct
    from {{ ref('dim_merchant') }}
),

tolerance as (
    select currency_code, abs_tolerance, pct_tolerance, timing_grace_days, fee_variance_pct
    from {{ source('config', 'recon_tolerance') }}
    where recon_scope = 'PAYMENT_SETTLEMENT'
),

base as (
    select
        a.attempt_key,
        a.transaction_key,
        a.source_system,
        a.source_transaction_id,
        a.merchant_id,
        m.merchant_name,
        m.region                                              as merchant_region,
        a.channel_code,
        a.attempt_status,
        a.currency_code,
        a.fx_rate_to_inr,
        a.status_date_ist                                     as captured_date_ist,
        iff(a.attempt_status = 'CAPTURED', a.attempt_amount, 0)                     as expected_gross,
        coalesce(s.sale_gross_amount, 0)                                              as settled_gross,
        coalesce(s.sale_fee_amount, 0)                                                as settled_fee,
        coalesce(s.sale_tax_amount, 0)                                                as settled_tax,
        coalesce(s.sale_net_amount, 0)                                                as settled_net,
        coalesce(s.refund_net_amount, 0)                                              as refund_net_settled,
        coalesce(s.chargeback_net_amount, 0)                                          as chargeback_net_settled,
        coalesce(r.processed_refund_amount, 0)                                        as processed_refund_amount,
        coalesce(s.sale_line_count, 0)                                                as sale_line_count,
        coalesce(s.has_non_final_sale_line, false)                                    as has_non_final_sale_line,
        s.first_sale_settlement_date,
        s.last_sale_settlement_date,
        s.settlement_batch_ids,
        coalesce(m.fee_pct, 0)                                                        as contracted_fee_pct,
        dateadd(day, coalesce(m.settlement_cycle_days, 1), a.status_date_ist)        as expected_settlement_date,
        coalesce(t.abs_tolerance, 0)                                                  as abs_tolerance,
        coalesce(t.pct_tolerance, 0)                                                  as pct_tolerance,
        coalesce(t.timing_grace_days, 0)                                              as timing_grace_days,
        t.fee_variance_pct
    from attempts a
    left join sett s       on s.canonical_attempt_id = a.attempt_key
    left join refunds r    on r.canonical_attempt_id = a.attempt_key
    left join merchants m  on m.merchant_key = a.merchant_key
    left join tolerance t  on t.currency_code = a.currency_code
    where a.attempt_status in ('CAPTURED', 'REVERSED', 'VOIDED')
       or s.canonical_attempt_id is not null
),

calc as (
    select
        b.*,
        b.expected_gross - b.settled_gross                                              as gross_difference,
        greatest(b.abs_tolerance, b.expected_gross * b.pct_tolerance)                   as applied_tolerance,
        round(b.expected_gross * b.contracted_fee_pct, 2)                               as expected_fee,
        b.expected_gross - round(b.expected_gross * b.contracted_fee_pct, 2)
            - round(round(b.expected_gross * b.contracted_fee_pct, 2) * 0.18, 2)        as expected_net,
        iff(b.settled_gross = 0, null, b.settled_fee / b.settled_gross)                 as actual_fee_rate,
        {{ recon_as_of_date() }}                                                        as recon_as_of_date
    from base b
)

select
    c.*,
    case
        when c.attempt_status <> 'CAPTURED' and c.settled_gross = 0                    then 'NOT_APPLICABLE'
        when c.attempt_status <> 'CAPTURED'                                            then 'SETTLED_NOT_CAPTURED'
        when c.settled_gross = 0
             and c.recon_as_of_date <= dateadd(day, c.timing_grace_days, c.expected_settlement_date)
                                                                                       then 'PENDING_SETTLEMENT'
        when c.settled_gross = 0                                                       then 'UNSETTLED'
        when abs(c.gross_difference) <= c.applied_tolerance                            then 'MATCHED'
        when c.settled_gross < c.expected_gross and c.has_non_final_sale_line          then 'PARTIALLY_SETTLED'
        when c.settled_gross > c.expected_gross                                        then 'OVER_SETTLED'
        else 'AMOUNT_MISMATCH'
    end                                                                                as recon_status,
    (c.first_sale_settlement_date > c.expected_settlement_date)                        as is_timing_difference,
    datediff(day, c.expected_settlement_date, c.first_sale_settlement_date)            as settlement_delay_days,
    (c.actual_fee_rate is not null and c.fee_variance_pct is not null
        and abs(c.actual_fee_rate - c.contracted_fee_pct) > c.fee_variance_pct)        as is_fee_variance,
    greatest(c.expected_gross - c.settled_gross, 0)                                    as outstanding_gross,
    round(greatest(c.expected_gross - c.settled_gross, 0) * coalesce(c.fx_rate_to_inr, 1), 2) as outstanding_gross_inr,
    round(c.expected_gross * coalesce(c.fx_rate_to_inr, 1), 2)                         as expected_gross_inr,
    round(c.settled_gross * coalesce(c.fx_rate_to_inr, 1), 2)                          as settled_gross_inr,
    datediff(day, c.captured_date_ist, c.recon_as_of_date)                             as age_days
from calc c
