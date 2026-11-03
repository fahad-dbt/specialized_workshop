{#-
    Builds the changelog for one snapshotted table. Replaces SP steps 3-8.

    Args:
      relation            ref() to the snapshot (SCD2 history)
      table_name          value written to TABLE_NAME, e.g. 'MPL_BIKES'
      pk                  primary key column (replaces SHOW PRIMARY KEYS)
      source_system       value written to SYSTEM_OF_CHANGE (replaces ETL_PERSIST_LAYER_CONFIG lookup)
      watermark           optional business timestamp used for CHANGE_DATE; falls back to the
                          snapshot time when missing (DATA-8515 "missing watermark" case)
      soft_delete_column  optional Y/N column; a change to 'Y' is a DELETE (DATA-8961), set at
                          write time instead of a post-insert UPDATE

    Output grain: one row per (record version, changed column).
      NEW     first version of a key that arrived after the initial load  -> COLUMN_NAME = 'ALL'
      UPDATE  one row per tracked column whose value changed between versions
      DELETE  key removed from the extract (snapshot dbt_is_deleted)       -> COLUMN_NAME = 'ALL'
              or soft_delete_column changed to 'Y'

    Set-based: one LAG over an object of all tracked columns, then LATERAL FLATTEN.
    The SP's approach was ~3N LAGs and N+1 scans.
-#}
{% macro build_changelog(relation, table_name, pk, source_system, watermark=none, soft_delete_column=none) %}

{%- set pk = pk | upper -%}
{%- set tracked = [] -%}

{%- if execute -%}
    {%- set relation_columns = [] -%}
    {%- for col in adapter.get_columns_in_relation(relation) -%}
        {%- do relation_columns.append(col.name | upper) -%}
    {%- endfor -%}

    {#- Compile-time replacement for the NO_PK_FOUND Teams alert -#}
    {%- if relation_columns | length > 0 and pk not in relation_columns -%}
        {{ exceptions.raise_compiler_error(
            "build_changelog: primary key '" ~ pk ~ "' not found in " ~ relation
            ~ ". Columns available: " ~ relation_columns | join(', ')
        ) }}
    {%- endif -%}

    {%- set tracked = get_tracked_columns(relation, pk) -%}
{%- endif -%}

{%- set tracked_names = [] -%}
{%- set change_whens = [] -%}
{%- set pct_whens = [] -%}
{%- for col in tracked -%}
    {%- do tracked_names.append(col.name) -%}
    {%- set calc = change_calc(col.name, col.data_type) -%}
    {%- if calc.change -%}
        {%- do change_whens.append("when '" ~ col.name ~ "' then " ~ calc.change) -%}
    {%- endif -%}
    {%- if calc.change_percent -%}
        {%- do pct_whens.append("when '" ~ col.name ~ "' then " ~ calc.change_percent) -%}
    {%- endif -%}
{%- endfor -%}

{%- if 'SKU' in tracked_names -%}
    {%- set sku_expr = 'sku::varchar' -%}
{%- elif pk == 'SKU' -%}
    {%- set sku_expr = pk ~ '::varchar' -%}
{%- else -%}
    {%- set sku_expr = 'null::varchar' -%}
{%- endif -%}

with

snapshot_history as (

    select * from {{ relation }}

),

versions as (

    select
        {{ pk }} as pk_value,
        {{ sku_expr }} as sku_value,
        dbt_valid_from as snapshot_valid_from,
        {% if watermark -%}
        coalesce({{ watermark }}, dbt_valid_from) as change_date,
        {%- else -%}
        dbt_valid_from as change_date,
        {%- endif %}
        coalesce(lower(dbt_is_deleted::varchar) = 'true', false) as is_deleted,
        object_construct_keep_null(
            {%- for col in tracked %}
            '{{ col.name }}', {{ col.name }}{% if not loop.last %},{% endif %}
            {%- endfor %}
        ) as current_values

    from snapshot_history


),

sequenced as (

    select
        *,
        lag(current_values) over (partition by pk_value order by snapshot_valid_from) as previous_values,
        coalesce(lag(is_deleted) over (partition by pk_value order by snapshot_valid_from), false) as previous_is_deleted,
        row_number() over (partition by pk_value order by snapshot_valid_from) as version_number,
        -- Replaces the SP's 1900-01-01 rule and the manual "delete fake NEWs at go-live" step:
        -- keys present in the very first snapshot load are history, not NEW.
        min(snapshot_valid_from) over () as initial_load_at

    from versions

),

new_records as (

    select
        pk_value,
        sku_value,
        'ALL' as column_name,
        null::varchar as old_value,
        null::varchar as new_value,
        null::varchar as change,
        null::float as change_percent,
        'NEW' as record_type,
        change_date,
        snapshot_valid_from

    from sequenced
    where not is_deleted
      and (version_number = 1 or previous_is_deleted)
      and snapshot_valid_from > initial_load_at

),

deleted_records as (

    select
        pk_value,
        sku_value,
        'ALL' as column_name,
        null::varchar as old_value,
        null::varchar as new_value,
        null::varchar as change,
        null::float as change_percent,
        'DELETE' as record_type,
        snapshot_valid_from as change_date,
        snapshot_valid_from

    from sequenced
    where is_deleted
      and not previous_is_deleted

),

changed_columns as (

    select
        sequenced.pk_value,
        sequenced.sku_value,
        sequenced.change_date,
        sequenced.snapshot_valid_from,
        flattened.key::varchar as column_name,
        flattened.value as new_variant,
        sequenced.previous_values[flattened.key] as old_variant

    from sequenced,
        lateral flatten(input => sequenced.current_values) as flattened
    where sequenced.version_number > 1
      and not sequenced.is_deleted
      and not sequenced.previous_is_deleted
      and flattened.value is distinct from sequenced.previous_values[flattened.key]

),

updated_records as (

    select
        pk_value,
        sku_value,
        column_name,
        old_variant::varchar as old_value,
        new_variant::varchar as new_value,
        {% if change_whens -%}
        case column_name
            {{ change_whens | join('\n            ') }}
        end
        {%- else -%}
        null
        {%- endif %}::varchar as change,
        {% if pct_whens -%}
        case column_name
            {{ pct_whens | join('\n            ') }}
        end
        {%- else -%}
        null
        {%- endif %}::float as change_percent,
        {% if soft_delete_column -%}
        case
            when column_name = '{{ soft_delete_column | upper }}' and new_variant::varchar = 'Y' then 'DELETE'
            else 'UPDATE'
        end
        {%- else -%}
        'UPDATE'
        {%- endif %} as record_type,
        change_date,
        snapshot_valid_from

    from changed_columns

),

unioned as (

    select * from new_records
    union all
    select * from deleted_records
    union all
    select * from updated_records

)

select
    md5(concat_ws('|',
        '{{ table_name }}',
        pk_value::varchar,
        column_name,
        record_type,
        snapshot_valid_from::varchar
    ))::varchar as change_key,
    '{{ table_name }}'::varchar as table_name,
    {{ changelog_key_columns(pk) }},
    column_name::varchar as column_name,
    old_value,
    new_value,
    change,
    change_percent::number(38, 4) as change_percent,
    record_type::varchar as record_type,
    change_date::timestamp_ntz as change_date,
    '{{ source_system }}'::varchar as system_of_change,
    snapshot_valid_from::timestamp_ntz as snapshot_valid_from

from unioned

{% endmacro %}
