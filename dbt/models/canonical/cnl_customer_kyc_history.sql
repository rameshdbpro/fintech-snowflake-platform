{#- Canonical Customer KYC History with validity windows (SCD2-ready).
    Grain: one row per customer per KYC/risk change.
    The FIRST version is extended back to 1900-01-01 so facts that precede
    the first recorded KYC event (late-arriving dimension) still resolve. -#}
with ordered as (
    select
        k.*,
        row_number() over (partition by customer_id order by effective_from, kyc_event_id) as version_number,
        lead(effective_from) over (partition by customer_id order by effective_from, kyc_event_id) as next_effective_from
    from {{ ref('stg_customer_kyc_history') }} k
)

select
    {{ surrogate_key(['customer_id', 'kyc_event_id']) }} as canonical_kyc_version_id,
    customer_id,
    kyc_event_id,
    version_number,
    kyc_level,
    kyc_status,
    risk_rating,
    pep_flag,
    document_type,
    verified_by,
    effective_from                                         as recorded_effective_from_utc,
    iff(version_number = 1, '1900-01-01'::timestamp_ntz, effective_from) as valid_from_utc,
    coalesce(next_effective_from, '9999-12-31'::timestamp_ntz)           as valid_to_utc,
    (next_effective_from is null)                          as is_current,
    ingested_at                                            as ingestion_timestamp_utc
from ordered
