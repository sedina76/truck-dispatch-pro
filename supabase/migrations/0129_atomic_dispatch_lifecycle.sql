-- =============================================================================
-- 0129_atomic_dispatch_lifecycle.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0001-0128 live. Frozen by the Batch-1 design review; implements
-- exactly that contract.
--
-- WHAT THIS MIGRATION DOES
--   1. public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) -> uuid
--      SECURITY INVOKER. Replaces createDispatch()'s five separate
--      auto-committed round trips (insert dispatch / dispatch_financials /
--      dispatch_internal_notes / loads.status='dispatched' / log_activity)
--      with ONE transaction: authenticate, role-gate to the exact RLS write
--      tier (owner/admin/dispatcher, 0010), lock the RLS-visible load,
--      derive organization_id from THAT load (never a parameter), gate to a
--      dispatchable load status, reject a second active dispatch for the
--      load, reject an active driver/truck/trailer conflict, INSERT the
--      dispatch (the 0055 guard_dispatch_org BEFORE INSERT trigger validates
--      same-org + same-carrier for every id; the 0125 stamp trigger stamps
--      proceeds_model; RLS dispatches_insert re-checks org+role; the 0125
--      AFTER INSERT trigger sets loads.financial_dispatch_id -- all inside
--      this txn), upsert financials + notes, advance the load, log. Any
--      RAISE rolls everything back. The 0054 partial unique indexes remain
--      the final race backstop.
--   2. public.cancel_dispatch(uuid,text) -> void
--      SECURITY INVOKER. Replaces cancelDispatch()'s three separate writes
--      with one transaction: authenticate, role-gate, idempotent no-op when
--      already cancelled, reject cancelling a delivered/completed dispatch,
--      set status='cancelled' + append the reason to notes + set
--      cancelled_at, return the load to 'booked' ONLY when no OTHER active
--      dispatch holds it AND the load has not moved past delivery, log --
--      atomically. loads.financial_dispatch_id and dispatch_financials /
--      dispatch_internal_notes are left intact (financial history).
--   3. create or replace public.auto_generate_invoice_from_delivered_load()
--      -- the delivered-load auto-invoice trigger function. Rebuilt from the
--      LIVE migration-0068 body (NOT the older 0028 body): the invoice
--      amount still comes from public.load_financials.rate, payment terms
--      still from broker_financials / customer_financials, one-invoice-per-
--      load is still `on conflict (load_id) do nothing`, the function is
--      still SECURITY DEFINER. TWO changes vs the live 0068 body:
--        (a) DISPATCH SELECTION. Was `select id from dispatches where
--            load_id = NEW.id limit 1` (no ORDER BY, no status filter -> a
--            cancel-and-redispatch could attach the invoice to the
--            CANCELLED dispatch). Now: prefer loads.financial_dispatch_id
--            when it still belongs to THIS load and is not cancelled; else
--            the newest non-cancelled dispatch, deterministically; NEVER a
--            cancelled or unrelated dispatch; may remain NULL.
--        (b) INVOICE NUMBER. Was public.generate_invoice_number(NEW.
--            organization_id) -- which since 0065 RAISEs unless the
--            operational user is owner/admin/accountant, so a dispatcher
--            completing an otherwise-authorized delivery had the ENTIRE
--            delivery transaction (dispatch status, loads.status, the
--            invoice) rolled back with a misleading generic error. Now
--            calls the new
--            public._generate_invoice_number_internal(NEW.organization_id)
--            (item 4) -- the same atomic counter mechanism WITHOUT the
--            accounting-role gate, reachable only from trusted
--            SECURITY DEFINER code.
--
--   4. public._generate_invoice_number_internal(uuid) -> text   [NEW]
--      SECURITY DEFINER, set search_path = public. The exact atomic, year-
--      scoped, per-organization counter upsert from 0065's
--      generate_invoice_number() -- format INV-YYYY-NNNNN -- with NO
--      authorization logic of its own (mechanism only). EXECUTE is REVOKEd
--      from public, anon, authenticated and service_role and GRANTed to no
--      application-facing role, so it is reachable ONLY through the two
--      owner-owned SECURITY DEFINER callers
--      (auto_generate_invoice_from_delivered_load and the public
--      generate_invoice_number). public.generate_invoice_number(uuid) is
--      re-created KEEPING its owner/admin/accountant guard verbatim, ADDING
--      an explicit tenant check (p_organization_id must equal
--      public.current_org_id() -- rejects null / mismatched / cross-tenant
--      so an owner/admin/accountant of org A can never consume org B's
--      counter), then delegating the mechanism to the internal helper. The
--      manual invoice-numbering path (src/app/(app)/invoices/new/page.tsx,
--      which passes current_org_id()) is behaviourally unchanged for a
--      same-org owner/admin/accountant and still fully protected; direct
--      client invocation of the un-gated mechanism is impossible.
--
--   NO VALID DISPATCH DECISION (documented + tested):
--     invoices.dispatch_id is NULLABLE (0004: `dispatch_id uuid references
--     public.dispatches(id) on delete cascade`, no NOT NULL) and the 0112
--     party-org guard explicitly does not cover dispatch_id ("never
--     client-submitted and inherently same-organization when auto-set from
--     a load"). A delivered load with NO valid (non-cancelled, same-load)
--     dispatch therefore STILL gets its draft invoice, with dispatch_id =
--     NULL -- delivered-load revenue is never silently lost. A NULL link
--     reads downstream as "carrier attribution needs manual review", which
--     is strictly safer than attributing an invoice to a cancelled or
--     foreign dispatch (wrong carrier / stale $0 financial snapshot) and
--     safer than suppressing the invoice (lost AR). This matches the
--     pre-0129 behavior for the genuine zero-dispatch case (the old
--     `limit 1` already left v_dispatch_id NULL there) -- 0129 only removes
--     the cancelled/unrelated mis-selection.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * ZERO row DML. Only DDL (CREATE FUNCTION, CREATE OR REPLACE FUNCTION,
--     REVOKE/GRANT). The DML inside the new function bodies runs only when a
--     caller later invokes them.
--   * does NOT introduce SECURITY DEFINER on the two new DISPATCH functions
--     (create_dispatch / cancel_dispatch are both SECURITY INVOKER -- RLS on
--     loads / dispatches / dispatch_financials / dispatch_internal_notes
--     applies to the caller). _generate_invoice_number_internal IS
--     SECURITY DEFINER by design -- it is mechanism-only, has EXECUTE
--     revoked from every application-facing role, and is unreachable except
--     from the two trusted SECURITY DEFINER callers.
--   * does NOT weaken the manual invoice-numbering path: the public
--     generate_invoice_number keeps its owner/admin/accountant guard and
--     gains a tenant-ownership check.
--   * does NOT alter migrations 0125-0128 or any object they created.
--   * does NOT touch the 0054 partial unique indexes, guard_dispatch_org
--     (0055), stamp_dispatch_proceeds_model / assign_load_financial_dispatch
--     (0125), sync_load_status_from_dispatch (0028), dispatch_financials_sync
--     (0068), or the auto_generate_invoice_on_delivery TRIGGER itself
--     (name/table/timing/columns unchanged -- only its function body's one
--     dispatch-selection statement).
--   * does NOT modify RLS policies, does NOT update any customer/business row.
--
-- STRUCTURE: explicit BEGIN ... COMMIT wraps everything. Leading DO block =
-- PHASE 1 read-only preconditions. Plain top-level DDL = PHASE 2. Trailing
-- DO block = PHASE 3 postconditions. ANY exception anywhere (a PHASE 1/3
-- RAISE, a PHASE 2 DDL error) aborts the whole transaction: because COMMIT
-- is the very last statement and is never reached on error, Postgres rolls
-- back every CREATE FUNCTION / CREATE OR REPLACE / GRANT / REVOKE in this
-- file -- nothing is left half-applied. NOT idempotent: a re-run RAISEs in
-- PHASE 1 at "function already exists" (and rolls back, changing nothing).
--
-- APPLICATION PROCEDURE (Supabase SQL Editor): paste this ENTIRE file and
-- Run once. The editor submits the whole buffer as one request; the
-- explicit BEGIN/COMMIT here make atomicity independent of the editor's own
-- implicit-transaction behaviour and of `supabase db push` / `psql -f`
-- (which otherwise autocommit per statement). Do NOT run it in fragments.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
declare
  -- The frozen ACTIVE dispatch statuses, SORTED (compared as a set, so
  -- order in the index DDL is irrelevant). MUST match
  -- ACTIVE_DISPATCH_STATUSES (src/lib/dispatch/conflicts.ts) and the 0054
  -- index predicates.
  c_frozen constant text[] := array[
    'accepted','assigned','at_delivery','at_pickup',
    'en_route_to_delivery','en_route_to_pickup','loaded'];
  -- The exact predicate Postgres renders for the 0054 indexes in
  -- production (pg_get_expr ALWAYS reconstructs `IN (...)` as
  -- `= ANY (ARRAY[...::dispatch_status])`). Used only for a static
  -- self-test that the semantic check below accepts that real form.
  c_prod_pred constant text :=
    '(status = ANY (ARRAY[''assigned''::dispatch_status, ''accepted''::dispatch_status, ''en_route_to_pickup''::dispatch_status, ''at_pickup''::dispatch_status, ''loaded''::dispatch_status, ''en_route_to_delivery''::dispatch_status, ''at_delivery''::dispatch_status]))';
  r        record;
  v_seen   int := 0;
  v_set    text[];
  v_pred   text;
  v_def    text;
  v_gin    text;
begin
  -- required existing objects
  if to_regclass('public.loads')                    is null then raise exception '0129 precondition: public.loads missing. STOP.'; end if;
  if to_regclass('public.dispatches')               is null then raise exception '0129 precondition: public.dispatches missing. STOP.'; end if;
  if to_regclass('public.dispatch_financials')      is null then raise exception '0129 precondition: public.dispatch_financials missing (apply 0067). STOP.'; end if;
  if to_regclass('public.dispatch_internal_notes')  is null then raise exception '0129 precondition: public.dispatch_internal_notes missing (apply 0067). STOP.'; end if;
  if to_regclass('public.invoices')                 is null then raise exception '0129 precondition: public.invoices missing. STOP.'; end if;
  if to_regclass('public.invoice_line_items')       is null then raise exception '0129 precondition: public.invoice_line_items missing. STOP.'; end if;

  -- helper functions the new RPCs / the invoice trigger rely on
  if to_regprocedure('public.has_role(public.org_role[])')                       is null then raise exception '0129 precondition: public.has_role(org_role[]) missing. STOP.'; end if;
  if to_regprocedure('public.current_org_id()')                                  is null then raise exception '0129 precondition: public.current_org_id() missing. STOP.'; end if;
  if to_regprocedure('public.log_activity(public.entity_type,uuid,text,jsonb,uuid)') is null then raise exception '0129 precondition: public.log_activity(entity_type,uuid,text,jsonb,uuid) missing (apply 0044/0046). STOP.'; end if;
  if to_regprocedure('public.generate_invoice_number(uuid)')                     is null then raise exception '0129 precondition: public.generate_invoice_number(uuid) missing. STOP.'; end if;

  -- objects 0129 CREATES must be ABSENT (fail closed)
  if to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is not null then
    raise exception '0129 precondition: public.create_dispatch(...) already exists -- 0129 partially applied? STOP.';
  end if;
  if to_regprocedure('public.cancel_dispatch(uuid,text)') is not null then
    raise exception '0129 precondition: public.cancel_dispatch(...) already exists -- 0129 partially applied? STOP.';
  end if;

  -- dispatch_status enum -- exact 10-label set (the create/cancel functions
  -- hard-code the active/terminal partitions).
  if (select array_agg(e.enumlabel::text order by e.enumlabel)
      from pg_enum e join pg_type t on t.oid = e.enumtypid join pg_namespace n on n.oid = t.typnamespace
      where n.nspname = 'public' and t.typname = 'dispatch_status')
     is distinct from array['accepted','assigned','at_delivery','at_pickup','cancelled','completed','delivered','en_route_to_delivery','en_route_to_pickup','loaded']::text[]
  then
    raise exception '0129 precondition: public.dispatch_status enum labels are not the expected 10-value set. STOP.';
  end if;

  -- the 3 x 0054 partial unique indexes -- rendering-INDEPENDENT semantic
  -- check. pg_get_indexdef / pg_get_expr always reconstruct `x IN (a,b,c)`
  -- as `x = ANY (ARRAY[a::dispatch_status, ...])`, so a textual match
  -- against an `IN (...)` form is a guaranteed false "drift". Instead:
  -- verify catalog facts (UNIQUE, partial, exactly one key column = the
  -- matching resource column) and normalize the predicate (lowercase, drop
  -- ::dispatch_status casts, drop whitespace) then compare the SET of
  -- status literals it contains against the frozen 7. Tolerates casts /
  -- ARRAY[] vs IN() / parens / whitespace / schema-qual; still fails for a
  -- genuinely missing / extra / changed status, a non-unique or
  -- non-partial index, the wrong key column, a terminal status, or (for
  -- the trailer index) a lost `trailer_id is not null` guard.
  for r in
    select
      ic.relname,
      i.indisunique,
      (i.indpred is not null) as is_partial,
      i.indnkeyatts           as nkeys,
      (select a.attname from pg_attribute a
         where a.attrelid = i.indrelid and a.attnum = i.indkey[0]) as key_col,
      regexp_replace(
        regexp_replace(lower(coalesce(pg_get_expr(i.indpred, i.indrelid), '')),
          '::[a-z_.]*dispatch_status', '', 'g'),
        '\s+', '', 'g') as pred_norm
    from pg_class ic
    join pg_index i on i.indexrelid = ic.oid
    where ic.relkind = 'i' and ic.relnamespace = 'public'::regnamespace
      and ic.relname in ('dispatches_active_driver_unique',
                         'dispatches_active_truck_unique',
                         'dispatches_active_trailer_unique')
  loop
    v_seen := v_seen + 1;

    if not r.indisunique then
      raise exception '0129 precondition: 0054 index % is not UNIQUE. STOP.', r.relname;
    end if;
    if not r.is_partial then
      raise exception '0129 precondition: 0054 index % has no partial predicate. STOP.', r.relname;
    end if;
    if r.nkeys <> 1 then
      raise exception '0129 precondition: 0054 index % does not key exactly one column (indnkeyatts=%). STOP.', r.relname, r.nkeys;
    end if;
    if r.key_col is distinct from (case r.relname
                                     when 'dispatches_active_driver_unique'  then 'driver_id'
                                     when 'dispatches_active_truck_unique'   then 'truck_id'
                                     when 'dispatches_active_trailer_unique' then 'trailer_id'
                                   end) then
      raise exception '0129 precondition: 0054 index % keys column "%" (expected the matching resource column). STOP.', r.relname, r.key_col;
    end if;

    if r.pred_norm not like '%status=any(array[%' and r.pred_norm not like '%statusin(%' then
      raise exception '0129 precondition: 0054 index % predicate is not a `status` membership test. Normalized: %. STOP.', r.relname, r.pred_norm;
    end if;

    select coalesce(array_agg(distinct m[1] order by m[1]), array[]::text[])
      into v_set
      from regexp_matches(r.pred_norm, '''([a-z_]+)''', 'g') as m;
    if v_set is distinct from c_frozen then
      raise exception '0129 precondition: 0054 index % active-status set has drifted from the frozen 7 -- found %, expected %. STOP.', r.relname, v_set, c_frozen;
    end if;

    if r.pred_norm like '%''delivered''%' or r.pred_norm like '%''completed''%' or r.pred_norm like '%''cancelled''%' then
      raise exception '0129 precondition: 0054 index % predicate includes a TERMINAL status. Normalized: %. STOP.', r.relname, r.pred_norm;
    end if;

    if r.relname = 'dispatches_active_trailer_unique' and r.pred_norm not like '%trailer_idisnotnull%' then
      raise exception '0129 precondition: 0054 index dispatches_active_trailer_unique lost its `trailer_id is not null` guard. Normalized: %. STOP.', r.pred_norm;
    end if;
  end loop;

  if v_seen <> 3 then
    raise exception '0129 precondition: expected 3 x 0054 partial unique index (driver / truck / trailer); found %. STOP.', v_seen;
  end if;

  -- static self-test: the semantic rule above must accept the exact
  -- production-rendered predicate. If this fails, the CHECK is broken, not
  -- the database.
  v_pred := regexp_replace(regexp_replace(lower(c_prod_pred), '::[a-z_.]*dispatch_status', '', 'g'), '\s+', '', 'g');
  select coalesce(array_agg(distinct m[1] order by m[1]), array[]::text[])
    into v_set from regexp_matches(v_pred, '''([a-z_]+)''', 'g') as m;
  if v_pred not like '%status=any(array[%' or v_set is distinct from c_frozen then
    raise exception '0129 self-test: the 0054 semantic predicate check does not accept the known production-rendered predicate. This is a bug in the check itself, not drift. STOP.';
  end if;

  -- guard_dispatch_org (0048/0055) must be attached to dispatches -- the
  -- create_dispatch INSERT relies on it for same-org / same-carrier
  -- validation of carrier/truck/driver/trailer.
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.dispatches'::regclass and tgname = 'dispatches_guard_org' and not tgisinternal
      and pg_get_triggerdef(oid) ilike '%before insert or update on public.dispatches%'
  ) then
    raise exception '0129 precondition: trigger dispatches_guard_org (BEFORE INSERT OR UPDATE on public.dispatches, 0055) is not attached. STOP -- create_dispatch depends on it for cross-org protection.';
  end if;

  -- 0125 dispatch triggers present (create_dispatch relies on the AFTER
  -- INSERT one to maintain loads.financial_dispatch_id).
  if not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_stamp_proceeds' and not tgisinternal) then
    raise exception '0129 precondition: trigger dispatches_stamp_proceeds (0125) missing. STOP.';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal) then
    raise exception '0129 precondition: trigger dispatches_assign_financial_controller (0125) missing. STOP.';
  end if;

  -- the auto-invoice trigger + its function must exist; the function must
  -- still be the LIVE migration-0068 shape:
  --   * sources the amount from public.load_financials.rate -- NOT NEW.rate
  --     (0069 removed loads.rate; a 0028-era body here would be stale/broken)
  --   * reads payment terms from broker_financials / customer_financials
  --   * still carries the vulnerable `select id ... from public.dispatches
  --     where load_id = new.id limit 1` dispatch selection this migration
  --     replaces
  --   * does NOT yet reference financial_dispatch_id
  --   * still calls the role-guarded public.generate_invoice_number(...)
  if not exists (
    select 1 from pg_trigger where tgrelid='public.loads'::regclass and tgname='auto_generate_invoice_on_delivery' and not tgisinternal
  ) then
    raise exception '0129 precondition: trigger auto_generate_invoice_on_delivery (0022) missing. STOP.';
  end if;
  if to_regprocedure('public.auto_generate_invoice_from_delivered_load()') is null then
    raise exception '0129 precondition: function auto_generate_invoice_from_delivered_load() missing. STOP.';
  end if;
  v_def := lower(regexp_replace(pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()')), '\s+', ' ', 'g'));
  if position('select id into v_dispatch_id from public.dispatches where load_id = new.id limit 1' in v_def) = 0 then
    raise exception '0129 precondition: auto_generate_invoice_from_delivered_load() does not carry the exact `select id ... limit 1` dispatch-selection statement this migration replaces -- body has drifted. STOP and inspect.';
  end if;
  if v_def like '%financial_dispatch_id%' then
    raise exception '0129 precondition: auto_generate_invoice_from_delivered_load() ALREADY references financial_dispatch_id -- 0129 (or an equivalent) already applied. Nothing to do. STOP.';
  end if;
  if v_def not like '%from public.load_financials where load_id = new.id%'
     or v_def not like '%public.broker_financials%'
     or v_def not like '%public.customer_financials%' then
    raise exception '0129 precondition: auto_generate_invoice_from_delivered_load() is not the expected LIVE 0068 form (load_financials / broker_financials / customer_financials markers missing) -- base body has drifted. STOP and inspect.';
  end if;
  if v_def like '%new.rate%' then
    raise exception '0129 precondition: auto_generate_invoice_from_delivered_load() still references NEW.rate -- loads.rate was removed by 0069; the live body must already read load_financials. STOP and inspect.';
  end if;
  if v_def not like '%on conflict (load_id)%' then
    raise exception '0129 precondition: auto_generate_invoice_from_delivered_load() is missing the one-invoice-per-load `on conflict (load_id)` guard. STOP.';
  end if;
  if v_def not like '%public.generate_invoice_number(new.organization_id)%' then
    raise exception '0129 precondition: auto_generate_invoice_from_delivered_load() does not call public.generate_invoice_number(NEW.organization_id) -- body has drifted. STOP and inspect.';
  end if;

  -- the invoice-number split objects 0129 introduces must be in their
  -- pre-migration state: the internal helper ABSENT, and the public
  -- generate_invoice_number still the 0065 body (owner/admin/accountant
  -- guard, SECURITY DEFINER, not yet delegating to a helper).
  if to_regprocedure('public._generate_invoice_number_internal(uuid)') is not null then
    raise exception '0129 precondition: public._generate_invoice_number_internal(uuid) already exists -- 0129 partially applied? STOP.';
  end if;
  if to_regprocedure('public.generate_invoice_number(uuid)') is null then
    raise exception '0129 precondition: public.generate_invoice_number(uuid) missing. STOP.';
  end if;
  v_gin := lower(regexp_replace(pg_get_functiondef(to_regprocedure('public.generate_invoice_number(uuid)')), '\s+', ' ', 'g'));
  if v_gin not like '%has_role(array[''owner'', ''admin'', ''accountant'']::public.org_role[])%' then
    raise exception '0129 precondition: public.generate_invoice_number(uuid) does not carry the expected 0065 owner/admin/accountant role guard -- body has drifted. STOP and inspect.';
  end if;
  if v_gin not like '%insert into public.invoice_number_counters%' then
    raise exception '0129 precondition: public.generate_invoice_number(uuid) does not carry the expected 0065 counter upsert -- body has drifted. STOP and inspect.';
  end if;
  if position('_generate_invoice_number_internal' in v_gin) > 0 then
    raise exception '0129 precondition: public.generate_invoice_number(uuid) already delegates to an internal helper -- 0129 (or an equivalent) already applied. STOP.';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.generate_invoice_number(uuid)') and p.prosecdef) then
    raise exception '0129 precondition: public.generate_invoice_number(uuid) is not SECURITY DEFINER. STOP and inspect.';
  end if;

  -- invoices.dispatch_id must be nullable (the NULL-link fallback depends on it)
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='invoices' and column_name='dispatch_id' and is_nullable='NO'
  ) then
    raise exception '0129 precondition: invoices.dispatch_id is NOT NULL -- the "no valid dispatch -> NULL-linked invoice" fallback is invalid. STOP and redesign.';
  end if;

  raise notice '0129 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION (DDL only) ======================

-- ---------------------------------------------------------------------------
-- A. create_dispatch -- one atomic transaction for the whole create path.
-- SECURITY INVOKER: every statement below runs with the caller's RLS. The
-- error MESSAGE strings are the exact user-facing copy the app shows; the
-- 5-char SQLSTATE (TDxxx) lets the app map to its DispatchConflictError
-- code/field; DETAIL carries the conflicting dispatch id for the
-- "View Active Dispatch" link.
-- ---------------------------------------------------------------------------
create function public.create_dispatch(
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
security invoker
set search_path = public
as $fn$
declare
  c_active constant text[] := array[
    'assigned','accepted','en_route_to_pickup','at_pickup','loaded',
    'en_route_to_delivery','at_delivery'];
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

  -- 3. lock the load. RLS (loads_select) hides other orgs' loads, so a
  --    cross-tenant p_load_id is simply "not found". organization_id comes
  --    from THIS row -- never from a parameter.
  select l.organization_id, l.status
    into v_org, v_load_status
  from public.loads l
  where l.id = p_load_id
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
  where d.load_id = p_load_id and d.status = any(c_active)
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
  where d.driver_id = p_driver_id and d.status = any(c_active)
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
  where d.truck_id = p_truck_id and d.status = any(c_active)
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
    where d.trailer_id = p_trailer_id and d.status = any(c_active)
    limit 1;
    if v_hit_id is not null then
      raise exception '% is already assigned to active %.',
        v_hit_label, case when v_hit_ln <> '' then 'load ' || v_hit_ln else 'another dispatch' end
        using errcode = 'TDTRL', detail = v_hit_id::text;
    end if;
  end if;

  -- 7. INSERT. Fires (in order): dispatches_guard_org (BEFORE, 0055 --
  --    same-org + same-carrier for every id), dispatches_stamp_proceeds
  --    (BEFORE, 0125), RLS dispatches_insert WITH CHECK (org + role),
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

-- ---------------------------------------------------------------------------
-- B. cancel_dispatch -- one atomic transaction for the whole cancel path.
-- Lock order is loads THEN dispatches, identical to create_dispatch, so the
-- two can never deadlock on the same load.
-- ---------------------------------------------------------------------------
create function public.cancel_dispatch(
  p_dispatch_id uuid,
  p_reason      text default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $fn$
declare
  c_active constant text[] := array[
    'assigned','accepted','en_route_to_pickup','at_pickup','loaded',
    'en_route_to_delivery','at_delivery'];
  v_org        uuid;
  v_load_id    uuid;
  v_status     text;
  v_notes      text;
  v_cancel_note text;
  v_reason     text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to cancel a dispatch.' using errcode = 'TDAUT';
  end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'Only an owner, admin, or dispatcher can cancel a dispatch.' using errcode = 'TDROL';
  end if;

  -- resolve the load id WITHOUT locking (RLS hides other orgs' dispatches)
  select d.organization_id, d.load_id, d.status
    into v_org, v_load_id, v_status
  from public.dispatches d
  where d.id = p_dispatch_id;
  if not found then
    raise exception 'That dispatch could not be found.' using errcode = 'TDCNF';
  end if;

  -- idempotent: already cancelled -> nothing to do
  if v_status = 'cancelled' then
    return;
  end if;

  -- lock LOAD first (matches create_dispatch's order), then the dispatch
  perform 1 from public.loads where id = v_load_id for update;
  select d.status, d.notes into v_status, v_notes
  from public.dispatches d where d.id = p_dispatch_id for update;

  if v_status = 'cancelled' then
    return; -- raced with another cancel; still a no-op
  end if;
  if v_status in ('delivered','completed') then
    raise exception 'A delivered or completed dispatch cannot be cancelled.' using errcode = 'TDTRM', detail = v_status;
  end if;

  v_cancel_note := '[Cancelled' || case when v_reason is not null then ': ' || v_reason else '' end || ']';

  update public.dispatches
     set status       = 'cancelled',
         notes        = case when v_notes is not null and btrim(v_notes) <> ''
                             then v_notes || E'\n' || v_cancel_note
                             else v_cancel_note end,
         cancelled_at = coalesce(cancelled_at, now())
   where id = p_dispatch_id;

  -- Return the load to 'booked' ONLY when no OTHER active dispatch holds it
  -- and it has not moved past delivery. financial_dispatch_id is left as-is
  -- (historical attribution).
  update public.loads l
     set status = 'booked'
   where l.id = v_load_id
     and l.status not in ('delivered','pod_received','invoiced','closed','cancelled')
     and not exists (
       select 1 from public.dispatches d
       where d.load_id = v_load_id and d.id <> p_dispatch_id and d.status = any(c_active));

  perform public.log_activity(
    'dispatch'::public.entity_type, p_dispatch_id, 'cancelled',
    case when v_reason is not null then jsonb_build_object('reason', v_reason) end,
    v_org);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- C. Invoice-number split -- separate the un-gated counter MECHANISM from the
-- role-guarded public entry point, so a trusted database trigger can mint a
-- number for an operationally-authorized user (e.g. a dispatcher completing
-- a delivery) WITHOUT that user needing an accounting role, while the direct
-- client path stays exactly as protected as it was in 0065 (plus a new
-- tenant-ownership check).
--
--   public._generate_invoice_number_internal(uuid)  [NEW, private]
--     The exact atomic upsert body from 0065's generate_invoice_number()
--     (INSERT ... ON CONFLICT (organization_id, year) DO UPDATE ... RETURNING;
--     format INV-YYYY-NNNNN). NO has_role / tenant logic -- mechanism only.
--     SECURITY DEFINER + fixed search_path so it can touch
--     invoice_number_counters (which has no client policy). EXECUTE is
--     revoked from public, anon, authenticated AND service_role and granted
--     to nobody -- the function owner keeps the implicit right, so it is
--     reachable ONLY from an owner-owned SECURITY DEFINER caller. There are
--     exactly two: public.generate_invoice_number (below) and
--     public.auto_generate_invoice_from_delivered_load (section D). A client
--     `supabase.rpc('_generate_invoice_number_internal', ...)` gets
--     "permission denied for function".
--
--   public.generate_invoice_number(uuid)  [re-created]
--     Keeps 0065's owner/admin/accountant guard VERBATIM (same message).
--     ADDS: the caller-supplied p_organization_id must equal
--     public.current_org_id() (the SECURITY DEFINER profile lookup, 0002) --
--     null, mismatched, or another tenant's id is rejected, so an
--     owner/admin/accountant of org A can no longer consume org B's counter.
--     Then delegates the mechanism to _generate_invoice_number_internal.
--     Still SECURITY DEFINER; `grant execute ... to authenticated` re-issued
--     (the drop-and-recreate would otherwise drop the ACL) exactly as 0065
--     had it. src/app/(app)/invoices/new/page.tsx already passes
--     current_org_id() and falls back to an empty suggested number on any
--     error, so a same-org owner/admin/accountant sees identical behaviour.
-- ---------------------------------------------------------------------------
create function public._generate_invoice_number_internal(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year integer := extract(year from current_date)::integer;
  v_number integer;
begin
  insert into public.invoice_number_counters (organization_id, year, last_number)
  values (p_organization_id, v_year, 1)
  on conflict (organization_id, year)
  do update set last_number = invoice_number_counters.last_number + 1, updated_at = now()
  returning last_number into v_number;

  return 'INV-' || v_year || '-' || lpad(v_number::text, 5, '0');
end;
$$;

-- No GRANT. Strip every default/inherited EXECUTE so no application-facing
-- role can reach the un-gated mechanism directly.
revoke execute on function public._generate_invoice_number_internal(uuid) from public;
revoke execute on function public._generate_invoice_number_internal(uuid) from anon;
revoke execute on function public._generate_invoice_number_internal(uuid) from authenticated;
revoke execute on function public._generate_invoice_number_internal(uuid) from service_role;

comment on function public._generate_invoice_number_internal(uuid) is
  'PRIVATE invoice-number mechanism (0129). Atomic per-org/year counter -> INV-YYYY-NNNNN. NO authorization logic. EXECUTE revoked from public/anon/authenticated/service_role -- callable only from the owner-owned SECURITY DEFINER functions public.generate_invoice_number and public.auto_generate_invoice_from_delivered_load. Never expose to a client.';

create or replace function public.generate_invoice_number(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_org uuid;
begin
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    raise exception 'Only owner, admin, or accountant roles can generate invoice numbers.';
  end if;

  -- Tenant-ownership check (0129): a permitted role must not be able to mint
  -- (and thereby advance) another organization's invoice counter by passing
  -- a foreign id. p_organization_id is validated against the caller's own
  -- trusted organization, never trusted as-is.
  v_caller_org := public.current_org_id();
  if v_caller_org is null then
    raise exception 'Could not determine your organization; cannot generate an invoice number.';
  end if;
  if p_organization_id is null or p_organization_id <> v_caller_org then
    raise exception 'Invoice numbers can only be generated for your own organization.';
  end if;

  return public._generate_invoice_number_internal(p_organization_id);
end;
$$;

grant execute on function public.generate_invoice_number(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- D. auto_generate_invoice_from_delivered_load() -- rebuilt from the LIVE
-- migration-0068 body (0068_financial_function_cutover.sql), reproduced
-- verbatim EXCEPT:
--   (a) the dispatch-selection statement (marked "0129 (a):" below) --
--       0068 had `select id ... from public.dispatches where load_id =
--       NEW.id limit 1`;
--   (b) the invoice-number call (marked "0129 (b):" below) -- 0068 called
--       public.generate_invoice_number(NEW.organization_id); now calls the
--       private mechanism so a dispatcher-completed delivery is not rolled
--       back by the accounting-role guard.
-- Still SECURITY DEFINER. Amount still from public.load_financials.rate;
-- payment terms still from broker_financials / customer_financials;
-- one-invoice-per-load still `on conflict (load_id) do nothing`.
-- ---------------------------------------------------------------------------
create or replace function public.auto_generate_invoice_from_delivered_load()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_to_name text;
  v_bill_to_email text;
  v_bill_to_address text;
  v_payment_terms integer;
  v_org_default_terms integer;
  v_invoice_number text;
  v_dispatch_id uuid;
  v_invoice_id uuid;
  v_rate numeric(10, 2);
begin
  if NEW.status is distinct from 'delivered' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status is not distinct from 'delivered' then
    return NEW;
  end if;

  if exists (select 1 from public.invoices where load_id = NEW.id) then
    return NEW;
  end if;

  if NEW.broker_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', address_line1, city, state, postal_code)), '')
      into v_bill_to_name, v_bill_to_email, v_bill_to_address
    from public.brokers where id = NEW.broker_id;
    select payment_terms_days into v_payment_terms from public.broker_financials where broker_id = NEW.broker_id;
  elsif NEW.customer_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', billing_address_line1, city, state, postal_code)), '')
      into v_bill_to_name, v_bill_to_email, v_bill_to_address
    from public.customers where id = NEW.customer_id;
    select payment_terms_days into v_payment_terms from public.customer_financials where customer_id = NEW.customer_id;
  else
    return NEW;
  end if;

  select default_payment_terms_days into v_org_default_terms
  from public.organizations where id = NEW.organization_id;

  -- 0129 (a): the dispatch this invoice is attributed to. Prefer the
  -- authoritative controlling dispatch (loads.financial_dispatch_id, 0125)
  -- when it still belongs to THIS load and is not cancelled; otherwise the
  -- newest non-cancelled dispatch for this load, deterministically. NEVER a
  -- cancelled or unrelated dispatch. May stay NULL (no valid dispatch) --
  -- the invoice is still created with dispatch_id = NULL (nullable column;
  -- 0112 party-org guard tolerates it) so delivered-load revenue is never
  -- lost; a NULL link means "carrier attribution needs review" downstream.
  v_dispatch_id := NEW.financial_dispatch_id;
  if v_dispatch_id is not null
     and not exists (
       select 1 from public.dispatches d
       where d.id = v_dispatch_id and d.load_id = NEW.id and d.status <> 'cancelled'
     ) then
    v_dispatch_id := null;
  end if;
  if v_dispatch_id is null then
    select d.id into v_dispatch_id
    from public.dispatches d
    where d.load_id = NEW.id and d.status <> 'cancelled'
    order by d.dispatched_at desc nulls last, d.created_at desc, d.id desc
    limit 1;
  end if;

  select rate into v_rate from public.load_financials where load_id = NEW.id;
  v_rate := coalesce(v_rate, 0);

  -- 0129 (b): mint the number through the private mechanism, NOT the
  -- role-guarded public.generate_invoice_number -- this trigger is trusted
  -- SECURITY DEFINER code and must succeed for an operationally-authorized
  -- deliverer (owner/admin/dispatcher) regardless of accounting role.
  v_invoice_number := public._generate_invoice_number_internal(NEW.organization_id);

  insert into public.invoices (
    organization_id, invoice_number, load_id, dispatch_id, broker_id, customer_id,
    status, bill_to_name, bill_to_email, bill_to_address,
    subtotal_amount, total_amount, issue_date, due_date, notes
  ) values (
    NEW.organization_id, v_invoice_number, NEW.id, v_dispatch_id, NEW.broker_id, NEW.customer_id,
    'draft', v_bill_to_name, v_bill_to_email, v_bill_to_address,
    v_rate, v_rate, current_date,
    current_date + coalesce(v_payment_terms, v_org_default_terms, 30),
    'Auto-generated on delivery for load ' || NEW.load_number
  )
  on conflict (load_id) where load_id is not null do nothing
  returning id into v_invoice_id;

  if v_invoice_id is not null then
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (NEW.organization_id, v_invoice_id, 'Freight charges -- Load ' || NEW.load_number, 1, v_rate, 0);

    perform public.log_activity('invoice', v_invoice_id, 'created', null, NEW.organization_id);
  end if;

  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- E. Privileges -- exact signatures. SECURITY INVOKER + authenticated only.
-- service_role is revoked too: these RPCs require a real authenticated org
-- member (auth.uid() + has_role gates would reject a service-role call
-- anyway -- the revoke just makes the intent explicit and blocks accidental
-- background use). No SECURITY DEFINER on either new function.
-- ---------------------------------------------------------------------------
revoke execute on function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) from public, anon, service_role;
grant  execute on function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) to authenticated;

revoke execute on function public.cancel_dispatch(uuid,text) from public, anon, service_role;
grant  execute on function public.cancel_dispatch(uuid,text) to authenticated;

comment on function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) is
  'Atomic dispatch creation (0129). SECURITY INVOKER. Authenticates, role-gates to owner/admin/dispatcher, derives organization_id from the RLS-visible load (never a parameter), gates dispatchable load status, rejects a second active dispatch for the load and active driver/truck/trailer conflicts, then INSERTs the dispatch + dispatch_financials + dispatch_internal_notes, advances loads.status to dispatched, and logs -- all in one transaction. guard_dispatch_org (0055) and the 0054 partial unique indexes remain the cross-org and race backstops.';
comment on function public.cancel_dispatch(uuid,text) is
  'Atomic dispatch cancellation (0129). SECURITY INVOKER. Idempotent when already cancelled; refuses to cancel a delivered/completed dispatch; sets status=cancelled + appends the reason to notes + sets cancelled_at, returns the load to booked only when no other active dispatch holds it and it has not moved past delivery, and logs -- all in one transaction. financial_dispatch_id / dispatch_financials / dispatch_internal_notes are left intact (financial history).';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare
  c_create constant regprocedure := 'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure;
  c_cancel constant regprocedure := 'public.cancel_dispatch(uuid,text)'::regprocedure;
  c_invfn  constant regprocedure := 'public.auto_generate_invoice_from_delivered_load()'::regprocedure;
  c_gin    constant regprocedure := 'public.generate_invoice_number(uuid)'::regprocedure;
  c_gin_i  constant regprocedure := 'public._generate_invoice_number_internal(uuid)'::regprocedure;
  c_frozen constant text[] := array[
    'accepted','assigned','at_delivery','at_pickup',
    'en_route_to_delivery','en_route_to_pickup','loaded'];
  r       record;
  v_seen  int := 0;
  v_set   text[];
  v_def text;
begin
  -- new functions exist with the exact signatures
  if to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null then
    raise exception '0129 postcondition: create_dispatch(...) with the exact signature is missing.';
  end if;
  if to_regprocedure('public.cancel_dispatch(uuid,text)') is null then
    raise exception '0129 postcondition: cancel_dispatch(...) with the exact signature is missing.';
  end if;

  -- both new functions are SECURITY INVOKER (NOT definer), search_path=public, plpgsql, return the right type
  if exists (select 1 from pg_proc p where p.oid in (c_create, c_cancel) and p.prosecdef) then
    raise exception '0129 postcondition: a new function is SECURITY DEFINER -- must be SECURITY INVOKER.';
  end if;
  if exists (
    select 1 from pg_proc p where p.oid in (c_create, c_cancel)
      and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') not like '%search_path=public%'
  ) then
    raise exception '0129 postcondition: a new function is missing set search_path=public.';
  end if;
  if (select prorettype from pg_proc where oid = c_create) <> 'uuid'::regtype then
    raise exception '0129 postcondition: create_dispatch does not return uuid.';
  end if;
  if (select prorettype from pg_proc where oid = c_cancel) <> 'void'::regtype then
    raise exception '0129 postcondition: cancel_dispatch does not return void.';
  end if;

  -- privileges: authenticated only; not anon/public/service_role; no PUBLIC acl entry
  if not has_function_privilege('authenticated', c_create, 'EXECUTE')
     or not has_function_privilege('authenticated', c_cancel, 'EXECUTE') then
    raise exception '0129 postcondition: authenticated lacks EXECUTE on a new function.';
  end if;
  if has_function_privilege('anon', c_create, 'EXECUTE') or has_function_privilege('anon', c_cancel, 'EXECUTE')
     or has_function_privilege('service_role', c_create, 'EXECUTE') or has_function_privilege('service_role', c_cancel, 'EXECUTE') then
    raise exception '0129 postcondition: anon or service_role still has EXECUTE on a new function.';
  end if;
  if exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid in (c_create, c_cancel) and a::text like '=%') then
    raise exception '0129 postcondition: a new function still has a PUBLIC grant in its ACL.';
  end if;

  -- body invariants: create_dispatch
  v_def := lower(regexp_replace(pg_get_functiondef(c_create), '\s+', ' ', 'g'));
  if position('for update' in v_def) = 0 then raise exception '0129 postcondition: create_dispatch does not lock the load FOR UPDATE.'; end if;
  if position('public.has_role(array[''owner'',''admin'',''dispatcher'']' in v_def) = 0 then raise exception '0129 postcondition: create_dispatch role gate is not owner/admin/dispatcher.'; end if;
  if position('auth.uid() is null' in v_def) = 0 then raise exception '0129 postcondition: create_dispatch has no unauthenticated gate.'; end if;
  if position('into v_org, v_load_status' in v_def) = 0 or position('from public.loads l' in v_def) = 0 then
    raise exception '0129 postcondition: create_dispatch does not derive organization_id from the locked load row.';
  end if;
  if lower(pg_get_function_arguments(c_create)) like '%organization%' then
    raise exception '0129 postcondition: create_dispatch signature mentions organization -- org id must come from the load, never a parameter.';
  end if;
  if position('into public.dispatches' in v_def) = 0 or position('into public.dispatch_financials' in v_def) = 0
     or position('into public.dispatch_internal_notes' in v_def) = 0
     or position('update public.loads set status = ''dispatched''' in v_def) = 0
     or position('log_activity' in v_def) = 0 then
    raise exception '0129 postcondition: create_dispatch is missing one of the 5 write steps (dispatch / financials / notes / load-status / activity).';
  end if;
  if position('when unique_violation then' in v_def) = 0 then
    raise exception '0129 postcondition: create_dispatch has no unique_violation (0054 race) handler.';
  end if;

  -- body invariants: cancel_dispatch
  v_def := lower(regexp_replace(pg_get_functiondef(c_cancel), '\s+', ' ', 'g'));
  if position('for update' in v_def) = 0 then raise exception '0129 postcondition: cancel_dispatch does not lock rows FOR UPDATE.'; end if;
  if position('if v_status = ''cancelled'' then return' in v_def) = 0 then raise exception '0129 postcondition: cancel_dispatch is not idempotent on already-cancelled.'; end if;
  if position('v_status in (''delivered'',''completed'')' in v_def) = 0 then raise exception '0129 postcondition: cancel_dispatch does not refuse delivered/completed.'; end if;
  if position('status not in (''delivered'',''pod_received'',''invoiced'',''closed'',''cancelled'')' in v_def) = 0 then
    raise exception '0129 postcondition: cancel_dispatch load-revert is missing the terminal-status guard.';
  end if;
  if position('d.id <> p_dispatch_id and d.status = any(c_active)' in v_def) = 0 then
    raise exception '0129 postcondition: cancel_dispatch reverts the load without checking for OTHER active dispatches.';
  end if;
  -- cancel_dispatch must never WRITE financial_dispatch_id (historical
  -- attribution is preserved). Match an actual assignment / UPDATE SET
  -- target -- `financial_dispatch_id =` -- not a mere mention: the body's
  -- own comment ("financial_dispatch_id is left as-is") is part of
  -- pg_get_functiondef() output and must not trip this.
  if v_def ~ 'financial_dispatch_id\s*=' then
    raise exception '0129 postcondition: cancel_dispatch writes financial_dispatch_id -- historical attribution must be preserved.';
  end if;

  -- invoice-number split: private mechanism -------------------------------
  if to_regprocedure('public._generate_invoice_number_internal(uuid)') is null then
    raise exception '0129 postcondition: public._generate_invoice_number_internal(uuid) was not created.';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = c_gin_i
      and p.prosecdef
      and p.prorettype = 'text'::regtype
      and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%'
  ) then
    raise exception '0129 postcondition: _generate_invoice_number_internal is not SECURITY DEFINER / returns text / set search_path=public.';
  end if;
  if has_function_privilege('anon',           c_gin_i, 'EXECUTE')
     or has_function_privilege('authenticated', c_gin_i, 'EXECUTE')
     or has_function_privilege('service_role',  c_gin_i, 'EXECUTE') then
    raise exception '0129 postcondition: an application-facing role (anon/authenticated/service_role) still has EXECUTE on _generate_invoice_number_internal.';
  end if;
  if exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid = c_gin_i and a::text like '=%') then
    raise exception '0129 postcondition: _generate_invoice_number_internal still has a PUBLIC grant in its ACL.';
  end if;
  v_def := lower(regexp_replace(pg_get_functiondef(c_gin_i), '\s+', ' ', 'g'));
  if position('has_role' in v_def) > 0 or position('current_org_id' in v_def) > 0 then
    raise exception '0129 postcondition: _generate_invoice_number_internal contains authorization logic -- it must be mechanism-only.';
  end if;
  if position('on conflict (organization_id, year) do update set last_number = invoice_number_counters.last_number + 1' in v_def) = 0
     or position('''inv-'' || v_year || ''-'' || lpad(v_number::text, 5, ''0'')' in v_def) = 0 then
    raise exception '0129 postcondition: _generate_invoice_number_internal lost the atomic counter upsert / INV-YYYY-NNNNN format.';
  end if;

  -- invoice-number split: public guarded entry point ---------------------
  v_def := lower(regexp_replace(pg_get_functiondef(c_gin), '\s+', ' ', 'g'));
  if position('has_role(array[''owner'', ''admin'', ''accountant'']::public.org_role[])' in v_def) = 0 then
    raise exception '0129 postcondition: public.generate_invoice_number lost its owner/admin/accountant role guard.';
  end if;
  if position('current_org_id()' in v_def) = 0 or position('p_organization_id <> v_caller_org' in v_def) = 0 then
    raise exception '0129 postcondition: public.generate_invoice_number has no tenant-ownership validation (current_org_id vs p_organization_id).';
  end if;
  if position('public._generate_invoice_number_internal(p_organization_id)' in v_def) = 0 then
    raise exception '0129 postcondition: public.generate_invoice_number does not delegate to the internal helper.';
  end if;
  if position('insert into public.invoice_number_counters' in v_def) > 0 then
    raise exception '0129 postcondition: public.generate_invoice_number still performs the raw counter upsert -- the mechanism must live only in the helper.';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = c_gin and p.prosecdef) then
    raise exception '0129 postcondition: public.generate_invoice_number is no longer SECURITY DEFINER.';
  end if;
  if not has_function_privilege('authenticated', c_gin, 'EXECUTE') then
    raise exception '0129 postcondition: authenticated lost EXECUTE on public.generate_invoice_number.';
  end if;

  -- auto-invoice: trigger bound; safe dispatch selection in; vulnerable
  -- line out; LIVE 0068 invariants preserved (NOT the stale 0028 NEW.rate
  -- body); mints via the private helper, never the guarded public function.
  if not exists (select 1 from pg_trigger where tgrelid='public.loads'::regclass and tgname='auto_generate_invoice_on_delivery' and not tgisinternal) then
    raise exception '0129 postcondition: the auto_generate_invoice_on_delivery trigger is gone.';
  end if;
  v_def := lower(regexp_replace(pg_get_functiondef(c_invfn), '\s+', ' ', 'g'));
  if position('new.financial_dispatch_id' in v_def) = 0
     or position('d.status <> ''cancelled''' in v_def) = 0
     or position('order by d.dispatched_at desc nulls last, d.created_at desc, d.id desc' in v_def) = 0 then
    raise exception '0129 postcondition: auto_generate_invoice_from_delivered_load() does not carry the safe 0129 dispatch-selection logic.';
  end if;
  if position('select id into v_dispatch_id from public.dispatches where load_id = new.id limit 1' in v_def) > 0 then
    raise exception '0129 postcondition: the vulnerable `select id ... limit 1` statement is still present.';
  end if;
  if position('from public.load_financials where load_id = new.id' in v_def) = 0
     or position('public.broker_financials' in v_def) = 0
     or position('public.customer_financials' in v_def) = 0
     or position('on conflict (load_id)' in v_def) = 0 then
    raise exception '0129 postcondition: auto_generate_invoice_from_delivered_load() lost a LIVE 0068 invariant (load_financials rate / broker_financials / customer_financials / on conflict (load_id)).';
  end if;
  if position('new.rate' in v_def) > 0 then
    raise exception '0129 postcondition: auto_generate_invoice_from_delivered_load() references NEW.rate -- it must read load_financials (0069 removed loads.rate).';
  end if;
  if position('public._generate_invoice_number_internal(new.organization_id)' in v_def) = 0 then
    raise exception '0129 postcondition: auto_generate_invoice_from_delivered_load() does not mint via _generate_invoice_number_internal(NEW.organization_id).';
  end if;
  if position('public.generate_invoice_number(' in v_def) > 0 then
    raise exception '0129 postcondition: auto_generate_invoice_from_delivered_load() still calls the role-guarded public.generate_invoice_number().';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = c_invfn and p.prosecdef) then
    raise exception '0129 postcondition: auto_generate_invoice_from_delivered_load() is no longer SECURITY DEFINER.';
  end if;

  -- protected objects untouched -- 0054 partial unique indexes re-validated
  -- with the SAME rendering-independent semantic rule used in PHASE 1
  -- (UNIQUE, partial, single correct key column, exactly the frozen 7
  -- active statuses, no terminal status, trailer index still NULL-guarded).
  for r in
    select
      ic.relname,
      i.indisunique,
      (i.indpred is not null) as is_partial,
      i.indnkeyatts           as nkeys,
      (select a.attname from pg_attribute a
         where a.attrelid = i.indrelid and a.attnum = i.indkey[0]) as key_col,
      regexp_replace(
        regexp_replace(lower(coalesce(pg_get_expr(i.indpred, i.indrelid), '')),
          '::[a-z_.]*dispatch_status', '', 'g'),
        '\s+', '', 'g') as pred_norm
    from pg_class ic
    join pg_index i on i.indexrelid = ic.oid
    where ic.relkind = 'i' and ic.relnamespace = 'public'::regnamespace
      and ic.relname in ('dispatches_active_driver_unique',
                         'dispatches_active_truck_unique',
                         'dispatches_active_trailer_unique')
  loop
    v_seen := v_seen + 1;
    select coalesce(array_agg(distinct m[1] order by m[1]), array[]::text[])
      into v_set from regexp_matches(r.pred_norm, '''([a-z_]+)''', 'g') as m;
    if not (
          r.indisunique
      and r.is_partial
      and r.nkeys = 1
      and r.key_col = (case r.relname
                         when 'dispatches_active_driver_unique'  then 'driver_id'
                         when 'dispatches_active_truck_unique'   then 'truck_id'
                         when 'dispatches_active_trailer_unique' then 'trailer_id'
                       end)
      and (r.pred_norm like '%status=any(array[%' or r.pred_norm like '%statusin(%')
      and v_set = c_frozen
      and r.pred_norm not like '%''delivered''%'
      and r.pred_norm not like '%''completed''%'
      and r.pred_norm not like '%''cancelled''%'
      and (r.relname <> 'dispatches_active_trailer_unique' or r.pred_norm like '%trailer_idisnotnull%')
    ) then
      raise exception '0129 postcondition: 0054 index % failed semantic re-validation (found statuses %). STOP.', r.relname, v_set;
    end if;
  end loop;
  if v_seen <> 3 then
    raise exception '0129 postcondition: a 0054 partial unique index disappeared (found % of 3).', v_seen;
  end if;
  if not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_guard_org' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal) then
    raise exception '0129 postcondition: guard_dispatch_org (0055) or dispatches_assign_financial_controller (0125) trigger disappeared.';
  end if;

  raise notice '0129 complete: create_dispatch / cancel_dispatch (SECURITY INVOKER, authenticated-only) created; _generate_invoice_number_internal (private mechanism, no EXECUTE for anon/authenticated/service_role) created; generate_invoice_number re-created with its owner/admin/accountant guard + a tenant-ownership check, delegating to the helper; auto_generate_invoice_from_delivered_load() rebuilt on the LIVE 0068 body with the hardened dispatch selection (financial_dispatch_id -> newest non-cancelled -> NULL) and minting via the private helper. ZERO rows written. 0054 indexes, guard_dispatch_org, 0125 triggers, and the auto-invoice trigger all verified intact.';
end
$mig$;

-- Reached only if PHASE 1, PHASE 2, and PHASE 3 all succeeded. Any earlier
-- exception aborted the transaction before this line, rolling back all DDL.
commit;
