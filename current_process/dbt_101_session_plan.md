Session 1: SPROCS to Models

1. Show their proc and the 4 steps, then show the same 4 steps in the linage graph for dbt.  Explain that a dbt model is just a select statement  and dbt abstracts the ddl and runs it for you
2. 
    1. Load the mpl_bikes seed and build a stg model from it (simulating source to stg), you can use this to show how ref() works.
    2. Write the int changlog for 3 columns msrp and launch date with LAG, and change and %change.  Don’t use jinja 
    3. Run dbt build > show the compiled sql and the lineage graph 
In the SPROC the sql only exists as a string in python at runtime (they are dynamically creating the procedure (remember my BICC merge?), with dbt you can see and test the exact sql before it runs, makes debug way better and the process less brittle

 Session 2: Sproc to Mart

1. Show snapshot explain that snapshot saves them a bunch of steps instead of a merge of their persist table, the Full_temp comparison and the delete job.
Explain dbt_valid_from, valid_to etc.
-right now they have 3 moving parts split between matillion and the SPROC, deletes run once a week??? WILD
2. Changlog model reads from the snapshot.  Avoid the wide_sql string they build in python that’s a mess.  Good opportunity to show full lineage, we know what’s happening here
3. Show macros now how their mess of f-strings and looping becomes a simple macro that is called with 1 line in the intermediate model
4. Show how dbt a new table added to the system is 4 small .sql files/nodes on the graph, each lane for each table is independent and can be parallelized (not sequential like proc)
5. Show incremental mart logic
6. Show how our tests are way better than their teams alerts after all is ran.  We can alert based on Test failure.  This is ez money slam dunk
7. DELETED = Y, put this in the macro and show them it again and say.  Now we don’t need to UPDATE after the insert against the whole changlog table for every dam table 

Session 3: How to run the pipeline 

1. Dev/prod environments in dbt platform vs if/else logic in SPROC
2. Parallel job running vs matillion iterating over each table at a time (find this in the model timing tab, increase threads to 8 so you can max parellalize)
    1. If they come with an objection on this “oh we have to run it one at a time because of XYZ…” just say oh yeah this was just to be representative of your project, not the exact same thing - but this shows you the possibilites over SPROCs because now you can easily parallelize things instead of running things sequentially which saves time and money blah blah…
3. GIT + CI vs SPROC with change history commented at top (EZ MONEY).  GIVE CI demo (know impact of your change prior to merging.  View impact at the row level (AdvancedCI) EZ MONYYYY)
4. Build a metric off something, show semantic layer in graph and query it or something.


---

Prep:

Build project with 3 branches: each session builds on another

---

## Why These Seeds (3 + 1)

Each of the 3 core tables shows something different, and the 4th shows how easy it is to add a table:

- **mpl_bikes:** NEW, UPDATE and DELETE, plus the change math
- **mpl_equipment:** the `DELETED = Y` rule
- **oracle_items:** the second source system, with a different key
- **mpl_bike_fobs (+1):** adds no new rules, so the demo is just "4 files and you're done"

Three is the fewest tables that covers every rule and still visibly runs in parallel.

---

## Proposed Lineage by End of Session

### End of Session 1

```
mpl_bikes ─► stg_mpl__bikes ─► int_changelog__mpl_bikes
```

| Node | Type | Tests | Macros / Jinja |
|---|---|---|---|
| `mpl_bikes` | seed | | |
| `stg_mpl__bikes` | view | | `ref()` |
| `int_changelog__mpl_bikes` | view, hand-written SQL | | `ref()` |

### End of Session 2

```
mpl_bikes     ─► stg_mpl__bikes     ─► snp_mpl_bikes     ─► int_changelog__mpl_bikes     ─┐
                                                                                          │
mpl_equipment ─► stg_mpl__equipment ─► snp_mpl_equipment ─► int_changelog__mpl_equipment ─┼─► fct_product_changes
                                                                                          │
oracle_items  ─► stg_oracle__items  ─► snp_oracle_items  ─► int_changelog__oracle_items  ─┘
```

| Node | Type | Tests | Macros / Jinja |
|---|---|---|---|
| `mpl_bikes`, `mpl_equipment`, `oracle_items` | seed | | `column_types` config |
| `stg_mpl__bikes`, `stg_mpl__equipment` | view | `unique` + `not_null` on `product_id` | `var('load_day')` |
| `stg_oracle__items` | view | `unique` + `not_null` on `inventory_item_id` | `var('load_day')` |
| `snp_*` (3) | snapshot (`check`, `hard_deletes: new_record`) | | |
| `int_changelog__*` (3) | view | | `build_changelog` |
| `fct_product_changes` | incremental | `accepted_values` on `record_type`, `not_null` on `change_date` | `is_incremental()`, loop over table list |

Not in the DAG: `reset_demo` macro (prep only). The `s2-broken` branch fails the `unique` test on `stg_mpl__bikes`.

### End of Session 3

```
  mpl_bikes     ─► stg_mpl__bikes     ─► snp_mpl_bikes     ─► int_changelog__mpl_bikes     ─┐
                                                                                            │
  mpl_equipment ─► stg_mpl__equipment ─► snp_mpl_equipment ─► int_changelog__mpl_equipment ─┤
                                                                                            ├─► fct_product_changes
  oracle_items  ─► stg_oracle__items  ─► snp_oracle_items  ─► int_changelog__oracle_items  ─┤
                                                                                            │
+ mpl_bike_fobs ─► stg_mpl__bike_fobs ─► snp_mpl_bike_fobs ─► int_changelog__mpl_bike_fobs ─┘


time_spine_daily ──────┐
fct_product_changes ───┴─► metrics (4) ─► product_change_report (exposure)
```

New since Session 2:

| Node | Type | Tests | Macros / Jinja |
|---|---|---|---|
| `mpl_bike_fobs` lane | seed > view > snapshot > view | `unique` + `not_null` on `fob_id` | `var('load_day')`, `build_changelog` |
| `fct_product_changes` | incremental + semantic model | same as Session 2 | 1 line added to table list |
| `time_spine_daily` | table | | `dbt.date_spine` |
| metrics: `product_changes`, `new_products`, `deleted_products`, `avg_msrp_change_pct` | Semantic Layer | | metric filters (`Dimension()`) |
| `product_change_report` | exposure (dashboard) | | depends on `fct_product_changes` + `product_changes` |

Platform objects (not in the DAG):

| Object | Replaces |
|---|---|
| Dev + prod environments | `CHANGELOG_DB` / `DAF_METADATA_DEV` |
| Prod job (`dbt build`, 8 threads, notifications) | Matillion jobs + Teams alerts |
| CI job (runs on PRs) | Editing the sproc in place |
