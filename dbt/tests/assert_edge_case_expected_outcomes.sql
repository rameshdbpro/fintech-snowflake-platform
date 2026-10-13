{#- Known-answer test for the controlled edge cases in
    snowflake/05_edge_cases.sql. Returns every expectation in
    CONFIG.EXPECTED_TEST_OUTCOME that the built models do NOT satisfy.
    Passes trivially if edge cases were not loaded (empty expectations). -#}

with expected as (
    select test_case_id, description, check_type, entity_key, expected_value
    from {{ source('config', 'expected_test_outcome') }}
),

actual as (
    select 'PAYMENT_RECON_STATUS' as check_type, source_system || '|' || source_transaction_id as entity_key,
           recon_status as actual_value
    from {{ ref('mart_settlement_reconciliation') }}

    union all
    select 'BATCH_RECON_STATUS', settlement_batch_id, recon_status
    from {{ ref('mart_bank_reconciliation') }}

    union all
    select 'ATTEMPT_COUNT', merchant_id || '|' || merchant_order_id, to_varchar(attempt_count)
    from {{ ref('fact_payment_transaction') }}

    union all
    select 'FINAL_STATUS', merchant_id || '|' || merchant_order_id, final_status
    from {{ ref('fact_payment_transaction') }}

    union all
    select 'REFUND_TOTAL', source_system || '|' || source_transaction_id,
           to_varchar(sum(iff(is_processed, refund_amount, 0))::number(18,2))
    from {{ ref('fact_refund') }}
    group by source_system, source_transaction_id

    union all
    select 'CHARGEBACK_AMOUNT', source_system || '|' || source_transaction_id,
           to_varchar(sum(iff(is_lost, chargeback_amount, 0))::number(18,2))
    from {{ ref('fact_chargeback') }}
    group by source_system, source_transaction_id

    union all
    select 'DEDUP_COUNT', source_system || '|' || source_transaction_id, to_varchar(count(*))
    from {{ ref('cnl_payment_attempt') }}
    group by source_system, source_transaction_id

    union all
    select 'EXCEPTION_TYPE', entity_key, exception_type
    from {{ ref('cnl_exceptions') }}

    union all
    select 'EXCEPTION_TYPE', entity_key, exception_type
    from {{ ref('mart_reconciliation_exceptions') }}

    union all
    select 'KYC_VERSIONS', customer_id, to_varchar(count(*))
    from {{ ref('dim_customer') }}
    group by customer_id

    union all
    select 'CURRENT_RISK', customer_id, risk_rating
    from {{ ref('dim_customer') }}
    where is_current
)

select e.*, a.actual_value as observed_value_for_key
from expected e
left join actual a
  on a.check_type = e.check_type
 and a.entity_key = e.entity_key
 and a.actual_value = e.expected_value
where a.check_type is null
