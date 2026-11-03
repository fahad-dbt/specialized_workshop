{#- No watermark column on this table: change_date falls back to the snapshot time. -#}
{{ build_changelog(
    relation=ref('snp_mpl_bike_fobs'),
    table_name='MPL_BIKE_FOBS',
    pk='fob_id',
    source_system='MPL'
) }}
