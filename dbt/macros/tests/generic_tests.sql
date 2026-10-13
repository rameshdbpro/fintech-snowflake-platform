{#- ======================= custom generic tests ========================= -#}

{#- Column must be >= 0 (optionally only where a condition holds) -#}
{% test non_negative(model, column_name, where_clause='1=1') %}
select *
from {{ model }}
where {{ column_name }} < 0 and ({{ where_clause }})
{% endtest %}


{#- Financial control total: SUM(column) in this model equals SUM in a
    compare model (same filter semantics). Tolerance in currency units. -#}
{% test amount_reconciles(model, column_name, compare_model, compare_column,
                          model_filter='1=1', compare_filter='1=1', tolerance=0.01) %}
with a as (select coalesce(sum({{ column_name }}), 0) as total from {{ model }} where {{ model_filter }}),
     b as (select coalesce(sum({{ compare_column }}), 0) as total from {{ compare_model }} where {{ compare_filter }})
select a.total as model_total, b.total as compare_total, a.total - b.total as difference
from a cross join b
where abs(a.total - b.total) > {{ tolerance }}
{% endtest %}


{#- Row count equality between two relations (fan-out guard) -#}
{% test row_count_matches(model, compare_model, model_filter='1=1', compare_filter='1=1') %}
with a as (select count(*) as n from {{ model }} where {{ model_filter }}),
     b as (select count(*) as n from {{ compare_model }} where {{ compare_filter }})
select a.n as model_rows, b.n as compare_rows
from a cross join b
where a.n <> b.n
{% endtest %}


{#- SCD2: validity windows of one business key must not overlap and only
    one row may be current. -#}
{% test scd2_valid_windows(model, business_key, valid_from='valid_from', valid_to='valid_to', current_flag='is_current') %}
with ordered as (
    select {{ business_key }} as bk, {{ valid_from }} as vf, {{ valid_to }} as vt, {{ current_flag }} as cur,
           lead({{ valid_from }}) over (partition by {{ business_key }} order by {{ valid_from }}) as next_vf
    from {{ model }}
),
overlaps as (
    select bk, 'overlap_or_gap' as issue from ordered
    where next_vf is not null and vt <> next_vf
),
multi_current as (
    select bk, 'multiple_current' as issue from ordered
    group by bk having sum(iff(cur, 1, 0)) <> 1
)
select * from overlaps
union all
select * from multi_current
{% endtest %}


{#- Every value must exist in CONFIG.CANONICAL_STATUS for the domain -#}
{% test canonical_status_valid(model, column_name, domain) %}
select m.{{ column_name }}
from {{ model }} m
left join {{ source('config', 'canonical_status') }} c
  on c.status_domain = '{{ domain }}' and c.canonical_status = m.{{ column_name }}
where m.{{ column_name }} is not null and c.canonical_status is null
{% endtest %}
