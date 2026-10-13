-- Refunds aggregated to the attempt grain (multiple partial refunds collapse here). Grain: attempt.
select
    canonical_attempt_id,
    count(*)                                                        as refund_count,
    count_if(refund_status = 'REFUND_PROCESSED')                    as processed_refund_count,
    sum(iff(refund_status = 'REFUND_PROCESSED', refund_amount, 0))  as processed_refund_amount,
    sum(iff(refund_status = 'REFUND_INITIATED', refund_amount, 0))  as pending_refund_amount
from {{ ref('cnl_refund') }}
where has_payment
group by canonical_attempt_id
