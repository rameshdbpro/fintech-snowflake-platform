{#- DIM_CUSTOMER (SCD Type 2 on KYC level / status / risk rating / PEP).
    Justification: risk-based reporting must use the risk classification
    that applied WHEN the payment happened, not today's.
    Grain: customer x KYC version. Business key: customer_id + valid_from.
    PII columns are masked by policy (post-hook) for non-KYC roles. -#}
{{
  config(
    post_hook=["{{ apply_masking({'full_name': 'MP_PII_NAME', 'email': 'MP_PII_EMAIL', 'phone': 'MP_PII_PHONE', 'date_of_birth': 'MP_PII_DATE', 'kyc_document_type': 'MP_KYC_RESTRICTED'}) }}"]
  )
}}

with versions as (
    select * from {{ ref('cnl_customer_kyc_history') }}
),

customers as (
    select * from {{ ref('cnl_party_customer') }}
)

select
    {{ surrogate_key(['c.customer_id', 'v.valid_from_utc']) }} as customer_key,
    c.customer_id,
    c.canonical_party_id,
    c.full_name,
    c.email,
    c.phone,
    c.date_of_birth,
    c.pan_token,
    c.city,
    c.state,
    c.country_code,
    c.customer_segment,
    coalesce(v.version_number, 1)              as version_number,
    coalesce(v.kyc_level, 'UNKNOWN')           as kyc_level,
    coalesce(v.kyc_status, 'UNKNOWN')          as kyc_status,
    coalesce(v.risk_rating, 'UNKNOWN')         as risk_rating,
    coalesce(v.pep_flag, false)                as pep_flag,
    v.document_type                            as kyc_document_type,
    coalesce(v.valid_from_utc, '1900-01-01'::timestamp_ntz) as valid_from,
    coalesce(v.valid_to_utc,   '9999-12-31'::timestamp_ntz) as valid_to,
    coalesce(v.is_current, true)               as is_current
from customers c
left join versions v on v.customer_id = c.customer_id

union all

select
    {{ surrogate_key(["'UNKNOWN'"]) }}, 'UNKNOWN', null, 'Unknown customer', null, null, null, null,
    null, null, null, 'UNKNOWN', 1, 'UNKNOWN', 'UNKNOWN', 'UNKNOWN', false, null,
    '1900-01-01'::timestamp_ntz, '9999-12-31'::timestamp_ntz, true
