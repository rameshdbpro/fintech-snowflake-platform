{#- FACT_FRAUD_ALERT
    Grain      : one row per alert, from the vendor engine OR a platform rule.
    PK         : fraud_alert_key
    FKs        : attempt_key (nullable), customer_key, merchant_key, alert_date_key
    Measures   : alert_count (=1), alert_score, observed_value
    Degenerate : rule_code, alert_source, alert_status, severity
    Severity of vendor alerts uses CONFIG.FRAUD_THRESHOLD ALERT_SCORE_HIGH (runtime). -#}

with score_threshold as (
    select coalesce(max(iff(rule_code = 'ALERT_SCORE_HIGH' and is_active, threshold_value, null)), 80) as high_score
    from {{ source('config', 'fraud_threshold') }}
),

vendor as (
    select
        v.canonical_alert_id, v.alert_source, v.rule_code, v.customer_id, v.canonical_attempt_id,
        v.source_system, v.source_transaction_id, a.merchant_id, v.alert_timestamp_utc,
        v.alert_score, null::number(18,4) as observed_value, null::number(18,4) as threshold_value,
        iff(v.alert_score >= st.high_score, 'HIGH', iff(v.alert_score >= 60, 'MEDIUM', 'LOW')) as severity,
        v.alert_status
    from {{ ref('cnl_fraud_alert') }} v
    cross join score_threshold st
    left join {{ ref('cnl_payment_attempt') }} a on a.canonical_attempt_id = v.canonical_attempt_id
),

platform as (
    select
        canonical_alert_id, alert_source, rule_code, customer_id, canonical_attempt_id,
        source_system, source_transaction_id, merchant_id, alert_timestamp_utc,
        null::number(5,2) as alert_score, observed_value, threshold_value, severity, alert_status
    from {{ ref('int_customer_velocity') }}
),

alerts as (
    select * from vendor
    union all
    select * from platform
),

customers as (select customer_key, customer_id, valid_from, valid_to from {{ ref('dim_customer') }}),
merchants as (select merchant_key, merchant_id, valid_from, valid_to from {{ ref('dim_merchant') }})

select
    a.canonical_alert_id                                           as fraud_alert_key,
    a.canonical_attempt_id                                         as attempt_key,
    coalesce(c.customer_key, {{ surrogate_key(["'UNKNOWN'"]) }})   as customer_key,
    coalesce(m.merchant_key, {{ surrogate_key(["'UNKNOWN'"]) }})   as merchant_key,
    to_number(to_char(to_date({{ to_reporting_tz('a.alert_timestamp_utc') }}), 'YYYYMMDD')) as alert_date_key,
    a.alert_source,
    a.rule_code,
    a.severity,
    a.alert_status,
    (a.alert_status = 'CONFIRMED_FRAUD')                           as is_confirmed_fraud,
    a.customer_id,
    a.merchant_id,
    a.source_system,
    a.source_transaction_id,
    1                                                              as alert_count,
    a.alert_score,
    a.observed_value,
    a.threshold_value,
    a.alert_timestamp_utc,
    {{ to_reporting_tz('a.alert_timestamp_utc') }}                 as alert_at_ist,
    to_date({{ to_reporting_tz('a.alert_timestamp_utc') }})        as alert_date_ist
from alerts a
left join customers c on c.customer_id = a.customer_id
                     and a.alert_timestamp_utc >= c.valid_from and a.alert_timestamp_utc < c.valid_to
left join merchants m on m.merchant_id = a.merchant_id
                     and a.alert_timestamp_utc >= m.valid_from and a.alert_timestamp_utc < m.valid_to
