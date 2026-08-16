-- =============================================================================
-- 0047_new_load_workflow.sql
-- Atomic Load + Stops creation for the upgraded New Load screen. Reuses the
-- existing loads/load_stops tables verbatim (no new columns -- load_type,
-- PO#, pieces/pallets, temperature, hazmat all have no existing column and
-- no other part of the app reads them, so none are added here). document_type
-- already contains 'rate_confirmation' (0001) -- no enum change needed.
--
-- create_load_with_stops() is intentionally NOT security definer: it runs
-- as the calling authenticated user, so the exact same RLS policies that
-- already govern `loads`/`load_stops` (0010_rls_policies.sql: org-scoped,
-- owner/admin/dispatcher write) apply to both inserts inside it, unchanged.
-- Atomicity comes from this being a single function invocation -- Postgres
-- rolls back everything the function did if any statement inside it raises,
-- so a load can never be left behind with a partially-failed stop list (or
-- vice versa) without any manual compensating-delete logic.
-- =============================================================================

create or replace function public.create_load_with_stops(
  p_load jsonb,
  p_stops jsonb
)
returns uuid
language plpgsql
as $$
declare
  v_org_id uuid;
  v_load_id uuid;
  v_stop jsonb;
  v_stop_count integer;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'Could not determine the current organization for this user.';
  end if;

  v_stop_count := coalesce(jsonb_array_length(p_stops), 0);
  if v_stop_count = 0 then
    raise exception 'At least a pickup and a delivery stop are required.';
  end if;

  insert into public.loads (
    organization_id, load_number, broker_id, customer_id, status, commodity,
    weight_lbs, equipment_type, total_miles, rate, rate_confirmation_number,
    special_instructions, booked_by
  )
  values (
    v_org_id,
    p_load ->> 'load_number',
    nullif(p_load ->> 'broker_id', '')::uuid,
    nullif(p_load ->> 'customer_id', '')::uuid,
    coalesce(nullif(p_load ->> 'status', ''), 'draft')::public.load_status,
    nullif(p_load ->> 'commodity', ''),
    nullif(p_load ->> 'weight_lbs', '')::integer,
    nullif(p_load ->> 'equipment_type', ''),
    nullif(p_load ->> 'total_miles', '')::numeric,
    coalesce(nullif(p_load ->> 'rate', '')::numeric, 0),
    nullif(p_load ->> 'rate_confirmation_number', ''),
    nullif(p_load ->> 'special_instructions', ''),
    -- Dispatcher/booked-by is always the real calling user, never a
    -- client-supplied id -- prevents one dispatcher from attributing a
    -- booking to someone else.
    auth.uid()
  )
  returning id into v_load_id;

  for v_stop in select * from jsonb_array_elements(p_stops)
  loop
    insert into public.load_stops (
      organization_id, load_id, stop_type, stop_sequence, facility_name,
      address_line1, address_line2, city, state, postal_code, country,
      contact_name, contact_phone, scheduled_at, scheduled_window_end,
      reference_number, notes
    )
    values (
      v_org_id,
      v_load_id,
      (v_stop ->> 'stop_type')::public.stop_type,
      (v_stop ->> 'stop_sequence')::integer,
      nullif(v_stop ->> 'facility_name', ''),
      nullif(v_stop ->> 'address_line1', ''),
      nullif(v_stop ->> 'address_line2', ''),
      v_stop ->> 'city',
      v_stop ->> 'state',
      nullif(v_stop ->> 'postal_code', ''),
      coalesce(nullif(v_stop ->> 'country', ''), 'US'),
      nullif(v_stop ->> 'contact_name', ''),
      nullif(v_stop ->> 'contact_phone', ''),
      nullif(v_stop ->> 'scheduled_at', '')::timestamptz,
      nullif(v_stop ->> 'scheduled_window_end', '')::timestamptz,
      nullif(v_stop ->> 'reference_number', ''),
      nullif(v_stop ->> 'notes', '')
    );
  end loop;

  perform public.log_activity('load'::public.entity_type, v_load_id, 'created', p_load, v_org_id);

  return v_load_id;
end;
$$;

grant execute on function public.create_load_with_stops(jsonb, jsonb) to authenticated;
