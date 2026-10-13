-- Fraud monitoring. Grain: alert date x alert_source x rule_code x severity x alert_status.
select
    alert_date_ist,
    alert_source,
    rule_code,
    severity,
    alert_status,
    count(*)                               as alert_count,
    count_if(is_confirmed_fraud)           as confirmed_fraud_count,
    count(distinct customer_id)            as distinct_customers,
    count(distinct merchant_id)            as distinct_merchants,
    avg(alert_score)                       as avg_alert_score
from {{ ref('fact_fraud_alert') }}
group by 1, 2, 3, 4, 5
