-- Session 1: the changelog for MPL_BIKES written by hand. No Jinja beyond ref().
-- Tracks three columns: MSRP_USD, LAUNCH_DATE and MODEL_NAME (staging names).

--
-- In the stored procedure this SQL only exists as a Python f-string at runtime.
-- Here it's a file: compile it, read it, run it, test it.

with

history as (

    select * from {{ ref('stg_mpl__bikes') }}

),

versions as (

    select
        product_id,
        sku,
        load_day,
        last_updated_at as change_date,

        msrp_usd,
        lag(msrp_usd) over (partition by product_id order by load_day) as prev_msrp_usd,

        launch_date,
        lag(launch_date) over (partition by product_id order by load_day) as prev_launch_date,

        model_name,
        lag(model_name) over (partition by product_id order by load_day) as prev_model_name,

        row_number() over (partition by product_id order by load_day) as version_number

    from history

),

msrp_changes as (

    select
        product_id,
        sku,
        'MSRP_USD' as column_name,
        prev_msrp_usd::varchar as old_value,
        msrp_usd::varchar as new_value,
        (msrp_usd - prev_msrp_usd)::varchar as change,
        round((msrp_usd - prev_msrp_usd) / nullif(prev_msrp_usd, 0), 4) as change_percent,
        change_date

    from versions
    where version_number > 1
      and msrp_usd is distinct from prev_msrp_usd

),


launch_date_changes as (

    select
        product_id,
        sku,
        'LAUNCH_DATE' as column_name,
        prev_launch_date::varchar as old_value,
        launch_date::varchar as new_value,
        datediff('day', prev_launch_date, launch_date)::varchar || ' days' as change,
        null as change_percent,
        change_date

    from versions
    where version_number > 1
      and launch_date is distinct from prev_launch_date

),

model_name_changes as (

    select
        product_id,
        sku,
        'MODEL_NAME' as column_name,
        prev_model_name as old_value,
        model_name as new_value,
        null as change,
        null as change_percent,
        change_date

    from versions
    where version_number > 1
      and model_name is distinct from prev_model_name

)

select * from msrp_changes
union all
select * from launch_date_changes
union all
select * from model_name_changes

