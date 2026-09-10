-- Run BEFORE applying 0115_mileage_concept_separation.sql.
--
-- Read-only except for one disposable, rolled-back check at the end.

begin;

-- 1. Confirm route_miles/actual_miles do NOT exist yet -- 0115 must be
--    the migration that introduces them.
select
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loads' and column_name = 'route_miles') as route_miles_exists,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loads' and column_name = 'route_miles_calculated_at') as route_miles_calculated_at_exists,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loads' and column_name = 'actual_miles') as actual_miles_exists,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loads' and column_name = 'actual_miles_recorded_at') as actual_miles_recorded_at_exists;
-- expect: 0, 0, 0, 0

-- 2. Baseline: confirm total_miles's current type/nullability is
--    unchanged from 0004_operations.sql (numeric(8,2), nullable) -- 0115
--    must not alter this column at all, only add new ones alongside it.
select column_name, data_type, numeric_precision, numeric_scale, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'loads' and column_name = 'total_miles';
-- expect: numeric, precision 8, scale 2, is_nullable = YES

-- 3. Baseline row counts, to compare against post-apply (0115 must not
--    change how many loads rows exist, or any of their total_miles
--    values).
select count(*) as total_loads_count, count(total_miles) as loads_with_contracted_miles
from public.loads;

-- 4. LD-100023's current state, captured here as a pre-migration
--    snapshot -- see VERIFY_LD100023_MILEAGE_AUDIT.sql for the full,
--    standalone diagnostic (not repeated here).
select id, load_number, total_miles, created_at, updated_at
from public.loads
where load_number = 'LD-100023';

-- 5. Disposable check: confirm the planned CHECK constraints' semantics
--    against a throwaway row before trusting them for real data -- a
--    negative mileage value must be rejected once 0115 is applied. This
--    can only meaningfully run AFTER 0115 is applied (the columns don't
--    exist yet) -- included here as a preflight-authored, ROLLED-BACK
--    placeholder so the exact check is on record; see
--    VERIFY_0115_POST_APPLY.sql for where it actually runs.
do $$
begin
  raise notice 'PREFLIGHT: negative-mileage rejection is verified post-apply (route_miles/actual_miles do not exist yet) -- see VERIFY_0115_POST_APPLY.sql.';
end $$;

rollback;
