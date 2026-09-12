-- =============================================================================
-- 0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0134 live. "Phase 3A.2 -- Dispatch Resource Reassignment and
-- Deployment Safety" -- narrowly scoped: closes the residual reachable
-- lock-order/carrier-tampering risk Phase 3A.1 explicitly disclosed
-- (updateDispatch()'s direct driver/truck/trailer/carrier UPDATE). Does NOT
-- touch invoices, factoring, payments, dispatch-service invoicing,
-- settlements, or reporting.
--
-- WHAT THIS MIGRATION DOES
--   A. DISPATCHES COLUMN-LEVEL PRIVILEGE LOCKDOWN. authenticated previously
--      held the full, never-narrowed 0010 table-level UPDATE grant on
--      dispatches (CONFIRMED via has_table_privilege, not assumed).
--      Narrowed to EXACTLY the one column any current authenticated client
--      still legitimately writes directly (grepped, read-only, whole
--      repository): `notes` (board-actions.ts's quick-notes-edit feature,
--      dispatch/actions.ts's writeDispatchNotes() writes a SEPARATE table
--      instead). carrier_id, load_id, driver_id, truck_id, trailer_id,
--      status, every 0057 operational timestamp, dispatched_by,
--      dispatched_at, completed_at, proceeds_model/proceeds_payer/
--      proceeds_payer_note, id, organization_id, created_at, updated_at --
--      ALL removed from the authenticated grant. Every one of them is
--      either stamped by a trigger, set once at INSERT by create_dispatch()
--      (SECURITY DEFINER, unaffected), or now changed exclusively through
--      transition_dispatch_status() (0134) or reassign_dispatch_resources()
--      (this migration) -- both SECURITY DEFINER, both unaffected by this
--      revoke, both the sole sanctioned path for their respective columns.
--   B. public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz) --
--      ONE authoritative, guarded RPC for driver/truck/trailer
--      reassignment. Same LOAD-FIRST-THEN-DISPATCH lock order as
--      transition_dispatch_status() (0134) and create_dispatch()/
--      cancel_dispatch() (0129) -- see the function body for full detail.
--      Never changes carrier_id, load_id, or status -- carrier is DERIVED
--      from the locked load/dispatch and any mismatch is a structural
--      abort, never a silent correction; status stays exclusively under
--      transition_dispatch_status().
--   * table public.dispatch_resource_reassignments -- idempotency ledger +
--      durable audit trail, same pattern as 0134's dispatch_status_
--      transitions (RLS select-only, explicit REVOKE of client writes).
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not touch create_dispatch()/cancel_dispatch()/transition_
--     dispatch_status() (0129/0134) -- this RPC handles ONLY driver/truck/
--     trailer, never status, never carrier/load
--   * does not add a carrier-reassignment workflow (reassign_load_carrier())
--     -- that remains a disclosed Phase 3B item; this migration only
--     REMOVES the ability to change carrier_id via the generic dispatch
--     edit form, it does not add a replacement carrier-change path
--   * does not touch driver-portal or geofence-automation paths -- both use
--     the service-role client (a DIFFERENT Postgres role, unaffected by any
--     REVOKE naming `authenticated`), are already forward-only, and never
--     write driver_id/truck_id/trailer_id/carrier_id/load_id (grep-
--     confirmed, read-only)
--   * does not add invoice/factoring/payment/settlement/reporting logic
--
-- STRUCTURE: explicit BEGIN/COMMIT. PHASE 1 preconditions -> PHASE 2 DDL ->
-- PHASE 3 postconditions. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
begin
  if to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is null then
    raise exception '0135 precondition: transition_dispatch_status(...) missing -- apply 0134 first. STOP.';
  end if;
  if to_regprocedure('public.guard_dispatch_org()') is null then
    raise exception '0135 precondition: public.guard_dispatch_org() missing -- apply 0055 first. STOP.';
  end if;
  if to_regprocedure('public.guard_dispatch_carrier_scope()') is null then
    raise exception '0135 precondition: public.guard_dispatch_carrier_scope() missing -- apply 0132 first. STOP.';
  end if;
  if to_regprocedure('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)') is not null then
    raise exception '0135 precondition: reassign_dispatch_resources(...) already exists -- partial apply? STOP.';
  end if;
  if to_regclass('public.dispatch_resource_reassignments') is not null then
    raise exception '0135 precondition: table dispatch_resource_reassignments already exists. STOP.';
  end if;
  raise notice '0135 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- A. DISPATCHES COLUMN-LEVEL PRIVILEGE LOCKDOWN (item 4). REGRANTing from
-- scratch (not incrementally revoking) -- same rationale as 0132/0134's
-- trailers narrowing: proves-by-construction the final permitted set is
-- EXACTLY this list, independent of whatever 0010's blanket grant happened
-- to include.
revoke update on public.dispatches from authenticated;
grant update (notes) on public.dispatches to authenticated;

comment on column public.dispatches.carrier_id is
  'The carrier this dispatch is assigned to -- MUST equal loads.carrier_id once the load has claimed one (guard_dispatch_carrier_scope, 0132). UPDATE is revoked from authenticated (0135) -- carrier can never be changed via a direct client write, only set once at creation via create_dispatch() (0129, SECURITY DEFINER). No controlled reassignment RPC exists yet (Phase 3B item); until it does, a dispatch''s carrier is immutable after creation.';
comment on column public.dispatches.driver_id is
  'UPDATE is revoked from authenticated (0135) -- change via public.reassign_dispatch_resources() only, which enforces same-carrier, active-status, and no-conflicting-active-assignment rules atomically under a load-then-dispatch lock.';
comment on column public.dispatches.truck_id is
  'UPDATE is revoked from authenticated (0135) -- change via public.reassign_dispatch_resources() only (see driver_id).';
comment on column public.dispatches.trailer_id is
  'UPDATE is revoked from authenticated (0135) -- change via public.reassign_dispatch_resources() only; must be carrier-owned or explicitly organization_shared, never unresolved (see driver_id).';
comment on column public.dispatches.load_id is
  'UPDATE is revoked from authenticated (0135) -- never changed by any application code path (grep-confirmed); set once at creation only.';
comment on column public.dispatches.status is
  'UPDATE is revoked from authenticated (0135) -- change via public.transition_dispatch_status() (0134) only.';

-- idempotency ledger + durable audit trail for reassign_dispatch_resources()
create table public.dispatch_resource_reassignments (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null references public.dispatches (id) on delete cascade,
  idempotency_key text not null,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  load_id uuid not null references public.loads (id) on delete cascade,
  old_driver_id uuid, new_driver_id uuid,
  old_truck_id uuid, new_truck_id uuid,
  old_trailer_id uuid, new_trailer_id uuid,
  reason text,
  result jsonb not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (dispatch_id, idempotency_key)
);

comment on table public.dispatch_resource_reassignments is
  'Idempotency ledger + durable audit trail for public.reassign_dispatch_resources(): one row per (dispatch_id, idempotency_key) actually applied, recording organization/carrier/load context and old/new driver/truck/trailer ids (Phase 3A.3, item 4 -- "show the audit information", carrier_id/load_id added). A retried call with the SAME pair replays the cached result verbatim. Written only by the RPC (SECURITY DEFINER); no direct client write path. A stale-record rejection (item 3) is NEVER written here -- no row, no audit event, matching "make no changes, create no reassignment audit event."';

alter table public.dispatch_resource_reassignments enable row level security;

create policy dispatch_resource_reassignments_select on public.dispatch_resource_reassignments
  for select using (organization_id = public.current_org_id());
revoke all on public.dispatch_resource_reassignments from anon;
revoke insert, update, delete on public.dispatch_resource_reassignments from authenticated;
grant select on public.dispatch_resource_reassignments to authenticated;

-- B. THE RPC ITSELF.
create or replace function public.reassign_dispatch_resources(
  p_dispatch_id uuid,
  p_driver_id uuid,
  p_truck_id uuid,
  p_trailer_id uuid,
  p_reason text default null,
  p_idempotency_key text default null,
  p_expected_updated_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_dispatch_org uuid;
  v_load_id uuid;
  v_load_org uuid;
  v_load_carrier uuid;
  v_dispatch_status public.dispatch_status;
  v_dispatch_carrier uuid;
  v_current_updated_at timestamptz;
  v_effective_carrier uuid;
  v_old_driver uuid;
  v_old_truck uuid;
  v_old_trailer uuid;
  v_changed boolean;
  v_driver_replacing boolean;
  v_truck_replacing boolean;
  v_trailer_replacing boolean;
  v_replacing boolean;
  v_driver_carrier uuid;
  v_driver_status public.driver_status;
  v_truck_carrier uuid;
  v_truck_status public.equipment_status;
  v_trailer_carrier uuid;
  v_trailer_status public.equipment_status;
  v_trailer_scope public.trailer_ownership_scope;
  v_conflict_id uuid;
  v_result jsonb;
  v_cached jsonb;
  c_active constant public.dispatch_status[] := array[
    'assigned','accepted','en_route_to_pickup','at_pickup','loaded',
    'en_route_to_delivery','at_delivery']::public.dispatch_status[];
begin
  -- Never allow browser-provided organization/carrier ownership to
  -- override database truth: this function takes NO organization_id or
  -- carrier_id parameter at all -- both are derived exclusively from the
  -- locked dispatch/load rows and from auth.uid()/current_org_id().
  if v_uid is null then
    raise exception 'reassign_dispatch_resources: authentication required.' using errcode = 'RRAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'reassign_dispatch_resources: caller has no organization.' using errcode = 'RRAUT';
  end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'reassign_dispatch_resources: only an owner, admin, or dispatcher may reassign dispatch resources.' using errcode = 'RRROL';
  end if;
  if p_driver_id is null or p_truck_id is null then
    raise exception 'reassign_dispatch_resources: a driver and a truck are required.' using errcode = 'RRVAL';
  end if;

  -- Idempotency short-circuit -- BEFORE any lock, any validation, any
  -- write. A retried call with the SAME (dispatch_id, idempotency_key)
  -- pair replays the ORIGINAL cached result verbatim.
  if p_idempotency_key is not null then
    select result into v_cached
    from public.dispatch_resource_reassignments
    where dispatch_id = p_dispatch_id and idempotency_key = p_idempotency_key;
    if found then
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

  -- Resolve dispatch -> load_id WITHOUT locking yet.
  select organization_id, load_id into v_dispatch_org, v_load_id
  from public.dispatches where id = p_dispatch_id;
  if v_dispatch_org is null or v_dispatch_org <> v_org then
    raise exception 'reassign_dispatch_resources: dispatch % not found.', p_dispatch_id using errcode = 'RRDNF';
  end if;

  -- ===== STEP 1: LOCK THE LOAD FIRST -- unconditional, matching
  -- create_dispatch()/cancel_dispatch() (0129) and transition_dispatch_
  -- status() (0134). See the "LOCK-ORDER STANDARD" note in 0134's header
  -- and TEST_LOCKORDER_0135_... for the full audit of every path touching
  -- both tables.
  select organization_id, carrier_id into v_load_org, v_load_carrier
  from public.loads where id = v_load_id for update;
  if v_load_org is null then
    raise exception 'reassign_dispatch_resources: load % missing.', v_load_id using errcode = 'RRDNF';
  end if;

  -- ===== STEP 2: LOCK THE DISPATCH SECOND, re-read under both locks.
  select status, carrier_id, driver_id, truck_id, trailer_id, updated_at
    into v_dispatch_status, v_dispatch_carrier, v_old_driver, v_old_truck, v_old_trailer, v_current_updated_at
  from public.dispatches where id = p_dispatch_id for update;

  -- Determine "is this a REPLACEMENT" EXCLUSIVELY from the locked row just
  -- read above -- never from anything the browser claims (Phase 3A.4, item
  -- 1). A resource is being replaced when it currently holds a non-null
  -- value AND the caller's submitted value differs from it (removing an
  -- assigned resource -- new value null -- also counts as a replacement:
  -- something IS being taken away). Assigning a previously-NULL value
  -- (trailer only -- driver/truck are NOT NULL columns on this table, so
  -- they are always already assigned for any dispatch that exists at all)
  -- is an INITIAL assignment, never a replacement.
  v_driver_replacing := v_old_driver is not null and p_driver_id is distinct from v_old_driver;
  v_truck_replacing := v_old_truck is not null and p_truck_id is distinct from v_old_truck;
  v_trailer_replacing := v_old_trailer is not null and p_trailer_id is distinct from v_old_trailer;
  v_replacing := v_driver_replacing or v_truck_replacing or v_trailer_replacing;
  v_changed := (p_driver_id is distinct from v_old_driver)
            or (p_truck_id is distinct from v_old_truck)
            or (p_trailer_id is distinct from v_old_trailer);

  -- ===== OPTIMISTIC CONCURRENCY: MANDATORY for any REPLACEMENT (Phase
  -- 3A.4, item 1). Phase 3A.3 shipped p_expected_updated_at as an optional
  -- convenience; that let an authenticated caller simply omit it to bypass
  -- version protection entirely on a real replacement. Both checks below
  -- run HERE, under the row lock already taken above, before ANY other
  -- business validation -- so a caller cannot dodge either one by tripping
  -- some other rejection first -- and BOTH return a structured jsonb
  -- result, never a raised exception: no write, no ledger row, no
  -- idempotency-success entry, no audit event, in either branch.
  --
  -- Initial assignment (v_replacing = false -- reachable only for a
  -- previously-unset trailer) may still omit the version: there is nothing
  -- existing to silently overwrite, and the row lock taken above IS the
  -- concurrency protection here -- two simultaneous "assign this same
  -- never-before-set trailer" calls still serialize on that lock, and
  -- whichever one reaches this point second re-reads v_old_trailer AFTER
  -- the first call committed, so it is no longer treated as an initial
  -- assignment at all (v_old_trailer is no longer null) -- it becomes a
  -- REPLACEMENT for that second caller, and this same mandatory check
  -- applies to it in full.
  --
  -- No internal/service-role "repair" workflow anywhere in this codebase
  -- calls this RPC (grep-confirmed) -- there is therefore no existing
  -- caller that needs to omit the version on a genuine replacement, and
  -- none is exempted here. Any FUTURE internal/repair workflow MUST add
  -- its own explicitly role-gated parameter or a separate function -- it
  -- must never simply pass NULL to this parameter to bypass this check.
  if v_replacing and p_expected_updated_at is null then
    return jsonb_build_object(
      'success', false,
      'expected_version_required', true,
      'dispatch_id', p_dispatch_id,
      'current_updated_at', v_current_updated_at,
      'message', 'This reassignment replaces an already-assigned driver, truck, or trailer, which requires the version of the dispatch you loaded. Please reload the page and try again.');
  end if;
  if p_expected_updated_at is not null and v_current_updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object(
      'success', false,
      'stale_record', true,
      'dispatch_id', p_dispatch_id,
      'current_updated_at', v_current_updated_at,
      'message', 'This dispatch was changed by someone else while you were editing it. Please refresh and review the latest assignment before trying again.');
  end if;

  -- Derive carrier EXCLUSIVELY from the locked load/dispatch -- never a
  -- parameter. Any mismatch between them is a structural inconsistency
  -- (should be impossible given guard_dispatch_carrier_scope, 0132) --
  -- reject outright, never silently pick one.
  if v_load_carrier is not null and v_dispatch_carrier is distinct from v_load_carrier then
    raise exception 'reassign_dispatch_resources: this dispatch''s carrier (%) does not match the load''s carrier (%) -- structural inconsistency, resource reassignment refused.', v_dispatch_carrier, v_load_carrier using errcode = 'RRCAR';
  end if;
  v_effective_carrier := coalesce(v_load_carrier, v_dispatch_carrier);
  if v_effective_carrier is null then
    raise exception 'reassign_dispatch_resources: this load/dispatch has no resolved carrier yet -- resources cannot be reassigned until a carrier is established.' using errcode = 'RRCAR';
  end if;

  if v_dispatch_status in ('cancelled','delivered','completed') then
    raise exception 'reassign_dispatch_resources: resources cannot be reassigned on a % dispatch.', v_dispatch_status using errcode = 'RRINV';
  end if;

  if not v_changed then
    v_result := jsonb_build_object(
      'success', true, 'dispatch_id', p_dispatch_id, 'no_op', true,
      'driver_id', v_old_driver, 'truck_id', v_old_truck, 'trailer_id', v_old_trailer);
  else
    -- A reason is required whenever an ALREADY-assigned resource is being
    -- REPLACED (item 2.13) -- i.e. whenever the old value was non-NULL and
    -- is changing. Assigning a previously-NULL trailer for the first time
    -- does not require one (nothing is being "replaced"). v_replacing was
    -- already computed, under the lock, above -- same flag the mandatory-
    -- version check uses, so "requires a reason" and "requires a version"
    -- are always in lockstep, never two different definitions of
    -- "replacement" drifting apart.
    if v_replacing and (p_reason is null or btrim(p_reason) = '') then
      raise exception 'reassign_dispatch_resources: a reason is required when replacing an already-assigned driver, truck, or trailer.' using errcode = 'RRRSN';
    end if;

    -- Verify driver belongs to the effective carrier and is active. Backed
    -- independently by guard_dispatch_org (0055), which re-checks org/
    -- carrier consistency on this same UPDATE regardless of what this RPC
    -- concludes -- defense in depth, not the sole gate.
    select carrier_id, status into v_driver_carrier, v_driver_status
    from public.drivers where id = p_driver_id and organization_id = v_org;
    if v_driver_carrier is null then
      raise exception 'reassign_dispatch_resources: driver % not found in this organization.', p_driver_id using errcode = 'RRDRV';
    end if;
    if v_driver_carrier <> v_effective_carrier then
      raise exception 'reassign_dispatch_resources: this driver does not belong to carrier %.', v_effective_carrier using errcode = 'RRDRV';
    end if;
    if v_driver_status <> 'active' then
      raise exception 'reassign_dispatch_resources: driver is not active (%).', v_driver_status using errcode = 'RRDRV';
    end if;

    -- Verify truck belongs to the effective carrier and is active.
    select carrier_id, status into v_truck_carrier, v_truck_status
    from public.trucks where id = p_truck_id and organization_id = v_org;
    if v_truck_carrier is null then
      raise exception 'reassign_dispatch_resources: truck % not found in this organization.', p_truck_id using errcode = 'RRTRK';
    end if;
    if v_truck_carrier <> v_effective_carrier then
      raise exception 'reassign_dispatch_resources: this truck does not belong to carrier %.', v_effective_carrier using errcode = 'RRTRK';
    end if;
    if v_truck_status <> 'active' then
      raise exception 'reassign_dispatch_resources: truck is not active (%).', v_truck_status using errcode = 'RRTRK';
    end if;

    -- Verify trailer, if one is being assigned: carrier-owned OR
    -- explicitly organization_shared, never unresolved, and active.
    if p_trailer_id is not null then
      select carrier_id, status, ownership_scope into v_trailer_carrier, v_trailer_status, v_trailer_scope
      from public.trailers where id = p_trailer_id and organization_id = v_org;
      if v_trailer_status is null then
        raise exception 'reassign_dispatch_resources: trailer % not found in this organization.', p_trailer_id using errcode = 'RRTRL';
      end if;
      if v_trailer_scope = 'unresolved' then
        raise exception 'reassign_dispatch_resources: trailer % has unresolved ownership; an owner/admin must classify it before it can be dispatched.', p_trailer_id using errcode = 'RRTRL';
      end if;
      if v_trailer_scope = 'carrier' and v_trailer_carrier is distinct from v_effective_carrier then
        raise exception 'reassign_dispatch_resources: this trailer belongs to a different carrier.' using errcode = 'RRTRL';
      end if;
      if v_trailer_status <> 'active' then
        raise exception 'reassign_dispatch_resources: trailer is not active (%).', v_trailer_status using errcode = 'RRTRL';
      end if;
    end if;

    -- Proactive conflicting-active-assignment pre-check (fast, friendly
    -- path). The 0054 partial unique indexes (dispatches_active_driver_
    -- unique / _truck_unique / _trailer_unique) are the AUTHORITATIVE,
    -- race-proof backstop -- they apply to this UPDATE exactly as they do
    -- to create_dispatch()'s INSERT, so a genuine concurrent race is still
    -- caught even if this pre-check's own SELECT is stale by the time the
    -- UPDATE below executes.
    select id into v_conflict_id from public.dispatches
      where driver_id = p_driver_id and id <> p_dispatch_id and status = any(c_active);
    if v_conflict_id is not null then
      raise exception 'reassign_dispatch_resources: this driver is already assigned to active dispatch %.', v_conflict_id using errcode = 'RRDRV', detail = v_conflict_id::text;
    end if;
    select id into v_conflict_id from public.dispatches
      where truck_id = p_truck_id and id <> p_dispatch_id and status = any(c_active);
    if v_conflict_id is not null then
      raise exception 'reassign_dispatch_resources: this truck is already assigned to active dispatch %.', v_conflict_id using errcode = 'RRTRK', detail = v_conflict_id::text;
    end if;
    if p_trailer_id is not null then
      select id into v_conflict_id from public.dispatches
        where trailer_id = p_trailer_id and id <> p_dispatch_id and status = any(c_active);
      if v_conflict_id is not null then
        raise exception 'reassign_dispatch_resources: this trailer is already assigned to active dispatch %.', v_conflict_id using errcode = 'RRTRL', detail = v_conflict_id::text;
      end if;
    end if;

    -- ===== STEP 4: UPDATE. carrier_id/load_id/status are NEVER in this SET
    -- list -- structurally impossible for this RPC to touch them.
    -- guard_dispatch_org (0055) fires here as an independent backstop
    -- (org + carrier-consistency re-check); guard_dispatch_carrier_scope
    -- (0132) also fires but is NOT carrier-relevant for this update (carrier_
    -- id/load_id unchanged, not a reactivation) except for its always-on
    -- unresolved-trailer check, which re-validates p_trailer_id
    -- independently of this function's own check above.
    begin
      update public.dispatches
      set driver_id = p_driver_id, truck_id = p_truck_id, trailer_id = p_trailer_id
      where id = p_dispatch_id;
    exception when unique_violation then
      if sqlerrm ilike '%dispatches_active_driver_unique%' then
        raise exception 'reassign_dispatch_resources: this driver was just taken by another active dispatch (concurrent race).' using errcode = 'RRDRV';
      elsif sqlerrm ilike '%dispatches_active_truck_unique%' then
        raise exception 'reassign_dispatch_resources: this truck was just taken by another active dispatch (concurrent race).' using errcode = 'RRTRK';
      elsif sqlerrm ilike '%dispatches_active_trailer_unique%' then
        raise exception 'reassign_dispatch_resources: this trailer was just taken by another active dispatch (concurrent race).' using errcode = 'RRTRL';
      else
        raise;
      end if;
    end;

    -- Phase 3A.3, item 4: the audit record must carry full context, not
    -- just old/new ids and a reason -- organization_id, carrier_id, load_id,
    -- and the idempotency key (when supplied) are included here so a
    -- durable, self-sufficient audit trail exists via log_activity() alone,
    -- independent of the ledger table (which additionally persists the same
    -- facts in structured columns for querying -- see the INSERT below).
    perform public.log_activity(
      'dispatch'::public.entity_type, p_dispatch_id, 'resources_reassigned',
      jsonb_build_object(
        'organization_id', v_org,
        'carrier_id', v_effective_carrier,
        'load_id', v_load_id,
        'old_driver_id', v_old_driver, 'new_driver_id', p_driver_id,
        'old_truck_id', v_old_truck, 'new_truck_id', p_truck_id,
        'old_trailer_id', v_old_trailer, 'new_trailer_id', p_trailer_id,
        'reason', p_reason,
        'idempotency_key', p_idempotency_key),
      v_org);

    v_result := jsonb_build_object(
      'success', true, 'dispatch_id', p_dispatch_id, 'no_op', false,
      'driver_id', p_driver_id, 'truck_id', p_truck_id, 'trailer_id', p_trailer_id);
  end if;

  if p_idempotency_key is not null then
    insert into public.dispatch_resource_reassignments
      (dispatch_id, idempotency_key, organization_id, carrier_id, load_id, old_driver_id, new_driver_id,
       old_truck_id, new_truck_id, old_trailer_id, new_trailer_id, reason, result, created_by)
    values (p_dispatch_id, p_idempotency_key, v_org, v_effective_carrier, v_load_id, v_old_driver, p_driver_id,
            v_old_truck, p_truck_id, v_old_trailer, p_trailer_id, p_reason, v_result, v_uid)
    on conflict (dispatch_id, idempotency_key) do nothing;
  end if;

  return v_result;
end;
$fn$;

revoke all on function public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz) from public;
grant execute on function public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz) to authenticated;

comment on function public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz) is
  'THE authoritative RPC for dispatch driver/truck/trailer reassignment (Phase 3A.2, items 1-2; Phase 3A.3 items 3-4; Phase 3A.4 item 1). Locks the load FIRST, then the dispatch, unconditionally -- same order as create_dispatch()/cancel_dispatch() (0129) and transition_dispatch_status() (0134). NEVER changes carrier_id, load_id, or status -- carrier is derived exclusively from the locked load/dispatch and any mismatch is a structural abort. Requires owner/admin/dispatcher role, a reason when REPLACING an already-assigned resource, same-carrier driver/truck, carrier-owned-or-organization_shared non-unresolved trailer, active status on all three, and no conflicting active assignment (proactive check + the 0054 unique-index backstop). "Replacing" is determined exclusively from the locked row (old value non-null and the submitted value differs), never from a client-supplied flag. p_expected_updated_at is MANDATORY whenever a replacement is happening (Phase 3A.4, item 1 -- closes the Phase 3A.3 bypass where simply omitting it skipped version protection entirely): omitting it on a replacement returns {success:false, expected_version_required:true}; supplying one that no longer matches the locked row returns {success:false, stale_record:true} -- neither raises an exception, and neither writes anything (no resource change, no ledger row, no idempotency-success entry, no audit event). Only a genuine INITIAL assignment (a previously-unset trailer -- driver/truck are NOT NULL columns and so are always already "replacing") may omit the version, protected by the row lock itself rather than a version comparison. Idempotent via p_idempotency_key. Writes one durable audit event via log_activity() (organization_id/carrier_id/load_id/old+new driver+truck+trailer/reason/idempotency_key) plus a matching row in dispatch_resource_reassignments. Accepts no organization_id or carrier_id parameter.';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare v_n integer;
begin
  -- dispatches column-privilege lockdown (item 4)
  if has_table_privilege('authenticated', 'public.dispatches', 'UPDATE') then
    raise exception '0135 postcondition: authenticated holds a TABLE-LEVEL UPDATE grant on dispatches -- must be column-scoped only.';
  end if;
  if exists (
    select 1 from information_schema.column_privileges
    where table_schema='public' and table_name='dispatches' and grantee='authenticated' and privilege_type='UPDATE'
      and column_name in ('id','organization_id','carrier_id','load_id','driver_id','truck_id','trailer_id',
                           'status','created_at','updated_at','dispatched_by','dispatched_at','completed_at',
                           'en_route_pickup_at','loaded_at','in_transit_at','delivered_at','cancelled_at')
  ) then
    raise exception '0135 postcondition: authenticated still holds UPDATE on a protected dispatches column.';
  end if;
  select count(*) into v_n from information_schema.column_privileges
    where table_schema='public' and table_name='dispatches' and grantee='authenticated' and privilege_type='UPDATE';
  if v_n <> 1 then
    raise exception '0135 postcondition: expected exactly 1 UPDATE-grantable dispatches column (notes) for authenticated, found %.', v_n;
  end if;
  if not has_column_privilege('authenticated','public.dispatches','notes','UPDATE') then
    raise exception '0135 postcondition: authenticated cannot update dispatches.notes -- should remain updatable.';
  end if;

  -- RPC + ledger present, correctly configured
  if to_regprocedure('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)') is null then
    raise exception '0135 postcondition: reassign_dispatch_resources(...) missing.';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='reassign_dispatch_resources'
      and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'::text[]),',') not like '%search_path=%')
  ) then
    raise exception '0135 postcondition: reassign_dispatch_resources is not (security definer + pinned search_path).';
  end if;
  if not has_function_privilege('authenticated','public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)','EXECUTE') then
    raise exception '0135 postcondition: authenticated lacks EXECUTE on reassign_dispatch_resources(...).';
  end if;
  if to_regclass('public.dispatch_resource_reassignments') is null then
    raise exception '0135 postcondition: table dispatch_resource_reassignments missing.';
  end if;
  if (select count(*) from public.dispatch_resource_reassignments) <> 0 then
    raise exception '0135 postcondition: dispatch_resource_reassignments is not empty -- 0135 creates no rows.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='dispatch_resource_reassignments' and cmd in ('INSERT','UPDATE','DELETE','ALL')) then
    raise exception '0135 postcondition: dispatch_resource_reassignments has an unexpected write policy.';
  end if;
  if exists (select 1 from information_schema.role_table_grants
             where table_schema='public' and table_name='dispatch_resource_reassignments'
               and grantee='authenticated' and privilege_type in ('INSERT','UPDATE','DELETE')) then
    raise exception '0135 postcondition: authenticated still holds table-level INSERT/UPDATE/DELETE on dispatch_resource_reassignments.';
  end if;
  -- Phase 3A.3, item 4: ledger must carry carrier_id/load_id, both NOT NULL.
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='dispatch_resource_reassignments'
      and column_name='carrier_id' and is_nullable='NO'
  ) then
    raise exception '0135 postcondition: dispatch_resource_reassignments.carrier_id missing or nullable.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='dispatch_resource_reassignments'
      and column_name='load_id' and is_nullable='NO'
  ) then
    raise exception '0135 postcondition: dispatch_resource_reassignments.load_id missing or nullable.';
  end if;

  -- untouched: 0129/0132/0134 functions/triggers still present
  if to_regprocedure('public.cancel_dispatch(uuid,text)') is null then
    raise exception '0135 postcondition: 0129 cancel_dispatch(uuid,text) disappeared.';
  end if;
  if to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is null then
    raise exception '0135 postcondition: 0134 transition_dispatch_status(...) disappeared.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='dispatches_guard_carrier_scope' and tgrelid='public.dispatches'::regclass and not tgisinternal) then
    raise exception '0135 postcondition: 0132 guard_dispatch_carrier_scope trigger disappeared.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='dispatches_guard_org' and tgrelid='public.dispatches'::regclass and not tgisinternal) then
    raise exception '0135 postcondition: 0055 guard_dispatch_org trigger disappeared.';
  end if;

  raise notice '0135 complete: dispatches UPDATE narrowed to 1 column (notes) for authenticated; reassign_dispatch_resources(...) + dispatch_resource_reassignments installed. carrier_id/load_id/driver_id/truck_id/trailer_id/status all now RPC-only for direct client writes. Existing 0055/0129/0132/0134 functions/triggers untouched.';
end
$mig$;

commit;
