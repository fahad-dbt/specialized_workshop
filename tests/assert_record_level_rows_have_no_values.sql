-- Record-level rows (NEW / DELETE with column_name = 'ALL') carry no column values.
select *
from {{ ref('fct_product_changes') }}
where column_name = 'ALL'
  and (
      old_value is not null
      or new_value is not null
      or change is not null
      or change_percent is not null
  )
