{{ config(severity='warn') }}
-- Processed refunds on an attempt should never exceed its captured amount.
-- Warn (not error): the provider is the system of record; we surface, not block.
select r.canonical_attempt_id, r.processed_refund_amount, a.transaction_amount
from {{ ref('int_refund_totals_by_attempt') }} r
join {{ ref('cnl_payment_attempt') }} a on a.canonical_attempt_id = r.canonical_attempt_id
where r.processed_refund_amount > a.transaction_amount + 0.01
