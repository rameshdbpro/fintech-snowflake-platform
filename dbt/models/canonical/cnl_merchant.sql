-- Canonical Merchant (current state). History lives in snapshots/snap_merchants -> DIM_MERCHANT.
select
    {{ surrogate_key(["'MERCHANT'", 'merchant_id']) }} as canonical_merchant_id,
    merchant_id,
    merchant_name,
    mcc_code,
    merchant_category,
    region,
    city,
    onboarded_date,
    settlement_cycle_days,
    fee_pct,
    merchant_status,
    updated_at        as merchant_updated_at_utc,
    ingested_at       as ingestion_timestamp_utc
from {{ ref('stg_merchants') }}
