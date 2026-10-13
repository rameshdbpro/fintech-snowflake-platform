-- Settlement batch totals (what the provider says it paid). Grain: batch x currency.
select
    settlement_batch_id,
    currency_code,
    any_value(source_system)                            as source_system,
    count(*)                                            as line_count,
    count_if(not is_matched_to_payment)                 as unmatched_line_count,
    sum(gross_amount)                                   as batch_gross_amount,
    sum(fee_amount)                                     as batch_fee_amount,
    sum(tax_amount)                                     as batch_tax_amount,
    sum(net_amount)                                     as batch_net_amount,
    min(settlement_date)                                as settlement_date,
    max(settlement_date)                                as last_settlement_date
from {{ ref('cnl_settlement') }}
group by settlement_batch_id, currency_code
