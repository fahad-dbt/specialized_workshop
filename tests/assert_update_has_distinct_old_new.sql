-- An UPDATE row is only valid if the value actually changed.
select *
from {{ ref('fct_product_changes') }}
where record_type = 'UPDATE'
  and old_value is not distinct from new_value
