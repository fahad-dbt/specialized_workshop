with

source as (

    -- One day's full extract. Equivalent of MPL_BIKES_FULL_TEMP.
    select * from {{ source('mpl', 'raw_mpl_bikes') }}
    where load_day = {{ var('load_day') }}

),

-- Staging is the one place columns get renamed. Everything downstream uses these names.
renamed as (

    select
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
