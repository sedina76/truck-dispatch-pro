-- ############################################################################
-- ##                                                                        ##
-- ##   MANUAL ONE-TIME PRODUCTION REPAIR  --  NEVER RUN AUTOMATICALLY.       ##
-- ##                                                                        ##
-- ##   This file is NOT a migration. It lives OUTSIDE supabase/migrations/   ##
-- ##   so `supabase db push` / any migration runner will NOT discover or    ##
-- ##   execute it. Apply it BY HAND, ONCE, in the Supabase SQL Editor,      ##
-- ##   ONLY after supabase/VERIFY_LD100024_DISPATCH_STATUS_REPAIR.sql has   ##
-- ##   been run and every row shows ok = true.                              ##
-- ##                                                                        ##
-- ############################################################################
--
-- WHAT IT DOES  (exactly one row, one column):
--   UPDATE public.loads SET status = 'dispatched'
--   WHERE id = '463891ec-88fb-4a48-a010-6e2789f62faa'
--     AND status = 'booked'
--     AND financial_dispatch_id = 'ff50462b-735b-48ae-ac83-d43886b605b8';
--
-- WHY:
--   Load LD-100024 has an ASSIGNED dispatch (ff50462b-...) and
--   loads.financial_dispatch_id already points at it, but loads.status was
--   left at 'booked'. The pre-0129 non-atomic createDispatch path inserted
--   the dispatch + dispatch_financials + set the financial controller, then
--   failed to advance the load before the request ended. Migration 0129's
--   create_dispatch() now does the whole thing in one transaction; this is
--   the single historical row that path left half-finished.
--
-- WHAT IT DOES NOT DO:
--   * touches NO other load, and NO row outside public.loads
--   * does NOT change driver, truck, carrier, trailer, dispatch status,
--     dispatch_financials, load_financials, load_stops, invoices,
--     activity_logs, webhooks, or any timestamp EXCEPT loads.updated_at,
--     which the standing set_updated_at BEFORE UPDATE trigger (0009) sets
--     to now() on every UPDATE -- that is the only permitted side effect
--   * does NOT generate an invoice (see "AUTO-INVOICE" below)
--   * does NOT clean up test data, does NOT touch stripe_webhook_events
--   * makes NO schema / migration / grant change
--
-- NOT IDEMPOTENT ON PURPOSE:
--   PHASE 1 requires loads.status = 'booked'. A second run finds it
--   'dispatched' and RAISES in PHASE 1 -- the transaction aborts and
--   nothing changes. There is no "already done, skip" path; re-running is
--   an error, by design.
--
-- SAFE TO REFUSE:
--   PHASE 1 re-checks EVERY precondition from
--   VERIFY_LD100024_DISPATCH_STATUS_REPAIR.sql. PHASE 2 additionally asserts
--   exactly one row was updated. If ANYTHING drifted since verification
--   (status, financial_dispatch_id, the dispatch, a new invoice, a new
--   conflicting dispatch), the script RAISES before or at the write and the
--   explicit BEGIN/COMMIT rolls the whole thing back.
--
-- ============================================================================
-- TRIGGERS THAT CAN FIRE ON public.loads FOR THIS 'booked' -> 'dispatched'
-- UPDATE  (full enumeration -- confirm against the tail of the VERIFY script):
--
--   1. set_updated_at                    BEFORE UPDATE   (0009, every table
--        with an updated_at column)
--        -> body: `new.updated_at = now(); return new;`
--        -> EFFECT: bumps loads.updated_at. This is the ONE intended,
--           DB-enforced side effect and is explicitly permitted.
--
--   2. loads_guard_load_number_change    BEFORE UPDATE   (0114)
--        -> guard_load_number_change(): FIRST statement is
--           `if new.load_number is not distinct from old.load_number
--            then return new; end if;`
--        -> EFFECT: immediate no-op. This UPDATE never touches load_number,
--           so the trigger returns before any role check, org check, reason
--           (GUC) check, lifecycle-lock check, counter advance, or
--           log_activity() call. Nothing raised, nothing logged.
--
--   3. loads_financial_dispatch_ref_guard BEFORE INSERT OR UPDATE  (0125)
--        -> guard_load_financial_dispatch_ref(): for TG_OP = 'UPDATE',
--           `if new.financial_dispatch_id is not distinct from
--            old.financial_dispatch_id then return new; end if;`
--        -> EFFECT: immediate no-op. This UPDATE never touches
--           financial_dispatch_id, so the referenced-dispatch same-load /
--           same-org validation is not even reached. (It would pass anyway:
--           ff50462b belongs to load 463891ec in org 11111111.)
--
--   4. auto_generate_invoice_on_delivery AFTER UPDATE   (trigger from 0022,
--        re-bound 0028/0044; body last set by 0068)
--        -> auto_generate_invoice_from_delivered_load(): FIRST two
--           statements are
--             `if NEW.status is distinct from 'delivered' then return NEW; end if;`
--             `if TG_OP = 'UPDATE' and OLD.status is not distinct from
--              'delivered' then return NEW; end if;`
--        -> EFFECT: immediate no-op. NEW.status = 'dispatched', which IS
--           distinct from 'delivered', so the function returns on line 1.
--           It never reads broker/customer billing data, never calls
--           public._generate_invoice_number_internal(...) or
--           public.generate_invoice_number(...), never inserts into
--           public.invoices / public.invoice_line_items, never calls
--           log_activity('invoice', ...). NO INVOICE IS CREATED.
--
--   5. loads_mirror_financials           -- NOT LIVE.
--        Added by 0067, DROPPED by 0068 (`drop trigger if exists
--        loads_mirror_financials on public.loads;`). Listed here only so the
--        enumeration is exhaustive; it does not exist on the database.
--
--   NOT on public.loads (do not fire from this UPDATE):
--     dispatches_sync_load_status  -- AFTER UPDATE on public.DISPATCHES; it
--       only propagates dispatch->load on a dispatch reaching
--       'delivered'/'completed'. Updating loads.status does not touch any
--       dispatch row, so this trigger is never entered.
--
--   RLS: the Supabase SQL Editor runs as the table owner and bypasses RLS.
--     The UPDATE is scoped to a single primary key regardless.
--
-- AUTO-INVOICE -- explicit confirmation:
--   auto_generate_invoice_from_delivered_load() only does work when
--   NEW.status = 'delivered' (see trigger #4 above). This repair sets
--   'dispatched'. Therefore no invoice, no invoice line item, no invoice
--   number consumed, no 'invoice' activity log. Verified additionally by
--   PHASE 3, which fails if any invoice row appears for the load.
--
-- ============================================================================
-- EXACT BEFORE / AFTER
--
--   public.loads  463891ec-88fb-4a48-a010-6e2789f62faa
--     column                 BEFORE       AFTER
--     status                 booked   ->  dispatched          (the only change)
--     financial_dispatch_id  ff50462b ->  ff50462b            (unchanged)
--     updated_at             <t0>     ->  now()               (set_updated_at trigger; permitted)
--     everything else        --       ->  --                  (unchanged)
--
--   public.dispatches  ff50462b-735b-48ae-ac83-d43886b605b8
--     status = 'assigned', driver_id / truck_id / carrier_id / trailer_id,
--     dispatched_at / completed_at / cancelled_at / created_at, and every
--     other column: UNCHANGED. No statement in this script writes to
--     public.dispatches, and no public.loads trigger writes to it.
--
--   public.invoices / invoice_line_items : NO ROWS CREATED.
--   public.load_stops / dispatch_financials / load_financials /
--     activity_logs : UNCHANGED.
--
--   Rows changed by this script: exactly 1 (public.loads).
--
-- ============================================================================
-- EMERGENCY ROLLBACK  --  manual, use ONLY if this repair caused an
-- unexpected problem AND no further dispatch / billing activity has happened
-- to LD-100024 since (no invoice, dispatch still 'assigned', load still
-- exactly 'dispatched'). Run by hand:
--
--     begin;
--     update public.loads
--        set status = 'booked'
--      where id = '463891ec-88fb-4a48-a010-6e2789f62faa'
--        and status = 'dispatched'
--        and financial_dispatch_id = 'ff50462b-735b-48ae-ac83-d43886b605b8';
--     -- expect: UPDATE 1  (if UPDATE 0, the state already moved on -- do
--     --                    NOT force it; investigate instead)
--     commit;
--
--   Do NOT run the rollback if LD-100024 has since been delivered / invoiced
--   or the dispatch has progressed -- reverting the load to 'booked' would
--   then be the corruption, not the fix.
-- ============================================================================

begin;

-- ======================= PHASE 1 -- FAIL-CLOSED PRECONDITIONS ===============
do $repair$
declare
  c_load   constant uuid   := '463891ec-88fb-4a48-a010-6e2789f62faa';
  c_disp   constant uuid   := 'ff50462b-735b-48ae-ac83-d43886b605b8';
  c_org    constant uuid   := '11111111-0000-0000-0000-000000000001';
  c_active constant text[] := array['assigned','accepted','en_route_to_pickup',
                                    'at_pickup','loaded','en_route_to_delivery','at_delivery'];
  v_lnum       text;
  v_status     text;
  v_fdi        uuid;
  v_org        uuid;
  v_org_name   text;
  v_d_status   text;
  v_d_load     uuid;
  v_d_org      uuid;
  v_d_driver   uuid;
  v_d_truck    uuid;
  v_d_trailer  uuid;
  v_active_n   integer;
  v_conflict_n integer;
  v_gin_i      text;
  v_inv        text;
begin
  -- 1. load exists + exact load number
  select l.load_number, l.status::text, l.financial_dispatch_id, l.organization_id
    into v_lnum, v_status, v_fdi, v_org
  from public.loads l
  where l.id = c_load;
  if not found then
    raise exception 'REPAIR_LD100024: load % not found. STOP.', c_load;
  end if;
  if v_lnum is distinct from 'LD-100024' then
    raise exception 'REPAIR_LD100024: load % load_number is % (expected LD-100024). STOP.', c_load, v_lnum;
  end if;

  -- 2. organization is Kali Freights LLC / expected id
  select o.name into v_org_name from public.organizations o where o.id = c_org;
  if v_org is distinct from c_org then
    raise exception 'REPAIR_LD100024: load organization is % (expected Kali Freights %). STOP.', v_org, c_org;
  end if;
  if v_org_name is null or lower(v_org_name) not like 'kali freights%' then
    raise exception 'REPAIR_LD100024: organization % name is % -- not Kali Freights. STOP.', c_org, coalesce(v_org_name, '<null>');
  end if;

  -- 3. current status MUST be booked (also what stops a 2nd run)
  if v_status is distinct from 'booked' then
    raise exception 'REPAIR_LD100024: loads.status is % (expected booked). Already repaired, or state changed -- STOP. This script is not rerunnable.', v_status;
  end if;

  -- 4. financial controller already points at ff50462b
  if v_fdi is distinct from c_disp then
    raise exception 'REPAIR_LD100024: loads.financial_dispatch_id is % (expected %). STOP.', coalesce(v_fdi::text,'<null>'), c_disp;
  end if;

  -- 5. dispatch row exists, same load + same org
  select d.status::text, d.load_id, d.organization_id, d.driver_id, d.truck_id, d.trailer_id
    into v_d_status, v_d_load, v_d_org, v_d_driver, v_d_truck, v_d_trailer
  from public.dispatches d
  where d.id = c_disp;
  if not found then
    raise exception 'REPAIR_LD100024: dispatch % not found. STOP.', c_disp;
  end if;
  if v_d_load is distinct from c_load then
    raise exception 'REPAIR_LD100024: dispatch % load_id is % (expected %). STOP.', c_disp, v_d_load, c_load;
  end if;
  if v_d_org is distinct from c_org then
    raise exception 'REPAIR_LD100024: dispatch % organization is % (expected %). STOP.', c_disp, v_d_org, c_org;
  end if;

  -- 6. dispatch status is assigned
  if v_d_status is distinct from 'assigned' then
    raise exception 'REPAIR_LD100024: dispatch % status is % (expected assigned). STOP.', c_disp, v_d_status;
  end if;

  -- 7. exactly ONE active dispatch for the load, and it is ff50462b
  select count(*) into v_active_n
  from public.dispatches d
  where d.load_id = c_load and d.status::text = any(c_active);
  if v_active_n <> 1 then
    raise exception 'REPAIR_LD100024: expected exactly 1 ACTIVE dispatch for the load, found %. STOP.', v_active_n;
  end if;
  if not exists (
    select 1 from public.dispatches d
    where d.load_id = c_load and d.id = c_disp and d.status::text = any(c_active)
  ) then
    raise exception 'REPAIR_LD100024: the single active dispatch for the load is not %. STOP.', c_disp;
  end if;

  -- 8. driver (Fuaad Ahmed) + truck T-112 attached
  if not exists (
    select 1 from public.drivers dr
    where dr.id = v_d_driver
      and (coalesce(dr.first_name,'') || ' ' || coalesce(dr.last_name,'')) ilike '%ahmed%'
  ) then
    raise exception 'REPAIR_LD100024: dispatch driver % is not the expected Ahmed. STOP.', coalesce(v_d_driver::text,'<null>');
  end if;
  if not exists (
    select 1 from public.trucks tk where tk.id = v_d_truck and tk.unit_number = 'T-112'
  ) then
    raise exception 'REPAIR_LD100024: dispatch truck % is not unit T-112. STOP.', coalesce(v_d_truck::text,'<null>');
  end if;

  -- 9. no invoice exists for the load
  if exists (select 1 from public.invoices i where i.load_id = c_load) then
    raise exception 'REPAIR_LD100024: an invoice already exists for load % -- STOP, do not touch billed loads.', c_load;
  end if;

  -- 10. no conflicting active dispatch (this dispatch's driver/truck/trailer
  --     are not held by any OTHER active dispatch)
  select count(*) into v_conflict_n
  from public.dispatches d2
  where d2.id <> c_disp
    and d2.status::text = any(c_active)
    and ( d2.driver_id = v_d_driver
       or d2.truck_id  = v_d_truck
       or (v_d_trailer is not null and d2.trailer_id = v_d_trailer) );
  if v_conflict_n <> 0 then
    raise exception 'REPAIR_LD100024: % other active dispatch(es) share this dispatch''s driver/truck/trailer. STOP.', v_conflict_n;
  end if;

  -- 11. migration 0129 functions present and wired
  if to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null
     or to_regprocedure('public.cancel_dispatch(uuid,text)') is null
     or to_regprocedure('public._generate_invoice_number_internal(uuid)') is null then
    raise exception 'REPAIR_LD100024: a migration 0129 function is missing -- this is not the verified 0129 environment. STOP.';
  end if;
  v_inv := lower(regexp_replace(pg_get_functiondef(
             'public.auto_generate_invoice_from_delivered_load()'::regprocedure), '\s+', ' ', 'g'));
  v_gin_i := lower(regexp_replace(pg_get_functiondef(
               'public.generate_invoice_number(uuid)'::regprocedure), '\s+', ' ', 'g'));
  if v_inv not like '%public._generate_invoice_number_internal(new.organization_id)%'
     or v_gin_i not like '%public._generate_invoice_number_internal(p_organization_id)%' then
    raise exception 'REPAIR_LD100024: 0129 invoice-number split is not in place -- not the verified environment. STOP.';
  end if;

  raise notice 'REPAIR_LD100024 PHASE 1 passed: load % (%), org Kali Freights %, dispatch % assigned, driver Ahmed + truck T-112, 1 active dispatch, no invoice, no conflicts, 0129 live.',
    c_load, v_lnum, c_org, c_disp;
end
$repair$;

-- ======================= PHASE 2 -- THE SCOPED WRITE =======================
do $repair$
declare
  v_n integer;
begin
  update public.loads
     set status = 'dispatched'
   where id = '463891ec-88fb-4a48-a010-6e2789f62faa'
     and status = 'booked'
     and financial_dispatch_id = 'ff50462b-735b-48ae-ac83-d43886b605b8';

  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'REPAIR_LD100024 PHASE 2: expected exactly 1 row updated, got % -- state drifted since PHASE 1. Transaction ABORTED, nothing committed.', v_n;
  end if;

  raise notice 'REPAIR_LD100024 PHASE 2: public.loads.status booked -> dispatched (1 row). loads.updated_at bumped by set_updated_at (standard).';
end
$repair$;

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $repair$
declare
  c_load   constant uuid   := '463891ec-88fb-4a48-a010-6e2789f62faa';
  c_disp   constant uuid   := 'ff50462b-735b-48ae-ac83-d43886b605b8';
  c_active constant text[] := array['assigned','accepted','en_route_to_pickup',
                                    'at_pickup','loaded','en_route_to_delivery','at_delivery'];
  v_status   text;
  v_fdi      uuid;
  v_d_status text;
  v_active_n integer;
begin
  select l.status::text, l.financial_dispatch_id into v_status, v_fdi
  from public.loads l where l.id = c_load;

  if v_status is distinct from 'dispatched' then
    raise exception 'REPAIR_LD100024 POST: loads.status is % (expected dispatched).', v_status;
  end if;
  if v_fdi is distinct from c_disp then
    raise exception 'REPAIR_LD100024 POST: loads.financial_dispatch_id is % (must remain %).', coalesce(v_fdi::text,'<null>'), c_disp;
  end if;

  select d.status::text into v_d_status from public.dispatches d where d.id = c_disp;
  if v_d_status is distinct from 'assigned' then
    raise exception 'REPAIR_LD100024 POST: dispatch % status is % (must remain assigned -- this script must not have touched it).', c_disp, v_d_status;
  end if;

  select count(*) into v_active_n
  from public.dispatches d
  where d.load_id = c_load and d.status::text = any(c_active);
  if v_active_n <> 1 then
    raise exception 'REPAIR_LD100024 POST: active dispatch count for the load is % (expected exactly 1).', v_active_n;
  end if;

  if exists (select 1 from public.invoices i where i.load_id = c_load) then
    raise exception 'REPAIR_LD100024 POST: an invoice now exists for load % -- the auto-invoice trigger fired unexpectedly. INVESTIGATE (emergency rollback is in this file''s header).', c_load;
  end if;

  raise notice 'REPAIR_LD100024 COMPLETE: load % is now dispatched; dispatch % still assigned; financial_dispatch_id unchanged; NO invoice created; exactly 1 active dispatch. Exactly 1 row changed (public.loads).', c_load, c_disp;
end
$repair$;

commit;

-- Reached only if PHASE 1, PHASE 2, and PHASE 3 all succeeded. Any exception
-- above aborts the transaction before COMMIT -- nothing is written.
