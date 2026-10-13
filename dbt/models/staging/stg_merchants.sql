-- Latest delivered state per merchant. History is captured by snapshots/snap_merchants.
select
    merchant_id,
    merchant_name,
    mcc_code,
    merchant_category,
    upper(region) as region,
    city,
    onboarded_date,
    settlement_cycle_days,
    fee_pct,
    merchant_status,
    updated_at,
    batch_id,
    ingested_at
from {{ source('raw', 'merchants') }}
qualify row_number() over (partition by merchant_id order by updated_at desc nulls last, ingested_at desc) = 1
