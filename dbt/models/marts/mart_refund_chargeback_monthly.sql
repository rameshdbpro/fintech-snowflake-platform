-- Refund & chargeback trends. Grain: month x channel_group x merchant_region.
select
    date_trunc('month', date_ist)                                 as month_start,
    channel_group,
    merchant_region,
    sum(successful_payment_count)                                 as successful_payment_count,
    sum(payment_volume_inr)                                       as payment_volume_inr,
    sum(refund_count)                                             as refund_count,
    sum(refund_amount_inr)                                        as refund_amount_inr,
    div0(sum(refund_amount_inr), sum(payment_volume_inr))         as refund_rate,
    sum(chargeback_count)                                         as chargeback_count,
    sum(chargeback_lost_count)                                    as chargeback_lost_count,
    sum(chargeback_amount_inr)                                    as chargeback_amount_inr,
    div0(sum(chargeback_count), sum(successful_payment_count))    as chargeback_rate
from {{ ref('mart_payment_daily') }}
group by 1, 2, 3
