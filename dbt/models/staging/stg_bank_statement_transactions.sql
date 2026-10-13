{#- Bank statement lines. The settlement batch reference is extracted from
    the bank-specific free-text narrative with CONFIG.BANK_NARRATIVE_PATTERN,
    via the Snowpark UDF (default) or a SQL REGEXP fallback. -#}
with patterns as (
    select array_agg(object_construct('bank_code', bank_code, 'priority', priority, 'pattern', pattern))
               within group (order by priority) as patterns
    from {{ source('config', 'bank_narrative_pattern') }}
    where is_active
),

stmt as (
    select *
    from {{ source('raw', 'bank_statement_transactions') }}
    qualify row_number() over (partition by bank_txn_id order by ingested_at desc) = 1
)

select
    s.bank_txn_id,
    s.bank_code,
    s.bank_account_token,
    s.value_date,
    s.posting_ts,
    s.dr_cr,
    s.amount,
    iff(s.dr_cr = 'CR', s.amount, -s.amount) as signed_amount,
    upper(s.currency_code) as currency_code,
    s.narrative,
    {{ parse_settlement_ref('s.narrative', 's.bank_code') }} as parsed_settlement_ref,
    s.batch_id,
    s.ingested_at
from stmt s
cross join patterns p
