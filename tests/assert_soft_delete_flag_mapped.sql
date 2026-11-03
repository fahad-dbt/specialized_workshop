-- DATA-8961: every change of DELETED to 'Y' must be recorded as a DELETE.
-- Replaces the post-insert UPDATE in the stored procedure with a permanent check.
select *
from {{ ref('fct_product_changes') }}
where column_name = 'DELETED'
  and new_value = 'Y'
  and record_type <> 'DELETE'
