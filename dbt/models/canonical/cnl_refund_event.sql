-- Canonical Refund Event. Grain: one row per refund status event.
with mapping as (
    select source_status, canonical_status, status_category, is_terminal, status_rank
    from {{ source('config', 'status_mapping') }}
    where status_domain = 'REFUND' and source_system = '*' and is_active
)

select
    {{ surrogate_key(['e.refund_event_id']) }} as canonical_refund_event_id,
    {{ surrogate_key(['e.refund_id']) }}       as canonical_refund_id,
    e.refund_event_id,
    e.refund_id,
    e.refund_status                            as source_status,
    m.canonical_status,
    m.status_category,
    coalesce(m.is_terminal, false)             as is_terminal,
    coalesce(m.status_rank, 0)                 as status_rank,
    (m.canonical_status is not null)           as is_known_status,
    e.event_ts                                 as event_timestamp_utc,
    e.ingested_at                              as ingestion_timestamp_utc
from {{ ref('stg_refund_status_history') }} e
left join mapping m on m.source_status = e.refund_status
