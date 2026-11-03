{#-
    Replaces the change_expr / change_pct_expr loop in SP step 4.

    Given a column's name and data type, returns SQL expressions for Change and Change %.
    `new_value` / `old_value` are the SQL expressions (variants) holding the current and previous value.

    Rules (same as the stored procedure):
      - columns in var('cols_to_exclude_change_diff') or ending in _ID -> no calculation
      - NUMBER / FLOAT                -> difference, and difference / previous (NULL when previous = 0)
      - DATE / TIMESTAMP              -> day difference with a ' days' suffix, no percentage
      - everything else               -> no calculation
    Returns none for "no calculation" so the caller can leave it out of the CASE.
-#}
{% macro change_calc(column_name, data_type, new_value='new_variant', old_value='old_variant') %}

    {%- set excluded = [] -%}
    {%- for col_name in var('cols_to_exclude_change_diff') -%}
        {%- do excluded.append(col_name | upper) -%}
    {%- endfor -%}

    {%- set is_numeric = data_type.startswith('NUMBER') or data_type.startswith('DECIMAL')
                         or data_type.startswith('FLOAT') or data_type.startswith('DOUBLE')
                         or data_type.startswith('INT') or data_type.startswith('BIGINT') -%}

    {%- if column_name in excluded or column_name.endswith('_ID') -%}
        {{ return({'change': none, 'change_percent': none}) }}

    {%- elif is_numeric -%}
        {{ return({
            'change': "round(" ~ new_value ~ "::float - " ~ old_value ~ "::float, 4)::varchar",
            'change_percent': "round((" ~ new_value ~ "::float - " ~ old_value ~ "::float) / nullif(" ~ old_value ~ "::float, 0), 4)"
        }) }}

    {%- elif data_type.startswith('TIMESTAMP') -%}
        {{ return({
            'change': "datediff('day', try_to_timestamp(" ~ old_value ~ "::varchar), try_to_timestamp(" ~ new_value ~ "::varchar))::varchar || ' days'",
            'change_percent': none
        }) }}

    {%- elif data_type.startswith('DATE') -%}
        {{ return({
            'change': "datediff('day', try_to_date(" ~ old_value ~ "::varchar), try_to_date(" ~ new_value ~ "::varchar))::varchar || ' days'",
            'change_percent': none
        }) }}

    {%- else -%}
        {{ return({'change': none, 'change_percent': none}) }}
    {%- endif -%}

{% endmacro %}
