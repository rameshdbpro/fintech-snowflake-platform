-- Bank statement lines aggregated by parsed settlement reference. Grain: settlement ref x currency.
select
    parsed_settlement_ref                    as settlement_batch_id,
    currency_code,
    count(*)                                 as bank_line_count,
    sum(signed_amount)                       as bank_net_amount,
    min(value_date)                          as first_value_date,
    max(value_date)                          as last_value_date,
    listagg(bank_txn_id, ',') within group (order by bank_txn_id) as bank_txn_ids,
    any_value(bank_code)                     as bank_code
from {{ ref('cnl_bank_statement_transaction') }}
where has_settlement_ref
group by parsed_settlement_ref, currency_code
