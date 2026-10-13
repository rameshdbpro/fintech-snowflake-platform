-- Latest version of each customer record (customers are re-delivered on change).
select
    customer_id,
    full_name,
    email,
    phone,
    date_of_birth,
    pan_number,
    city,
    state,
    country_code,
    customer_segment,
    created_at,
    updated_at,
    batch_id,
    ingested_at
from {{ source('raw', 'customers') }}
qualify row_number() over (partition by customer_id order by updated_at desc nulls last, ingested_at desc) = 1
