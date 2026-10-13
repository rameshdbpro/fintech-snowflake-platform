-- int_customer_velocity hard-codes a 60-minute RANGE window (structural).
-- Fails if runtime config claims a different window, which would silently not apply.
select rule_code, window_minutes
from {{ source('config', 'fraud_threshold') }}
where rule_code in ('VELOCITY_ATTEMPTS', 'VELOCITY_FAILED')
  and is_active
  and coalesce(window_minutes, 60) <> 60
