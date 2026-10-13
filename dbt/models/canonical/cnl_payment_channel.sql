-- Canonical Payment Channel. Grain: one row per canonical channel_code (provider values collapse into it).
select
    channel_code,
    any_value(channel_name)                         as channel_name,
    any_value(channel_group)                        as channel_group,
    any_value(instrument_type)                      as instrument_type,
    array_agg(distinct source_system || ':' || provider_channel_value) as provider_values,
    boolor_agg(is_active)                           as is_active
from {{ ref('stg_payment_channels') }}
group by channel_code
