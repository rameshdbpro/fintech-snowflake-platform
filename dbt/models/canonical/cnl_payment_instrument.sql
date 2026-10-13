{#- Canonical Payment Instrument. Grain: one row per (source_system, token).
    Only provider tokens and last-4 digits ever exist here: no PAN, VPA or
    account numbers are ingested by design. -#}
select
    canonical_instrument_id,
    source_system,
    any_value(instrument_type)        as instrument_type,
    any_value(instrument_last4)       as instrument_last4,
    any_value(instrument_network)     as instrument_network,
    count(distinct customer_id)       as customer_count,
    min(event_timestamp_utc)          as first_seen_utc,
    max(event_timestamp_utc)          as last_seen_utc,
    count(*)                          as attempt_count
from {{ ref('cnl_payment_attempt') }}
where canonical_instrument_id is not null
group by canonical_instrument_id, source_system
