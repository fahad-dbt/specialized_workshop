{#-
    Demo prep only. Drops every snapshot and fct_product_changes so the
    load_day 1 -> 2 -> 3 walkthrough can start from scratch.

    Usage:  dbt run-operation reset_demo
-#}
{% macro reset_demo() %}

    {%- for node in graph.nodes.values() -%}
        {%- if node.resource_type == 'snapshot' or node.name == 'fct_product_changes' -%}
            {%- set relation = adapter.get_relation(
                database=node.database,
                schema=node.schema,
                identifier=node.alias
            ) -%}
            {%- if relation -%}
                {%- do adapter.drop_relation(relation) -%}
                {{ log("Dropped " ~ relation, info=true) }}
            {%- else -%}
                {{ log("Nothing to drop for " ~ node.name, info=true) }}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}

{% endmacro %}
