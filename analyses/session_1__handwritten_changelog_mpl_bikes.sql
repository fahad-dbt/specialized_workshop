-- Session 1: the changelog for MPL_BIKES written by hand. No Jinja beyond ref().
-- Tracks three columns: MSRP, LAUNCH_DATE and MODEL_NAME.
-- The seed holds every load day, so it stands in for the SCD2 persist table here.
--
-- Compare with SP_BUILD_MDM_CHANGELOG: this is the same LAG + Change + Change % logic,
-- but you can read, compile and run it before it touches any data.
-- In Session 2 this becomes a single call to the build_changelog macro.


with

history as (

    select * from {{ ref('mpl_bikes') }}

),

versions as (

    select
        product_id,
        sku,
        load_day,
        last_update as change_date,

        msrp,
        lag(msrp) over (partition by product_id order by load_day) as prev_msrp,

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
        'MSRP' as column_name,
        prev_msrp::varchar as old_value,
        msrp::varchar as new_value,
        (msrp - prev_msrp)::varchar as change,
        round((msrp - prev_msrp) / nullif(prev_msrp, 0), 4) as change_percent,
        change_date

    from versions
    where version_number > 1
      and msrp is distinct from prev_msrp

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
order by product_id, change_date
