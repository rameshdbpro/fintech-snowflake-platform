{#- Settlement lines aggregated to the attempt grain BEFORE any join with
    payments (prevents fan-out when a payment has several settlement events).
    Grain: one row per canonical_attempt_id that has >= 1 settlement line. -#}
select
    canonical_attempt_id,
    count(*)                                                   as settlement_line_count,
    count_if(settlement_type = 'SALE')                         as sale_line_count,
    sum(iff(settlement_type = 'SALE', gross_amount, 0))        as sale_gross_amount,
    sum(iff(settlement_type = 'SALE', fee_amount, 0))          as sale_fee_amount,
    sum(iff(settlement_type = 'SALE', tax_amount, 0))          as sale_tax_amount,
    sum(iff(settlement_type = 'SALE', net_amount, 0))          as sale_net_amount,
    sum(iff(settlement_type = 'REFUND', net_amount, 0))        as refund_net_amount,
    sum(iff(settlement_type = 'CHARGEBACK', net_amount, 0))    as chargeback_net_amount,
    sum(net_amount)                                            as total_net_amount,
    boolor_agg(settlement_type = 'SALE' and not is_final_settlement) as has_non_final_sale_line,
    min(iff(settlement_type = 'SALE', settlement_date, null))  as first_sale_settlement_date,
    max(iff(settlement_type = 'SALE', settlement_date, null))  as last_sale_settlement_date,
    array_agg(distinct settlement_batch_id)                    as settlement_batch_ids
from {{ ref('cnl_settlement') }}
where canonical_attempt_id is not null
  and is_matched_to_payment
group by canonical_attempt_id
