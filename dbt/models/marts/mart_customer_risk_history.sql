{#- Customer risk classification history: one row per customer per KYC
    version with the previous classification, so "how did risk change over
    time" is a simple query. No PII columns. Grain: customer x version. -#}
select
    customer_key,
    customer_id,
    version_number,
    kyc_level,
    kyc_status,
    risk_rating,
    pep_flag,
    lag(risk_rating) over (partition by customer_id order by version_number) as previous_risk_rating,
    lag(kyc_level)   over (partition by customer_id order by version_number) as previous_kyc_level,
    case
        when lag(risk_rating) over (partition by customer_id order by version_number) is null then 'INITIAL'
        when risk_rating = lag(risk_rating) over (partition by customer_id order by version_number) then 'UNCHANGED'
        when decode(risk_rating, 'LOW', 1, 'MEDIUM', 2, 'HIGH', 3, 0)
           > decode(lag(risk_rating) over (partition by customer_id order by version_number), 'LOW', 1, 'MEDIUM', 2, 'HIGH', 3, 0)
                                                                          then 'ESCALATED'
        else 'DE-ESCALATED'
    end                                                                   as risk_change,
    iff(valid_from = '1900-01-01'::timestamp_ntz, null, valid_from)       as effective_from_utc,
    iff(valid_to = '9999-12-31'::timestamp_ntz, null, valid_to)           as effective_to_utc,
    to_date(iff(valid_from = '1900-01-01'::timestamp_ntz, null, valid_from)) as effective_date,
    is_current
from {{ ref('dim_customer') }}
where customer_id <> 'UNKNOWN'
