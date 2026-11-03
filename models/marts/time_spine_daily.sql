with

base_dates as (

    {{
        dbt.date_spine(
            'day',
            "to_date('2024-01-01')",
            "to_date('2030-01-01')"
        )
    }}

)

select
    cast(date_day as date) as date_day

from base_dates
