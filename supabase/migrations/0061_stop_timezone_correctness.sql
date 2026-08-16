-- =============================================================================
-- 0061_stop_timezone_correctness.sql
-- Phase 2C.1: Stop Timezone Correctness & Appointment Timestamp Integrity.
-- Purely additive on top of 0057-0060. Does not modify, drop, or rename
-- anything from those migrations, and does NOT rewrite any existing
-- scheduled_at/scheduled_window_end value -- there is no reliable way to
-- know whether a historical instant was entered correctly, so none are
-- touched (spec section 19).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- load_stops.timezone: the IANA identifier (e.g. 'America/Chicago') the
-- stop's own scheduled_at/scheduled_window_end were converted from at
-- entry time. NULL for every existing row (spec section 19) -- the app
-- layer falls back to organizations.timezone at read time
-- (resolveStopTimezone(), src/lib/timezone/resolve.ts) rather than this
-- migration guessing a value it can't verify. Deliberately a plain text
-- column, not a Postgres enum -- IANA's zone list changes over time and a
-- Postgres enum would need a migration for every addition; application-
-- layer validation (isValidIanaTimezone(), backed by
-- Intl.supportedValuesOf('timeZone')) is authoritative, matching spec
-- section 34's explicit instruction not to encode the IANA database as a
-- CHECK constraint.
-- ---------------------------------------------------------------------------
alter table public.load_stops
  add column if not exists timezone text,
  add column if not exists timezone_source text;

alter table public.load_stops
  add constraint load_stops_timezone_not_blank
    check (timezone is null or length(trim(timezone)) > 0);

alter table public.load_stops
  add constraint load_stops_timezone_source_check
    check (timezone_source is null or timezone_source in ('manual', 'organization_default', 'geocoded', 'legacy'));

comment on column public.load_stops.timezone is 'IANA identifier (e.g. America/Chicago) this stop''s scheduled_at/scheduled_window_end were converted from. NULL means unknown/legacy -- never fabricated by this migration. Falls back to organizations.timezone at display/edit time.';
comment on column public.load_stops.timezone_source is 'How .timezone was set: manual (dispatcher picked it), organization_default (defaulted from the org at entry time), geocoded (reserved for a future coordinate-based lookup, not implemented this phase), legacy (backfilled by the office repair flow without reinterpreting the stored instant).';

comment on column public.organizations.timezone is 'IANA identifier, used as the fallback stop timezone when a stop has none of its own (spec section 3''s priority order). Existing rows default to America/Chicago from column creation, not a verified-correct value for that organization -- see Settings > Organization for validated editing (isValidIanaTimezone()) added in Phase 2C.1.';

-- ---------------------------------------------------------------------------
-- create_load_with_stops(): extended (create or replace, same function
-- signature -- see 0044_driver_portal_upgrade.sql for the identical
-- precedent of extending an existing function via a later migration
-- without touching the file that first defined it) to also persist
-- timezone/timezone_source per stop. The conversion from local wall time
-- to the correct UTC instant happens entirely in the application layer
-- (src/lib/timezone/convert.ts) BEFORE this function is ever called --
-- p_stops already carries real timestamptz-parseable UTC strings in
-- scheduled_at/scheduled_window_end, exactly as before. This function's
-- only change is no longer silently dropping the timezone that instant
-- was converted from.
-- ---------------------------------------------------------------------------
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
    auth.uid()
  )
  returning id into v_load_id;

  for v_stop in select * from jsonb_array_elements(p_stops)
  loop
    insert into public.load_stops (
      organization_id, load_id, stop_type, stop_sequence, facility_name,
      address_line1, address_line2, city, state, postal_code, country,
      contact_name, contact_phone, scheduled_at, scheduled_window_end,
      reference_number, notes, timezone, timezone_source
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
      nullif(v_stop ->> 'notes', ''),
      nullif(v_stop ->> 'timezone', ''),
      nullif(v_stop ->> 'timezone_source', '')
    );
  end loop;

  perform public.log_activity('load'::public.entity_type, v_load_id, 'created', p_load, v_org_id);

  return v_load_id;
end;
$$;

grant execute on function public.create_load_with_stops(jsonb, jsonb) to authenticated;
