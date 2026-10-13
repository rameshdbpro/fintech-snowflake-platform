select
    upper(channel_code)       as channel_code,
    source_system,
    provider_channel_value,
    channel_name,
    upper(channel_group)      as channel_group,
    upper(instrument_type)    as instrument_type,
    coalesce(is_active, true) as is_active
from {{ source('raw', 'payment_channels') }}
qualify row_number() over (partition by source_system, provider_channel_value order by ingested_at desc) = 1
