with

source as (

    -- One day's full extract. Equivalent of ORACLE_ITEMS_FULL_TEMP.
    select * from {{ ref('oracle_items') }}
    where load_day = {{ var('load_day') }}

),

renamed as (

    select
        inventory_item_id,
        sku,
        description,
        item_status,
        primary_uom,
        list_price,
        unit_weight,
        creation_date,
        last_update_date

    from source

)

select * from renamed
