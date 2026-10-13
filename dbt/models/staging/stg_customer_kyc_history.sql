select
    kyc_event_id,
    customer_id,
    upper(kyc_level)   as kyc_level,
    upper(kyc_status)  as kyc_status,
    upper(risk_rating) as risk_rating,
    coalesce(pep_flag, false) as pep_flag,
    document_type,
    effective_from,
    verified_by,
    batch_id,
    ingested_at
from {{ source('raw', 'customer_kyc_history') }}
qualify row_number() over (partition by kyc_event_id order by ingested_at desc) = 1
