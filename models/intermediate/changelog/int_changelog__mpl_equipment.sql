{{ build_changelog(
    relation=ref('snp_mpl_equipment'),
    table_name='MPL_EQUIPMENT',
    pk='product_id',
    source_system='MPL',
    watermark='last_update',
    soft_delete_column='deleted'
) }}
