with

source as (

    -- One day's full extract. Equivalent of MPL_BIKE_FOBS_FULL_TEMP.
    select * from {{ ref('mpl_bike_fobs') }}
    where load_day = {{ var('load_day') }}

),

renamed as (

    select
        fob_id,
        sku,
        fob_port,
        currency * 18.62 as peso,
        currency,
        fob_cost,
        effective_date

    from source

)

select * from renamed
