-- =============================================================================
-- proposed_0152.sql -- authorize before replay + bind replay to the original request (8 RPCs) + internal-helper privilege hardening
-- PROPOSAL 0152 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 (this). Current proposal 0148 is unrelated and MUST be
-- renumbered to 0153 or higher before promotion.
--
-- DEFECT CLASS. An idempotency ledger was read (and its cached result returned) before one or more of: current role, target-organization
-- ownership, request binding. Confirmed by proposals/0152/defect_repro.sql on the real 0135/0139/0141/0142/0143 functions (see AUDIT.md).
-- REPAIRED (function bodies only; signatures, SECURITY DEFINER, search_path, owner, ACL, comments unchanged):
--   reassign_dispatch_resources (0135), set_carrier_factoring_policy (0139), configure_/rotate_carrier_factoring_integration,
--   transition_carrier_factoring_integration_lifecycle, deactivate_factoring_relationship (0141), review_legacy_invoice_carrier_migration (0142),
--   update_carrier_invoice_draft (0143).  transition_dispatch_status is repaired by proposal 0151 (not repeated here).
-- SCHEMA (necessary, minimal): one NOT NULL column  request_fingerprint text  on factoring_policy_idempotency (0139) and
--   factoring_integration_lifecycle_idempotency (0141) -- neither ledger stores the request, so request binding is otherwise impossible.
--   ZERO-ROW INVARIANT: both ledgers are introduced by 0139/0141 in the same maintenance window and must still be EMPTY here; the migration takes
--   ACCESS EXCLUSIVE locks on both, re-counts under the locks and ABORTS WITHOUT CHANGES if either holds a row (no fingerprint is ever fabricated).
--   (0135's ledger already stores driver/truck/trailer/reason; 0142's review row and 0143's ledger already bind; no other table changes.)
-- PRIVILEGES: EXECUTE revoked from service_role (and public/anon/authenticated) on three internal-only SECURITY DEFINER helpers. The owner keeps
--   implicit EXECUTE, so the approved callers (which share the owner) keep working. Supabase grants EXECUTE on new functions to service_role by default.
-- STABLE MISMATCH CODES: jsonb-returning RPCs -> code IDEMPOTENCY_KEY_REUSED (the existing 0143+ code); raising RPCs -> RRIDK (reassign), FPIDK (policy).
-- POLICY: actor is NOT bound; a different CURRENT authorized owner/admin (dispatcher for reassign) may replay organization-owned operations.
-- =============================================================================
begin;
-- LOCK ORDER (fixed, documented; the only place these two locks are taken together): 1) factoring_policy_idempotency, 2) factoring_integration_lifecycle_idempotency,
-- acquired left-to-right by ONE LOCK TABLE statement. No RPC or migration takes them in any other order (each repaired RPC writes at most ONE of the two ledgers per
-- transaction). A bounded wait turns any unexpected contention into a clean abort (nothing changed) instead of an indefinite hang in the maintenance window.
set local lock_timeout = '15s';

-- ======================= PHASE 1 -- PRECONDITIONS ==============================
do $mig$
declare
  r record;
  v_md5 text;
begin
  for r in select * from (values
    ('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)', '7275c1efb655f198bdc0c20043bdb8fb'),
    ('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)', 'da10cb9a8f52a60df7cba39c7d554c8b'),
    ('public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', '26bf692b2ceb209e578016335adedc28'),
    ('public.rotate_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', 'bb906c5a5869a2a7dcd667bbcbfaa908'),
    ('public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)', '4623555e7353ca9d4aaeee10280e8ae3'),
    ('public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)', '6d7f33e2f6d6f2b79c19b7da1883f6ac'),
    ('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'e40fdf2d68e9bfb4b9fa57faf9c082ae'),
    ('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', '46aaae9d829d888d9da2dbed865680fb')
  ) as t(sig, body_md5) loop
    if to_regprocedure(r.sig) is null then raise exception '0152 precondition: % missing. STOP.', r.sig; end if;
    select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure(r.sig);
    if v_md5 is distinct from r.body_md5 then raise exception '0152 precondition: live % is not the reviewed baseline definition (md5 %) -- already repaired, or drifted. STOP.', r.sig, v_md5; end if;
    if not (select p.prosecdef and p.proconfig::text = '{"search_path=pg_catalog, public"}' from pg_proc p where p.oid = to_regprocedure(r.sig)) then
      raise exception '0152 precondition: % is not SECURITY DEFINER with the pinned search_path. STOP.', r.sig;
    end if;
  end loop;
  -- 0151 must already be applied (transition_dispatch_status authorizes before replay): 0152 continues the same defect class.
  if position('tsidk' in (select regexp_replace(lower(prosrc), '\s+', '', 'g') from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)'))) = 0 then
    raise exception '0152 precondition: proposal 0151 is not applied. STOP.';
  end if;
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is null then raise exception '0152 precondition: compute_financial_request_fingerprint(jsonb) missing (0143). STOP.'; end if;
  if to_regclass('public.factoring_policy_idempotency') is null or to_regclass('public.factoring_integration_lifecycle_idempotency') is null
     or to_regclass('public.dispatch_resource_reassignments') is null or to_regclass('public.legacy_invoice_review_idempotency') is null
     or to_regclass('public.carrier_invoice_lifecycle_idempotency') is null then
    raise exception '0152 precondition: a ledger table is missing. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint'
             and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')) then
    raise exception '0152 precondition: request_fingerprint already exists -- already applied? STOP.';
  end if;
  -- ZERO-ROW INVARIANT, checked UNDER exclusive locks (no concurrent writer can slip a row in before the ALTERs commit). Independent of preflight.sql.
  lock table public.factoring_policy_idempotency, public.factoring_integration_lifecycle_idempotency in access exclusive mode;   -- fixed order: policy ledger, then lifecycle ledger
  if (select count(*) from public.factoring_policy_idempotency) <> 0 then
    raise exception '0152 precondition: factoring_policy_idempotency is NOT empty (% row(s)); fingerprints cannot be derived for existing rows and a NULL fingerprint must never replay. STOP -- nothing was changed.', (select count(*) from public.factoring_policy_idempotency);
  end if;
  if (select count(*) from public.factoring_integration_lifecycle_idempotency) <> 0 then
    raise exception '0152 precondition: factoring_integration_lifecycle_idempotency is NOT empty (% row(s)); fingerprints cannot be derived for existing rows and a NULL fingerprint must never replay. STOP -- nothing was changed.', (select count(*) from public.factoring_integration_lifecycle_idempotency);
  end if;
  foreach v_md5 in array array['public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text)', 'public.transition_carrier_factoring_integration_lifecycle(text, uuid, text, timestamptz, text)', 'public._generate_carrier_invoice_payment_number_internal()'] loop
    if to_regprocedure(v_md5) is null then raise exception '0152 precondition: helper % missing. STOP.', v_md5; end if;
  end loop;

  create temp table _mig0152_funcs on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  create temp table _mig0152_misc on commit drop as
    select (select count(*) from public.factoring_policy_idempotency) n_pol, (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.carrier_id, t.idempotency_key), '')) from public.factoring_policy_idempotency t) pol_md5,
           (select count(*) from public.factoring_integration_lifecycle_idempotency) n_life, (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.action, t.target_id, t.idempotency_key), '')) from public.factoring_integration_lifecycle_idempotency t) life_md5,
           (select count(*) from public.dispatch_resource_reassignments) n_rea, (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_resource_reassignments t) rea_md5,
           (select count(*) from public.legacy_invoice_review_idempotency) n_rev, (select count(*) from public.carrier_invoice_lifecycle_idempotency) n_civ;
  raise notice '0152 PHASE 1 passed.';
end
$mig$;

-- ======================= PHASE 2 -- SCHEMA (NOT NULL columns), FUNCTIONS, PRIVILEGES =====
alter table public.factoring_policy_idempotency add column request_fingerprint text not null;
alter table public.factoring_integration_lifecycle_idempotency add column request_fingerprint text not null;
comment on column public.factoring_policy_idempotency.request_fingerprint is
  '0152: sha256 request fingerprint (operation, organization, carrier, mode, reason; NOT the expected_updated_at concurrency token -- 0139 deliberately replays across a stale token). NOT NULL: 0152 applies only while this ledger is empty. A replay whose fingerprint differs is refused (FPIDK).';
comment on column public.factoring_integration_lifecycle_idempotency.request_fingerprint is
  '0152: sha256 request fingerprint (operation, organization, target, every material parameter, reason; NOT the expected_updated_at concurrency token, which replay deliberately ignores). NOT NULL: 0152 applies only while this ledger is empty. A replay whose fingerprint differs is refused (IDEMPOTENCY_KEY_REUSED).';

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
  v_c_driver uuid;
  v_c_truck uuid;
  v_c_trailer uuid;
  v_c_reason text;
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

  -- 0152: the target dispatch is resolved and verified to belong to the caller's organization (else the SAME RRDNF a missing dispatch
  -- gets) BEFORE the ledger is read. The role gate above already precedes this point.
  select organization_id, load_id into v_dispatch_org, v_load_id
  from public.dispatches where id = p_dispatch_id;
  if v_dispatch_org is null or v_dispatch_org <> v_org then
    raise exception 'reassign_dispatch_resources: dispatch % not found.', p_dispatch_id using errcode = 'RRDNF';
  end if;

  -- Idempotency short-circuit -- AFTER authorization, BEFORE any lock, validation or write; organization-scoped and request-bound.
  if p_idempotency_key is not null then
    select r.result, r.new_driver_id, r.new_truck_id, r.new_trailer_id, r.reason
      into v_cached, v_c_driver, v_c_truck, v_c_trailer, v_c_reason
    from public.dispatch_resource_reassignments r
    where r.dispatch_id = p_dispatch_id and r.idempotency_key = p_idempotency_key and r.organization_id = v_org;
    if found then
      -- (pre-lock) the key is bound to the ORIGINAL request (driver, truck, trailer, reason as recorded in the ledger row).
      if (v_c_driver, v_c_truck, v_c_trailer, v_c_reason) is distinct from (p_driver_id, p_truck_id, p_trailer_id, p_reason) then
        raise exception 'reassign_dispatch_resources: this idempotency key was already used for a different request.' using errcode = 'RRIDK';
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
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

  -- 0152: re-check the ledger UNDER the load+dispatch locks so a concurrent duplicate replays the winner's committed result.
  if p_idempotency_key is not null then
    select r.result, r.new_driver_id, r.new_truck_id, r.new_trailer_id, r.reason
      into v_cached, v_c_driver, v_c_truck, v_c_trailer, v_c_reason
    from public.dispatch_resource_reassignments r
    where r.dispatch_id = p_dispatch_id and r.idempotency_key = p_idempotency_key and r.organization_id = v_org;
    if found then
      -- (post-lock) the key is bound to the ORIGINAL request (driver, truck, trailer, reason as recorded in the ledger row).
      if (v_c_driver, v_c_truck, v_c_trailer, v_c_reason) is distinct from (p_driver_id, p_truck_id, p_trailer_id, p_reason) then
        raise exception 'reassign_dispatch_resources: this idempotency key was already used for a different request.' using errcode = 'RRIDK';
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

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

create or replace function public.set_carrier_factoring_policy(
  p_carrier_id uuid,
  p_mode public.carrier_factoring_mode,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_carrier record;
  v_cached jsonb;
  v_cached_fp text;
  v_fp text;
  v_carrier_org uuid;
  v_open_activity int;
  v_readiness jsonb;
begin
  if v_uid is null then
    raise exception 'set_carrier_factoring_policy: authentication required.' using errcode = 'FPAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'set_carrier_factoring_policy: caller has no organization.' using errcode = 'FPAUT';
  end if;
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'set_carrier_factoring_policy: only an owner or admin may change a carrier''s factoring policy.' using errcode = 'FPROL';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'set_carrier_factoring_policy: a reason is required.' using errcode = 'FPRSN';
  end if;

  -- 0152: the target carrier must belong to the caller's organization (else the SAME FPDNF a missing carrier gets) BEFORE the ledger is read.
  select organization_id into v_carrier_org from public.carriers where id = p_carrier_id;
  if v_carrier_org is null or v_carrier_org <> v_org then
    raise exception 'set_carrier_factoring_policy: carrier not found.' using errcode = 'FPDNF';
  end if;
  v_fp := public.compute_financial_request_fingerprint(jsonb_build_object(
      'operation', 'set_carrier_factoring_policy',
      'schema_version', 1,
      'organization_id', v_org,
      'carrier_id', p_carrier_id,
      'mode', p_mode,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    ));
  if p_idempotency_key is not null then
    select result, request_fingerprint into v_cached, v_cached_fp from public.factoring_policy_idempotency
      where carrier_id = p_carrier_id and idempotency_key = p_idempotency_key and organization_id = v_org;
    if found then
      -- (pre-lock) request-bound; fails CLOSED: a NULL or different fingerprint is never replayed (the column is NOT NULL, this is defence in depth).
      if v_cached_fp is distinct from v_fp then
        raise exception 'set_carrier_factoring_policy: this idempotency key was already used for a different request.' using errcode = 'FPIDK';
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('carrier_factoring_policy:' || p_carrier_id::text));

  select id, organization_id, factoring_mode, updated_at into v_carrier
  from public.carriers where id = p_carrier_id for update;

  -- 0152: re-check the ledger UNDER the advisory + row locks so a concurrent duplicate replays the winner's committed result.
  if p_idempotency_key is not null then
    select result, request_fingerprint into v_cached, v_cached_fp from public.factoring_policy_idempotency
      where carrier_id = p_carrier_id and idempotency_key = p_idempotency_key and organization_id = v_org;
    if found then
      -- (post-lock) request-bound; fails CLOSED: a NULL or different fingerprint is never replayed (the column is NOT NULL, this is defence in depth).
      if v_cached_fp is distinct from v_fp then
        raise exception 'set_carrier_factoring_policy: this idempotency key was already used for a different request.' using errcode = 'FPIDK';
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

  if v_carrier.id is null or v_carrier.organization_id <> v_org then
    raise exception 'set_carrier_factoring_policy: carrier not found.' using errcode = 'FPDNF';
  end if;

  -- Optimistic concurrency (mirrors reassign_dispatch_resources, 0135):
  -- a mismatch is a STRUCTURED result, never an exception -- no write.
  if p_expected_updated_at is null then
    return jsonb_build_object('success', false, 'expected_version_required', true, 'carrier_id', p_carrier_id,
      'current_updated_at', v_carrier.updated_at,
      'message', 'This policy change requires the version of the carrier you loaded. Please reload and try again.');
  end if;
  if v_carrier.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'stale_record', true, 'carrier_id', p_carrier_id,
      'current_updated_at', v_carrier.updated_at,
      'message', 'This carrier was changed by someone else. Please refresh and try again.');
  end if;

  if v_carrier.factoring_mode = p_mode then
    v_readiness := jsonb_build_object('success', true, 'no_op', true, 'carrier_id', p_carrier_id, 'mode', p_mode);
  else
    -- factored -> direct: block if open factored-invoice activity exists.
    if v_carrier.factoring_mode = 'factored' and p_mode = 'direct' then
      select count(*) into v_open_activity
      from public.factored_invoices fi
      join public.factoring_relationships fr on fr.id = fi.factoring_relationship_id
      where fr.carrier_id = p_carrier_id
        and fi.status not in ('rejected', 'cancelled', 'closed');
      if v_open_activity > 0 then
        return jsonb_build_object('success', false, 'blocked', true, 'reason', 'open_factored_activity',
          'carrier_id', p_carrier_id, 'open_count', v_open_activity,
          'message', format('This carrier has %s open factored invoice(s) in flight -- resolve or close them before switching to direct billing.', v_open_activity));
      end if;
    end if;

    -- ->factored: must be ready (mirrors the classifier's own logic,
    -- re-derived here rather than calling the classifier, which itself
    -- reads factoring_mode and would be circular mid-transition).
    if p_mode = 'factored' then
      if not exists (
        select 1 from public.factoring_relationships fr
        join public.factoring_companies fc on fc.id = fr.factoring_company_id
        where fr.carrier_id = p_carrier_id and fr.is_default and fr.is_active and fc.is_active
          and (fr.effective_from is null or fr.effective_from <= current_date)
          and (fr.effective_to is null or fr.effective_to >= current_date)
          and fr.remittance_instructions is not null and btrim(fr.remittance_instructions) <> ''
          and fr.noa_approved
          and fr.submission_method is not null
      ) then
        return jsonb_build_object('success', false, 'not_ready', true, 'carrier_id', p_carrier_id,
          'message', 'This carrier has no complete, ready default factoring relationship yet -- see classify_carrier_factoring_readiness() for exactly what is missing.');
      end if;
    end if;

    update public.carriers set factoring_mode = p_mode where id = p_carrier_id;

    perform public.log_activity(
      'carrier'::public.entity_type, p_carrier_id, 'factoring_policy_changed',
      jsonb_build_object('old_mode', v_carrier.factoring_mode, 'new_mode', p_mode, 'reason', p_reason),
      v_org);

    v_readiness := jsonb_build_object('success', true, 'no_op', false, 'carrier_id', p_carrier_id, 'mode', p_mode);
  end if;

  if p_idempotency_key is not null then
    insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result, request_fingerprint)
    values (v_org, p_carrier_id, p_idempotency_key, v_readiness, v_fp)
    on conflict (carrier_id, idempotency_key) do nothing;
  end if;

  return v_readiness;
end;
$fn$;

create or replace function public.configure_carrier_factoring_integration(
  p_relationship_id uuid,
  p_secret_reference text,
  p_external_account_identifier text,
  p_provider public.integration_provider,
  p_submission_destination text,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_fp text;
  v_relationship record;
  v_new_id uuid;
  v_updated_at timestamptz;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may configure a factoring integration.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;
  if p_secret_reference is not null and p_secret_reference !~ '^[a-z][a-z0-9+.-]*://[A-Za-z0-9_.~-]{1,200}$' then
    return jsonb_build_object('success', false, 'code', 'OPAQUE_REFERENCE_REQUIRED',
      'message', 'The credential reference must be an opaque pointer (e.g. vault://...), never a raw secret.');
  end if;

  select * into v_relationship from public.factoring_relationships where id = p_relationship_id and organization_id = v_org for update;
  if v_relationship.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring relationship not found.');
  end if;
  if v_relationship.carrier_id is null then
    return jsonb_build_object('success', false, 'code', 'UNRESOLVED_CARRIER', 'message', 'This relationship has no resolved carrier yet.');
  end if;

  -- 0152: request binding. The organization-scoped target lookup and the owner/admin gate above already precede this read.
  v_fp := public.compute_financial_request_fingerprint(jsonb_build_object(
      'operation', 'configure_carrier_factoring_integration',
      'schema_version', 1,
      'organization_id', v_org,
      'relationship_id', p_relationship_id,
      'secret_reference', p_secret_reference,
      'external_account_identifier', p_external_account_identifier,
      'provider', p_provider,
      'submission_destination', p_submission_destination,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    ));
  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = 'configure' and target_id = p_relationship_id and idempotency_key = p_idempotency_key;
  if found then
    if v_cached.request_fingerprint is distinct from v_fp then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_relationship.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_relationship.updated_at,
      'message', 'This factoring relationship was changed by someone else. Please refresh and try again.');
  end if;
  if v_relationship.submission_method = 'api' and (p_secret_reference is null or p_provider is distinct from 'factoring_api'::public.integration_provider
    or nullif(btrim(p_external_account_identifier), '') is null)
  then
    return jsonb_build_object('success', false, 'code', 'API_METADATA_REQUIRED',
      'message', 'API submission requires a provider, an external account identifier, and a credential reference.');
  end if;

  insert into public.carrier_factoring_integrations (
    organization_id, carrier_id, factoring_relationship_id, factoring_company_id,
    submission_method, provider, secret_reference, external_account_identifier, submission_destination, created_by
  ) values (
    v_org, v_relationship.carrier_id, v_relationship.id, v_relationship.factoring_company_id,
    v_relationship.submission_method, p_provider, p_secret_reference, p_external_account_identifier, p_submission_destination, v_uid
  )
  returning id, updated_at into v_new_id, v_updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_integration_configured',
    jsonb_build_object('integration_id', v_new_id, 'relationship_id', v_relationship.id, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'integration_id', v_new_id, 'relationship_id', v_relationship.id,
    'carrier_id', v_relationship.carrier_id, 'configuration_status', 'draft', 'updated_at', v_updated_at);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result, request_fingerprint)
  values (v_org, 'configure', p_relationship_id, p_idempotency_key, v_result, v_fp);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
end
$fn$;

create or replace function public.rotate_carrier_factoring_integration(
  p_integration_id uuid,
  p_secret_reference text,
  p_external_account_identifier text,
  p_provider public.integration_provider,
  p_submission_destination text,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_fp text;
  v_relationship_id uuid;
  v_old public.carrier_factoring_integrations%rowtype;
  v_new_id uuid;
  v_updated_at timestamptz;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may rotate a factoring integration''s credential reference.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;
  if p_secret_reference is not null and p_secret_reference !~ '^[a-z][a-z0-9+.-]*://[A-Za-z0-9_.~-]{1,200}$' then
    return jsonb_build_object('success', false, 'code', 'OPAQUE_REFERENCE_REQUIRED',
      'message', 'The credential reference must be an opaque pointer (e.g. vault://...), never a raw secret.');
  end if;

  -- Resolve, without locking, purely to know which relationship row to
  -- lock first (same fixed order as every other lifecycle transition).
  select factoring_relationship_id into v_relationship_id
  from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org;
  if v_relationship_id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring integration not found.');
  end if;
  perform 1 from public.factoring_relationships where id = v_relationship_id for update;
  select * into v_old from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org for update;

  -- 0152: request binding. The organization-scoped target lookup and the owner/admin gate above already precede this read.
  v_fp := public.compute_financial_request_fingerprint(jsonb_build_object(
      'operation', 'rotate_carrier_factoring_integration',
      'schema_version', 1,
      'organization_id', v_org,
      'integration_id', p_integration_id,
      'secret_reference', p_secret_reference,
      'external_account_identifier', p_external_account_identifier,
      'provider', p_provider,
      'submission_destination', p_submission_destination,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    ));
  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = 'rotate' and target_id = p_integration_id and idempotency_key = p_idempotency_key;
  if found then
    if v_cached.request_fingerprint is distinct from v_fp then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_old.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_old.updated_at,
      'message', 'This factoring integration was changed by someone else. Please refresh and try again.');
  end if;
  if v_old.configuration_status = 'revoked' then
    return jsonb_build_object('success', false, 'code', 'REVOKED_TERMINAL', 'message', 'This integration is already revoked -- configure a new one instead of rotating it.');
  end if;

  -- Revoke the OLD row (history preserved, never overwritten) and insert
  -- a brand-new draft replacement atomically -- rotation deliberately
  -- requires another verification/activation cycle, never a silent
  -- credential swap on an already-ready row.
  update public.carrier_factoring_integrations set configuration_status = 'revoked', is_active = false where id = v_old.id;

  insert into public.carrier_factoring_integrations (
    organization_id, carrier_id, factoring_relationship_id, factoring_company_id,
    submission_method, provider, secret_reference, external_account_identifier, submission_destination, created_by
  ) values (
    v_org, v_old.carrier_id, v_old.factoring_relationship_id, v_old.factoring_company_id,
    v_old.submission_method, p_provider, p_secret_reference, p_external_account_identifier, p_submission_destination, v_uid
  )
  returning id, updated_at into v_new_id, v_updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_old.carrier_id, 'factoring_integration_rotated',
    jsonb_build_object('replaced_integration_id', v_old.id, 'integration_id', v_new_id, 'relationship_id', v_old.factoring_relationship_id, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'integration_id', v_new_id, 'replaced_integration_id', v_old.id,
    'relationship_id', v_old.factoring_relationship_id, 'carrier_id', v_old.carrier_id, 'configuration_status', 'draft', 'updated_at', v_updated_at);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result, request_fingerprint)
  values (v_org, 'rotate', p_integration_id, p_idempotency_key, v_result, v_fp);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
end
$fn$;

create or replace function public.transition_carrier_factoring_integration_lifecycle(
  p_action text, p_integration_id uuid, p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_fp text;
  v_relationship_id uuid;
  v_carrier record;
  v_company_active boolean;
  v_doc record;
  v_integration record;
  v_next_state text;
  v_problem text;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may change a factoring integration''s lifecycle state.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;

  v_next_state := case p_action
    when 'activate' then 'ready'
    when 'deactivate' then 'suspended'
    when 'verify' then 'pending_verification'
    when 'fail' then 'failed'
    when 'revoke' then 'revoked'
  end;
  if v_next_state is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_ACTION', 'message', 'Unrecognized lifecycle action.');
  end if;

  -- Resolve the relationship id WITHOUT locking, purely to know which
  -- relationship row to lock first (fixed order: relationship, then --
  -- only for activation -- carrier/company/document, then the
  -- integration row itself. This is the SAME relationship row
  -- set_default_factoring_relationship()/approve_factoring_relationship_
  -- noa() already lock FOR UPDATE, and the SAME carrier row set_carrier_
  -- factoring_policy() already locks FOR UPDATE -- taking them here in
  -- the identical order closes the TOCTOU window between this RPC and
  -- those three without requiring any change to their own bodies).
  select factoring_relationship_id into v_relationship_id
  from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org;
  if v_relationship_id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring integration not found.');
  end if;

  perform 1 from public.factoring_relationships where id = v_relationship_id for update;

  if v_next_state = 'ready' then
    -- Fixed order (relationship already locked above): carrier row FOR
    -- UPDATE (the SAME row set_carrier_factoring_policy() locks), then a
    -- FOR SHARE read-lock on the factoring company row and the NOA
    -- document row (if referenced) -- FOR SHARE is enough here since
    -- activation only ever READS these, but it must still conflict with
    -- a concurrent UPDATE of either (company deactivation; document
    -- unverification), closing the TOCTOU window Section 8 scenario 6
    -- asks for. A template-only NOA (no document) simply locks nothing
    -- here -- there is no document row to protect.
    select c.* into v_carrier from public.carriers c
      join public.factoring_relationships r on r.carrier_id = c.id
      where r.id = v_relationship_id
      for update of c;
    select fc.is_active into v_company_active from public.factoring_companies fc
      join public.factoring_relationships r on r.factoring_company_id = fc.id
      where r.id = v_relationship_id
      for share of fc;
    select d.* into v_doc from public.documents d
      join public.factoring_relationships r on r.noa_document_id = d.id
      where r.id = v_relationship_id
      for share of d;
  end if;

  select * into v_integration from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org for update;
  if v_integration.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring integration not found.');
  end if;

  -- Idempotency replay check happens AFTER the locks above -- a
  -- concurrent identical-key request that serialized behind this one
  -- will see the FIRST call's committed cache row here, not race it.
  -- 0152: request binding. The organization-scoped target lookup and the owner/admin gate above already precede this read.
  v_fp := public.compute_financial_request_fingerprint(jsonb_build_object(
      'operation', 'transition_carrier_factoring_integration_lifecycle',
      'schema_version', 1,
      'organization_id', v_org,
      'integration_id', p_integration_id,
      'action', p_action,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    ));
  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = p_action and target_id = p_integration_id and idempotency_key = p_idempotency_key;
  if found then
    if v_cached.request_fingerprint is distinct from v_fp then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_integration.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_integration.updated_at,
      'message', 'This factoring integration was changed by someone else. Please refresh and try again.');
  end if;
  if v_integration.configuration_status = v_next_state then
    return jsonb_build_object('success', false, 'code', 'ALREADY_IN_STATE', 'message', format('This integration is already %s.', v_next_state));
  end if;
  if v_integration.configuration_status = 'revoked' then
    return jsonb_build_object('success', false, 'code', 'REVOKED_TERMINAL', 'message', 'A revoked integration is terminal -- configure a new one.');
  end if;

  if v_next_state = 'ready' then
    if not exists (
      select 1 from public.carrier_factoring_integrations x
      where x.factoring_relationship_id = v_relationship_id and x.is_active and x.id <> v_integration.id
    ) then
      -- (no conflicting active row -- fall through)
      null;
    else
      return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'Another integration is already active and ready for this relationship. Deactivate it first.');
    end if;
    v_problem := public.factoring_relationship_lifecycle_problem(v_relationship_id);
    if v_problem is not null then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', v_problem,
        'message', format('This relationship is not ready for an active integration (%s).', v_problem));
    end if;
    if v_integration.effective_to is not null then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', 'finite_expiry_requires_lifecycle_scheduler',
        'message', 'This integration has a finite end date -- nothing in this schema clears it automatically. Reconfigure without an end date, or contact engineering before activating a time-limited integration.');
    end if;
    if v_integration.effective_from > current_date then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', 'integration_not_yet_effective',
        'message', 'This integration is not yet effective.');
    end if;
    if v_integration.submission_method = 'api' and (
      v_integration.provider is distinct from 'factoring_api'::public.integration_provider
      or nullif(btrim(v_integration.external_account_identifier), '') is null
      or v_integration.secret_reference is null
    ) then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', 'api_metadata_incomplete',
        'message', 'This integration is missing required provider/account/credential-reference metadata for API submission.');
    end if;
  end if;

  update public.carrier_factoring_integrations
  set configuration_status = v_next_state,
      is_active = (v_next_state = 'ready'),
      approved_by = case when v_next_state = 'ready' then v_uid else approved_by end,
      approved_at = case when v_next_state = 'ready' then now() else approved_at end
  where id = v_integration.id
  returning updated_at into v_integration.updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_integration.carrier_id, 'factoring_integration_' || p_action,
    jsonb_build_object('integration_id', v_integration.id, 'relationship_id', v_relationship_id, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'integration_id', v_integration.id, 'relationship_id', v_relationship_id,
    'carrier_id', v_integration.carrier_id, 'configuration_status', v_next_state, 'updated_at', v_integration.updated_at);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result, request_fingerprint)
  values (v_org, p_action, p_integration_id, p_idempotency_key, v_result, v_fp);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
  when sqlstate 'F1402' then
    return jsonb_build_object('success', false, 'code', 'INVALID_LIFECYCLE_TRANSITION', 'message', 'That lifecycle transition is not permitted.');
  when unique_violation then
    return jsonb_build_object('success', false, 'code', 'LIFECYCLE_CONFLICT', 'message', 'Another integration became active for this relationship first. Please refresh and try again.');
end
$fn$;

create or replace function public.deactivate_factoring_relationship(
  p_relationship_id uuid,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text,
  p_coordinated boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_fp text;
  v_relationship record;
  v_active_count int;
  v_updated_at timestamptz;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may deactivate a factoring relationship.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;

  select * into v_relationship from public.factoring_relationships where id = p_relationship_id and organization_id = v_org for update;
  if v_relationship.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring relationship not found.');
  end if;

  -- 0152: request binding. The organization-scoped target lookup and the owner/admin gate above already precede this read.
  v_fp := public.compute_financial_request_fingerprint(jsonb_build_object(
      'operation', 'deactivate_factoring_relationship',
      'schema_version', 1,
      'organization_id', v_org,
      'relationship_id', p_relationship_id,
      'coordinated', coalesce(p_coordinated, false),
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    ));
  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = 'deactivate_relationship' and target_id = p_relationship_id and idempotency_key = p_idempotency_key;
  if found then
    if v_cached.request_fingerprint is distinct from v_fp then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_relationship.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_relationship.updated_at,
      'message', 'This factoring relationship was changed by someone else. Please refresh and try again.');
  end if;
  if not v_relationship.is_active then
    return jsonb_build_object('success', false, 'code', 'ALREADY_INACTIVE', 'message', 'This relationship is already inactive.');
  end if;

  select count(*) into v_active_count from public.carrier_factoring_integrations
    where factoring_relationship_id = v_relationship.id and is_active;
  if v_active_count > 0 and not p_coordinated then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'active_count', v_active_count,
      'message', format('This relationship has %s active factoring integration(s). Deactivate them first, or pass p_coordinated=true to deactivate them together with the relationship.', v_active_count));
  end if;

  if v_active_count > 0 then
    update public.carrier_factoring_integrations set configuration_status = 'suspended', is_active = false
      where factoring_relationship_id = v_relationship.id and is_active;
  end if;

  update public.factoring_relationships set is_active = false, is_default = false
    where id = v_relationship.id
    returning updated_at into v_updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_relationship_deactivated',
    jsonb_build_object('relationship_id', v_relationship.id, 'coordinated', p_coordinated, 'suspended_integrations', v_active_count, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'relationship_id', v_relationship.id, 'carrier_id', v_relationship.carrier_id,
    'updated_at', v_updated_at, 'suspended_integrations', v_active_count);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result, request_fingerprint)
  values (v_org, 'deactivate_relationship', p_relationship_id, p_idempotency_key, v_result, v_fp);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
end
$fn$;

create or replace function public.review_legacy_invoice_carrier_migration(
  p_review_id uuid,
  p_resolution text,
  p_notes text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_row record;
  v_cached jsonb;
  v_cached_review uuid;
  v_result jsonb;
begin
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may review a legacy invoice classification.');
  end if;

  if p_resolution is null or btrim(p_resolution) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A meaningful resolution is required.');
  end if;

  -- Row-lock BEFORE the organization/staleness checks so two concurrent
  -- reviews of the SAME row can never both pass the staleness check --
  -- the second waits for the first's transaction to commit (or roll
  -- back) before evaluating its own updated_at comparison.
  select id, organization_id, legacy_invoice_id, updated_at, resolution, review_notes into v_row
  from public.legacy_invoice_carrier_migration_review
  where id = p_review_id
  for update;

  if v_row.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Review record not found.');
  end if;
  -- "Not found" and "belongs to another organization" are deliberately
  -- indistinguishable -- a forged review id from another tenant must
  -- never learn whether it exists elsewhere.
  if v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Review record not found.');
  end if;
  -- 0152: replay decision AFTER the role gate, the row lock and the organization-verified target check. Bound to the review row itself:
  -- the key must have been used for THIS review, with the same resolution and notes (the row still holds the originals).
  select result, review_id into v_cached, v_cached_review from public.legacy_invoice_review_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached is not null then
    if v_cached_review is distinct from p_review_id or v_row.resolution is distinct from btrim(p_resolution) or v_row.review_notes is distinct from p_notes then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached;
  end if;

  if v_row.updated_at <> p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This review record has changed since you loaded it. Reload and try again.');
  end if;

  update public.legacy_invoice_carrier_migration_review
    set reviewed = true,
        reviewed_by = auth.uid(),
        reviewed_at = now(),
        resolution = btrim(p_resolution),
        review_notes = p_notes
    where id = p_review_id;

  perform public.log_activity('invoice'::public.entity_type, v_row.legacy_invoice_id, 'carrier_migration_reviewed',
    jsonb_build_object('review_id', p_review_id, 'resolution', btrim(p_resolution), 'notes', p_notes));

  v_result := jsonb_build_object(
    'success', true, 'code', 'REVIEWED', 'review_id', p_review_id,
    'reviewed_by', auth.uid(), 'reviewed_at', now(), 'resolution', btrim(p_resolution)
  );

  insert into public.legacy_invoice_review_idempotency (organization_id, idempotency_key, review_id, result)
  values (v_org, p_idempotency_key, p_review_id, v_result);

  return v_result;
end;
$fn$;

create or replace function public.update_carrier_invoice_draft(
  p_invoice_id uuid,
  p_patch jsonb,
  p_expected_updated_at timestamptz,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_row record;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_fingerprint text;
  v_lock_key bigint;
  v_patch_keys text[];
  v_master_keys constant text[] := array['notes','due_date','payment_terms_days','broker_id','customer_id','currency'];
  v_financial_keys constant text[] := array['broker_id','customer_id','currency','payment_terms_days'];
  v_role_keys text[];
  v_new_notes text;
  v_new_due_date date;
  v_has_due_date boolean := false;
  v_new_payment_terms_days integer;
  v_has_payment_terms boolean := false;
  v_new_currency text;
  v_touches_recipient boolean := false;
  v_new_recipient_type public.invoice_recipient_type;
  -- Presence-gated, purely SYNTACTIC parse -- fingerprint-safe, computed
  -- before any lock or row access.
  v_new_broker_id uuid;
  v_has_broker_id boolean := false;
  v_new_customer_id uuid;
  v_has_customer_id boolean := false;
  -- Row-resolved (an omitted half of the recipient pair defaults to the
  -- LOCKED row's current value) -- business logic, computed only after
  -- the row is locked, used for validation/eligibility and the actual
  -- UPDATE, never fingerprinted.
  v_apply_broker_id uuid;
  v_apply_customer_id uuid;
  v_normalized_patch jsonb := '{}'::jsonb;
  v_party_status public.carrier_party_status;
  v_changed_fields text[] := '{}';
  v_result jsonb;
  v_operation constant text := 'update_carrier_invoice_draft';
  v_schema_version constant integer := 1;
begin
  ------------------------------------------------------------------
  -- STEP 1-4: request-shape validation, unknown-key rejection, and
  -- SYNTACTIC normalization of every permitted, present value -- pure
  -- functions of p_patch alone, no row access, no role check, nothing
  -- written yet.
  ------------------------------------------------------------------
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'p_patch must be a JSON object.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  -- Step 2: reject unknown keys BEFORE fingerprinting, locking, or ever
  -- touching the idempotency table.
  select array_agg(k) into v_patch_keys from jsonb_object_keys(p_patch) k;
  v_patch_keys := coalesce(v_patch_keys, '{}');
  if not (v_patch_keys <@ v_master_keys) then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Unknown field in patch.');
  end if;
  if array_length(v_patch_keys, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'No recognized field was provided to change.');
  end if;

  -- Step 3: normalize each PERMITTED, PRESENT value exactly as it will
  -- be stored (still no writes, no row access).
  if p_patch ? 'notes' then
    if jsonb_typeof(p_patch->'notes') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'notes must be a string or null.');
    end if;
    v_new_notes := p_patch->>'notes';
  end if;

  if p_patch ? 'due_date' then
    if jsonb_typeof(p_patch->'due_date') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'due_date must be a date string or null.');
    end if;
    begin
      v_new_due_date := nullif(p_patch->>'due_date', '')::date;
      v_has_due_date := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'due_date is not a valid date.');
    end;
  end if;

  if p_patch ? 'payment_terms_days' then
    if jsonb_typeof(p_patch->'payment_terms_days') not in ('number', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days must be a number or null.');
    end if;
    begin
      v_new_payment_terms_days := (p_patch->>'payment_terms_days')::integer;
      v_has_payment_terms := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days is not a valid integer.');
    end;
    if v_new_payment_terms_days is not null and (v_new_payment_terms_days < 0 or v_new_payment_terms_days > 365) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days must be between 0 and 365.');
    end if;
  end if;

  if p_patch ? 'currency' then
    if jsonb_typeof(p_patch->'currency') <> 'string' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'currency must be a string.');
    end if;
    v_new_currency := p_patch->>'currency';
    if v_new_currency !~ '^[A-Z]{3}$' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'currency must be a 3-letter uppercase code.');
    end if;
  end if;

  if p_patch ? 'broker_id' then
    if jsonb_typeof(p_patch->'broker_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id must be a uuid string or null.');
    end if;
    begin
      v_new_broker_id := nullif(p_patch->>'broker_id', '')::uuid;
      v_has_broker_id := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id/customer_id must be valid uuids.');
    end;
  end if;
  if p_patch ? 'customer_id' then
    if jsonb_typeof(p_patch->'customer_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'customer_id must be a uuid string or null.');
    end if;
    begin
      v_new_customer_id := nullif(p_patch->>'customer_id', '')::uuid;
      v_has_customer_id := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id/customer_id must be valid uuids.');
    end;
  end if;
  v_touches_recipient := v_has_broker_id or v_has_customer_id;

  -- Step 4: normalized_patch carries ONLY the keys actually present,
  -- each holding its canonical, as-will-be-stored value -- an absent key
  -- never appears here (absence still means "leave unchanged"), and an
  -- explicit JSON null is never conflated with a missing key.
  if p_patch ? 'notes' then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('notes', v_new_notes);
  end if;
  if v_has_due_date then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('due_date', to_jsonb(v_new_due_date));
  end if;
  if v_has_payment_terms then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('payment_terms_days', to_jsonb(v_new_payment_terms_days));
  end if;
  if p_patch ? 'currency' then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('currency', v_new_currency);
  end if;
  if v_has_broker_id then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('broker_id', to_jsonb(v_new_broker_id));
  end if;
  if v_has_customer_id then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('customer_id', to_jsonb(v_new_customer_id));
  end if;

  ------------------------------------------------------------------
  -- STEP 5-9: build the canonical payload from normalized_patch (never
  -- raw p_patch), fingerprint, acquire the advisory lock, lock and
  -- revalidate the invoice, resolve idempotency.
  ------------------------------------------------------------------
  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation,
      'schema_version', v_schema_version,
      'organization_id', v_org,
      'invoice_id', p_invoice_id,
      'patch', v_normalized_patch,
      'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );

  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select id, organization_id, invoice_document_type, issuance_status, updated_at, carrier_id,
         recipient_type, recipient_broker_id, recipient_customer_id
    into v_row
  from public.carrier_invoices where id = p_invoice_id for update;

  -- "Not found" and "belongs to another organization" are deliberately
  -- indistinguishable.
  if v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_invoice_lifecycle_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    -- 0152: a replay requires CURRENT authorization exactly as performing the edit does (role, and the fields this role may edit).
    if public.has_role(array['owner', 'admin']::public.org_role[]) then
      v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'broker_id', 'customer_id', 'currency'];
    elsif public.has_role(array['accountant']::public.org_role[]) then
      v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'currency'];
    elsif public.has_role(array['dispatcher']::public.org_role[]) then
      v_role_keys := array['notes'];
    else
      return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to edit this invoice.');
    end if;
    if not (v_patch_keys <@ v_role_keys) then
      return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'One or more fields in this patch are not permitted for your role.');
    end if;
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_row.issuance_status not in ('draft', 'ready_for_issue') then
    return jsonb_build_object('success', false, 'code', 'NOT_EDITABLE', 'message', 'Only a draft or ready-for-issue invoice can be edited through this RPC.');
  end if;
  if v_row.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This invoice has changed since you loaded it. Reload and try again.');
  end if;

  ------------------------------------------------------------------
  -- STEP 10: role/business validation -- including whatever genuinely
  -- requires the now-locked row. Nothing here changes the fingerprint;
  -- it can only REJECT a request the fingerprint has already committed
  -- to representing.
  ------------------------------------------------------------------
  if public.has_role(array['owner', 'admin']::public.org_role[]) then
    v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'broker_id', 'customer_id', 'currency'];
  elsif public.has_role(array['accountant']::public.org_role[]) then
    v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'currency'];
  elsif public.has_role(array['dispatcher']::public.org_role[]) then
    v_role_keys := array['notes'];
  else
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to edit this invoice.');
  end if;

  if not (v_patch_keys <@ v_role_keys) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'One or more fields in this patch are not permitted for your role.');
  end if;

  if (v_patch_keys && v_financial_keys) and (p_reason is null or btrim(p_reason) = '') then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A reason is required to change billing/recipient fields.');
  end if;

  if v_touches_recipient then
    if v_row.invoice_document_type = 'dispatch_service_invoice' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A dispatch-service invoice cannot receive a broker/customer recipient.');
    end if;

    -- An OMITTED half of the recipient pair defaults to the LOCKED row's
    -- current value -- this is business resolution requiring the row,
    -- deliberately kept separate from the fingerprinted, presence-only
    -- v_new_broker_id/v_new_customer_id above.
    v_apply_broker_id := case when v_has_broker_id then v_new_broker_id else v_row.recipient_broker_id end;
    v_apply_customer_id := case when v_has_customer_id then v_new_customer_id else v_row.recipient_customer_id end;

    if (v_apply_broker_id is not null) = (v_apply_customer_id is not null) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Exactly one of broker_id or customer_id must be set for a freight invoice.');
    end if;
    v_new_recipient_type := case when v_apply_broker_id is not null then 'broker' else 'customer' end;

    -- Cross-organization / never-existed is deliberately indistinguishable.
    if v_apply_broker_id is not null then
      if not exists (select 1 from public.brokers where id = v_apply_broker_id and organization_id = v_org and not is_blacklisted) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected broker is not available.');
      end if;
      select status into v_party_status from public.carrier_brokers where carrier_id = v_row.carrier_id and broker_id = v_apply_broker_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected broker.');
      end if;
    else
      if not exists (select 1 from public.customers where id = v_apply_customer_id and organization_id = v_org and is_active) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected customer is not available.');
      end if;
      select status into v_party_status from public.carrier_customers where carrier_id = v_row.carrier_id and customer_id = v_apply_customer_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected customer.');
      end if;
    end if;
  end if;

  ------------------------------------------------------------------
  -- STEP 11-12: APPLY the already-normalized patch; audit and store the
  -- result atomically. The mutation, the audit event, and the
  -- idempotency-record insert are wrapped in ONE nested block (plpgsql
  -- BEGIN/EXCEPTION implicitly opens a savepoint) so a collision at the
  -- final INSERT rolls back the WHOLE block together -- a collision
  -- produces zero mutation and zero audit event, never a partial success
  -- behind a reported failure.
  ------------------------------------------------------------------
  begin
    if p_patch ? 'notes' then
      update public.carrier_invoices set notes = v_new_notes where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'notes');
    end if;
    if v_has_due_date then
      update public.carrier_invoices set due_date = v_new_due_date where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'due_date');
    end if;
    if v_has_payment_terms then
      update public.carrier_invoices set payment_terms_days = v_new_payment_terms_days where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'payment_terms_days');
    end if;
    if p_patch ? 'currency' then
      update public.carrier_invoices set currency = v_new_currency where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'currency');
    end if;
    if v_touches_recipient then
      update public.carrier_invoices
        set recipient_type = v_new_recipient_type, recipient_broker_id = v_apply_broker_id, recipient_customer_id = v_apply_customer_id
        where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'recipient');
    end if;

    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'carrier_invoice_draft_updated',
      jsonb_build_object('changed_fields', to_jsonb(v_changed_fields), 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'UPDATED', 'invoice_id', p_invoice_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'updated_at', (select updated_at from public.carrier_invoices where id = p_invoice_id)
    );

    insert into public.carrier_invoice_lifecycle_idempotency
      (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, p_invoice_id, v_operation, v_fingerprint, v_schema_version, v_result, 'completed', auth.uid());
  exception
    when unique_violation then
      declare
        v_constraint text;
      begin
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'civ_idempotency_unique' then
          raise;
        end if;
      end;
      -- The whole APPLY block above (mutation + audit event + this same
      -- INSERT attempt) has already been rolled back to the savepoint at
      -- this point -- the row is exactly as it was before this call.
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_invoice_lifecycle_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

revoke all on function public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.transition_carrier_factoring_integration_lifecycle(text, uuid, text, timestamptz, text) from public, anon, authenticated, service_role;
revoke all on function public._generate_carrier_invoice_payment_number_internal() from public, anon, authenticated, service_role;

-- ======================= PHASE 3 -- POSTCONDITIONS =============================
do $mig$
declare
  r record;
  v_bad integer;
  m record;
begin
  for r in select * from (values
    ('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)', '25feafae360e205e44c89cac6b8af6aa'),
    ('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)', '8eb6b0a5aafee5842e8c1b56914e1a5a'),
    ('public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', '9d74b0fee3062605df4e9ce7fb84589c'),
    ('public.rotate_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', '79776401048dd10919e1d969fde81545'),
    ('public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)', '3cf14466f17953413047b3b4ab8d37e4'),
    ('public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)', '532c14e3edb67e56e972adfdf9fdf79c'),
    ('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', '9e15d52c59ed3ea03491a8737dce273d'),
    ('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', '58037929fdf3093a3f5ac72ef72a277d')
  ) as t(sig, body_md5) loop
    if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure(r.sig)) is distinct from r.body_md5 then
      raise exception '0152 postcondition: live % is not the reviewed 0152 definition.', r.sig;
    end if;
  end loop;

  create temp table _mig0152_after on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  -- no function added/removed; every property except ACL identical; ACL identical except the three helpers
  select count(*) into v_bad from _mig0152_funcs o full join _mig0152_after n using (sig)
   where o.sig is null or n.sig is null
      or (o.config, o.prosecdef, o.proowner, o.prorettype, o.provolatile, o.args, o.descr) is distinct from (n.config, n.prosecdef, n.proowner, n.prorettype, n.provolatile, n.args, n.descr)
      or (o.acl is distinct from n.acl and o.sig not in (select to_regprocedure(h)::text from unnest(array['public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text)', 'public.transition_carrier_factoring_integration_lifecycle(text, uuid, text, timestamptz, text)', 'public._generate_carrier_invoice_payment_number_internal()']) h));
  if v_bad <> 0 then raise exception '0152 postcondition: % function(s) added/removed or with changed properties/ACL.', v_bad; end if;
  -- exactly the eight bodies changed
  select count(*) into v_bad from _mig0152_funcs o join _mig0152_after n using (sig) where o.body_md5 is distinct from n.body_md5;
  if v_bad <> 8 then raise exception '0152 postcondition: expected exactly 8 changed function bodies, found %.', v_bad; end if;
  select count(*) into v_bad from _mig0152_funcs o join _mig0152_after n using (sig)
   where o.body_md5 is distinct from n.body_md5 and o.sig not in (select to_regprocedure(s)::text from unnest(array['public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)', 'public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)', 'public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', 'public.rotate_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', 'public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)', 'public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)']) s);
  if v_bad <> 0 then raise exception '0152 postcondition: a function outside the reviewed eight changed.'; end if;

  foreach r.sig in array array['public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text)', 'public.transition_carrier_factoring_integration_lifecycle(text, uuid, text, timestamptz, text)', 'public._generate_carrier_invoice_payment_number_internal()'] loop
    if has_function_privilege('service_role', to_regprocedure(r.sig), 'execute') or has_function_privilege('authenticated', to_regprocedure(r.sig), 'execute')
       or has_function_privilege('anon', to_regprocedure(r.sig), 'execute') or (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure(r.sig)) then
      raise exception '0152 postcondition: % is still executable by a client role / service_role.', r.sig;
    end if;
  end loop;

  select count(*) into v_bad from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and data_type = 'text' and is_nullable = 'NO'
     and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency');
  if v_bad <> 2 then raise exception '0152 postcondition: request_fingerprint columns missing.'; end if;

  select * into m from _mig0152_misc;
  if (select count(*) from public.factoring_policy_idempotency) <> m.n_pol or (select md5(coalesce(string_agg((to_jsonb(t) - 'request_fingerprint')::text, '|' order by t.carrier_id, t.idempotency_key), '')) from public.factoring_policy_idempotency t) <> m.pol_md5
     or (select count(*) from public.factoring_integration_lifecycle_idempotency) <> m.n_life or (select md5(coalesce(string_agg((to_jsonb(t) - 'request_fingerprint')::text, '|' order by t.action, t.target_id, t.idempotency_key), '')) from public.factoring_integration_lifecycle_idempotency t) <> m.life_md5
     or (select count(*) from public.dispatch_resource_reassignments) <> m.n_rea or (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_resource_reassignments t) <> m.rea_md5
     or (select count(*) from public.legacy_invoice_review_idempotency) <> m.n_rev or (select count(*) from public.carrier_invoice_lifecycle_idempotency) <> m.n_civ then
    raise exception '0152 postcondition: a ledger changed (0152 never writes them).';
  end if;
  raise notice '0152 complete: 8 RPCs authorize/bind before replay; 2 NOT NULL fingerprint columns; 3 internal helpers no longer executable by service_role.';
end
$mig$;

commit;
