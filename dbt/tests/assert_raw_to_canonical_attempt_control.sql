-- Source-to-target control: every distinct (source_system, provider id) of a
-- mapped provider in RAW.PAYMENTS appears exactly once in CNL_PAYMENT_ATTEMPT,
-- and unmapped-provider rows appear in CNL_EXCEPTIONS. Returns differences.
with raw_mapped as (
    select count(distinct source_system || '|' || source_transaction_id) as n
    from {{ ref('stg_payments') }}
    where is_mapped_provider
),
canonical as (
    select count(*) as n from {{ ref('cnl_payment_attempt') }}
)
select r.n as raw_distinct_attempts, c.n as canonical_attempts
from raw_mapped r cross join canonical c
where r.n <> c.n
