{#- DIM_MERCHANT (SCD2 from snapshot). Grain: merchant x version.
    First version extended back to 1900 so late-arriving facts resolve.
    Row access policy on REGION restricts regional analysts. -#}
{{
  config(
    post_hook=["{{ apply_row_access('RAP_MERCHANT_REGION', 'region') }}"]
  )
}}

with snap as (
    select
        s.*,
        row_number() over (partition by merchant_id order by dbt_valid_from) as version_number
    from {{ ref('snap_merchants') }} s
)

select
    {{ surrogate_key(['merchant_id', 'dbt_valid_from']) }} as merchant_key,
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
    version_number,
    iff(version_number = 1, '1900-01-01'::timestamp_ntz, dbt_valid_from) as valid_from,
    coalesce(dbt_valid_to, '9999-12-31'::timestamp_ntz)                  as valid_to,
    (dbt_valid_to is null)                                               as is_current
from snap

union all

select
    {{ surrogate_key(["'UNKNOWN'"]) }}, 'UNKNOWN', 'Unknown merchant', null, 'UNKNOWN', 'UNKNOWN', null, null,
    1, 0, 'UNKNOWN', 1, '1900-01-01'::timestamp_ntz, '9999-12-31'::timestamp_ntz, true
