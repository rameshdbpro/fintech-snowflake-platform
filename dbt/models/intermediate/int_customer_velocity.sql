{#- Platform fraud rules driven by CONFIG.FRAUD_THRESHOLD (runtime config):
      VELOCITY_ATTEMPTS : attempts by one customer in a sliding window
      VELOCITY_FAILED   : failed attempts by one customer in a sliding window
      HIGH_VALUE_INR    : single captured attempt above an INR threshold
    One alert per customer per rule per hour bucket (no alert storms).
    Thresholds are RUNTIME config. The 60-minute window length is CODE: a
    RANGE frame needs a literal interval. tests/assert_velocity_window_matches_code.sql
    fails if someone changes window_minutes in config without a deployment.
    Grain: one row per generated platform alert. -#}
{{ config(materialized='table') }}

with thresholds as (
    select rule_code, threshold_value, coalesce(window_minutes, 60) as window_minutes, severity
    from {{ source('config', 'fraud_threshold') }}
    where is_active
),

attempts as (
    select
        a.canonical_attempt_id,
        a.customer_id,
        a.source_system,
        a.source_transaction_id,
        a.merchant_id,
        a.event_timestamp_utc,
        a.transaction_status,
        a.transaction_amount,
        a.currency_code
    from {{ ref('cnl_payment_attempt') }} a
    where a.is_valid_record and a.customer_id is not null
),

windowed as (
    select
        a.*,
        count(*) over (partition by customer_id order by event_timestamp_utc
                       range between interval '60 minutes' preceding and current row) as attempts_60m,
        count_if(transaction_status = 'FAILED') over (partition by customer_id order by event_timestamp_utc
                       range between interval '60 minutes' preceding and current row) as failed_60m
    from attempts a
),

fx as (
    select rate_month, currency_code, rate_to_inr from {{ ref('fx_rates_monthly') }}
),

candidates as (
    select w.*, 'VELOCITY_ATTEMPTS' as rule_code, w.attempts_60m as observed_value
    from windowed w join thresholds t on t.rule_code = 'VELOCITY_ATTEMPTS'
    where w.attempts_60m >= t.threshold_value
    union all
    select w.*, 'VELOCITY_FAILED', w.failed_60m
    from windowed w join thresholds t on t.rule_code = 'VELOCITY_FAILED'
    where w.failed_60m >= t.threshold_value
    union all
    select w.*, 'HIGH_VALUE_INR', round(w.transaction_amount * coalesce(fx.rate_to_inr, 1), 2)
    from windowed w
    join thresholds t on t.rule_code = 'HIGH_VALUE_INR'
    left join fx on fx.currency_code = w.currency_code
                and fx.rate_month = date_trunc('month', to_date({{ to_reporting_tz('w.event_timestamp_utc') }}))
    where w.transaction_status = 'CAPTURED'
      and w.transaction_amount * coalesce(fx.rate_to_inr, 1) > t.threshold_value
)

select
    {{ surrogate_key(["'PLATFORM'", 'c.rule_code', 'c.customer_id', "date_trunc('hour', c.event_timestamp_utc)"]) }} as canonical_alert_id,
    c.rule_code,
    'PLATFORM_RULE'                    as alert_source,
    c.customer_id,
    c.canonical_attempt_id,
    c.source_system,
    c.source_transaction_id,
    c.merchant_id,
    c.event_timestamp_utc              as alert_timestamp_utc,
    c.observed_value,
    t.threshold_value,
    t.severity,
    'OPEN'                             as alert_status
from candidates c
join thresholds t on t.rule_code = c.rule_code
qualify row_number() over (partition by c.rule_code, c.customer_id, date_trunc('hour', c.event_timestamp_utc)
                           order by c.event_timestamp_utc) = 1
