{{ build_changelog(
    relation=ref('snp_oracle_items'),
    table_name='ORACLE_ITEMS',
    pk='inventory_item_id',
    source_system='ORACLE',
    watermark='last_update_date'
) }}
