-- Canonical Customer Risk Profile. Grain: one row per customer (current state + history summary).
with k as (
    select * from {{ ref('cnl_customer_kyc_history') }}
),

summary as (
    select
        customer_id,
        count(*)                                        as kyc_version_count,
        count_if(risk_rating = 'HIGH')                  as high_risk_versions,
        max(iff(pep_flag, 1, 0)) = 1                    as ever_pep,
        min(recorded_effective_from_utc)                as first_kyc_at_utc
    from k
    group by customer_id
)

select
    c.customer_id,
    cur.kyc_level                 as current_kyc_level,
    cur.kyc_status                as current_kyc_status,
    cur.risk_rating               as current_risk_rating,
    cur.pep_flag                  as current_pep_flag,
    cur.recorded_effective_from_utc as risk_effective_from_utc,
    s.kyc_version_count,
    s.high_risk_versions,
    s.ever_pep,
    s.first_kyc_at_utc,
    case
        when cur.risk_rating = 'HIGH' or cur.pep_flag then 'ENHANCED_DUE_DILIGENCE'
        when cur.kyc_level = 'MIN'                    then 'LIMITED_ACCOUNT'
        else 'STANDARD'
    end                           as risk_treatment
from {{ ref('cnl_party_customer') }} c
left join k cur      on cur.customer_id = c.customer_id and cur.is_current
left join summary s  on s.customer_id = c.customer_id
