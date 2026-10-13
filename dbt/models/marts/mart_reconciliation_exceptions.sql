{#- Every open reconciliation exception, traceable to its source rows.
    Grain: one row per exception (exception_id). Categories:
      PAYMENT_SETTLEMENT : UNSETTLED, PARTIALLY_SETTLED, AMOUNT_MISMATCH, OVER_SETTLED, SETTLED_NOT_CAPTURED, FEE_VARIANCE
      SETTLEMENT_ORPHAN  : UNMATCHED_SETTLEMENT (line with no payment)
      BATCH_BANK         : MISSING_BANK_CREDIT, UNMATCHED_BANK_CREDIT, BATCH_AMOUNT_MISMATCH
      BANK_UNIDENTIFIED  : UNIDENTIFIED_BANK_ENTRY (no settlement reference in narrative)
    PENDING_* statuses are timing differences, not exceptions. -#}

with payment_level as (
    select
        'PAYMENT_SETTLEMENT'                                   as exception_category,
        recon_status                                           as exception_type,
        source_system || '|' || source_transaction_id          as entity_key,
        source_system, source_transaction_id, merchant_id, merchant_region,
        null::varchar                                          as settlement_batch_id,
        currency_code,
        gross_difference                                       as exception_amount,
        round(gross_difference * coalesce(fx_rate_to_inr, 1), 2) as exception_amount_inr,
        expected_gross, settled_gross,
        captured_date_ist                                      as reference_date,
        age_days,
        'expected=' || expected_gross || ' settled=' || settled_gross || ' lines=' || sale_line_count as detail
    from {{ ref('mart_settlement_reconciliation') }}
    where recon_status in ('UNSETTLED', 'PARTIALLY_SETTLED', 'AMOUNT_MISMATCH', 'OVER_SETTLED', 'SETTLED_NOT_CAPTURED')
    union all
    select
        'PAYMENT_SETTLEMENT', 'FEE_VARIANCE', source_system || '|' || source_transaction_id,
        source_system, source_transaction_id, merchant_id, merchant_region, null, currency_code,
        settled_fee - round(settled_gross * contracted_fee_pct, 2),
        round((settled_fee - round(settled_gross * contracted_fee_pct, 2)) * coalesce(fx_rate_to_inr, 1), 2),
        expected_gross, settled_gross, captured_date_ist, age_days,
        'actual_rate=' || round(actual_fee_rate, 6) || ' contracted=' || contracted_fee_pct
    from {{ ref('mart_settlement_reconciliation') }}
    where is_fee_variance
),

orphan_lines as (
    select
        'SETTLEMENT_ORPHAN', 'UNMATCHED_SETTLEMENT', settlement_line_id,
        source_system, source_transaction_id, merchant_id, null, settlement_batch_id, currency_code,
        gross_amount, gross_amount_inr, null::number(18,2), gross_amount, settlement_date,
        datediff(day, settlement_date, {{ recon_as_of_date() }}),
        'settlement line references unknown payment ' || coalesce(source_system, '?') || '|' || coalesce(source_transaction_id, '?')
    from {{ ref('fact_settlement_event') }}
    where not is_matched_to_payment
),

batch_level as (
    select
        'BATCH_BANK',
        iff(recon_status = 'AMOUNT_MISMATCH', 'BATCH_AMOUNT_MISMATCH', recon_status),
        settlement_batch_id, source_system, null, null, null, settlement_batch_id, currency_code,
        difference, null::number(18,2), batch_net_amount, bank_net_amount,
        coalesce(settlement_date, first_value_date),
        datediff(day, coalesce(settlement_date, first_value_date), recon_as_of_date),
        'batch_net=' || coalesce(to_varchar(batch_net_amount), 'NULL') || ' bank=' || coalesce(to_varchar(bank_net_amount), 'NULL')
            || ' bank_txns=' || coalesce(bank_txn_ids, '-')
    from {{ ref('mart_bank_reconciliation') }}
    where recon_status in ('MISSING_BANK_CREDIT', 'UNMATCHED_BANK_CREDIT', 'AMOUNT_MISMATCH')
),

unidentified as (
    select
        'BANK_UNIDENTIFIED', 'UNIDENTIFIED_BANK_ENTRY', bank_txn_id, null, null, null, null, null, currency_code,
        signed_amount, null::number(18,2), null::number(18,2), signed_amount, value_date,
        datediff(day, value_date, {{ recon_as_of_date() }}),
        bank_code || ': ' || narrative
    from {{ ref('cnl_bank_statement_transaction') }}
    where not has_settlement_ref
),

all_exceptions as (
    select * from payment_level
    union all select * from orphan_lines
    union all select * from batch_level
    union all select * from unidentified
)

select
    {{ surrogate_key(['exception_category', 'exception_type', 'entity_key']) }} as exception_id,
    e.*,
    case
        when exception_type in ('UNMATCHED_SETTLEMENT', 'MISSING_BANK_CREDIT', 'UNMATCHED_BANK_CREDIT',
                                'OVER_SETTLED', 'SETTLED_NOT_CAPTURED')       then 'HIGH'
        when exception_type in ('AMOUNT_MISMATCH', 'BATCH_AMOUNT_MISMATCH', 'UNSETTLED') then 'MEDIUM'
        else 'LOW'
    end as severity,
    case
        when e.age_days > 30 then '>30d'
        when e.age_days > 7  then '8-30d'
        else '0-7d'
    end as age_bucket
from all_exceptions e
