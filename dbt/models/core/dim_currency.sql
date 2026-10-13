-- DIM_CURRENCY. Grain: one ISO currency + an UNKNOWN member. Type 1 (no history needed).
select
    {{ surrogate_key(['currency_code']) }} as currency_key,
    currency_code,
    currency_name,
    minor_units,
    is_active
from {{ ref('cnl_currency') }}
union all
select {{ surrogate_key(["'UNKNOWN'"]) }}, 'UNK', 'Unknown currency', 2, false
