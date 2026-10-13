-- DIM_PAYMENT_CHANNEL. Grain: one canonical channel + UNKNOWN member. Type 1.
select
    {{ surrogate_key(['channel_code']) }} as channel_key,
    channel_code,
    channel_name,
    channel_group,
    instrument_type,
    provider_values,
    is_active
from {{ ref('cnl_payment_channel') }}
union all
select {{ surrogate_key(["'UNKNOWN'"]) }}, 'UNKNOWN', 'Unknown channel', 'UNKNOWN', 'UNKNOWN', array_construct(), false
