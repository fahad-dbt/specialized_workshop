{#-
    Replaces the PRODUCT_ID / ITEM_ID / INVENTORY_ITEM_ID / FOB_ID CASE lines that the stored
    procedure repeats in both the UPDATE/NEW and DELETE branches.

    Written once. Adding a new key column (what DATA-8515 did) is a one-line change to `key_columns`.
    Expects the calling query to expose `pk_value` and `sku_value`.
-#}
{% macro changelog_key_columns(pk) %}

    {%- set key_columns = ['PRODUCT_ID', 'ITEM_ID', 'INVENTORY_ITEM_ID', 'FOB_ID'] -%}

        '{{ pk | upper }}'::varchar as table_pk,
        pk_value::varchar as table_pk_value,
    {%- for key in key_columns %}
        {% if (pk | upper) == key %}pk_value::varchar{% else %}null::varchar{% endif %} as {{ key | lower }},
    {%- endfor %}
        sku_value::varchar as sku

{%- endmacro %}
