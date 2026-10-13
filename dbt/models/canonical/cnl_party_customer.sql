{#- Canonical Party / Customer. Grain: one row per customer_id (current).
    PII is kept here (needed for KYC operations) but masked by policy in
    DIM_CUSTOMER. PAN is replaced by a non-reversible token for analytics. -#}
select
    {{ surrogate_key(["'CUSTOMER'", 'customer_id']) }} as canonical_party_id,
    customer_id,
    'INDIVIDUAL'                                     as party_type,
    full_name,
    email,
    phone,
    date_of_birth,
    sha2(upper(pan_number), 256)                     as pan_token,
    city,
    state,
    country_code,
    customer_segment,
    created_at                                       as customer_created_at_utc,
    updated_at                                       as customer_updated_at_utc,
    ingested_at                                      as ingestion_timestamp_utc
from {{ ref('stg_customers') }}
