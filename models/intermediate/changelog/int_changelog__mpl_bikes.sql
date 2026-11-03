{{ build_changelog(
    relation=ref('snp_mpl_bikes'),
    table_name='MPL_BIKES',
    pk='product_id',
    source_system='MPL',
    watermark='last_update'
) }}
