with

source as (

    -- One day's full extract. Equivalent of MPL_EQUIPMENT_FULL_TEMP.
    select * from {{ ref('mpl_equipment') }}
    where load_day = {{ var('load_day') }}

),

renamed as (

    select
        product_id,
        sku,
        equipment_name,
        category,
        msrp,
        deleted,
        update_user,
        last_update

    from source

)

select * from renamed
