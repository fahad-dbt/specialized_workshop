with

source as (

    -- One day's full extract. Equivalent of MPL_BIKES_FULL_TEMP.
    select * from {{ ref('mpl_bikes') }}
    where load_day = {{ var('load_day') }}

),

renamed as (

    select
        product_id,
        sku,
        model_name,
        model_year,
        product_family,
        msrp,
        launch_date,
        display_order,
        update_user,
        last_update

    from source

)

select * from renamed
