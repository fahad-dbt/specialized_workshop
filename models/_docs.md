{% docs __overview__ %}
# MDM Product Changelog

This project rebuilds the Snowflake stored procedure `SP_BUILD_MDM_CHANGELOG` as a dbt project.
It captures every change to product data across MPL and Oracle: new products, column-level
updates and deletes. All of it lands in one table, `fct_product_changes`, which replaces
`MDM_CHANGELOG_TBL`.

## How data flows

Each tracked table is an independent lane. The lanes run in parallel instead of one table at
a time in a Matillion loop.

`seed` → `stg_*` → `snp_*` (snapshot) → `int_changelog__*` → `fct_product_changes` → metrics

| Layer | What it does | Replaces in the stored procedure |
|---|---|---|
| Seeds | Simulated daily extracts, one per `load_day` | `<TABLE>_FULL_TEMP` tables |
| Staging | One day's extract, cleaned and renamed | Source-to-persist load |
| Snapshots | SCD2 history, including hard deletes | Persist-table merge, FULL_TEMP anti-join, biweekly delete job |
| Intermediate | One `build_changelog` call per table | The `wide_sql` string, the unpivot and the post-insert `UPDATE` |
| Mart | Incremental merge on a deterministic key | `INSERT INTO MDM_CHANGELOG_TBL`, `CHANGELOG_SEQ`, `CHANGELOG_LAST_RUN` |

## Record types

- **NEW**: the first version of a key that arrived after the initial load. `column_name = 'ALL'`.
- **UPDATE**: one row per tracked column whose value changed between versions.
- **DELETE**: the key disappeared from the extract (`column_name = 'ALL'`), or a soft-delete
  flag such as `DELETED` changed to `Y` (DATA-8961).

## Adding a table

Add a seed (or source), a staging model, a snapshot entry and a one-line
`int_changelog__<table>` model. Then add that model's name to the list in `fct_product_changes`.
{% enddocs %}


{# ---------------------------------------------------------------------------
   Extract / business columns. Shared by seeds, staging models and snapshots.
   --------------------------------------------------------------------------- #}

{% docs load_day %}
Which daily extract the row belongs to (1, 2 or 3). Each `load_day` is a full extract of the
table, the equivalent of `<TABLE>_FULL_TEMP` on that day. Staging models keep only the rows where
`load_day = var('load_day')`.
{% enddocs %}

{% docs mpl_product_id %}
MPL product key and the primary key of the table. Declared in the `build_changelog` call
instead of being looked up at runtime with `SHOW PRIMARY KEYS`.
{% enddocs %}

{% docs sku %}
Stock keeping unit, e.g. `BK-1001` for bikes and `EQ-2001` for equipment. Joins the same
product across MPL and Oracle.
{% enddocs %}

{% docs model_name %}
Marketing name of the bike model. Tracked in the changelog.
{% enddocs %}

{% docs model_year %}
Model year of the bike. Tracked in the changelog.
{% enddocs %}

{% docs product_family %}
Product family (Road, Mountain, Gravel, Active, Trail). Tracked in the changelog.
{% enddocs %}

{% docs msrp %}
Manufacturer's suggested retail price in USD. Tracked in the changelog, which records the
difference as Change and the relative difference as Change %.
{% enddocs %}

{% docs launch_date %}
Date the product launches. Tracked in the changelog; Change is the day difference, e.g. `14 days`.
{% enddocs %}

{% docs display_order %}
Sort order used for display. Tracked in the changelog, but Change and Change % are always NULL:
it's numeric, but the difference has no meaning (listed in `cols_to_exclude_change_diff`).
{% enddocs %}

{% docs update_user %}
ID of the user who last updated the record. Tracked in the changelog, but Change and Change % are
always NULL (listed in `cols_to_exclude_change_diff`).
{% enddocs %}

{% docs last_update %}
When the record was last updated in MPL. Not tracked as a column change (it's in
`cols_to_exclude`), but used as the watermark: it becomes `change_date` for NEW and UPDATE rows.
{% enddocs %}

{% docs equipment_name %}
Name of the equipment item. Tracked in the changelog.
{% enddocs %}

{% docs equipment_category %}
Equipment category (Helmets, Tires, Saddles, Accessories, Apparel, Shoes, Wheels). Tracked in the changelog.
{% enddocs %}

{% docs deleted_flag %}
Soft-delete flag: `Y`, `N` or NULL. A change where the new value is `Y` is recorded as a
**DELETE**. Every other transition (NULL to N, Y to N) is an UPDATE (DATA-8961).
{% enddocs %}

{% docs inventory_item_id %}
Oracle inventory item key and the primary key of the table. Fills the `inventory_item_id`
column in the changelog (DATA-8515).
{% enddocs %}

{% docs oracle_item_description %}
Oracle item description, usually the model name plus a size. Tracked in the changelog.
{% enddocs %}

{% docs item_status %}
Oracle item lifecycle status (Active, Inactive, Obsolete). Tracked in the changelog.
{% enddocs %}

{% docs primary_uom %}
Primary unit of measure, e.g. `EA` (each) or `PR` (pair). Tracked in the changelog.
{% enddocs %}

{% docs list_price %}
Oracle list price in USD. Tracked in the changelog with Change and Change %.
{% enddocs %}

{% docs unit_weight %}
Unit weight in kilograms. Tracked in the changelog with Change and Change %.
{% enddocs %}

{% docs creation_date %}
When the item was created in Oracle. Not tracked (it's in `cols_to_exclude`).
{% enddocs %}

{% docs last_update_date %}
When the item was last updated in Oracle. Not tracked (it's in `cols_to_exclude`), but used as
the watermark: it becomes `change_date` for NEW and UPDATE rows.
{% enddocs %}

{% docs fob_id %}
MPL FOB key and the primary key of the table. Fills the `fob_id` column in the changelog.
{% enddocs %}

{% docs fob_port %}
Port the bike ships from on a Free On Board (FOB) basis. Tracked in the changelog.
{% enddocs %}

{% docs currency %}
Currency of the FOB cost. Tracked in the changelog.
{% enddocs %}

{% docs fob_cost %}
Cost of the bike at the port of shipment. Tracked in the changelog with Change and Change %.
{% enddocs %}

{% docs effective_date %}
Date the FOB cost takes effect. Tracked in the changelog; Change is the day difference.
{% enddocs %}


{# ---------------------------------------------------------------------------
   Snapshot meta columns added by dbt.
   --------------------------------------------------------------------------- #}

{% docs dbt_scd_id %}
Unique identifier for each version of a record, generated by the snapshot.
{% enddocs %}

{% docs dbt_updated_at %}
When the snapshot captured this version. With the `check` strategy this is the snapshot run time.
{% enddocs %}

{% docs dbt_valid_from %}
When this version became the current one. Replaces `SCD_START_DATE` in the persist tables.
The changelog orders versions by this column.
{% enddocs %}

{% docs dbt_valid_to %}
When this version stopped being current. NULL for the current version. Replaces `SCD_END_DATE`.
{% enddocs %}

{% docs dbt_is_deleted %}
`True` on the row the snapshot writes when a key disappears from the extract
(`hard_deletes: new_record`). The changelog turns it into a DELETE row. This replaces the
FULL_TEMP anti-join and the persist-table `UPDATE` in the stored procedure.
{% enddocs %}


{# ---------------------------------------------------------------------------
   Changelog output columns. Shared by the int_changelog__* models and fct_product_changes.
   --------------------------------------------------------------------------- #}

{% docs changelog__change_key %}
Deterministic surrogate key: a hash of table_name, table_pk_value, column_name, record_type and
snapshot_valid_from. It replaces `CHANGELOG_SEQ.NEXTVAL`, which gave different IDs on every
rebuild. A rerun merges into the same rows instead of creating duplicates.
{% enddocs %}

{% docs changelog__table_name %}
Tracked table the change came from, e.g. `MPL_BIKES`.
{% enddocs %}

{% docs changelog__table_pk %}
Name of the tracked table's primary key column, e.g. `PRODUCT_ID`. Same meaning as `TABLE_PK`
in `MDM_CHANGELOG_TBL`.
{% enddocs %}

{% docs changelog__table_pk_value %}
Primary key value of the changed record, as text. The column in `table_pk` holds this value.
{% enddocs %}

{% docs changelog__product_id %}
Filled only when the tracked table is keyed on `PRODUCT_ID`, otherwise NULL.
{% enddocs %}

{% docs changelog__item_id %}
Filled only when the tracked table is keyed on `ITEM_ID`, otherwise NULL.
{% enddocs %}

{% docs changelog__inventory_item_id %}
Filled only when the tracked table is keyed on `INVENTORY_ITEM_ID`, otherwise NULL (DATA-8515).
{% enddocs %}

{% docs changelog__fob_id %}
Filled only when the tracked table is keyed on `FOB_ID`, otherwise NULL (DATA-8515).
{% enddocs %}

{% docs changelog__sku %}
SKU of the record. Taken from the table's SKU column when it has one, even if SKU isn't the
primary key. If the primary key is SKU, it's taken from the key.
{% enddocs %}

{% docs changelog__column_name %}
Name of the changed column for UPDATE rows, e.g. `MSRP`. `ALL` for record-level NEW and DELETE rows.
{% enddocs %}

{% docs changelog__old_value %}
Value before the change, as text. NULL on NEW / DELETE rows, and when the column was previously empty.
{% enddocs %}

{% docs changelog__new_value %}
Value after the change, as text. NULL on NEW / DELETE rows, and when the column was emptied.
{% enddocs %}

{% docs changelog__change %}
Difference between the new and old value, as text:
- **Numbers**: new minus old, e.g. `-500`.
- **Dates / timestamps**: day difference with a suffix, e.g. `14 days`.
- **NULL** for text columns, columns ending in `_ID`, columns in `cols_to_exclude_change_diff`,
  and whenever either value is NULL.
{% enddocs %}

{% docs changelog__change_percent %}
(new - old) / old, rounded to 4 decimals. For example, `-0.0588` means a 5.88% decrease. Numbers
only. NULL when the old value is 0 or NULL, and for every non-numeric column.
{% enddocs %}

{% docs changelog__record_type %}
`NEW`, `UPDATE` or `DELETE`. See the project overview for what each one means.
{% enddocs %}

{% docs changelog__change_date %}
When the change happened. For NEW and UPDATE rows it's the table's watermark column (e.g.
`last_update`). For DELETE rows, and for tables without a watermark, it's the snapshot time.
{% enddocs %}

{% docs changelog__system_of_change %}
Source system of the tracked table: `MPL` or `ORACLE`.
{% enddocs %}

{% docs changelog__snapshot_valid_from %}
When the snapshot captured the version. `fct_product_changes` uses it to pick up only new
versions on each incremental run.
{% enddocs %}

{% docs changelog__load_date %}
When the row was last merged into `fct_product_changes`.
{% enddocs %}
