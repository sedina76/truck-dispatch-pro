-- =============================================================================
-- 0132_load_carrier_and_trailer_scope.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0131 live. Phase 3A slice 3.
--
-- WHAT THIS MIGRATION DOES
--   * enum   public.trailer_ownership_scope ('carrier','organization_shared','unresolved')
--   * columns (all nullable, no default -> existing rows observe NULL; the
--     load carrier backfill is the SEPARATE migration 0133)
--       loads.carrier_id         uuid  FK -> carriers(id) ON DELETE RESTRICT
--       loads.carrier_resolution text  CHECK in ('resolved','backfilled','unresolved')
--       loads.carrier_locked_at  timestamptz
--   * column  trailers.ownership_scope public.trailer_ownership_scope NOT NULL
--       BACKFILLED deterministically:
--         carrier_id IS NOT NULL -> 'carrier'
--         carrier_id IS NULL     -> 'unresolved'   (NOT 'organization_shared' --
--         a NULL carrier may be missing data, correction 10). An owner/admin
--         promotes 'unresolved' -> 'organization_shared' after review.
--       + CHECK tying ownership_scope to carrier_id nullability (validated)
--       + BEFORE INSERT trigger trailers_derive_ownership_scope: fills a NULL
--         ownership_scope on new rows from carrier_id.
--   * function + trigger public.guard_load_carrier_change() BEFORE INSERT OR
--       UPDATE on loads:
--         - carrier_id (when set) must belong to the load's organization
--         - an already-set carrier_id may not be changed or cleared once the
--           load has ANY dispatch or a financial_dispatch_id (correction J/O;
--           full financial-dependency set arrives with later slices). Use
--           public.reassign_load_carrier() (later slice) for controlled moves.
--         - NULL -> value (resolution / new-load assignment) is always allowed.
--   * function + trigger public.guard_dispatch_carrier_scope() BEFORE INSERT
--       OR UPDATE on dispatches (NEW trigger, additive, separate from the
--       0055 dispatches_guard_org and 0125 triggers) -- AUTHORITATIVE and
--       ROW-LOCKED (correction: "cross-carrier integrity defect" /
--       "authoritative load row locking"). On INSERT, on any carrier_id /
--       load_id change, or when a CANCELLED dispatch is REACTIVATED (status
--       leaving 'cancelled'):
--         1. `SELECT ... FROM loads WHERE id = load_id FOR UPDATE` --
--            acquired BEFORE any carrier field is read or written, so two
--            concurrent dispatch inserts for the SAME load now serialize on
--            this lock instead of both reading a stale, unlocked row.
--         2. loads.carrier_id, if already set, is authoritative -- the
--            dispatch carrier must match, unconditionally (Output 6 /
--            correction D). No exception, no controller override.
--         3. carrier_resolution = 'unresolved' -- rejects the dispatch
--            outright, no exceptions (correction #5/#6; strengthened this
--            round to also cover UPDATE/reactivation, not INSERT only).
--         4. Else (loads.carrier_id is still NULL -- step 1 did not apply),
--            derive the effective carrier from every CURRENTLY non-cancelled
--            dispatch on the load (excluding the row being evaluated) -- NOT
--            from financial_dispatch_id directly, which 0129's
--            cancel_dispatch() deliberately preserves through cancellation
--            ("financial history"). If they all agree, that carrier is
--            effective and the new/reactivated dispatch must match it --
--            this is the fix for the defect the concurrency test found: a
--            conflicting-carrier dispatch can no longer be inserted
--            alongside an existing LIVE one. If more than one distinct
--            carrier is already live (a pre-existing anomaly), reject
--            outright.
--            IMPORTANT, corrected after direct empirical testing (Phase 3A
--            clarification round, "cancel-then-redispatch contradiction"):
--            this branch is reached ONLY while loads.carrier_id is still
--            NULL. Once the FIRST live dispatch on a load claims it (step 5
--            below), loads.carrier_id becomes non-NULL and PERMANENTLY
--            authoritative per step 1 -- cancelling that dispatch does NOT
--            clear loads.carrier_id (cancellation is a dispatch-status
--            change only; nothing in this trigger, in cancel_dispatch(), or
--            anywhere else touches loads.carrier_id on cancellation). A
--            DIFFERENT-CARRIER redispatch attempt after that cancellation is
--            therefore REJECTED by step 2, not permitted by this branch --
--            confirmed by direct test, not merely reasoned about (see the
--            migration header's "CANCEL-THEN-REDISPATCH" section below for
--            the full rule and its Phase 3A/3B boundary). A SAME-carrier
--            redispatch after cancellation still succeeds normally (step 2's
--            match check passes). This branch's real, common effect is
--            narrower than "supports cancel-then-redispatch": it lets the
--            FIRST ever live dispatch on a load claim the load atomically
--            (step 5) even when an earlier, never-claiming dispatch on that
--            load was already cancelled (e.g. a dispatch inserted directly
--            in 'cancelled' status, so the atomic-claim step never ran for
--            it) -- a narrow edge case, not the common create-then-cancel
--            pattern.
--         5. Else (no carrier_id, no live dispatch at all): the FIRST
--            carrier-relevant, non-cancelled dispatch ATOMICALLY CLAIMS the
--            load --
--            sets loads.carrier_id + carrier_resolution='resolved' inside
--            THIS SAME locked transaction, closing the carrier_resolution
--            IS NULL loophole: no dispatch can ever become financial
--            controller while loads.carrier_id remains NULL.
--         - separately, on INSERT or trailer_id change: a trailer whose
--           ownership_scope = 'unresolved' may NOT be assigned (correction 10)
--       Direct INSERT into dispatches (bypassing create_dispatch(), 0129) is
--       independently and equivalently protected -- this trigger fires on
--       ANY insert/update regardless of caller, RPC or otherwise. This
--       trigger -- not a CHECK constraint -- is the sole enforcement point
--       for "no dispatch may attach to an unresolved-carrier load": a CHECK
--       cannot distinguish a live write attempt from 0133 honestly
--       recording a pre-existing historical conflict (correction: "correct
--       migration 0133 candidate rules").
--   * correction #6: reassigning an ALREADY-SET loads.carrier_id (zero-
--     activity case) now requires owner/admin; the initial NULL -> value
--     assignment stays open to dispatcher (decision 1)
--   * table  public.trailer_ownership_scope_audit -- append-only audit of
--       every ownership_scope / carrier_id transition (correction #4)
--   * function public.approve_trailer_ownership_scope(uuid, trailer_
--       ownership_scope, text, uuid) -> jsonb -- the ONLY sanctioned way to
--       change a trailer's ownership_scope or carrier_id. owner/admin only,
--       requires a non-empty reason, writes an audit row (correction #4)
--   * function + trigger public.guard_trailer_ownership_scope_change()
--       BEFORE UPDATE on trailers: rejects ANY change to ownership_scope or
--       carrier_id that did not go through the RPC above (checked via a
--       transaction-local flag the RPC sets) -- even an owner/admin's DIRECT
--       table UPDATE is rejected; only the guarded RPC can make this change
--       (correction #4, "direct table updates must not bypass authorization")
--
-- BEHAVIOR CHANGE ON APPLY (documented per correction 15)
--   Existing behavior: 0055 guard_dispatch_org allows a carrier-less trailer
--   (carrier_id NULL) on any dispatch. After 0132 backfills those trailers to
--   ownership_scope = 'unresolved', guard_dispatch_carrier_scope REJECTS
--   assigning such a trailer to a NEW dispatch or RE-assigning it onto an
--   existing dispatch. It does NOT fire on other UPDATEs (status changes
--   etc.) of a dispatch that already holds such a trailer, so live operations
--   on existing dispatches are unaffected. The preflight audit
--   (VERIFY_0132_PREFLIGHT.sql) reports how many trailers become 'unresolved'
--   and how many active dispatches currently reference them so the blast
--   radius is visible BEFORE apply.
--
--   NEW as of this correction: the moment 0132 is applied, EVERY new
--   dispatch (or reactivation of a cancelled one) on a load with NO
--   loads.carrier_id yet is now evaluated against the load's LIVE
--   non-cancelled dispatch carrier (or claims the load if there is none).
--   A second dispatch for a DIFFERENT carrier on an already (non-cancelled-)
--   dispatched load -- something the pre-0132 schema silently permitted --
--   is now REJECTED. This is intentional: it is precisely the defect class
--   this correction closes, not a side effect.
--
--   CANCEL-THEN-REDISPATCH -- THE EXACT RULE, CONFIRMED BY DIRECT TEST (a
--   prior draft of this note incorrectly claimed different-carrier
--   redispatch "remains fully supported" after a cancellation; that claim
--   was WRONG and has been corrected here after being caught in review):
--     1. create load (no carrier) -> dispatch to Carrier A -> loads.carrier_id
--        becomes A, carrier_resolution='resolved' (atomic claim, step 5
--        above).
--     2. cancel Carrier A's dispatch -> loads.carrier_id REMAINS A,
--        carrier_resolution REMAINS 'resolved', financial_dispatch_id STILL
--        points at the now-cancelled dispatch (cancellation is a
--        dispatch-status change only; nothing clears loads.carrier_id).
--     3. dispatch the SAME load to Carrier B -> REJECTED (step 2 above:
--        loads.carrier_id=A is unconditionally authoritative; step 4's
--        "derive from live dispatches" branch is never reached because
--        loads.carrier_id is already non-NULL).
--     4. dispatch the SAME load to Carrier A again (same carrier) ->
--        SUCCEEDS (matches the authoritative carrier).
--   BUSINESS RULE ENFORCED BY THIS MIGRATION (Phase 3A, in effect NOW):
--     - Cancelling a dispatch never automatically changes loads.carrier_id.
--     - A different carrier can NEVER be assigned merely because the prior
--       dispatch on the load was cancelled -- this is enforced today, by
--       this trigger, unconditionally, with no RPC or role able to bypass
--       it (see guard_load_carrier_change() in section B for the loads-side
--       half of the same rule: reassigning an already-set carrier_id to a
--       DIFFERENT value requires zero dependent dispatches, which a
--       cancelled dispatch does NOT satisfy -- dispatch COUNT, not status,
--       is what guard_load_carrier_change checks).
--     - Same-carrier redispatch after cancellation remains allowed.
--     - THE ONLY WAY TO MOVE AN ALREADY-CARRIER-CLAIMED LOAD TO A DIFFERENT
--       CARRIER IS A FUTURE, CONTROLLED public.reassign_load_carrier() RPC
--       THAT DOES NOT EXIST IN PHASE 3A. Until that RPC ships (Phase 3B),
--       different-carrier reassignment of any load that has ever had a live
--       dispatch is UNCONDITIONALLY BLOCKED -- there is no workaround, no
--       owner/admin override, no direct-SQL-only escape hatch documented or
--       intended here. This is a disclosed Phase 3A LIMITATION, not a
--       partially-working feature. reassign_load_carrier() (Phase 3B, not
--       built here) is expected to: verify zero issued invoices / payments /
--       factoring activity / dispatch-service invoices / settlements /
--       other protected financial activity before permitting the move;
--       leave the old dispatch cancelled as history, untouched; explicitly
--       clear or reassign financial_dispatch_id per its own documented
--       rule (not silently); and audit every change. None of that RPC exists
--       yet -- Phase 3A ships the guard that makes today's carrier-locking
--       behavior safe and race-free; it does not ship a reassignment path.
--   Verified directly (not merely reasoned about) via a live psql session
--   reproducing all 4 steps above, and via TEST_0132_load_carrier_and_
--   trailer_scope.sql's own "reassignment requires owner/admin" test suite,
--   which exercises the SAME underlying immutability rule from the loads
--   side.
--
--   NO MAINTENANCE WINDOW IS REQUIRED BETWEEN 0132 AND 0133. Every load this
--   guard "claims" a carrier for before 0133 has run becomes exactly the
--   PRE_EXISTING case 0133 already handles (validated, preserved, excluded
--   from rollback provenance -- see 0133's header and
--   TEST_0133_PREEXISTING_CARRIER_RACE.sql). The guard never creates a
--   state 0133 cannot safely observe: it only ever assigns a carrier when
--   doing so cannot conflict with anything live, and it rejects everything
--   that would. This claim is proven by
--   TEST_CONCURRENCY_0132_carrier_guard.sh (real two-session test) and by
--   TEST_0133_PREEXISTING_CARRIER_RACE.sql, both re-verified for this
--   correction.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does NOT populate loads.carrier_id for any existing load (0133)
--   * does NOT modify create_dispatch(), cancel_dispatch(),
--     auto_generate_invoice_from_delivered_load(), guard_dispatch_org (0055),
--     or any 0125 trigger/function
--   * does NOT add carrier scope to invoices / payments / factoring / documents
--   * does NOT change the 0003 trailers.carrier_id FK (still ON DELETE SET
--     NULL). KNOWN GAP: deleting a carrier would set a 'carrier'-scoped
--     trailer's carrier_id to NULL and violate the new CHECK; carrier hard-
--     delete is out of scope for this slice and is addressed by the trailers
--     slice + Output 4 RESTRICT changes.
--
-- DATA EFFECT: trailers.ownership_scope is written on EVERY trailer row
-- (deterministic, no ambiguity). trailers.updated_at is NOT bumped (the
-- backfill UPDATE sets ownership_scope only; there is no set_updated_at
-- trigger firing here because the column list excludes updated_at and the
-- shared trigger sets it unconditionally -- see note below). Every other new
-- column is nullable/NULL on existing rows.
--
-- NOTE on trailers.updated_at: public.set_updated_at() is attached to
-- trailers by 0009 and sets NEW.updated_at = now() on EVERY update. The
-- backfill UPDATE below therefore DOES bump trailers.updated_at. This is an
-- accepted, disclosed side effect of a one-time structural backfill (same
-- class as 0126's loads.updated_at bump). No amount / assignment / status
-- changes.
--
-- STRUCTURE: explicit BEGIN/COMMIT. DO $mig$ PHASE 1 -> DDL + backfill
-- PHASE 2 -> DO $mig$ PHASE 3. Any RAISE rolls back all. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
begin
  if to_regclass('public.loads')      is null then raise exception '0132 precondition: public.loads missing. STOP.'; end if;
  if to_regclass('public.dispatches') is null then raise exception '0132 precondition: public.dispatches missing. STOP.'; end if;
  if to_regclass('public.trailers')   is null then raise exception '0132 precondition: public.trailers missing. STOP.'; end if;
  if to_regclass('public.carriers')   is null then raise exception '0132 precondition: public.carriers missing. STOP.'; end if;

  -- 0125 landmark
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id') then
    raise exception '0132 precondition: loads.financial_dispatch_id missing (apply 0125). STOP.';
  end if;
  -- 0131 landmark
  if to_regclass('public.carrier_brokers') is null then
    raise exception '0132 precondition: public.carrier_brokers missing -- apply 0131 first. STOP.';
  end if;

  -- objects 0132 CREATES must be ABSENT
  if exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
             where n.nspname='public' and t.typname='trailer_ownership_scope') then
    raise exception '0132 precondition: type public.trailer_ownership_scope already exists -- partial apply? STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_id') then
    raise exception '0132 precondition: loads.carrier_id already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_resolution') then
    raise exception '0132 precondition: loads.carrier_resolution already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_locked_at') then
    raise exception '0132 precondition: loads.carrier_locked_at already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='trailers' and column_name='ownership_scope') then
    raise exception '0132 precondition: trailers.ownership_scope already exists. STOP.';
  end if;
  if to_regprocedure('public.guard_load_carrier_change()')      is not null then raise exception '0132 precondition: function public.guard_load_carrier_change() already exists. STOP.'; end if;
  if to_regprocedure('public.guard_dispatch_carrier_scope()')   is not null then raise exception '0132 precondition: function public.guard_dispatch_carrier_scope() already exists. STOP.'; end if;
  if to_regprocedure('public.trailers_derive_ownership_scope()') is not null then raise exception '0132 precondition: function public.trailers_derive_ownership_scope() already exists. STOP.'; end if;
  if to_regclass('public.trailer_ownership_scope_audit') is not null then raise exception '0132 precondition: table public.trailer_ownership_scope_audit already exists. STOP.'; end if;
  if to_regprocedure('public.guard_trailer_ownership_scope_change()') is not null then raise exception '0132 precondition: function public.guard_trailer_ownership_scope_change() already exists. STOP.'; end if;
  -- (the type public.trailer_ownership_scope doesn't exist yet at this point
  -- in the file, so approve_trailer_ownership_scope's full signature cannot
  -- be checked via to_regprocedure(); check by name instead.)
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public' and p.proname='approve_trailer_ownership_scope') then
    raise exception '0132 precondition: a function named public.approve_trailer_ownership_scope already exists. STOP.';
  end if;

  create temp table _mig0132_baseline on commit drop as
  select
    (select count(*) from public.loads)      as n_load,
    (select count(*) from public.dispatches) as n_dispatch,
    (select count(*) from public.trailers)   as n_trailer,
    (select count(*) from public.trailers where carrier_id is not null) as n_trailer_with_carrier,
    (select count(*) from public.trailers where carrier_id is null)     as n_trailer_no_carrier,
    (select count(*) from public.invoices)   as n_invoice,
    (select count(*) from public.payments)   as n_payment,
    (select count(*) from public.settlements) as n_settlement,
    (select array_agg(id order by id) from public.trailers) as trailer_ids,
    (select array_agg(carrier_id order by id) from public.trailers) as trailer_carrier_ids;

  raise notice '0132 PHASE 1 preconditions passed. % trailer(s): % with a carrier -> "carrier", % without -> "unresolved".',
    (select n_trailer from _mig0132_baseline),
    (select n_trailer_with_carrier from _mig0132_baseline),
    (select n_trailer_no_carrier from _mig0132_baseline);
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

create type public.trailer_ownership_scope as enum ('carrier','organization_shared','unresolved');

-- A. loads columns -------------------------------------------------------
alter table public.loads
  add column carrier_id uuid references public.carriers (id) on delete restrict;

alter table public.loads
  add column carrier_resolution text
    constraint loads_carrier_resolution_values
    check (carrier_resolution is null or carrier_resolution in ('resolved','backfilled','unresolved'));

alter table public.loads
  add column carrier_locked_at timestamptz;

comment on column public.loads.carrier_id is
  'The single responsible carrier for this load. Set for new loads by the load-creation RPC (later slice); legacy loads backfilled deterministically by migration 0133 (financial_dispatch_id -> dispatch carrier, else unambiguous dispatch carrier, else NULL + unresolved_carrier_records). Once set, immutable while the load has dispatches / financial activity -- see guard_load_carrier_change().';
comment on column public.loads.carrier_resolution is
  'How carrier_id was determined: resolved (from financial_dispatch_id), backfilled (from an unambiguous dispatch carrier), unresolved (could not prove -- carrier_id stays NULL, all downstream financial automation blocked). NULL only for loads created before 0133 ran that a later slice has not yet classified.';
comment on column public.loads.carrier_locked_at is
  'Audit/display timestamp of when this load acquired a financial carrier identity. NOT the authority for immutability -- guard_load_carrier_change() runs live dependency checks.';

-- A2. Financial-controller-on-unresolved invariant -- ENFORCED BY THE
-- TRIGGER, NOT A CHECK CONSTRAINT (correction: "correct migration 0133
-- candidate rules" superseded an earlier draft of this migration that added
-- a CHECK forbidding carrier_resolution='unresolved' with a non-NULL
-- financial_dispatch_id). That CHECK was WRONG once 0133 had to correctly
-- represent a load whose financial_dispatch_id is a historical fact (0129's
-- cancel_dispatch() and this migration's own guard never clear it) but
-- whose carrier is discovered to be genuinely ambiguous BECAUSE a live,
-- non-cancelled dispatch contradicts the controller (the new
-- C1_controller_conflict case) -- 0133 must be able to mark such a load
-- 'unresolved' WITHOUT touching financial_dispatch_id (which it never
-- touches, by design), and a blanket CHECK forbidding that combination made
-- that impossible. The correct, precise enforcement point is
-- guard_dispatch_carrier_scope() below: it categorically rejects any NEW or
-- REACTIVATED dispatch on a load whose carrier_resolution='unresolved',
-- regardless of financial_dispatch_id -- a live write-time guard, not a
-- storage-level constraint that cannot distinguish "a new write attempted
-- this" from "0133 is honestly recording a pre-existing historical fact".
--
-- B. loads carrier-change guard ----------------------------------------
create or replace function public.guard_load_carrier_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_carrier_org uuid;
  v_dispatch_count integer;
begin
  -- same-org (correction R)
  if new.carrier_id is not null then
    select organization_id into v_carrier_org from public.carriers where id = new.carrier_id;
    if v_carrier_org is null then
      raise exception 'loads.carrier_id % references a non-existent carrier.', new.carrier_id using errcode = '23503';
    end if;
    if v_carrier_org <> new.organization_id then
      raise exception 'loads.carrier_id % org % <> load org %.', new.carrier_id, v_carrier_org, new.organization_id using errcode = '23514';
    end if;
  end if;

  if tg_op = 'UPDATE' and old.carrier_id is not null
     and new.carrier_id is distinct from old.carrier_id then
    -- clearing an assigned carrier is never allowed
    if new.carrier_id is null then
      raise exception 'loads.carrier_id cannot be cleared once assigned (load %).', new.id using errcode = '23514';
    end if;
    -- reassigning to a different carrier requires zero dependent activity
    select count(*) into v_dispatch_count from public.dispatches where load_id = new.id;
    if v_dispatch_count > 0 or old.financial_dispatch_id is not null or new.financial_dispatch_id is not null then
      raise exception 'loads.carrier_id (% -> %) cannot change: load % has % dispatch(es) / a financial controller. Use public.reassign_load_carrier().',
        old.carrier_id, new.carrier_id, new.id, v_dispatch_count using errcode = '23514';
    end if;
    -- correction #6: reassigning an ALREADY-set carrier (even with zero
    -- dependent activity) is owner/admin authority, not delegated -- unlike
    -- the initial NULL -> value assignment, which stays open to dispatcher
    -- per decision 1 (load-creation carrier selection). A migration/service
    -- context (auth.uid() IS NULL) is trusted, matching every other guard.
    if auth.uid() is not null and not public.has_role(array['owner','admin']::public.org_role[]) then
      raise exception 'loads.carrier_id (% -> %) reassignment requires owner/admin authority (load %).',
        old.carrier_id, new.carrier_id, new.id using errcode = '42501';
    end if;
  end if;

  return new;
end;
$fn$;

create trigger loads_guard_carrier_change
  before insert or update on public.loads
  for each row execute function public.guard_load_carrier_change();

-- C. trailers.ownership_scope ---------------------------------------
alter table public.trailers
  add column ownership_scope public.trailer_ownership_scope;

-- deterministic backfill (correction 10)
update public.trailers
set ownership_scope = case
  when carrier_id is not null then 'carrier'::public.trailer_ownership_scope
  else 'unresolved'::public.trailer_ownership_scope
end;

alter table public.trailers
  alter column ownership_scope set not null;

alter table public.trailers
  add constraint trailers_ownership_scope_consistency
  check (
    (ownership_scope = 'carrier'              and carrier_id is not null)
    or (ownership_scope = 'organization_shared' and carrier_id is null)
    or (ownership_scope = 'unresolved'          and carrier_id is null)
  );

comment on column public.trailers.ownership_scope is
  'carrier: owned by trailers.carrier_id. organization_shared: an explicitly reviewed shared-pool trailer (carrier_id must be NULL). unresolved: carrier_id is NULL and ownership has not been confirmed -- CANNOT be dispatched until an owner/admin classifies it. Backfill: carrier_id present -> carrier, absent -> unresolved.';

-- new trailers: fill a NULL ownership_scope from carrier_id
create or replace function public.trailers_derive_ownership_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if new.ownership_scope is null then
    new.ownership_scope := case
      when new.carrier_id is not null then 'carrier'::public.trailer_ownership_scope
      else 'unresolved'::public.trailer_ownership_scope
    end;
  end if;
  return new;
end;
$fn$;

create trigger trailers_derive_ownership_scope
  before insert on public.trailers
  for each row execute function public.trailers_derive_ownership_scope();

-- D. dispatch carrier/trailer scope guard -- AUTHORITATIVE, row-locked
-- (correction: "cross-carrier integrity defect" -- a prior version of this
-- guard read loads.carrier_id / financial_dispatch_id WITHOUT locking the
-- row, so two concurrent dispatch INSERTs for the SAME load with DIFFERENT
-- carriers could both pass validation before either committed: both
-- dispatches survived, one silently became the financial controller (0125's
-- own locked AFTER INSERT trigger), and 0133 then trusted that controller's
-- carrier while a conflicting NON-CANCELLED dispatch of a different carrier
-- remained on the load. That is now structurally impossible -- see below.
create or replace function public.guard_dispatch_carrier_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_load_org uuid;
  v_load_carrier uuid;
  v_load_resolution text;
  v_noncanc_carriers uuid[];
  v_effective_carrier uuid;
  v_reactivating boolean;
  v_carrier_relevant boolean;
  v_trailer_scope public.trailer_ownership_scope;
begin
  -- A carrier-relevant change is: a brand-new row, its carrier/load
  -- changing, OR a previously-CANCELLED dispatch being REACTIVATED (status
  -- moving away from 'cancelled') -- reactivation can reintroduce a
  -- conflict a cancelled dispatch was safely allowed to carry historically.
  v_reactivating := (tg_op = 'UPDATE' and old.status = 'cancelled' and new.status <> 'cancelled');
  v_carrier_relevant :=
    tg_op = 'INSERT'
    or new.carrier_id is distinct from old.carrier_id
    or new.load_id is distinct from old.load_id
    or v_reactivating;

  if v_carrier_relevant then
    -- AUTHORITATIVE LOCK: acquire the load row FOR UPDATE before reading OR
    -- assigning any carrier-ownership field. This is what makes the whole
    -- guard race-safe -- a second concurrent dispatch INSERT/reactivation
    -- for the SAME load now blocks here until the first transaction
    -- commits or rolls back, and then re-reads the now-current row. No
    -- BEFORE trigger anywhere in this design evaluates carrier ownership
    -- against an unlocked read.
    select organization_id, carrier_id, carrier_resolution
      into v_load_org, v_load_carrier, v_load_resolution
      from public.loads
      where id = new.load_id
      for update;

    if v_load_org is null then
      raise exception 'dispatch load % does not exist.', new.load_id using errcode = '23503';
    end if;

    -- Determine the load's EFFECTIVE carrier, authoritatively, in priority
    -- order (correction: "correct the invariant"):
    --   1. loads.carrier_id, if already set -- always wins, unconditionally.
    --   2. carrier_resolution = 'unresolved' -- reject outright. A load
    --      0133 (or later) has explicitly flagged carrier-ambiguous accepts
    --      NO new/reactivated dispatch until manually resolved.
    --   3. Else (loads.carrier_id is still NULL, so step 1 never applied),
    --      derive from the set of CURRENTLY non-cancelled dispatches on this
    --      load (excluding the row being evaluated) rather than from
    --      financial_dispatch_id directly (0129's cancel_dispatch()
    --      preserves it through cancellation as history). If every
    --      non-cancelled dispatch shares one carrier, that carrier is
    --      effective. If more than one distinct carrier is already active
    --      on the load (a pre-existing anomaly from before this guard
    --      existed), fail closed -- reject rather than silently pick one.
    --      If there are none, the load has no live claim: free to be
    --      claimed (step below).
    --      CONFIRMED BY DIRECT TEST (see the migration header's
    --      "CANCEL-THEN-REDISPATCH" note): this branch does NOT make
    --      cancel-then-redispatch-to-a-different-carrier a generally
    --      supported pattern. Once step 5 below atomically claims
    --      loads.carrier_id on a load's first live dispatch, that value is
    --      permanent per step 1 above -- cancelling the dispatch that
    --      claimed it does not clear loads.carrier_id, so a later,
    --      different-carrier dispatch attempt is rejected by step 1/2, never
    --      reaching this branch. This branch is reached only while
    --      loads.carrier_id is still NULL (e.g. every prior dispatch on the
    --      load was inserted directly as 'cancelled' and therefore never
    --      ran the atomic-claim step) -- a narrow case, not the common
    --      create-then-cancel pattern.
    if v_load_carrier is not null then
      v_effective_carrier := v_load_carrier;
    elsif v_load_resolution = 'unresolved' then
      raise exception 'load % has an unresolved carrier (see unresolved_carrier_records) -- no dispatch may be created or reactivated on it until the carrier is resolved.', new.load_id
        using errcode = '23514';
    else
      select array_agg(distinct d.carrier_id) into v_noncanc_carriers
      from public.dispatches d
      where d.load_id = new.load_id and d.status <> 'cancelled' and d.id <> new.id;

      if array_length(v_noncanc_carriers, 1) = 1 then
        v_effective_carrier := v_noncanc_carriers[1];
      elsif array_length(v_noncanc_carriers, 1) > 1 then
        raise exception 'load % already has multiple conflicting non-cancelled dispatch carriers (%) -- cannot add/reactivate dispatch % until this is manually resolved.', new.load_id, v_noncanc_carriers, new.id
          using errcode = '23514';
      else
        v_effective_carrier := null;
      end if;
    end if;

    if v_effective_carrier is not null and new.carrier_id is distinct from v_effective_carrier then
      raise exception 'dispatch carrier % does not match load % carrier % -- a conflicting carrier can never coexist with an existing carrier/live-dispatch assignment on the same load.', new.carrier_id, new.load_id, v_effective_carrier
        using errcode = '23514';
    end if;

    -- Atomic first-dispatch claim: only for a genuinely NEW, non-cancelled
    -- carrier-relevant dispatch on a load with no prior claim whatsoever.
    if v_effective_carrier is null and new.status <> 'cancelled' then
      update public.loads
      set carrier_id = new.carrier_id,
          carrier_resolution = 'resolved'
      where id = new.load_id
        and carrier_id is null;  -- re-check under the lock we already hold; always true here, defense in depth
    end if;
  end if;

  -- unresolved-trailer guard: an unresolved trailer may not be assigned.
  -- Checked on INSERT and whenever trailer_id changes, so existing dispatches
  -- that already hold such a trailer are unaffected by other updates.
  if new.trailer_id is not null
     and (tg_op = 'INSERT' or new.trailer_id is distinct from old.trailer_id) then
    select ownership_scope into v_trailer_scope from public.trailers where id = new.trailer_id;
    if v_trailer_scope = 'unresolved' then
      raise exception 'trailer % has unresolved ownership; an owner/admin must classify it as carrier or organization_shared before it can be dispatched.', new.trailer_id
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$fn$;

create trigger dispatches_guard_carrier_scope
  before insert or update on public.dispatches
  for each row execute function public.guard_dispatch_carrier_scope();

-- E. Shared-trailer approval: audit table + guarded RPC + direct-update
-- lockout (correction #4). A CHECK constraint only validates the final
-- shape of a row -- it cannot prove an authorized owner/admin approved the
-- TRANSITION. This closes that gap.
create table public.trailer_ownership_scope_audit (
  id uuid primary key default gen_random_uuid(),
  trailer_id uuid not null references public.trailers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  ownership_scope_before public.trailer_ownership_scope not null,
  ownership_scope_after  public.trailer_ownership_scope not null,
  carrier_id_before uuid,
  carrier_id_after  uuid,
  reason text not null,
  approved_by uuid not null references public.profiles (id) on delete restrict,
  approved_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

comment on table public.trailer_ownership_scope_audit is
  'Append-only audit of every trailer ownership_scope / carrier_id transition. Written exclusively by public.approve_trailer_ownership_scope(); no direct client write path exists.';

alter table public.trailer_ownership_scope_audit enable row level security;

create policy trailer_ownership_scope_audit_select on public.trailer_ownership_scope_audit
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','accountant']::public.org_role[])
  );
-- No INSERT/UPDATE/DELETE policy for authenticated: written only by the RPC
-- below (SECURITY DEFINER, runs as table owner).

-- Explicit, defense-in-depth revocation (found during this correction's own
-- adversarial test pass): 0010's `ALTER DEFAULT PRIVILEGES ... GRANT SELECT,
-- INSERT, UPDATE, DELETE ON TABLES TO authenticated` auto-applies to EVERY
-- new table at CREATE TABLE time -- including this one -- regardless of
-- which RLS policies are later defined. Left unrevoked, `authenticated`
-- silently holds table-level INSERT/UPDATE/DELETE here. RLS's IMPLICIT
-- default-deny (no INSERT/UPDATE/DELETE/ALL policy exists) does still block
-- every one of those -- INSERT raises "new row violates row-level security
-- policy"; UPDATE/DELETE silently affect zero rows -- but that is an
-- implicit protection resting on "no matching policy happens to exist",
-- exactly the class of reliance correction #7 warns against ("do not rely on
-- ... as the sole authorization mechanism" generalizes to implicit RLS
-- default-deny too, not just a spoofable GUC). Revoking the privilege
-- outright makes the block explicit, unconditional, and independent of the
-- policy set ever changing.
revoke all on public.trailer_ownership_scope_audit from anon;
revoke insert, update, delete on public.trailer_ownership_scope_audit from authenticated;
grant select on public.trailer_ownership_scope_audit to authenticated;

-- Direct-update lockout: an ownership-relevant UPDATE is rejected unless the
-- transaction-local GUC below is set -- which only approve_trailer_
-- ownership_scope() ever sets, and only after its own role + reason checks
-- pass. `set_config(..., true)` (is_local) reverts at transaction end, but
-- that is NOT the same guarantee as "reverts when the RPC returns" -- a
-- caller invoking the RPC and then performing an unrelated direct UPDATE in
-- the SAME transaction would otherwise inherit the still-set flag. The RPC
-- therefore explicitly CLEARS the flag itself immediately after writing the
-- audit row (see its final steps below), closing that window regardless of
-- the surrounding transaction's shape -- a caught-and-fixed defect from this
-- correction's own test pass (correction #4). auth.uid() IS NULL (migration/
-- service context) bypasses this -- needed for 0132's OWN deterministic
-- backfill UPDATE above, which runs BEFORE this trigger is even created and
-- is therefore unaffected regardless.
create or replace function public.guard_trailer_ownership_scope_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if new.ownership_scope is distinct from old.ownership_scope
     or new.carrier_id is distinct from old.carrier_id then
    if auth.uid() is not null then
      if coalesce(current_setting('app.trailer_ownership_rpc_reason', true), '') = '' then
        raise exception 'trailer ownership_scope / carrier_id changes must go through public.approve_trailer_ownership_scope(...); direct updates are rejected (trailer %).', old.id
          using errcode = '42501';
      end if;
      if not public.has_role(array['owner','admin']::public.org_role[]) then
        raise exception 'trailer ownership_scope / carrier_id changes require owner/admin authority (trailer %).', old.id
          using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end;
$fn$;

create trigger trailers_guard_ownership_scope_change
  before update on public.trailers
  for each row execute function public.guard_trailer_ownership_scope_change();

-- approve_trailer_ownership_scope(...) -- the ONLY sanctioned path.
create or replace function public.approve_trailer_ownership_scope(
  p_trailer_id uuid,
  p_new_ownership_scope public.trailer_ownership_scope,
  p_reason text,
  p_new_carrier_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid := public.current_org_id();
  v_trailer public.trailers%rowtype;
  v_final_carrier uuid;
begin
  if v_uid is null then
    raise exception 'approve_trailer_ownership_scope: authentication required.' using errcode = '42501';
  end if;
  if v_org is null then
    raise exception 'approve_trailer_ownership_scope: caller has no organization.' using errcode = '42501';
  end if;
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'approve_trailer_ownership_scope: only owner/admin may change trailer ownership scope.' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'approve_trailer_ownership_scope: a reason is required.' using errcode = '22023';
  end if;

  select * into v_trailer from public.trailers where id = p_trailer_id and organization_id = v_org for update;
  if not found then
    raise exception 'approve_trailer_ownership_scope: trailer % not found in caller''s organization.', p_trailer_id using errcode = '42501';
  end if;

  if p_new_ownership_scope = 'organization_shared' then
    v_final_carrier := null;
  elsif p_new_ownership_scope = 'unresolved' then
    v_final_carrier := null;
  elsif p_new_ownership_scope = 'carrier' then
    if p_new_carrier_id is null then
      raise exception 'approve_trailer_ownership_scope: ownership_scope=carrier requires p_new_carrier_id.' using errcode = '22023';
    end if;
    if (select organization_id from public.carriers where id = p_new_carrier_id) is distinct from v_org then
      raise exception 'approve_trailer_ownership_scope: carrier % is not in the caller''s organization.', p_new_carrier_id using errcode = '42501';
    end if;
    v_final_carrier := p_new_carrier_id;
  end if;

  perform set_config('app.trailer_ownership_rpc_reason', p_reason, true);

  update public.trailers
  set ownership_scope = p_new_ownership_scope,
      carrier_id = v_final_carrier
  where id = p_trailer_id;

  insert into public.trailer_ownership_scope_audit (
    trailer_id, organization_id, ownership_scope_before, ownership_scope_after,
    carrier_id_before, carrier_id_after, reason, approved_by, approved_at
  ) values (
    p_trailer_id, v_org, v_trailer.ownership_scope, p_new_ownership_scope,
    v_trailer.carrier_id, v_final_carrier, p_reason, v_uid, now()
  );

  -- Clear the flag IMMEDIATELY, not just at transaction end. `is_local=true`
  -- reverts at transaction end, which is NOT the same as "end of this RPC
  -- call" -- a caller that invokes this RPC and then, in the SAME
  -- transaction, performs an unrelated direct UPDATE to trailers would
  -- otherwise inherit the still-set flag and silently bypass the lockout.
  -- Explicitly clearing it here closes that window regardless of the
  -- surrounding transaction's shape.
  perform set_config('app.trailer_ownership_rpc_reason', '', true);

  return jsonb_build_object(
    'success', true,
    'trailer_id', p_trailer_id,
    'ownership_scope', p_new_ownership_scope,
    'carrier_id', v_final_carrier,
    'approved_by', v_uid,
    'approved_at', now()
  );
end;
$fn$;

revoke all on function public.approve_trailer_ownership_scope(uuid,public.trailer_ownership_scope,text,uuid) from public;
grant execute on function public.approve_trailer_ownership_scope(uuid,public.trailer_ownership_scope,text,uuid) to authenticated;

comment on function public.approve_trailer_ownership_scope(uuid,public.trailer_ownership_scope,text,uuid) is
  'The ONLY sanctioned way to change a trailer''s ownership_scope or carrier_id. owner/admin only, requires a non-empty reason, writes trailer_ownership_scope_audit atomically. Direct table UPDATEs to these columns are unreachable for authenticated (column-level privilege revocation, below) and independently rejected by guard_trailer_ownership_scope_change() as a backstop -- correction #4/#7.';

-- F. Column-level privilege revocation (correction #7: "review trailer
-- authorization flag for spoofing"). The trigger's transaction-local GUC
-- flag is NOT relied upon as the sole authorization mechanism -- an
-- authenticated client could in principle reproduce a `set_config()` call
-- with the same name if it ever learned it. The actual, unforgeable
-- boundary is here: `authenticated` (the single Postgres role every app
-- user connects as, regardless of org_role) loses UPDATE on these two
-- specific columns entirely. A direct client UPDATE touching either column
-- fails with a Postgres permission error BEFORE the statement executes --
-- before any trigger, any GUC, any role check ever runs. The guarded RPC is
-- SECURITY DEFINER and therefore runs as the function owner (who is NOT
-- subject to this per-column revocation -- table/function owners always
-- bypass their own grants), so it is completely unaffected.
--
-- IMPORTANT Postgres privilege-model detail, discovered and fixed during
-- this correction's own test pass: `REVOKE UPDATE (col) ON t FROM role`
-- only removes a privilege that was ITSELF granted at the column level. It
-- does NOT narrow a broader TABLE-level UPDATE grant (0010's `GRANT SELECT,
-- INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated`)
-- -- that table-level grant independently covers every column, including
-- these two, regardless of any column-level REVOKE. The only correct way to
-- narrow it is: REVOKE the table-level UPDATE entirely, then GRANT UPDATE
-- back on the explicit list of every OTHER column -- which is what this
-- does. All OTHER trailer columns (status, notes, registration dates, etc.)
-- remain fully updatable by authenticated; only ownership_scope and
-- carrier_id are removed.
revoke update on public.trailers from authenticated;
grant update (
  id, organization_id, unit_number, vin, trailer_type, length_ft,
  license_plate, license_state, ownership_type, status,
  registration_expiry_date, annual_inspection_expiry_date, notes,
  created_at, updated_at
) on public.trailers to authenticated;

comment on column public.trailers.ownership_scope is
  'carrier: owned by trailers.carrier_id. organization_shared: an explicitly reviewed shared-pool trailer (carrier_id must be NULL). unresolved: carrier_id is NULL and ownership has not been confirmed -- CANNOT be dispatched until an owner/admin classifies it. Backfill: carrier_id present -> carrier, absent -> unresolved. UPDATE on this column is revoked from authenticated (correction #7) -- change it only via public.approve_trailer_ownership_scope().';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare
  b record;
  v_labels text;
  v_n integer;
begin
  select * into b from _mig0132_baseline;

  select string_agg(e.enumlabel, ',' order by e.enumsortorder) into v_labels
  from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
  where n.nspname='public' and t.typname='trailer_ownership_scope';
  if v_labels is distinct from 'carrier,organization_shared,unresolved' then
    raise exception '0132 postcondition: trailer_ownership_scope members = "%", expected "carrier,organization_shared,unresolved".', v_labels;
  end if;

  -- loads columns
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='loads' and column_name='carrier_id'
      and data_type='uuid' and is_nullable='YES' and column_default is null) then
    raise exception '0132 postcondition: loads.carrier_id is not (uuid, nullable, no default).';
  end if;
  if not exists (
    select 1 from pg_constraint c
    where c.conrelid='public.loads'::regclass and c.contype='f'
      and c.confrelid='public.carriers'::regclass and c.confdeltype='r'
      and (select array_agg(a.attname order by k.ord)
           from unnest(c.conkey) with ordinality as k(attnum, ord)
           join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum) = array['carrier_id']::name[]
  ) then
    raise exception '0132 postcondition: loads.carrier_id FK -> carriers(id) ON DELETE RESTRICT missing/wrong.';
  end if;
  if not exists (select 1 from pg_constraint where conname='loads_carrier_resolution_values' and conrelid='public.loads'::regclass) then
    raise exception '0132 postcondition: CHECK loads_carrier_resolution_values missing.';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='loads' and column_name='carrier_locked_at'
      and data_type='timestamp with time zone' and is_nullable='YES') then
    raise exception '0132 postcondition: loads.carrier_locked_at is not (timestamptz, nullable).';
  end if;

  -- 0132 does NOT backfill loads
  select count(*) into v_n from public.loads where carrier_id is not null or carrier_resolution is not null or carrier_locked_at is not null;
  if v_n <> 0 then
    raise exception '0132 postcondition: % load(s) have a non-NULL carrier_id/carrier_resolution/carrier_locked_at -- 0132 must not backfill loads (that is 0133).', v_n;
  end if;

  -- trailers.ownership_scope
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='trailers' and column_name='ownership_scope'
      and udt_name='trailer_ownership_scope' and is_nullable='NO') then
    raise exception '0132 postcondition: trailers.ownership_scope is not (trailer_ownership_scope, NOT NULL).';
  end if;
  if not exists (select 1 from pg_constraint where conname='trailers_ownership_scope_consistency'
                 and conrelid='public.trailers'::regclass and contype='c' and convalidated) then
    raise exception '0132 postcondition: CHECK trailers_ownership_scope_consistency missing or NOT VALID.';
  end if;

  -- deterministic backfill result
  select count(*) into v_n from public.trailers
  where (carrier_id is not null and ownership_scope <> 'carrier')
     or (carrier_id is null and ownership_scope <> 'unresolved');
  if v_n <> 0 then
    raise exception '0132 postcondition: % trailer(s) have ownership_scope inconsistent with the deterministic backfill rule.', v_n;
  end if;
  if exists (select 1 from public.trailers where ownership_scope = 'organization_shared') then
    raise exception '0132 postcondition: a trailer was backfilled to organization_shared -- backfill only produces carrier / unresolved.';
  end if;

  -- trailer rows otherwise untouched (carrier_id unchanged, count unchanged)
  if (select count(*) from public.trailers) <> b.n_trailer then
    raise exception '0132 postcondition: trailers count changed.';
  end if;
  select count(*) into v_n
  from unnest(b.trailer_ids, b.trailer_carrier_ids) as base(id, carrier_id)
  join public.trailers tr on tr.id = base.id
  where tr.carrier_id is distinct from base.carrier_id;
  if v_n <> 0 then
    raise exception '0132 postcondition: % trailer(s) had carrier_id changed by 0132.', v_n;
  end if;

  -- triggers / functions
  if not exists (select 1 from pg_trigger where tgname='trailers_derive_ownership_scope' and tgrelid='public.trailers'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT%') then
    raise exception '0132 postcondition: trigger trailers_derive_ownership_scope (BEFORE INSERT) missing/wrong.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='loads_guard_carrier_change' and tgrelid='public.loads'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%') then
    raise exception '0132 postcondition: trigger loads_guard_carrier_change (BEFORE INSERT OR UPDATE) missing/wrong.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='dispatches_guard_carrier_scope' and tgrelid='public.dispatches'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%') then
    raise exception '0132 postcondition: trigger dispatches_guard_carrier_scope (BEFORE INSERT OR UPDATE) missing/wrong.';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('guard_load_carrier_change','guard_dispatch_carrier_scope','trailers_derive_ownership_scope')
      and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'::text[]),',') not like '%search_path=%')
  ) then
    raise exception '0132 postcondition: a 0132 function is not (security definer + pinned search_path).';
  end if;

  -- 0055 / 0125 triggers on dispatches still present (0132 must not disturb them)
  if not exists (select 1 from pg_trigger where tgname='dispatches_guard_org' and tgrelid='public.dispatches'::regclass and not tgisinternal) then
    raise exception '0132 postcondition: 0055 dispatches_guard_org trigger disappeared.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass and not tgisinternal) then
    raise exception '0132 postcondition: 0125 dispatches_assign_financial_controller trigger disappeared.';
  end if;

  -- correction #5 sanity (informational -- NOT a CHECK constraint; see the
  -- header/section A2 note on why a blanket CHECK here would be wrong once
  -- 0133 exists): immediately after 0132 (0133 has not run yet in this same
  -- transaction), no load can possibly already carry both an 'unresolved'
  -- classification and a financial_dispatch_id, since nothing has
  -- classified any load yet.
  if exists (select 1 from public.loads where carrier_resolution = 'unresolved' and financial_dispatch_id is not null) then
    raise exception '0132 postcondition: a load has carrier_resolution=unresolved AND a financial_dispatch_id immediately after 0132 -- unexpected this early.';
  end if;

  -- correction #4: shared-trailer approval infrastructure
  if to_regclass('public.trailer_ownership_scope_audit') is null then
    raise exception '0132 postcondition: table public.trailer_ownership_scope_audit missing.';
  end if;
  if (select count(*) from public.trailer_ownership_scope_audit) <> 0 then
    raise exception '0132 postcondition: trailer_ownership_scope_audit is not empty -- 0132 creates no rows.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='trailer_ownership_scope_audit' and cmd in ('INSERT','UPDATE','DELETE','ALL')) then
    raise exception '0132 postcondition: trailer_ownership_scope_audit has an unexpected write policy.';
  end if;
  if exists (select 1 from information_schema.role_table_grants
             where table_schema='public' and table_name='trailer_ownership_scope_audit'
               and grantee='authenticated' and privilege_type in ('INSERT','UPDATE','DELETE')) then
    raise exception '0132 postcondition: authenticated still holds table-level INSERT/UPDATE/DELETE on trailer_ownership_scope_audit -- the explicit defense-in-depth revoke did not take.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                 where n.nspname='public' and p.proname='approve_trailer_ownership_scope') then
    raise exception '0132 postcondition: function public.approve_trailer_ownership_scope(...) missing.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='trailers_guard_ownership_scope_change' and tgrelid='public.trailers'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE UPDATE%') then
    raise exception '0132 postcondition: trigger trailers_guard_ownership_scope_change (BEFORE UPDATE) missing/wrong.';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('approve_trailer_ownership_scope','guard_trailer_ownership_scope_change')
      and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'::text[]),',') not like '%search_path=%')
  ) then
    raise exception '0132 postcondition: a shared-trailer function is not (security definer + pinned search_path).';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='approve_trailer_ownership_scope'
      and has_function_privilege('public', p.oid, 'execute')
  ) then
    raise exception '0132 postcondition: approve_trailer_ownership_scope is still EXECUTE-able by PUBLIC.';
  end if;

  -- protected counts preserved
  if (select count(*) from public.loads)       <> b.n_load       then raise exception '0132 postcondition: loads count changed.'; end if;
  if (select count(*) from public.dispatches)  <> b.n_dispatch   then raise exception '0132 postcondition: dispatches count changed.'; end if;
  if (select count(*) from public.invoices)    <> b.n_invoice    then raise exception '0132 postcondition: invoices count changed.'; end if;
  if (select count(*) from public.payments)    <> b.n_payment    then raise exception '0132 postcondition: payments count changed.'; end if;
  if (select count(*) from public.settlements) <> b.n_settlement then raise exception '0132 postcondition: settlements count changed.'; end if;

  -- auto-invoice function not touched
  if (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) ilike '%carrier_id%' then
    raise exception '0132 postcondition: auto_generate_invoice_from_delivered_load() now references carrier_id -- not this slice''s job.';
  end if;

  raise notice '0132 complete: trailer_ownership_scope enum; loads.carrier_id/carrier_resolution/carrier_locked_at (all NULL); trailers.ownership_scope backfilled (% carrier / % unresolved / 0 organization_shared); guard_load_carrier_change (now owner/admin-gated for reassignment) + guard_dispatch_carrier_scope (row-locked, authoritative, blocks conflicting/unresolved dispatch creation and atomically claims a load''s carrier on its first live dispatch) + trailers_derive_ownership_scope installed; trailer_ownership_scope_audit + approve_trailer_ownership_scope(...) + guard_trailer_ownership_scope_change (direct-update lockout) installed. Load carrier backfill is migration 0133.',
    (select count(*) from public.trailers where ownership_scope='carrier'),
    (select count(*) from public.trailers where ownership_scope='unresolved');
end
$mig$;

commit;
