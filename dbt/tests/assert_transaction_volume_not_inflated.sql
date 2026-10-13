-- Fan-out guard across grains: captured value in FACT_PAYMENT_TRANSACTION must equal
-- the sum of CAPTURED valid attempts (retries/providers must not double count or drop value).
with attempts as (
    select coalesce(sum(attempt_amount), 0) as v
    from {{ ref('fact_payment_attempt') }}
    where is_valid_record and attempt_status = 'CAPTURED'
),
txns as (
    select coalesce(sum(captured_amount), 0) as v
    from {{ ref('fact_payment_transaction') }}
)
select a.v as attempt_captured_total, t.v as transaction_captured_total
from attempts a cross join txns t
where abs(a.v - t.v) > 0.01
