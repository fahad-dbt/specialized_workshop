# Plan: Rebuild SP_BUILD_MDM_CHANGELOG as a dbt project

Status: planning only. Nothing here has been executed.

## Context
`SP_BUILD_MDM_CHANGELOG` (v1.4.0, Snowpark Python) builds `MDM_CHANGELOG_TBL` one table at a time. It has these problems:
- **Full re-scan per column.** It re-scans the whole SCD2 persist table, and re-runs the wide `LAG` query once per tracked column in the UNION ALL unpivot. That is N+1 scans, and each column recomputes `LAG` 3 times.
- **Hand-managed state.** Incremental state is `MAX(change_date)`, an anti-join on `existing_records`, and `CHANGELOG_LAST_RUN` in `ETL_PERSIST_LAYER_CONFIG`.
- **Config lives in a database table.** The `changelog_flag` lives in `ETL_PERSIST_LAYER_CONFIG`, and the PK comes from `SHOW PRIMARY KEYS`.
- **Side effects inside the procedure.** It updates the changelog (`RECORD_TYPE='DELETE'`) and the persist table, and it uses `CHANGELOG_SEQ.NEXTVAL`.
- **No tests, no lineage, no CI.** Every change is a `CREATE OR REPLACE PROCEDURE` with a version comment.

Goal: a declarative dbt implementation. It is incremental and idempotent. Adding a table is one thin model plus YAML. Logic is covered by unit tests and data tests.

Assumptions (flag if wrong):
- The persist tables stay in Snowflake as SCD2 (`SCD_START_DATE`, `SCD_ACTIVE_FLAG`).
- The `<TABLE>_FULL_TEMP` tables stay in `<DB>.WORKING`.
- The persist-table delete update (SP step 8) stays in Matillion, not dbt.

## Project layout
```
models/
  sources/_plm__sources.yml            # persist tables + *_FULL_TEMP, freshness, PK/meta config
  intermediate/changelog/
    int_changelog__<table>.sql         # 8 thin models: {{ changelog_versions(source(...)) }}   (NEW/UPDATE)
    int_changelog_deletes__<table>.sql # 8 thin models: {{ changelog_deletes(source(...)) }}   (DELETE)
    _int_changelog.yml                 # tests
  marts/
    mdm_changelog.sql                  # incremental table: union of all int_ models (replaces MDM_CHANGELOG_TBL)
    mdm_changelog_v.sql                # view: event tracking / SVOP enrichment (replaces MDM_CHANGELOG_V)
    _marts.yml
macros/changelog/
  get_tracked_columns.sql
  changelog_versions.sql
  changelog_deletes.sql
  change_calc.sql
  changelog_key_columns.sql
  changelog_validate_config.sql
tests/generic/  tests/singular/  unit tests in _int_changelog.yml
dbt_project.yml  (vars: cols_to_exclude, cols_to_exclude_change_diff, changelog_go_live_ts)
```

## Mapping: stored procedure section → dbt object

| SP section | What it does today | dbt object | How |
|---|---|---|---|
| 1. Constants: normalize params, `changelog_table`, `PLM` vs `PLM_DEV` | Uppercases params and picks the target DB by parameter | `dbt_project.yml` + `profiles`/targets | `target.database` replaces `CHANGELOG_DB`. `dev` and `prod` targets replace the `DAF_METADATA` vs `DAF_METADATA_DEV` switch. |
| 1. `cols_to_exclude`, `cols_to_exclude_change_diff` | Hardcoded Python lists | `vars:` in `dbt_project.yml`, read by macros | One place to change. Reviewable in a PR. |
| 2. Read `source_system_name`, `watermark_col`, `changelog_flag` from `ETL_PERSIST_LAYER_CONFIG` | A config-table lookup per run | Source YAML `meta:` per table: `source_system_name`, `watermark_column`, `pk`, `soft_delete_column` | Tracked tables are exactly the ones that have an `int_changelog__*` model, so no flag is needed. The default for a missing watermark (`SCD_START_DATE`) lives in `changelog_versions`. |
| 2. `changelog_flag = FALSE` → Teams alert + exit | Runtime guard | **Macro** `changelog_validate_config` (`exceptions.raise_compiler_error`) | It fails at compile time if `meta.pk` or `meta.source_system_name` is missing. Alerts come from dbt job failure notifications to `#alert-snowflake`. |
| 2. `max_change_date` = max of changelog and `CHANGELOG_LAST_RUN` | Hand-rolled watermark | `mdm_changelog` `materialized='incremental'`, `incremental_strategy='merge'`, `unique_key='change_key'`, `{% if is_incremental() %}` filter on `change_date >= (select max(change_date) from {{ this }})` minus a lookback | The merge key makes reruns idempotent. The lookback removes the need for `CHANGELOG_LAST_RUN` and the `existing_records` anti-join. |
| 2. 1900-01-01 default and "skip NEW on initial load" (and the manual delete of fake NEW rows at go-live) | Special-cases the first run | `var('changelog_go_live_ts')` plus a macro filter | Emit NEW rows only when `change_date >= go_live`. A full refresh then never produces fake NEWs. |
| 3. `SHOW PRIMARY KEYS` | PK discovered at runtime, with an alert if missing | Source `meta.pk` plus generic test `changelog_pk_defined` plus `unique`/`not_null` on the source column | The PK is declared in version control. `unique`/`not_null` on the active record (`scd_active_flag`) verifies it is real. |
| 4. `INFORMATION_SCHEMA.COLUMNS` minus excluded minus `SK_%` | Dynamic column list with data types | **Macro** `get_tracked_columns(relation)` using `adapter.get_columns_in_relation`, filtered by `var('cols_to_exclude')`, `^SK_`, and the PK | Returns (name, data_type) pairs at compile time. |
| 4. `has_sku` / `sku_expr`; `PRODUCT_ID`, `ITEM_ID`, `INVENTORY_ITEM_ID`, `FOB_ID` CASE columns | Derived key columns | **Macro** `changelog_key_columns(pk, tracked_cols)` | One definition, shared by the NEW/UPDATE and DELETE paths. Adding a new key column (as DATA-8515 did) is a one-line change. |
| 4. `LAG` per column, `PREV_<col>`, `'NO CHANGE'` sentinel | N×3 window evaluations | **Macro** `changelog_versions`: a CTE `versions` that computes `LAG(OBJECT_CONSTRUCT_KEEP_NULL(<tracked cols>)) OVER (PARTITION BY pk ORDER BY scd_start_date)` once, then `LATERAL FLATTEN` of current vs previous object | The table is scanned once and `LAG` runs once. It emits one row per changed column, so no N-way UNION ALL and no `'NO CHANGE'` string. |
| 4. Change / Change % by data type, `_ID` and `DISPLAY_ORDER`/`UPDATE_USER` exclusions | Generated per-column CASE expressions | **Macro** `change_calc(column_name, data_type)`: numeric returns diff and ROUND(diff/prev, 4); date/timestamp returns `DATEDIFF('day')||' days'`; everything else returns NULL | Compile-time data types drive one `CASE column_name WHEN ...` expression. Unit-tested. |
| 4. `record_type` NEW vs UPDATE (`LAG(pk) IS NULL`) | First SCD version = NEW | In `changelog_versions`: `row_number() = 1` gives NEW (`COLUMN_NAME='ALL'`, NULL old/new), otherwise UPDATE | The same CTE feeds both record types. |
| 5. `wide_sql`, row-count check, unpivot, `UNION ALL` | One giant dynamic SQL per table | 8 `int_changelog__<table>` models, each calling `changelog_versions(source(...))`, plus `mdm_changelog` unioning them with `dbt_utils.union_relations` | Parallel, individually selectable (`dbt build -s int_changelog__mpl_bikes+`). No "no rows → exit" branch is needed, because an empty incremental run is a no-op. |
| 5. `CHANGELOG_SEQ.NEXTVAL` as `CHANGE_ID` | A sequence, non-deterministic | `change_key = dbt_utils.generate_surrogate_key(['table_name','table_pk','column_name','record_type','scd_start_date'])`. Consumers that need a numeric `CHANGE_ID` get it in the view. | Deterministic keys allow idempotent merges. |
| 6. Delete detection: active persist rows with no match in `<T>_FULL_TEMP` | Anti-join, then `DELETE` rows with `COLUMN_NAME='ALL'` | **Macro** `changelog_deletes(source, full_temp_source)` and the 8 `int_changelog_deletes__<table>` models | Detects a row as deleted when it is active but missing from FULL_TEMP, **or** when it has `deleted=true`/`scd_end_date` recently set. Both branches are idempotent whichever of dbt or Matillion runs first. |
| 7. `INSERT INTO MDM_CHANGELOG_TBL ... FROM unpivot` | Append with a row count return | `mdm_changelog` incremental merge | The insert count comes from the dbt run results. |
| 8a. `UPDATE changelog SET RECORD_TYPE='DELETE' WHERE COLUMN_NAME='DELETED' AND NEW_VALUE='Y'` (`MPL_EQUIPMENT`, `MPL_EQUIP_SKUS`) | A post-insert update | In `changelog_versions`: `record_type = CASE WHEN column_name = meta.soft_delete_column AND new_value = 'Y' THEN 'DELETE' ELSE 'UPDATE' END` | It is set at write time, with no UPDATE and no race. |
| 8b. `UPDATE persist SET deleted=true, scd_active_flag=false, scd_end_date=now()` | Writes back to the source layer | **Not in dbt.** It stays in the Matillion persist job (or an ingestion post-step). | dbt does not mutate sources. The `changelog_deletes` OR-condition above removes the ordering dependency. |
| 8c. `CHANGELOG_LAST_RUN` in `ETL_PERSIST_LAYER_CONFIG` | Last-run bookkeeping | dbt artifacts (`run_results.json`) and `{{ this }}` max timestamp | Retire the column after cutover. |
| `MDM_CHANGELOG_V` (event tracking, SVOP enrichment: future) | A view over the table | `mdm_changelog_v` (view) | The SVOP join is added here later, without touching the changelog logic. |
| Matillion `CALL_MDM_CHANGELOG_QUERY`, `MDM_CHANGELOG_DELETE_QUERY` (biweekly) | Orchestrate per-table SP calls | A dbt job that runs `dbt build -s tag:changelog` (NEW/UPDATE) and `-s tag:changelog_deletes` (separate schedule if the biweekly cadence stays). Matillion just triggers the job. | The loop over tables disappears because the DAG handles it. |

## Efficiency gains (why this is faster)
- One scan and one `LAG` per table, instead of 1 + N scans and 3N `LAG`s.
- Incremental merge on `scd_start_date` (with lookback) instead of `SELECT DISTINCT` over the full history on every run.
- The 8 tables build in parallel threads. The Python procedure is serial.
- No per-run `INFORMATION_SCHEMA`, `SHOW PRIMARY KEYS`, or config-table queries. Columns are resolved at compile time.
- No post-insert `UPDATE`s on a growing table.

## Tests

**Generic (reusable, in YAML):**
- `unique_combination_of_columns` on `mdm_changelog (table_name, table_pk, column_name, record_type, change_date)`, or `unique` on `change_key`.
- `not_null` on `table_name`, `table_pk`, `record_type`, `change_date`, `system_of_change`, `change_key`.
- `accepted_values` on `record_type` (NEW, UPDATE, DELETE) and `table_name` (the 8 tables).
- Custom `changelog_pk_defined`: source `meta.pk` is set and exists as a column. This replaces the NO_PK_FOUND alert.
- `unique`/`not_null` on the PK of each source among active rows (`where: scd_active_flag`).
- Source freshness on watermark columns, to catch the "missing watermark" case.

**Singular (SQL in `tests/singular/`):**
- `assert_no_new_before_go_live`: no NEW rows with `change_date < changelog_go_live_ts`.
- `assert_update_has_distinct_old_new`: UPDATE rows have `old_value is distinct from new_value`.
- `assert_all_rows_have_null_values`: NEW/DELETE rows (`column_name='ALL'`) have null old/new/change.
- `assert_delete_matches_missing_in_full_temp`: every DELETE PK is absent from FULL_TEMP or has `deleted=true`.
- `assert_changelog_reconciles_to_scd`: the count of distinct (PK, version) transitions in the source equals the distinct changed (PK, version) in the changelog. This catches silently dropped changes.
- `assert_soft_delete_flag_mapped`: for `MPL_EQUIPMENT` and `MPL_EQUIP_SKUS`, every `DELETED`=Y change has `record_type='DELETE'`.

**Unit tests (dbt ≥1.8 `unit_tests:`) on the `int_` models with mock SCD2 rows:**
- number change and change %, including prev = 0 (percent NULL).
- date and timestamp day diff with the ` days` suffix.
- NULL→value is captured, and value→NULL is captured.
- `_ID`, `DISPLAY_ORDER` and `UPDATE_USER` columns get NULL change.
- the first version gives NEW with `ALL`.
- `SKU` derivation when SKU is, and is not, the PK.
- `DELETED` N→Y gives DELETE, and NULL→N stays UPDATE.

## Software-engineering practices
- Everything in git with PR review and CI (`dbt build --select state:modified+ --defer`) against `PLM_DEV`.
- `contract: enforced` on `mdm_changelog` and `mdm_changelog_v` (column names and types), so Tableau cannot break silently.
- `meta`/`owner`/descriptions and `exposures` for the Tableau datasource (once it exists).
- Slim CI plus a scheduled prod job. Failure notifications go to `#alert-snowflake`.
- Cutover: run dbt in `PLM_DEV` beside the SP and diff outputs (row counts by table and column, `EXCEPT` on keys). Set `changelog_go_live_ts`, backfill with a full refresh, then retire the SP, the Matillion loop and `CHANGELOG_LAST_RUN`.

## Critical files and reuse
- Reference logic: `specialized_workshop/current_process/SP_BUILD_MDM_CHANGELOG.sql`.
- Spec: `specialized_workshop/current_process/DATA-DE ID - MDM - Product Change Reporting.md`.
- New dbt project directory (to be decided at implementation).
- Reuse the `dbt_utils` package (`union_relations`, `generate_surrogate_key`, `unique_combination_of_columns`).

## Verification
1. `dbt parse` / `dbt compile -s int_changelog__mpl_bikes`, and inspect the compiled SQL against the SP's `wide_sql`.
2. `dbt build --target dev -s tag:changelog+`: unit tests, then data tests.
3. Parity check: for each of the 8 tables, compare `PLM_DEV.PUBLIC.MDM_CHANGELOG_TBL` (SP output) with the dbt output. Diff on `(table_name, table_pk, column_name, old_value, new_value, record_type, change_date)`.
4. Idempotency: run twice, and the row count must be unchanged. Insert a new SCD version into a dev persist table, rerun, and expect exactly the changed columns.
5. Delete path: remove a PK from a `_FULL_TEMP` table and expect one `DELETE/ALL` row. Run again and expect no duplicate.
6. Timing comparison: SP vs `dbt build` per table.

## Open questions for implementation
- Is a numeric `CHANGE_ID` required downstream, or is the hash key fine?
- Should deletes keep the biweekly cadence, or run with every changelog run?
- Does a dbt project exist (or should one be created) in the DE repo or `de-snowflake`?

---

# dbt 101 for the authors of the stored procedure

Audience: the engineers who wrote `SP_BUILD_MDM_CHANGELOG`. They know the problem well. This section teaches each dbt primitive and anchors it to something they already built. It runs in the order data flows: source, then model, then mart.

**Thesis:** the stored procedure is a program that *writes SQL and changes state*. dbt is a project that *declares the tables you want* and lets the framework handle ordering, incrementality and testing.

## 1. Source: "where the data starts"
- **dbt concept.** A *source* is a YAML declaration of a raw table you did not build. Models reference it with `{{ source('plm', 'mpl_bikes') }}`.
- **In the SPROC.** Step 1 builds the table name from parameters (`f"{DATABASE_NAME}.{SCHEMA_NAME}.{TABLE_NAME}"`) and step 2 reads `source_system_name` and `watermark_col` from `ETL_PERSIST_LAYER_CONFIG`.
- **In dbt.** The 8 persist tables and 8 `_FULL_TEMP` tables are declared once. The values from the config table become `meta:` on each source.
- **Why it matters.** Lineage appears in the docs graph, and *source freshness* checks the watermark columns (the DATA-8515 "missing watermark" case).

## 2. Configuration: "settings live in files, not in code"
- **dbt concept.** `dbt_project.yml` holds `vars` and *targets* (dev/prod) hold connection settings.
- **In the SPROC.** `cols_to_exclude`, `cols_to_exclude_change_diff`, and the `PLM` vs `PLM_DEV` switch (`def_metadata_table`).
- **In dbt.** The lists become `vars`. `target.database` replaces the `CHANGELOG_DB` parameter.
- **Why it matters.** A change to an exclusion list is a one-line pull request, not a new procedure version.

## 3. Model: "a SELECT statement is a table"
- **dbt concept.** A *model* is a `.sql` file containing one `SELECT`. dbt wraps it in `CREATE TABLE/VIEW` and orders models by their `ref()`/`source()` dependencies, which forms the DAG.
- **In the SPROC.** Step 5 builds one giant SQL string per table, run by a Matillion loop.
- **In dbt.** Each tracked table gets a three-line model, `int_changelog__<table>`. dbt runs the 8 models in parallel.
- **Why it matters.** `dbt build -s int_changelog__mpl_bikes+` runs one table and everything downstream. Adding a table is a YAML entry plus two small files.

## 4. Macro: "a function that writes SQL"
- **dbt concept.** A *macro* is a Jinja function that returns SQL text at **compile time**. You can see the result in `target/compiled/` before it touches data.
- **In the SPROC.** The Python loops in step 4 (`for c, dt in tracked_cols`) that build `select_exprs`, `change_expr` and `change_pct_expr` are macros in everything but name.
- **In dbt.** They become named, reusable macros:
  - `get_tracked_columns` replaces the `INFORMATION_SCHEMA` query and the `SK_` / exclusion filters.
  - `changelog_key_columns` replaces the `SKU`, `PRODUCT_ID`, `ITEM_ID`, `INVENTORY_ITEM_ID`, `FOB_ID` CASE lines.
  - `change_calc` replaces the Change and Change % rules.
  - `changelog_versions` and `changelog_deletes` replace the two big `if not DELETED / else` branches.
- **Why it matters (DRY).** The SPROC repeats the key-column CASE block in the UPDATE/NEW path and again in the DELETE path. A macro is written once, so DATA-8515 would have been a one-line diff.
- **Compile time vs run time.** The SPROC discovers columns while it runs. dbt discovers them first, so you can diff the SQL without running it.

## 5. Change detection: "think in sets, not loops"
- **Concept.** Prefer a set-based query over generating SQL that grows with the number of columns.
- **In the SPROC.** Each tracked column gets a `PREV_<col>` CASE with three `LAG()` calls, a `'NO CHANGE'` string, and its own `UNION ALL` branch. That is about 3N window functions and N+1 scans.
- **In dbt.** One `LAG` over an object of all tracked columns, then `LATERAL FLATTEN` and compare with `IS DISTINCT FROM`. Each changed column becomes one row.
- **Why it matters.** Faster, shorter generated SQL, and NULL→value and value→NULL are handled the same way.

## 6. Materialization and incremental models: "dbt owns the table"
- **dbt concept.** *Materializations* decide how a model is stored: `view`, `table`, or `incremental`. An incremental model with a `unique_key` *merges* only new or changed rows on each run.
- **In the SPROC.** Step 2 computes `max_change_date`, step 5 anti-joins `existing_records`, step 7 runs `INSERT`, and step 8 writes `CHANGELOG_LAST_RUN`.
- **In dbt.** `mdm_changelog` is `incremental` with `unique_key='change_key'`. The watermark is `max(change_date)` from `{{ this }}` minus a small lookback, with no config-table write.
- **Why it matters (idempotency).** Running it twice gives the same table. Late rows merge instead of duplicating.

## 7. Surrogate keys: "determinism beats sequences"
- **dbt concept.** `dbt_utils.generate_surrogate_key` hashes columns into a stable key.
- **In the SPROC.** `CHANGELOG_SEQ.NEXTVAL` assigns `CHANGE_ID`, which differs on every rebuild.
- **In dbt.** `change_key` is a hash of (`table_name`, `table_pk`, `column_name`, `record_type`, `scd_start_date`). A numeric `CHANGE_ID` can still be derived in the view if downstream needs it.
- **Why it matters.** A rebuild produces the same keys, which makes backfills, comparisons and merges safe.

## 8. Tests: "assertions that run every time"
- **dbt concept.** *Generic tests* (`unique`, `not_null`, `accepted_values`) and *singular tests* (a SQL file that returns the rows that should not exist). *Unit tests* feed mock input to a model and check its output.
- **In the SPROC.** Guards: the `changelog_flag` check and the `NO_PK_FOUND` alert. Nothing checks the output.
- **In dbt.**
  - Unit tests for the Change % rules, the NULL transitions, the `SKU` rule and the `DELETED` rule.
  - `unique` and `not_null` on `change_key` and on source PKs among active rows.
  - Singular tests: no NEW rows before go-live, and the changelog reconciles to the SCD2 history.
- **Why it matters.** The v1.3 fix "Change % should be a NUMBER, not VARCHAR" would have been a failing test, not a production surprise.

## 9. Validation at compile time: "fail early"
- **dbt concept.** A macro can call `exceptions.raise_compiler_error`, and CI can run on every pull request.
- **In the SPROC.** Missing flag or PK sends a Teams alert and raises, but only after the job has started.
- **In dbt.** `changelog_validate_config` fails the compile if `meta.pk` is missing. Failed production jobs notify `#alert-snowflake`.
- **Why it matters.** Bad configuration is caught in the PR, not at 2 a.m.

## 10. Separating "derive" from "mutate": deletes
- **dbt concept.** Models read sources and write only their own output. They do not update source tables.
- **In the SPROC.** Step 6 finds deletes by anti-joining the persist table to `<T>_FULL_TEMP`. Step 8 then *updates the persist table* (`deleted`, `scd_active_flag`, `scd_end_date`). If a run fails between the two, the same delete can be emitted twice.
- **In dbt.** `changelog_deletes` reports deletes when a row is active but missing from FULL_TEMP **or** already marked deleted. The merge key makes it safe in either order. The persist-table update stays in Matillion.
- **Why it matters.** No ordering dependency, no duplicates, and each layer owns its own writes.

## 11. Removing post-hoc fix-ups: the `DELETED` flag
- **In the SPROC.** After the insert, `UPDATE changelog SET RECORD_TYPE='DELETE' WHERE COLUMN_NAME='DELETED' AND NEW_VALUE='Y'`. That is a second pass over a large table, for two tables out of eight (DATA-8961).
- **In dbt.** `meta.soft_delete_column` in the source YAML, and the model sets `record_type` correctly when it writes the row.
- **Why it matters.** The rule becomes data and a test, not an extra statement.

## 12. The go-live problem
- **In the SPROC.** `1900-01-01` suppresses NEW rows on the first run, and the runbook says "delete all NEW records when we push to PROD".
- **In dbt.** A `changelog_go_live_ts` variable and a test, `assert_no_new_before_go_live`.
- **Why it matters.** A one-off operational step becomes configuration plus a permanent check. A full refresh can never recreate the fake NEW rows.

## 13. Mart and contracts: "the part Tableau sees"
- **dbt concept.** A *mart* is the final, consumer-facing model. A *contract* (`contract: enforced`) fixes its column names and types. An *exposure* documents who depends on it.
- **In the SPROC.** `MDM_CHANGELOG_TBL` is the output and `MDM_CHANGELOG_V` is a view on top, with SVOP enrichment still to come.
- **In dbt.** `mdm_changelog` (incremental table with a contract) and `mdm_changelog_v` (view for event tracking and future SVOP).
- **Why it matters.** SVOP is added to the view later without touching the changelog logic, and Tableau cannot be broken by a silent column change.

## 14. Working like software engineers
- **Git and pull requests** replace `CREATE OR REPLACE PROCEDURE` and the `# Last update:` comment block.
- **CI** runs `dbt build --select state:modified+ --defer` in `PLM_DEV` on every pull request.
- **Docs** (`dbt docs generate`) give lineage and column descriptions for free.
- **Parity check before cutover.** Run the SPROC and dbt side by side and compare outputs with `EXCEPT` in both directions. Then set the go-live timestamp, full-refresh, switch Matillion to trigger the dbt job, and retire the procedure.

## One-slide summary

| SPROC piece | dbt primitive |
|---|---|
| Parameters, constants, `PLM` vs `PLM_DEV` | `vars`, targets |
| `ETL_PERSIST_LAYER_CONFIG` lookup | Source `meta` |
| `SHOW PRIMARY KEYS` and alerts | `meta.pk`, compile-time errors, tests |
| Python loops that build SQL | Macros |
| One giant SQL string per table | Models in a DAG |
| `max_change_date`, anti-join, `INSERT` | Incremental model with `unique_key` |
| `CHANGELOG_SEQ.NEXTVAL` | Surrogate key |
| Delete branch and persist update | Delete model, with the update kept in ingestion |
| Post-insert `UPDATE`s | Logic inside the model |
| `MDM_CHANGELOG_TBL` and `_V` | Mart with a contract, plus a view |
| Version comments | Git, pull requests, CI, tests |
