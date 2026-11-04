with

source as (

    -- Every load day of the extract. Stands in for the SCD2 persist table.
    select * from {{ ref('mpl_bikes') }}

),

renamed as (

    select
        load_day,
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
