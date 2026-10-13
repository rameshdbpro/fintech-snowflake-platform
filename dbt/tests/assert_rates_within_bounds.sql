-- Governed ratios must lie in [0, 1] at every aggregation level we publish.
select month_start, merchant_id, payment_success_rate, payment_failure_rate, settlement_match_rate
from {{ ref('mart_merchant_performance') }}
where payment_success_rate not between 0 and 1
   or payment_failure_rate not between 0 and 1
   or settlement_match_rate not between 0 and 1
   or payment_success_rate + payment_failure_rate > 1.000001
