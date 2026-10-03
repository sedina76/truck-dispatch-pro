-- ============================================================================
-- 0162_production_drift_repair.sql
--
-- A read-only comparison of the production schema with the schema the
-- repository's migrations build (supabase/ci/twin-db.sh + the generated
-- DRIFT_CHECK_READONLY.sql, 2026-10-01) found that production never received
-- parts of three old migrations, plus one manual enum value:
--
--  A. 0019 (pgcrypto search_path) -- set/reveal_driver_pii and
--     set/reveal_bank_account_pii still run with search_path = public, so
--     pgp_sym_encrypt/decrypt (pgcrypto lives in schema extensions on
--     Supabase) cannot be found: saving or revealing a driver's SSN /
--     direct-deposit numbers or the company bank numbers fails.
--  B. 0043 (profile-sharing allowlist fix) -- guard_profile_share_org() is
--     still 0042's version, which accepts any document type (e.g. a W-9 or
--     'other') on an external profile share as long as it belongs to the
--     driver/carrier.
--  C. 0115 (mileage columns) -- loads.route_miles / route_miles_calculated_at
--     / actual_miles / actual_miles_recorded_at are missing (nothing in the
--     app reads them yet; added so production matches the repository).
--  D. integration_provider has a 'resend' value in production that no
--     migration adds -- recorded here so new environments match.
--  E. dispatches.notes: 0069 dropped it (notes live in
--     dispatch_internal_notes); production has no such column. 0135 grants
--     UPDATE on it, so a database built from the repository re-creates it
--     for 0135 only -- dropped here again. No-op in production.
--  F. create_dispatch: 0135 revoked UPDATE on dispatches from users, which
--     broke the SECURITY INVOKER create_dispatch ("permission denied for
--     table dispatches" -- its SELECT ... FOR UPDATE needs UPDATE). In
--     production it was then switched to SECURITY DEFINER by hand, which
--     made dispatching work again but bypassed the RLS that confined the
--     load lookup to the caller's organization: an owner/dispatcher of one
--     company could create a dispatch on another company's load (proven on
--     the twin). Now: SECURITY DEFINER (needed) + the organization enforced
--     explicitly on the load lookup and the conflict checks. Body otherwise
--     identical to 0149.
--
-- Function bodies are taken unchanged from 0043 / 0115; 0019 differs from
-- 0014 only in search_path, so A is an ALTER FUNCTION. Privileges set by
-- 0161 are untouched (ALTER / CREATE OR REPLACE keep the existing ACL).
-- One transaction; safe to re-run.
-- ============================================================================

begin;

-- A ---------------------------------------------------------------------------
alter function public.set_bank_account_pii(uuid, text, text) set search_path = public, extensions;
alter function public.reveal_bank_account_pii(uuid, text, text) set search_path = public, extensions;
alter function public.set_driver_pii(uuid, text, text) set search_path = public, extensions;
alter function public.reveal_driver_pii(uuid, text, text) set search_path = public, extensions;

-- B (verbatim from 0043_profile_sharing_fix.sql) --------------------------------
create or replace function public.guard_profile_share_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_doc record;
  v_matched integer := 0;
begin
  select organization_id into v_org from public.loads where id = new.load_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'Load must belong to the same organization.';
  end if;

  if new.driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Driver must belong to the same organization.';
    end if;
  end if;

  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Carrier must belong to the same organization.';
    end if;
  end if;

  if new.document_ids_included is not null and array_length(new.document_ids_included, 1) > 0 then
    for v_doc in
      select id, organization_id, entity_type, entity_id, document_type
      from public.documents
      where id = any(new.document_ids_included)
    loop
      v_matched := v_matched + 1;
      if v_doc.organization_id <> new.organization_id then
        raise exception 'Attached document does not belong to your organization.';
      end if;
      if not (
        (v_doc.entity_type = 'driver' and v_doc.entity_id = new.driver_id)
        or (v_doc.entity_type = 'carrier' and v_doc.entity_id = new.carrier_id)
      ) then
        raise exception 'Attached document does not belong to the driver/carrier on this share.';
      end if;
      -- Explicit allowlist -- fixes the gap found live in Test H5.
      -- Matches SAFE_DOCUMENT_TYPES + SENSITIVE_DOCUMENT_TYPES exactly
      -- (src/lib/profile-share/generate.ts). Anything else (w9, other,
      -- bol, rate_confirmation, etc.) is never attachable to an external
      -- profile share, regardless of ownership or role.
      if v_doc.document_type::text not in ('insurance_certificate', 'motor_carrier_authority', 'cdl', 'medical_card') then
        raise exception 'This document type is not eligible for external profile sharing.';
      end if;
      if v_doc.document_type::text in ('cdl', 'medical_card') and not public.has_role(array['owner', 'admin']::public.org_role[]) then
        raise exception 'Only owners and admins may include sensitive identity/compliance documents.';
      end if;
    end loop;
    if v_matched <> array_length(new.document_ids_included, 1) then
      raise exception 'One or more attached document ids are invalid.';
    end if;
  end if;

  return new;
end;
$$;

-- C (from 0115_mileage_concept_separation.sql, made re-runnable) ----------------
alter table public.loads
  add column if not exists route_miles numeric(8, 2) constraint loads_route_miles_check check (route_miles is null or route_miles >= 0),
  add column if not exists route_miles_calculated_at timestamptz,
  add column if not exists actual_miles numeric(8, 2) constraint loads_actual_miles_check check (actual_miles is null or actual_miles >= 0),
  add column if not exists actual_miles_recorded_at timestamptz;
comment on column public.loads.route_miles is
  'ROUTE miles -- calculated, stop-to-stop routing distance (0115). Distinct from dispatch_route_intelligence.route_distance_meters (0060), which is a live dispatch''s CURRENT-LEG remaining distance to its next stop, not a stable planned total -- the two are never conflated or auto-derived from each other. NULL until a route-calculation feature populates it (not built by 0115 -- see this phase''s own report). Intended to drive routing/ETA displays going forward; never overwrites or is overwritten by total_miles (contracted_miles).';
comment on column public.loads.actual_miles is
  'ACTUAL miles -- GPS/ELD-derived mileage once a trip is complete (0115). NULL until a completed-trip GPS-distance aggregation feature exists (none does today -- see this phase''s own report); for post-trip operational reporting only, never for contracted rate-per-mile or driver/carrier compensation.';

-- D ---------------------------------------------------------------------------
alter type public.integration_provider add value if not exists 'resend' before 'factoring_api';

-- E ---------------------------------------------------------------------------
alter table public.dispatches drop column if exists notes;

-- F ---------------------------------------------------------------------------
create or replace function public.create_dispatch(
  p_load_id                 uuid,
  p_carrier_id              uuid,
  p_truck_id                uuid,
  p_driver_id               uuid,
  p_trailer_id              uuid    default null,
  p_dispatch_fee_percentage numeric default null,
  p_notes                   text    default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  c_active constant public.dispatch_status[] := array[
    'assigned','accepted','en_route_to_pickup','at_pickup','loaded',
    'en_route_to_delivery','at_delivery']::public.dispatch_status[];
  v_org         uuid;
  v_load_status text;
  v_dispatch_id uuid;
  v_hit_id      uuid;
  v_hit_ln      text;
  v_hit_label   text;
begin
  -- 1. authenticated
  if auth.uid() is null then
    raise exception 'You must be signed in to create a dispatch.' using errcode = 'TDAUT';
  end if;

  -- 2. role -- exactly the RLS dispatches write tier (0010_rls_policies.sql)
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'Only an owner, admin, or dispatcher can create a dispatch.' using errcode = 'TDROL';
  end if;

  -- 3. lock the load. 0162: SECURITY DEFINER bypasses RLS, so the caller's
  --    organization is enforced explicitly -- a cross-tenant p_load_id is
  --    "not found", exactly as RLS made it before. organization_id comes
  --    from THIS row -- never from a parameter.
  select l.organization_id, l.status
    into v_org, v_load_status
  from public.loads l
  where l.id = p_load_id
    and l.organization_id = public.current_org_id()
  for update;
  if not found then
    raise exception 'That load could not be found.' using errcode = 'TDLNF';
  end if;

  -- 4. dispatchable status only
  if v_load_status not in ('draft','posted','booked') then
    raise exception 'This load is not in a state that can be dispatched (%).', v_load_status using errcode = 'TDLND', detail = v_load_status;
  end if;

  -- 5. one active dispatch per load. Lock candidate rows so a concurrent
  --    create_dispatch for the SAME load serialises here.
  select d.id into v_dispatch_id
  from public.dispatches d
  where d.load_id = p_load_id and d.organization_id = v_org and d.status = any(c_active)
  for update
  limit 1;
  if v_dispatch_id is not null then
    raise exception 'This load already has an active dispatch. Open it from the Dispatch Board to make changes, or cancel that dispatch first.'
      using errcode = 'TDDUP', detail = v_dispatch_id::text;
  end if;

  -- 6. active driver / truck / trailer conflicts (specific message; the
  --    0054 partial unique indexes are the final race backstop on step 7).
  select d.id, coalesce(dl.load_number, ''), coalesce(dr.first_name || ' ' || dr.last_name, 'This driver')
    into v_hit_id, v_hit_ln, v_hit_label
  from public.dispatches d
  left join public.loads   dl on dl.id = d.load_id
  left join public.drivers dr on dr.id = d.driver_id
  where d.driver_id = p_driver_id and d.organization_id = v_org and d.status = any(c_active)
  limit 1;
  if v_hit_id is not null then
    raise exception '% is already assigned to active %.',
      v_hit_label, case when v_hit_ln <> '' then 'load ' || v_hit_ln else 'another dispatch' end
      using errcode = 'TDDRV', detail = v_hit_id::text;
  end if;

  select d.id, coalesce(dl.load_number, ''), coalesce('Truck ' || tk.unit_number, 'This truck')
    into v_hit_id, v_hit_ln, v_hit_label
  from public.dispatches d
  left join public.loads  dl on dl.id = d.load_id
  left join public.trucks tk on tk.id = d.truck_id
  where d.truck_id = p_truck_id and d.organization_id = v_org and d.status = any(c_active)
  limit 1;
  if v_hit_id is not null then
    raise exception '% is already assigned to active %.',
      v_hit_label, case when v_hit_ln <> '' then 'load ' || v_hit_ln else 'another dispatch' end
      using errcode = 'TDTRK', detail = v_hit_id::text;
  end if;

  if p_trailer_id is not null then
    select d.id, coalesce(dl.load_number, ''), coalesce('Trailer ' || tr.unit_number, 'This trailer')
      into v_hit_id, v_hit_ln, v_hit_label
    from public.dispatches d
    left join public.loads    dl on dl.id = d.load_id
    left join public.trailers tr on tr.id = d.trailer_id
    where d.trailer_id = p_trailer_id and d.organization_id = v_org and d.status = any(c_active)
    limit 1;
    if v_hit_id is not null then
      raise exception '% is already assigned to active %.',
        v_hit_label, case when v_hit_ln <> '' then 'load ' || v_hit_ln else 'another dispatch' end
        using errcode = 'TDTRL', detail = v_hit_id::text;
    end if;
  end if;

  -- 7. INSERT. Fires (in order): dispatches_guard_org (BEFORE, 0055 --
  --    same-org + same-carrier for every id -- with v_org = the caller's
  --    org this rejects another org's carrier/driver/truck/trailer),
  --    dispatches_stamp_proceeds (BEFORE, 0125),
  --    dispatches_assign_financial_controller (AFTER, 0125 -- sets
  --    loads.financial_dispatch_id), dispatch_financials_sync (0009/0068).
  insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, trailer_id, status)
  values (v_org, p_load_id, p_carrier_id, p_truck_id, p_driver_id, p_trailer_id, 'assigned')
  returning id into v_dispatch_id;

  -- 8. financials + notes (upsert -- mirrors writeDispatchFinancials /
  --    writeDispatchNotes; dispatch_financials_sync recomputes the amounts).
  insert into public.dispatch_financials (dispatch_id, organization_id, dispatch_fee_percentage)
  values (v_dispatch_id, v_org, coalesce(p_dispatch_fee_percentage, 10))
  on conflict (dispatch_id) do update set dispatch_fee_percentage = excluded.dispatch_fee_percentage;

  if p_notes is not null and btrim(p_notes) <> '' then
    insert into public.dispatch_internal_notes (dispatch_id, organization_id, notes)
    values (v_dispatch_id, v_org, p_notes)
    on conflict (dispatch_id) do update set notes = excluded.notes;
  end if;

  -- 9. advance the load
  update public.loads set status = 'dispatched' where id = p_load_id;

  -- 10. audit (same shape as the old app call)
  perform public.log_activity('dispatch'::public.entity_type, v_dispatch_id, 'created', null::jsonb, v_org);

  return v_dispatch_id;

exception
  when unique_violation then
    -- A genuine race between step 6 and step 7 tripped a 0054 partial
    -- unique index. The subtransaction is rolled back; re-derive the
    -- specific holder (fresh read) so the message still names the resource,
    -- else fall back to the same generic "just taken" copy the old
    -- raceLoserConflict() produced.
    select d.id, coalesce(dl.load_number, ''), coalesce(dr.first_name || ' ' || dr.last_name, 'This driver')
      into v_hit_id, v_hit_ln, v_hit_label
    from public.dispatches d
    left join public.loads dl on dl.id = d.load_id
    left join public.drivers dr on dr.id = d.driver_id
    where d.driver_id = p_driver_id and d.status = any(c_active) limit 1;
    if v_hit_id is not null then
      raise exception '% is already assigned to active %.',
        v_hit_label, case when v_hit_ln <> '' then 'load ' || v_hit_ln else 'another dispatch' end
        using errcode = 'TDDRV', detail = v_hit_id::text;
    end if;
    select d.id, coalesce(dl.load_number, ''), coalesce('Truck ' || tk.unit_number, 'This truck')
      into v_hit_id, v_hit_ln, v_hit_label
    from public.dispatches d
    left join public.loads dl on dl.id = d.load_id
    left join public.trucks tk on tk.id = d.truck_id
    where d.truck_id = p_truck_id and d.status = any(c_active) limit 1;
    if v_hit_id is not null then
      raise exception '% is already assigned to active %.',
        v_hit_label, case when v_hit_ln <> '' then 'load ' || v_hit_ln else 'another dispatch' end
        using errcode = 'TDTRK', detail = v_hit_id::text;
    end if;
    if p_trailer_id is not null then
      select d.id, coalesce(dl.load_number, ''), coalesce('Trailer ' || tr.unit_number, 'This trailer')
        into v_hit_id, v_hit_ln, v_hit_label
      from public.dispatches d
      left join public.loads dl on dl.id = d.load_id
      left join public.trailers tr on tr.id = d.trailer_id
      where d.trailer_id = p_trailer_id and d.status = any(c_active) limit 1;
      if v_hit_id is not null then
        raise exception '% is already assigned to active %.',
          v_hit_label, case when v_hit_ln <> '' then 'load ' || v_hit_ln else 'another dispatch' end
          using errcode = 'TDTRL', detail = v_hit_id::text;
      end if;
    end if;
    raise exception 'This assignment was just taken by another dispatch. Please review and choose different equipment/driver.'
      using errcode = 'TDDUP';
end;
$fn$;

-- postconditions ----------------------------------------------------------------
do $post$
begin
  if exists (select 1 from pg_proc where oid in ('public.set_bank_account_pii(uuid,text,text)'::regprocedure, 'public.reveal_bank_account_pii(uuid,text,text)'::regprocedure,
                                                 'public.set_driver_pii(uuid,text,text)'::regprocedure, 'public.reveal_driver_pii(uuid,text,text)'::regprocedure)
             and proconfig is distinct from array['search_path=public, extensions']) then
    raise exception '0162 postcondition: PII functions search_path not fixed.';
  end if;
  if position('not eligible for external profile sharing' in (select prosrc from pg_proc where oid = 'public.guard_profile_share_org()'::regprocedure)) = 0 then
    raise exception '0162 postcondition: profile-share allowlist missing.';
  end if;
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loads'
      and column_name in ('route_miles', 'route_miles_calculated_at', 'actual_miles', 'actual_miles_recorded_at')) <> 4 then
    raise exception '0162 postcondition: mileage columns missing.';
  end if;
  if not (select prosecdef from pg_proc where oid = 'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure)
     or position('l.organization_id = public.current_org_id()' in (select prosrc from pg_proc where oid = 'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure)) = 0 then
    raise exception '0162 postcondition: create_dispatch organization check missing.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'dispatches' and column_name = 'notes') then
    raise exception '0162 postcondition: dispatches.notes still exists.';
  end if;
end $post$;

commit;
