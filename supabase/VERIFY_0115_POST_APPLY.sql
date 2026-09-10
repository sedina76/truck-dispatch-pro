-- Run AFTER applying 0115_mileage_concept_separation.sql.
--
-- Read-only except for one disposable, rolled-back fixture block at the
-- end (standard pattern for this engagement) -- nothing here persists,
-- and no existing loads row is ever modified.

begin;

-- 1. Confirm the new columns exist with the expected shape.
select column_name, data_type, numeric_precision, numeric_scale, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'loads'
  and column_name in ('total_miles', 'route_miles', 'route_miles_calculated_at', 'actual_miles', 'actual_miles_recorded_at')
order by column_name;
-- expect: total_miles unchanged (numeric(8,2), nullable); route_miles and
-- actual_miles both numeric(8,2), nullable; the two _at columns both
-- timestamptz, nullable.

-- 2. Confirm NOTHING was backfilled -- every existing row's route_miles/
--    actual_miles must be NULL (0115 never computes or guesses a value
--    for historical loads), and every row's total_miles is untouched
--    (compare these counts against VERIFY_0115_PREFLIGHT.sql section 3 --
--    they must be IDENTICAL).
select
  count(*) as total_loads_count,
  count(total_miles) as loads_with_contracted_miles,
  count(route_miles) as loads_with_route_miles,
  count(actual_miles) as loads_with_actual_miles
from public.loads;
-- expect: total_loads_count and loads_with_contracted_miles identical to
-- the preflight snapshot; loads_with_route_miles = 0; loads_with_actual_miles = 0.

-- 3. LD-100023 specifically -- total_miles must be byte-for-byte
--    unchanged from the preflight snapshot; route_miles/actual_miles
--    must both be NULL (0115 does not touch this record).
select id, load_number, total_miles, route_miles, actual_miles, created_at, updated_at
from public.loads
where load_number = 'LD-100023';
-- expect: total_miles/created_at/updated_at identical to the preflight
-- snapshot; route_miles and actual_miles both null.

-- 4. Check constraints reject a negative value for either new column,
--    and accept a valid non-negative one -- disposable fixture, rolled
--    back unconditionally at the end.
do $$
declare
  v_org_id uuid;
  v_load_id uuid;
begin
  select id into v_org_id from public.organizations limit 1;
  if v_org_id is null then
    raise exception 'No organization exists to scope a disposable test fixture under -- cannot run this verification.';
  end if;

  insert into public.loads (organization_id, load_number, status)
  values (v_org_id, 'TEST-0115-MILEAGE', 'draft')
  returning id into v_load_id;

  begin
    update public.loads set route_miles = -5 where id = v_load_id;
    raise notice 'POST-APPLY (route_miles rejects negative): FAIL -- a negative route_miles value was accepted.';
  exception when others then
    raise notice 'POST-APPLY (route_miles rejects negative): PASS -- REJECTED (%).', sqlerrm;
  end;

  begin
    update public.loads set actual_miles = -5 where id = v_load_id;
    raise notice 'POST-APPLY (actual_miles rejects negative): FAIL -- a negative actual_miles value was accepted.';
  exception when others then
    raise notice 'POST-APPLY (actual_miles rejects negative): PASS -- REJECTED (%).', sqlerrm;
  end;

  begin
    update public.loads set route_miles = 1189.8, route_miles_calculated_at = now(), actual_miles = 1195.2, actual_miles_recorded_at = now() where id = v_load_id;
    raise notice 'POST-APPLY (valid non-negative values accepted): PASS -- route_miles/actual_miles both set successfully.';
  exception when others then
    raise notice 'POST-APPLY (valid non-negative values accepted): FAIL -- a valid, non-negative value was unexpectedly rejected (%).', sqlerrm;
  end;

  -- Confirm total_miles (contracted_miles) is untouched by any of the
  -- above -- these are genuinely separate columns, never cross-written.
  if (select total_miles from public.loads where id = v_load_id) is null then
    raise notice 'POST-APPLY (contracted miles never cross-written by route/actual updates): PASS -- total_miles remains null, exactly as this fixture created it.';
  else
    raise notice 'POST-APPLY (contracted miles never cross-written by route/actual updates): FAIL -- total_miles unexpectedly has a value.';
  end if;
end $$;

-- Discards the disposable fixture load created above, unconditionally.
-- Nothing from this script persists.
rollback;
