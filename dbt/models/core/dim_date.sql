-- DIM_DATE. Grain: one calendar day (reporting timezone Asia/Kolkata). date_key = YYYYMMDD.
with days as (
    -- ROW_NUMBER (not SEQ4) guarantees a gap-free sequence
    select dateadd(day, row_number() over (order by seq4()) - 1, '2024-01-01'::date) as date_day
    from table(generator(rowcount => 1461))   -- 2024-01-01 .. 2027-12-31
)

select
    to_number(to_char(date_day, 'YYYYMMDD'))   as date_key,
    date_day,
    year(date_day)                             as year_number,
    quarter(date_day)                          as quarter_number,
    'Q' || quarter(date_day) || '-' || year(date_day) as quarter_label,
    month(date_day)                            as month_number,
    to_char(date_day, 'MON')                   as month_short_name,
    date_trunc('month', date_day)              as month_start_date,
    last_day(date_day)                         as month_end_date,
    weekofyear(date_day)                       as week_of_year,
    date_trunc('week', date_day)               as week_start_date,
    dayofweekiso(date_day)                     as iso_day_of_week,
    dayname(date_day)                          as day_name,
    (dayofweekiso(date_day) in (6, 7))         as is_weekend,
    -- Indian fiscal year: April - March
    iff(month(date_day) >= 4, year(date_day), year(date_day) - 1) as fiscal_year_start,
    'FY' || iff(month(date_day) >= 4, year(date_day), year(date_day) - 1) || '-' ||
        right(to_varchar(iff(month(date_day) >= 4, year(date_day) + 1, year(date_day))), 2) as fiscal_year_label
from days
