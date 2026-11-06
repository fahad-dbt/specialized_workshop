with

source as (

    -- Every load day of the extract. Stands in for the SCD2 persist table.
    select * from {{ source('mpl', 'raw_mpl_bikes') }}

),

-- Staging is the one place columns get renamed. Everything downstream uses these names.
renamed as (

    select
        load_day,
        product_id,
        sku,
        model_name,
        model_year,
        product_family,
        msrp            as msrp_usd,
        launch_date,
        display_order,
        update_user     as updated_by_user_id,
        last_update     as last_updated_at

    from source

)

select * from renamed
