{#- Canonical integration exceptions. Nothing is silently dropped: every
    record that cannot be fully canonicalised appears here with a type,
    a traceable key back to RAW and the original values.
    Grain: one row per (exception_type, entity, entity_key). -#}

with attempts as (
    select * from {{ ref('cnl_payment_attempt') }}
),

exceptions as (

    -- provider with no mapping in dbt vars
    select 'UNMAPPED_PROVIDER' as exception_type, 'PAYMENT_ATTEMPT' as entity,
           source_system || '|' || source_transaction_id as entity_key, source_system, source_transaction_id,
           'Provider ' || source_system || ' has no payment_providers mapping' as detail,
           batch_id, ingested_at as ingestion_timestamp_utc
    from {{ ref('stg_payments') }}
    where not is_mapped_provider and record_version_desc = 1

    union all
    select 'INVALID_AMOUNT', 'PAYMENT_ATTEMPT', source_system || '|' || source_transaction_id,
           source_system, source_transaction_id,
           'amount_raw=' || coalesce(amount_raw, 'NULL'), batch_id, ingestion_timestamp_utc
    from attempts where not is_valid_amount

    union all
    select 'INVALID_CURRENCY', 'PAYMENT_ATTEMPT', source_system || '|' || source_transaction_id,
           source_system, source_transaction_id,
           'currency=' || coalesce(currency_code, 'NULL'), batch_id, ingestion_timestamp_utc
    from attempts where not is_valid_currency

    union all
    select 'INVALID_TIMESTAMP', 'PAYMENT_ATTEMPT', source_system || '|' || source_transaction_id,
           source_system, source_transaction_id,
           'event_ts_raw=' || coalesce(event_ts_raw, 'NULL'), batch_id, ingestion_timestamp_utc
    from attempts where not is_valid_timestamp

    union all
    select 'MISSING_BUSINESS_KEY', 'PAYMENT_ATTEMPT', source_system || '|' || source_transaction_id,
           source_system, source_transaction_id,
           'merchant_id/merchant_order_id missing', batch_id, ingestion_timestamp_utc
    from attempts where not has_business_key

    union all
    select 'UNKNOWN_CHANNEL', 'PAYMENT_ATTEMPT', source_system || '|' || source_transaction_id,
           source_system, source_transaction_id,
           'channel=' || coalesce(channel_value_raw, 'NULL'), batch_id, ingestion_timestamp_utc
    from attempts where not is_known_channel

    union all   -- one row per unknown provider status value seen for an attempt
    select distinct 'UNKNOWN_STATUS', 'PAYMENT_ATTEMPT', source_system || '|' || source_transaction_id,
           source_system, source_transaction_id,
           'status=' || coalesce(source_status, 'NULL') || ' (' || event_source || ')', batch_id, ingestion_timestamp_utc
    from {{ ref('cnl_payment_event') }}
    where not is_known_status

    union all
    select 'UNKNOWN_MERCHANT', 'PAYMENT_ATTEMPT', a.source_system || '|' || a.source_transaction_id,
           a.source_system, a.source_transaction_id, 'merchant_id=' || a.merchant_id, a.batch_id, a.ingestion_timestamp_utc
    from attempts a
    left join {{ ref('cnl_merchant') }} m on m.merchant_id = a.merchant_id
    where a.merchant_id is not null and m.merchant_id is null

    union all
    select 'UNKNOWN_CUSTOMER', 'PAYMENT_ATTEMPT', a.source_system || '|' || a.source_transaction_id,
           a.source_system, a.source_transaction_id, 'customer_id=' || a.customer_id, a.batch_id, a.ingestion_timestamp_utc
    from attempts a
    left join {{ ref('cnl_party_customer') }} c on c.customer_id = a.customer_id
    where a.customer_id is not null and c.customer_id is null

    union all
    select 'ORPHAN_REFUND', 'REFUND', refund_id, source_system, source_transaction_id,
           'refund references unknown payment', batch_id, ingestion_timestamp_utc
    from {{ ref('cnl_refund') }} where not has_payment

    union all
    select 'INVALID_REFUND_AMOUNT', 'REFUND', refund_id, source_system, source_transaction_id,
           'refund_amount=' || coalesce(to_varchar(refund_amount), 'NULL'), batch_id, ingestion_timestamp_utc
    from {{ ref('cnl_refund') }} where not is_valid_amount

    union all   -- processed refunds exceeding the captured amount of the attempt
    select 'REFUND_EXCEEDS_CAPTURE', 'PAYMENT_ATTEMPT', a.source_system || '|' || a.source_transaction_id,
           a.source_system, a.source_transaction_id,
           'refunded=' || r.refunded || ' captured=' || a.transaction_amount, a.batch_id, a.ingestion_timestamp_utc
    from attempts a
    join (select canonical_attempt_id, sum(refund_amount) as refunded
          from {{ ref('cnl_refund') }} where refund_status = 'REFUND_PROCESSED'
          group by 1) r on r.canonical_attempt_id = a.canonical_attempt_id
    where r.refunded > a.transaction_amount + 0.01

    union all
    select 'ORPHAN_CHARGEBACK', 'CHARGEBACK', chargeback_id, source_system, source_transaction_id,
           'chargeback references unknown payment', batch_id, ingestion_timestamp_utc
    from {{ ref('cnl_chargeback') }} where not has_payment

    union all
    select 'UNKNOWN_CHARGEBACK_STATUS', 'CHARGEBACK', chargeback_id, source_system, source_transaction_id,
           'status=' || coalesce(source_status, 'NULL'), batch_id, ingestion_timestamp_utc
    from {{ ref('cnl_chargeback') }} where not is_known_status

    union all
    select 'UNBALANCED_SETTLEMENT_LINE', 'SETTLEMENT', settlement_line_id, source_system, source_transaction_id,
           'gross-fee-tax<>net', batch_id, ingestion_timestamp_utc
    from {{ ref('cnl_settlement') }} where not is_line_balanced
)

select
    {{ surrogate_key(['exception_type', 'entity', 'entity_key', 'detail']) }} as exception_id,
    exception_type,
    entity,
    entity_key,
    source_system,
    source_transaction_id,
    detail,
    batch_id,
    ingestion_timestamp_utc,
    case
        when exception_type in ('UNMAPPED_PROVIDER', 'UNKNOWN_STATUS', 'INVALID_AMOUNT', 'INVALID_CURRENCY',
                                'REFUND_EXCEEDS_CAPTURE', 'UNBALANCED_SETTLEMENT_LINE') then 'HIGH'
        when exception_type in ('ORPHAN_REFUND', 'ORPHAN_CHARGEBACK', 'MISSING_BUSINESS_KEY', 'INVALID_TIMESTAMP') then 'MEDIUM'
        else 'LOW'
    end as severity,
    current_timestamp()::timestamp_ntz as detected_at_utc
from exceptions
qualify row_number() over (partition by exception_type, entity, entity_key, detail order by ingestion_timestamp_utc) = 1
