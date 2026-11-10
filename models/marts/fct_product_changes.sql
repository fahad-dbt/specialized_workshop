{#- DEMO BRANCH ONLY: materialized as a table to test whether CI compare skips incremental models. -#}
{{
    config(
        materialized='table',
        incremental_strategy='merge',
        unique_key='change_key',
        on_schema_change='fail'
    )
}}


{#-
    Replaces MDM_CHANGELOG_TBL and SP step 7 (INSERT), plus the max_change_date /
    existing_records / CHANGELOG_LAST_RUN bookkeeping.

    Adding a table to the changelog = add its int model to this list.
-#}
{%- set changelog_models = [
    'int_changelog__mpl_bikes',
    'int_changelog__mpl_equipment',
    'int_changelog__oracle_items',
    'int_changelog__mpl_bike_fobs',
] -%}

with

{% for model_name in changelog_models %}
{{ model_name }} as (

    select * from {{ ref(model_name) }}
    {% if is_incremental() %}
    -- Only versions snapshotted since the last run. Re-merging the last batch is safe:
    -- change_key is deterministic, so reruns update in place instead of duplicating.
    where snapshot_valid_from >= (
        select coalesce(max(snapshot_valid_from), '1900-01-01'::timestamp_ntz) from {{ this }}
    )
    {% endif %}

),
{% endfor %}

unioned as (

    {% for model_name in changelog_models %}
    select * from {{ model_name }}
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

)

select
    change_key,
    table_name,
    table_pk,
    table_pk_value,
    product_id,
    item_id,
    inventory_item_id,
    fob_id,
    sku,
    column_name,
    old_value,
    new_value,
    change,
    change_percent,
    record_type,
    change_date,
    system_of_change,
    snapshot_valid_from,
    current_timestamp()::timestamp_ntz as load_date

from unioned
