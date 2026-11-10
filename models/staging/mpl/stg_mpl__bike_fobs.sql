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
            currency,
            fob_cost,
            fob_cost + 100 as fob_cost_100,
            effective_date

        from source

    )

    select * from renamed
