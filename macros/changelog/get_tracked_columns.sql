{#-
    Replaces SP step 4: the INFORMATION_SCHEMA.COLUMNS query.

    Returns a list of {'name': ..., 'data_type': ...} for every column in `relation` that
    should be tracked in the changelog. Skipped:
      - the primary key
      - anything in var('cols_to_exclude') (metadata / SCD columns)
      - our surrogate keys (SK_*)
      - snapshot meta columns (DBT_*)
-#}
{% macro get_tracked_columns(relation, pk) %}

    {%- set excluded = [pk | upper] -%}
    {%- for col_name in var('cols_to_exclude') -%}
        {%- do excluded.append(col_name | upper) -%}
    {%- endfor -%}

    {%- set tracked = [] -%}
    {%- for col in adapter.get_columns_in_relation(relation) -%}
        {%- set name = col.name | upper -%}
        {%- if name not in excluded and not name.startswith('SK_') and not name.startswith('DBT_') -%}
            {%- do tracked.append({'name': name, 'data_type': col.dtype | upper}) -%}
        {%- endif -%}
    {%- endfor -%}

    {{ return(tracked) }}

{% endmacro %}
