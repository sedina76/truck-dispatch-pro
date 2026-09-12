-- =============================================================================
-- 0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0133 live. "Phase 3A.1 Deployment Compatibility and Deadlock
-- Hotfix" -- narrowly scoped: closes the two Phase 3A production-blockers
-- (a reproducible deadlock in a currently-reachable dashboard workflow, and
-- an over-broad trailer column grant). Does NOT touch invoices, factoring,
-- payments, dispatch-service invoicing, settlements, or reporting.
--
-- WHAT THIS MIGRATION DOES
--   A. TRAILER COLUMN PRIVILEGES (correction): the 0132 grant list included
--      id/organization_id/created_at/updated_at -- none of which any real
--      trailer create/update caller in this codebase ever submits, and none
--      of which an ordinary authenticated user should ever set directly.
--      Narrowed to EXACTLY the fields src/app/(app)/trailers/actions.ts's
--      trailerValues() (the only trailer write path) submits, plus vin/
--      notes (present in the schema, not yet exposed by any form, harmless
--      to leave updatable -- neither is ownership/security-sensitive).
--   B/C. public.transition_dispatch_status(uuid, dispatch_status, text, text)
--      -- ONE authoritative, guarded RPC for pure dispatch STATUS changes.
--      Lock order: LOAD FIRST, THEN DISPATCH, UNCONDITIONALLY, for every
--      call regardless of whether this specific transition strictly needs
--      the load lock -- this is what makes every path through this RPC
--      safe against create_dispatch()/cancel_dispatch()'s own load-then-
--      dispatch order (0129), closing the deadlock class Phase 3A's own
--      TEST_DEADLOCK_0132_lock_order.sh reproduced. See the function body
--      for full detail.
--   D. public.is_valid_dispatch_status_transition(dispatch_status,
--      dispatch_status) -- the explicit status-transition matrix, pure/
--      testable in isolation.
--   * table public.dispatch_status_transitions -- idempotency ledger: one
--      row per (dispatch_id, idempotency_key) actually applied, so a
--      retried call replays the SAME cached result rather than re-running
--      business logic.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not touch create_dispatch()/cancel_dispatch() (0129) -- this RPC
--     DELEGATES cancellation to cancel_dispatch() rather than duplicating
--     its terminal-status guard, notes/cancelled_at bookkeeping, or
--     "return load to booked" logic
--   * does not touch driver-portal or geofence-automation dispatch status
--     paths (src/app/driver-portal/actions.ts, src/lib/tracking/evaluate-
--     geofences.ts) -- both are already forward-only (confirmed by reading
--     the application code) and never reactivate a cancelled dispatch, so
--     neither is in the reproduced deadlock's risk class; routing them
--     through a generic RPC they don't need would only risk duplicating/
--     weakening their own already-tested, driver/GPS-specific rules
--   * does not add invoice/factoring/payment/settlement/reporting logic
--   * does not modify loads.carrier_id / carrier_resolution semantics --
--     guard_dispatch_carrier_scope (0132) is unchanged and remains the
--     sole authority on carrier consistency; this RPC's own pre-check
--     (reactivation-carrier-match) is a defense-in-depth convenience for a
--     clean error message, not a replacement for that trigger
--
-- STRUCTURE: explicit BEGIN/COMMIT. PHASE 1 preconditions -> PHASE 2 DDL ->
-- PHASE 3 postconditions. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
begin
  if to_regclass('public.loads')      is null then raise exception '0134 precondition: public.loads missing. STOP.'; end if;
  if to_regclass('public.dispatches') is null then raise exception '0134 precondition: public.dispatches missing. STOP.'; end if;
  if to_regclass('public.trailers')   is null then raise exception '0134 precondition: public.trailers missing. STOP.'; end if;
  if to_regprocedure('public.cancel_dispatch(uuid,text)') is null then
    raise exception '0134 precondition: public.cancel_dispatch(uuid,text) missing -- apply 0129 first. STOP.';
  end if;
  if to_regprocedure('public.guard_dispatch_carrier_scope()') is null then
    raise exception '0134 precondition: public.guard_dispatch_carrier_scope() missing -- apply 0132 first. STOP.';
  end if;
  if to_regprocedure('public.log_activity(public.entity_type,uuid,text,jsonb,uuid)') is null then
    raise exception '0134 precondition: public.log_activity(...) missing. STOP.';
  end if;

  -- objects 0134 CREATES must be ABSENT
  if to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is not null then
    raise exception '0134 precondition: function public.transition_dispatch_status(...) already exists -- partial apply? STOP.';
  end if;
  if to_regprocedure('public.is_valid_dispatch_status_transition(public.dispatch_status,public.dispatch_status)') is not null then
    raise exception '0134 precondition: function public.is_valid_dispatch_status_transition(...) already exists. STOP.';
  end if;
  if to_regprocedure('public.dispatch_status_sequence_rank(public.dispatch_status)') is not null then
    raise exception '0134 precondition: function public.dispatch_status_sequence_rank(...) already exists. STOP.';
  end if;
  if to_regclass('public.dispatch_status_transitions') is not null then
    raise exception '0134 precondition: table public.dispatch_status_transitions already exists. STOP.';
  end if;

  raise notice '0134 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- A. TRAILER COLUMN PRIVILEGES -- correction of 0132 section F. The prior
-- grant list included id/organization_id/created_at/updated_at:
--   * id, organization_id: never legitimately client-settable on ANY table
--     via direct UPDATE -- primary key and tenant boundary are structural,
--     never form fields. Grepped (read-only): no trailer caller anywhere in
--     src/ ever submits either.
--   * created_at: a creation timestamp is a historical fact, not something
--     a later edit should ever touch. No caller submits it.
--   * updated_at: intended to be controlled by the existing set_updated_at
--     trigger (0009), never supplied by the browser. Revoking client UPDATE
--     on this column does NOT break that trigger -- CONFIRMED EMPIRICALLY
--     (not assumed): a BEFORE trigger's assignment to NEW.<column> is not a
--     second, separately-privilege-checked UPDATE statement; Postgres
--     checks column privileges once, against the SQL statement's own SET
--     list, before any trigger runs. The trigger's own write to
--     NEW.updated_at is therefore unaffected by this revoke, regardless of
--     which role fired the original UPDATE (see TEST_0134_... "trigger
--     still stamps updated_at with client UPDATE privilege revoked").
--
-- carrier_id / ownership_scope: already excluded by 0132, unaffected here.
-- "ownership approval fields" / "audit identity fields": VERIFIED (read-
-- only) that no such columns exist directly on public.trailers -- 0003
-- (creation) and 0132 (ownership_scope) are the ONLY two migrations that
-- ever ALTER this table; every ownership-approval/audit-identity concern
-- already lives in the separate trailer_ownership_scope_audit table (0132
-- section E), which has no client write policy at all and, as of the Phase
-- 3A clarification round, an explicit REVOKE of INSERT/UPDATE/DELETE from
-- authenticated -- nothing further to narrow there.
--
-- ownership_type vs. ownership_scope -- REVIEWED, no overlap/bypass risk:
--   ownership_type (0003): 'owned' | 'leased' | 'owner_operator' -- the
--     trailer's OWN financial/legal ownership (does the dispatching
--     organization own this physical asset, lease it, or does an
--     owner-operator driver own it). A descriptive/informational field.
--   ownership_scope (0132): 'carrier' | 'organization_shared' | 'unresolved'
--     -- which CARRIER this trailer's DISPATCH assignments are scoped to
--     (carrier_id, or explicitly shared across carriers, or not yet
--     classified). Governs guard_dispatch_carrier_scope's unresolved-
--     trailer dispatch block.
--   These are ORTHOGONAL axes (a leased trailer can be carrier-scoped OR
--   shared; an owned trailer can be either too) with NO code path anywhere
--   that derives one from the other or lets ownership_type influence
--   carrier-scope enforcement -- grepped (read-only): ownership_type is
--   read only for display (trailers list/detail pages) and the create/edit
--   form. Leaving ownership_type client-editable therefore creates NO
--   bypass of carrier/shared ownership rules; documented here so the
--   distinction never has to be re-derived.
--
-- Final permitted list -- built from the ACTUAL current caller
-- (src/app/(app)/trailers/actions.ts's trailerValues(), the only trailer
-- write path in this codebase), plus vin/notes (schema columns no current
-- form submits yet -- harmless, non-ownership, left open for forward
-- compatibility rather than silently unreachable):
--   unit_number, vin, trailer_type, length_ft, license_plate,
--   license_state, ownership_type, status, registration_expiry_date,
--   annual_inspection_expiry_date, notes.
-- Table-level UPDATE was already fully revoked from authenticated by 0132
-- (never re-granted at the table level) -- REGRANTing the column list from
-- scratch here (rather than incrementally revoking the 4 extra columns)
-- is deliberate: it is the only way to prove-by-construction that the
-- final permitted set is EXACTLY this list, not "whatever 0132 granted
-- minus 4" (which would silently inherit any future drift in 0132 instead
-- of being independently authoritative here).
revoke update on public.trailers from authenticated;
grant update (
  unit_number, vin, trailer_type, length_ft, license_plate, license_state,
  ownership_type, status, registration_expiry_date,
  annual_inspection_expiry_date, notes
) on public.trailers to authenticated;

comment on column public.trailers.ownership_scope is
  'carrier: owned by trailers.carrier_id. organization_shared: an explicitly reviewed shared-pool trailer (carrier_id must be NULL). unresolved: carrier_id is NULL and ownership has not been confirmed -- CANNOT be dispatched until an owner/admin classifies it. Backfill: carrier_id present -> carrier, absent -> unresolved. UPDATE on this column is revoked from authenticated -- change it only via public.approve_trailer_ownership_scope(). NOT the same axis as ownership_type (financial/legal ownership of the physical asset) -- see 0134 header for the full distinction; ownership_type is freely editable and cannot bypass carrier/shared dispatch-scope rules.';

comment on column public.trailers.ownership_type is
  'The trailer''s own financial/legal ownership: owned by this organization, leased, or provided by an owner-operator driver. Orthogonal to ownership_scope (which carrier this trailer''s DISPATCH assignments are scoped to) -- freely editable by operational_write roles, cannot influence or bypass carrier/shared ownership-scope enforcement (correction: Phase 3A.1 hotfix, item A).';

-- B/C. THE STATUS-TRANSITION MATRIX -- pure, side-effect-free, independently
-- testable. Built from the REAL public.dispatch_status enum (0001) and the
-- actual current workflow (grepped, read-only): the Dispatch Board's own
-- kanban columns (src/app/(app)/dispatch/board/kanban-board.tsx) already
-- allow free drag between any of the 7 non-terminal, non-cancelled statuses
-- in either direction (forward progress AND backward correction -- board-
-- actions.ts's own comment documents "moving OUT of a delivered-like
-- status" as an intentional, already-supported correction) -- this matrix
-- does not remove that existing behavior. It adds exactly the restrictions
-- the clarification round asked for:
--   * 'completed' is genuinely terminal (only reachable FROM 'delivered',
--     and has no valid non-cancelled outbound transition of its own --
--     the board never targets 'completed' directly anyway; only the full
--     edit form's status field can, and only when the dispatch is already
--     'delivered')
--   * reactivation (old = 'cancelled', new <> 'cancelled') is restricted to
--     exactly 'cancelled' -> 'assigned' -- a clean restart, never a
--     silent resume mid-trip. Authorization (owner/admin), a required
--     reason, and same-carrier-as-load enforcement are the RPC's job, not
--     this matrix's -- this function answers ONLY "is this status SHAPE
--     permitted", never "is this caller allowed to do it right now."
--   * any status -> 'cancelled' is permitted HERE (this matrix does not
--     duplicate cancel_dispatch()'s own delivered/completed-cannot-be-
--     cancelled rule -- that remains cancel_dispatch()'s sole authority,
--     enforced when transition_dispatch_status() delegates to it)
create or replace function public.is_valid_dispatch_status_transition(
  p_old public.dispatch_status,
  p_new public.dispatch_status
)
returns boolean
language sql
immutable
as $fn$
  select case
    when p_old = p_new then true
    when p_new = 'cancelled' then true
    when p_old = 'cancelled' then p_new = 'assigned'
    when p_old = 'completed' then false
    when p_new = 'completed' then p_old = 'delivered'
    else true
  end;
$fn$;

comment on function public.is_valid_dispatch_status_transition(public.dispatch_status, public.dispatch_status) is
  'Pure status-transition matrix (Phase 3A.1 hotfix, item D). Answers ONLY whether a status SHAPE is permitted -- authorization (role), required reason, and carrier consistency are transition_dispatch_status()''s job, not this function''s. Free movement is preserved among the 7 non-terminal, non-cancelled statuses (matches the Dispatch Board''s own existing unrestricted drag behavior); completed is terminal except from delivered; reactivation from cancelled is restricted to exactly -> assigned; any status may transition -> cancelled (cancel_dispatch() itself is the sole authority on whether that specific old status may actually be cancelled). NOTE (Phase 3A.2, item 8): this function still answers only the SHAPE question -- whether a BACKWARD move within the permitted shape additionally requires owner/admin + a reason is transition_dispatch_status()''s own job, via public.dispatch_status_sequence_rank() below.';

-- Phase 3A.2 clarification round, item 8 ("status matrix review"): the
-- ordinal position of each FORWARD-progress status in the normal operational
-- sequence. NULL for 'cancelled' and 'completed' -- neither participates in
-- "backward move" reasoning the same way (cancelled is reached via a
-- dedicated path with its own rules; completed is terminal, entered only
-- from delivered, per the matrix above). Used by transition_dispatch_
-- status() to detect a BACKWARD move (new rank < old rank) and require
-- owner/admin + a reason for it -- "free movement" among these statuses
-- remains true for FORWARD progress only; moving backward (a correction) is
-- now a permissioned action, not an ordinary dispatcher drag, closing the
-- "does not damage operational history" gap this round's review raised.
create or replace function public.dispatch_status_sequence_rank(p_status public.dispatch_status)
returns integer
language sql
immutable
as $fn$
  select case p_status
    when 'assigned'            then 1
    when 'accepted'             then 2
    when 'en_route_to_pickup'   then 3
    when 'at_pickup'            then 4
    when 'loaded'               then 5
    when 'en_route_to_delivery' then 6
    when 'at_delivery'          then 7
    when 'delivered'            then 8
    else null
  end;
$fn$;

comment on function public.dispatch_status_sequence_rank(public.dispatch_status) is
  'Ordinal position (1-8) of a status in the normal forward operational sequence (assigned..delivered); NULL for cancelled/completed. transition_dispatch_status() uses this to require owner/admin + a reason for any BACKWARD move (new rank < old rank) -- an ordinary dispatcher may always move FORWARD (or to cancelled), never backward, without that authorization (Phase 3A.2, item 8: "delivered and completed should not move backward through an ordinary board drag; backward correction from advanced operational statuses should require owner/admin permission and a reason").';

-- idempotency ledger for transition_dispatch_status()
create table public.dispatch_status_transitions (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null references public.dispatches (id) on delete cascade,
  idempotency_key text not null,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  old_status public.dispatch_status not null,
  new_status public.dispatch_status not null,
  result jsonb not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (dispatch_id, idempotency_key)
);

comment on table public.dispatch_status_transitions is
  'Idempotency ledger for public.transition_dispatch_status(): one row per (dispatch_id, idempotency_key) actually applied. A retried call with the SAME pair replays the cached result verbatim rather than re-running business logic (true idempotency -- a client-side timeout/retry after the write actually succeeded never double-applies or re-validates against a row that has since moved on). Written only by transition_dispatch_status() (SECURITY DEFINER); no direct client write path.';

alter table public.dispatch_status_transitions enable row level security;

create policy dispatch_status_transitions_select on public.dispatch_status_transitions
  for select using (organization_id = public.current_org_id());
-- No INSERT/UPDATE/DELETE policy for authenticated -- written only by the
-- RPC below (SECURITY DEFINER, runs as table owner), matching the
-- trailer_ownership_scope_audit pattern (0132 section E) exactly, INCLUDING
-- its own explicit defense-in-depth revoke (the ALTER DEFAULT PRIVILEGES
-- lesson from that correction, applied here from the start rather than
-- discovered later).
revoke all on public.dispatch_status_transitions from anon;
revoke insert, update, delete on public.dispatch_status_transitions from authenticated;
grant select on public.dispatch_status_transitions to authenticated;

-- B/C. THE RPC ITSELF.
create or replace function public.transition_dispatch_status(
  p_dispatch_id uuid,
  p_new_status public.dispatch_status,
  p_reason text default null,
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
  v_dispatch_org uuid;
  v_load_id uuid;
  v_load_org uuid;
  v_load_carrier uuid;
  v_old_status public.dispatch_status;
  v_dispatch_carrier uuid;
  v_now timestamptz := now();
  v_ts_col text;
  v_result jsonb;
  v_cached jsonb;
  v_is_reactivation boolean;
  v_final_status public.dispatch_status;
  v_old_rank integer;
  v_new_rank integer;
begin
  -- Never allow browser-provided organization/carrier ownership to
  -- override database truth: this function takes NO organization_id or
  -- carrier_id parameter at all -- both are derived exclusively from the
  -- dispatch/load rows themselves and from auth.uid()/current_org_id().
  if v_uid is null then
    raise exception 'transition_dispatch_status: authentication required.' using errcode = 'TSAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'transition_dispatch_status: caller has no organization.' using errcode = 'TSAUT';
  end if;

  -- Idempotency short-circuit -- BEFORE any lock, any validation, any
  -- write. A retried call with the SAME (dispatch_id, idempotency_key)
  -- pair replays the ORIGINAL cached result verbatim, never re-validates
  -- against however the row looks now.
  if p_idempotency_key is not null then
    select result into v_cached
    from public.dispatch_status_transitions
    where dispatch_id = p_dispatch_id and idempotency_key = p_idempotency_key;
    if found then
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

  -- Resolve dispatch -> load_id WITHOUT locking yet -- load_id is needed
  -- to lock the LOAD before touching the dispatch row at all.
  select organization_id, load_id into v_dispatch_org, v_load_id
  from public.dispatches where id = p_dispatch_id;
  if v_dispatch_org is null or v_dispatch_org <> v_org then
    -- cross-tenant reported identically to "not found" -- never confirm
    -- existence of another organization's row.
    raise exception 'transition_dispatch_status: dispatch % not found.', p_dispatch_id using errcode = 'TSDNF';
  end if;

  -- ===== STEP 1: LOCK THE LOAD FIRST -- unconditional, for EVERY call,
  -- regardless of whether this specific transition strictly needs it. A
  -- BEFORE trigger (guard_dispatch_carrier_scope, 0132) cannot acquire a
  -- lock "before" Postgres has already locked the target row of the
  -- statement that fired it -- that is a structural constraint of the
  -- trigger mechanism, not a choice any trigger body can make. The ONLY
  -- way to guarantee load-then-dispatch order for every write this RPC
  -- performs is to take the load lock HERE, before the dispatch row is
  -- touched at all. This is what closes the deadlock class
  -- TEST_DEADLOCK_0132_lock_order.sh reproduced (Phase 3A clarification
  -- round, item 4) for every caller that routes through this RPC.
  select organization_id, carrier_id into v_load_org, v_load_carrier
  from public.loads where id = v_load_id for update;
  if v_load_org is null then
    raise exception 'transition_dispatch_status: load % missing.', v_load_id using errcode = 'TSDNF';
  end if;

  -- ===== STEP 2: LOCK THE DISPATCH SECOND, re-read current values under
  -- both locks. Never trust the pre-lock read above for anything but
  -- resolving load_id.
  select status, carrier_id into v_old_status, v_dispatch_carrier
  from public.dispatches where id = p_dispatch_id for update;

  if v_old_status = p_new_status then
    -- idempotent no-op, authoritative (post-lock) read
    v_result := jsonb_build_object(
      'success', true, 'dispatch_id', p_dispatch_id,
      'old_status', v_old_status, 'new_status', p_new_status,
      'no_op', true, 'reactivated', false);
  else
    v_is_reactivation := (v_old_status = 'cancelled');

    -- ===== STEP 3: VALIDATE (role, reason, carrier consistency) =====
    if v_is_reactivation then
      -- Recommended matrix: ordinary dispatchers cannot reactivate a
      -- cancelled dispatch directly. Owner/admin may, only with a reason,
      -- only onto the SAME carrier the load already has, and only when
      -- the transition matrix (below) agrees the shape is even permitted
      -- (cancelled -> assigned only -- never a silent mid-trip resume).
      if not public.has_role(array['owner','admin']::public.org_role[]) then
        raise exception 'transition_dispatch_status: reactivating a cancelled dispatch requires owner/admin authority. Create a new same-carrier dispatch instead, or ask an owner/admin to reactivate this one with a reason.' using errcode = 'TSROL';
      end if;
      if p_reason is null or btrim(p_reason) = '' then
        raise exception 'transition_dispatch_status: a reason is required to reactivate a cancelled dispatch.' using errcode = 'TSRSN';
      end if;
      if v_load_carrier is not null and v_dispatch_carrier is distinct from v_load_carrier then
        raise exception 'transition_dispatch_status: cannot reactivate -- this dispatch''s carrier (%) no longer matches the load''s carrier (%). Create a new same-carrier dispatch instead.', v_dispatch_carrier, v_load_carrier using errcode = 'TSCAR';
      end if;
    else
      if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
        raise exception 'transition_dispatch_status: only an owner, admin, or dispatcher may change dispatch status.' using errcode = 'TSROL';
      end if;

      -- Phase 3A.2, item 8: a BACKWARD move within the normal forward
      -- sequence (e.g. in_transit -> assigned, at_delivery -> dispatched,
      -- delivered -> an earlier active status) is a CORRECTION, not an
      -- ordinary dispatcher drag -- it requires owner/admin authority and a
      -- reason, exactly like reactivation does. Forward progress (and any
      -- move -> cancelled, handled entirely separately above) remains open
      -- to an ordinary dispatcher with no reason required -- "free
      -- movement" is preserved for FORWARD drags only. NULL ranks
      -- (p_new_status = 'completed', which is not a sequence-ranked status)
      -- never trigger this -- 'completed' is one-way from 'delivered' by
      -- the matrix already, and BOTH null out of the rank comparison
      -- safely (the `is not null and is not null and <` guard below).
      v_old_rank := public.dispatch_status_sequence_rank(v_old_status);
      v_new_rank := public.dispatch_status_sequence_rank(p_new_status);
      if v_old_rank is not null and v_new_rank is not null and v_new_rank < v_old_rank then
        if not public.has_role(array['owner','admin']::public.org_role[]) then
          raise exception 'transition_dispatch_status: moving % -> % is a BACKWARD correction and requires owner/admin authority.', v_old_status, p_new_status using errcode = 'TSROL';
        end if;
        if p_reason is null or btrim(p_reason) = '' then
          raise exception 'transition_dispatch_status: a reason is required to move % -> % (a backward correction).', v_old_status, p_new_status using errcode = 'TSRSN';
        end if;
      end if;
    end if;

    if not public.is_valid_dispatch_status_transition(v_old_status, p_new_status) then
      raise exception 'transition_dispatch_status: % -> % is not a permitted status transition.', v_old_status, p_new_status using errcode = 'TSINV';
    end if;

    -- ===== STEP 4: UPDATE =====
    if p_new_status = 'cancelled' then
      -- Delegate ENTIRELY to cancel_dispatch() (0129) -- never duplicate
      -- its terminal-status guard (delivered/completed cannot be
      -- cancelled), its notes/cancelled_at bookkeeping, or its "return
      -- load to booked" logic. The load+dispatch locks this function
      -- already holds are simply re-entrant when cancel_dispatch()
      -- re-acquires them internally (same transaction) -- instant, never
      -- a wait, never a second deadlock opportunity.
      perform public.cancel_dispatch(p_dispatch_id, p_reason);
    else
      -- Mirrors src/lib/dispatch/operational-timestamps.ts's
      -- computeOperationalTimestampUpdates() exactly: stamp the ONE
      -- dedicated timestamp column this status owns, only if not already
      -- set (idempotent -- bouncing back into a status already reached
      -- once never overwrites the original moment).
      v_ts_col := case p_new_status
        when 'en_route_to_pickup'  then 'en_route_pickup_at'
        when 'loaded'              then 'loaded_at'
        when 'en_route_to_delivery' then 'in_transit_at'
        when 'delivered'           then 'delivered_at'
        else null
      end;
      if v_ts_col = 'en_route_pickup_at' then
        update public.dispatches set status = p_new_status, en_route_pickup_at = coalesce(en_route_pickup_at, v_now) where id = p_dispatch_id;
      elsif v_ts_col = 'loaded_at' then
        update public.dispatches set status = p_new_status, loaded_at = coalesce(loaded_at, v_now) where id = p_dispatch_id;
      elsif v_ts_col = 'in_transit_at' then
        update public.dispatches set status = p_new_status, in_transit_at = coalesce(in_transit_at, v_now) where id = p_dispatch_id;
      elsif v_ts_col = 'delivered_at' then
        update public.dispatches set status = p_new_status, delivered_at = coalesce(delivered_at, v_now) where id = p_dispatch_id;
      else
        update public.dispatches set status = p_new_status where id = p_dispatch_id;
      end if;
      -- guard_dispatch_carrier_scope (0132) fires here on this UPDATE.
      -- The load lock from STEP 1 is already held by THIS transaction, so
      -- its own internal `for update` on loads is an instant re-lock, not
      -- a wait -- the structural fix this whole hotfix exists to prove.
    end if;

    select status into v_final_status from public.dispatches where id = p_dispatch_id;
    v_result := jsonb_build_object(
      'success', true, 'dispatch_id', p_dispatch_id,
      'old_status', v_old_status, 'new_status', v_final_status,
      'no_op', false, 'reactivated', v_is_reactivation);

    -- AUDIT (Phase 3A.2 clarification round, item 7 -- "cancellation audit
    -- duplication check"): cancel_dispatch() (0129, line ~644) ALREADY
    -- writes its own log_activity('dispatch', ..., 'cancelled',
    -- {reason}, ...) event -- confirmed by reading its body, not assumed.
    -- An earlier draft of this function wrote a SECOND, unconditional
    -- 'status_changed' event here regardless of path, producing TWO
    -- activity_logs rows for every cancellation. Fixed: this RPC writes
    -- its OWN audit event only for the non-cancellation branch;
    -- cancel_dispatch()'s event is the sole, authoritative audit record
    -- for a cancellation -- never duplicated, never weakened.
    -- TEST_0135_..., "cancellation audit duplication" asserts EXACTLY ONE
    -- activity_logs row per cancellation, by exact count.
    if p_new_status <> 'cancelled' then
      perform public.log_activity(
        'dispatch'::public.entity_type, p_dispatch_id, 'status_changed',
        jsonb_build_object('old_status', v_old_status, 'new_status', v_final_status, 'reason', p_reason, 'reactivated', v_is_reactivation),
        v_org);
    end if;
  end if;

  if p_idempotency_key is not null then
    insert into public.dispatch_status_transitions
      (dispatch_id, idempotency_key, organization_id, old_status, new_status, result, created_by)
    values (p_dispatch_id, p_idempotency_key, v_org, v_old_status, coalesce(v_final_status, v_old_status), v_result, v_uid)
    on conflict (dispatch_id, idempotency_key) do nothing;
  end if;

  return v_result;
end;
$fn$;

revoke all on function public.transition_dispatch_status(uuid,public.dispatch_status,text,text) from public;
grant execute on function public.transition_dispatch_status(uuid,public.dispatch_status,text,text) to authenticated;

comment on function public.transition_dispatch_status(uuid,public.dispatch_status,text,text) is
  'THE authoritative RPC for dispatch STATUS changes (Phase 3A.1 hotfix, items B/C). Locks the load FIRST, then the dispatch, unconditionally, for every call -- this is what makes it safe against create_dispatch()/cancel_dispatch()''s own load-then-dispatch order (0129). Delegates cancellation entirely to cancel_dispatch() -- never duplicates its rules. Reactivation (cancelled -> assigned) requires owner/admin, a reason, and same-carrier-as-load. Idempotent via p_idempotency_key. Scoped to pure status changes only -- does NOT handle driver/truck/trailer/carrier reassignment (that remains the edit form''s own create_dispatch-adjacent path) and is NOT used by the driver portal or geofence automation, which are already forward-only and outside this deadlock''s risk class.';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare v_n integer;
begin
  -- trailer grant: exactly the intended column set, nothing more
  if exists (
    select 1 from information_schema.column_privileges
    where table_schema='public' and table_name='trailers' and grantee='authenticated'
      and privilege_type='UPDATE'
      and column_name in ('id','organization_id','carrier_id','ownership_scope','created_at','updated_at')
  ) then
    raise exception '0134 postcondition: authenticated still holds UPDATE on a protected/structural trailers column.';
  end if;
  select count(*) into v_n
  from information_schema.column_privileges
  where table_schema='public' and table_name='trailers' and grantee='authenticated' and privilege_type='UPDATE';
  if v_n <> 11 then
    raise exception '0134 postcondition: expected exactly 11 UPDATE-grantable trailers columns for authenticated, found %.', v_n;
  end if;
  if has_table_privilege('authenticated', 'public.trailers', 'UPDATE') then
    raise exception '0134 postcondition: authenticated holds a TABLE-LEVEL UPDATE grant on trailers -- must be column-scoped only.';
  end if;

  -- RPC + matrix + ledger present, correctly configured
  if to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is null then
    raise exception '0134 postcondition: transition_dispatch_status(...) missing.';
  end if;
  if to_regprocedure('public.is_valid_dispatch_status_transition(public.dispatch_status,public.dispatch_status)') is null then
    raise exception '0134 postcondition: is_valid_dispatch_status_transition(...) missing.';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='transition_dispatch_status'
      and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'::text[]),',') not like '%search_path=%')
  ) then
    raise exception '0134 postcondition: transition_dispatch_status is not (security definer + pinned search_path).';
  end if;
  if to_regclass('public.dispatch_status_transitions') is null then
    raise exception '0134 postcondition: table dispatch_status_transitions missing.';
  end if;
  if (select count(*) from public.dispatch_status_transitions) <> 0 then
    raise exception '0134 postcondition: dispatch_status_transitions is not empty -- 0134 creates no rows.';
  end if;
  if exists (select 1 from information_schema.role_table_grants
             where table_schema='public' and table_name='dispatch_status_transitions'
               and grantee='authenticated' and privilege_type in ('INSERT','UPDATE','DELETE')) then
    raise exception '0134 postcondition: authenticated still holds table-level INSERT/UPDATE/DELETE on dispatch_status_transitions.';
  end if;

  -- sanity-check the matrix function directly against a handful of known cases
  if public.is_valid_dispatch_status_transition('cancelled','loaded') then
    raise exception '0134 postcondition: matrix wrongly permits cancelled -> loaded (reactivation must be -> assigned only).';
  end if;
  if not public.is_valid_dispatch_status_transition('cancelled','assigned') then
    raise exception '0134 postcondition: matrix wrongly rejects cancelled -> assigned (the one permitted reactivation shape).';
  end if;
  if public.is_valid_dispatch_status_transition('completed','delivered') then
    raise exception '0134 postcondition: matrix wrongly permits completed -> delivered (completed must be terminal).';
  end if;
  if not public.is_valid_dispatch_status_transition('delivered','completed') then
    raise exception '0134 postcondition: matrix wrongly rejects delivered -> completed.';
  end if;
  if not public.is_valid_dispatch_status_transition('assigned','cancelled') then
    raise exception '0134 postcondition: matrix wrongly rejects assigned -> cancelled.';
  end if;
  if not public.is_valid_dispatch_status_transition('loaded','assigned') then
    raise exception '0134 postcondition: matrix wrongly rejects loaded -> assigned (existing board correction behavior must be preserved).';
  end if;

  -- sequence-rank function (Phase 3A.2, item 8)
  if to_regprocedure('public.dispatch_status_sequence_rank(public.dispatch_status)') is null then
    raise exception '0134 postcondition: dispatch_status_sequence_rank(...) missing.';
  end if;
  if public.dispatch_status_sequence_rank('assigned') <> 1 or public.dispatch_status_sequence_rank('delivered') <> 8 then
    raise exception '0134 postcondition: dispatch_status_sequence_rank endpoints wrong.';
  end if;
  if public.dispatch_status_sequence_rank('cancelled') is not null or public.dispatch_status_sequence_rank('completed') is not null then
    raise exception '0134 postcondition: dispatch_status_sequence_rank must be NULL for cancelled/completed.';
  end if;
  if not (public.dispatch_status_sequence_rank('loaded') > public.dispatch_status_sequence_rank('assigned')) then
    raise exception '0134 postcondition: dispatch_status_sequence_rank ordering is wrong (loaded must rank higher than assigned).';
  end if;

  raise notice '0134 complete: trailers UPDATE narrowed to 11 real, non-ownership columns for authenticated; transition_dispatch_status(...) + is_valid_dispatch_status_transition(...) + dispatch_status_sequence_rank(...) + dispatch_status_transitions installed. Existing 0129/0132 functions/triggers untouched.';
end
$mig$;

commit;
