-- One FX rate per (month, currency); duplicates would fan out every *_inr measure.
select rate_month, currency_code, count(*) as n
from {{ ref('fx_rates_monthly') }}
group by 1, 2
having count(*) > 1
