-- Canonical Currency (ISO 4217 subset). Precision standard: NUMBER(18,2) major units; minor_units drives conversion.
select
    currency_code,
    currency_name,
    minor_units,
    is_active
from {{ ref('currency') }}
