{#- SCD2 history of merchants (fee rate, settlement cycle, region, status
    change over time and matter for reconciliation and row access). -#}
{% snapshot snap_merchants %}
{{
  config(
    unique_key='merchant_id',
    strategy='check',
    check_cols=['merchant_name', 'mcc_code', 'merchant_category', 'region', 'city',
                'settlement_cycle_days', 'fee_pct', 'merchant_status'],
    invalidate_hard_deletes=true
  )
}}
select
    merchant_id, merchant_name, mcc_code, merchant_category, region, city,
    onboarded_date, settlement_cycle_days, fee_pct, merchant_status, updated_at
from {{ ref('stg_merchants') }}
{% endsnapshot %}
