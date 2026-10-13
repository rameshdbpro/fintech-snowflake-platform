{#- SETTLEMENT BATCH <-> BANK STATEMENT reconciliation (level 2)
    Grain: one row per settlement batch x currency, plus one row per bank
           settlement reference that matches no batch.

    Formulas
      batch_net_amount = SUM(net_amount) of all lines in the batch
                         (SALE net of fees and GST, minus REFUND and CHARGEBACK debits)
      bank_net_amount  = SUM(CR) - SUM(DR) of bank lines whose narrative parses to the batch id
      difference       = batch_net_amount - bank_net_amount
      Gross payment volume is never compared with bank credits: fees, GST,
      refunds and chargebacks make them legitimately different.

    Status
      UNMATCHED_BANK_CREDIT  bank reference with no batch
      PENDING_BANK_CREDIT    no bank line yet, inside settlement_date + grace
      MISSING_BANK_CREDIT    no bank line after grace
      MATCHED                |difference| <= abs_tolerance (CONFIG.RECON_TOLERANCE BATCH_BANK)
      AMOUNT_MISMATCH        otherwise -#}

with batches as (select * from {{ ref('int_settlement_batch_totals') }}),
bank as (select * from {{ ref('int_bank_credit_by_ref') }}),

tolerance as (
    select currency_code, abs_tolerance, timing_grace_days
    from {{ source('config', 'recon_tolerance') }}
    where recon_scope = 'BATCH_BANK'
),

joined as (
    select
        coalesce(b.settlement_batch_id, k.settlement_batch_id)  as settlement_batch_id,
        coalesce(b.currency_code, k.currency_code)              as currency_code,
        b.source_system,
        b.line_count,
        b.unmatched_line_count,
        b.batch_gross_amount,
        b.batch_fee_amount,
        b.batch_tax_amount,
        b.batch_net_amount,
        b.settlement_date,
        k.bank_line_count,
        k.bank_net_amount,
        k.first_value_date,
        k.bank_txn_ids,
        k.bank_code,
        (b.settlement_batch_id is not null)                     as has_batch,
        (k.settlement_batch_id is not null)                     as has_bank_entry
    from batches b
    full outer join bank k
      on k.settlement_batch_id = b.settlement_batch_id
     and k.currency_code = b.currency_code
)

select
    j.*,
    coalesce(j.batch_net_amount, 0) - coalesce(j.bank_net_amount, 0)    as difference,
    coalesce(t.abs_tolerance, 0)                                        as abs_tolerance,
    datediff(day, j.settlement_date, j.first_value_date)                 as timing_difference_days,
    {{ recon_as_of_date() }}                                             as recon_as_of_date,
    case
        when not j.has_batch                                             then 'UNMATCHED_BANK_CREDIT'
        when not j.has_bank_entry
             and {{ recon_as_of_date() }} <= dateadd(day, coalesce(t.timing_grace_days, 0), j.settlement_date)
                                                                         then 'PENDING_BANK_CREDIT'
        when not j.has_bank_entry                                        then 'MISSING_BANK_CREDIT'
        when abs(j.batch_net_amount - j.bank_net_amount) <= coalesce(t.abs_tolerance, 0) then 'MATCHED'
        else 'AMOUNT_MISMATCH'
    end                                                                  as recon_status
from joined j
left join tolerance t on t.currency_code = j.currency_code
