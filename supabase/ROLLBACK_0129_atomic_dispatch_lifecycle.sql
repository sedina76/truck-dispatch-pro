-- ############################################################################
-- ##                                                                        ##
-- ##   MANUAL EMERGENCY ROLLBACK  --  NEVER RUN AUTOMATICALLY.               ##
-- ##                                                                        ##
-- ##   This file is NOT a migration. It lives OUTSIDE supabase/migrations/   ##
-- ##   so `supabase db push` / any migration runner will NOT discover or    ##
-- ##   execute it. Apply it by hand, once, ONLY after a human decision to   ##
-- ##   roll back migration 0129_atomic_dispatch_lifecycle.sql.              ##
-- ##                                                                        ##
-- ############################################################################
--
-- WHAT IT DOES (exactly the inverse of 0129, DDL only, ZERO row DML):
--   1. CREATE OR REPLACE public.auto_generate_invoice_from_delivered_load()
--      with the EXACT LIVE migration-0068 body
--      (0068_financial_function_cutover.sql) -- restores the pre-0129
--      dispatch-selection statement `select id ... from public.dispatches
--      where load_id = NEW.id limit 1` AND the call to the role-guarded
--      public.generate_invoice_number(NEW.organization_id). Amount stays
--      sourced from public.load_financials.rate, terms from
--      broker_financials / customer_financials -- byte-identical to 0068.
--      (NOT the older 0028 `NEW.rate` body -- loads.rate was removed by
--      0069, so a 0028-shaped body would raise "column loads.rate does not
--      exist" on the next delivery.)
--   2. CREATE OR REPLACE public.generate_invoice_number(uuid) with the EXACT
--      migration-0065 body (0065_billing_readiness.sql) -- owner/admin/
--      accountant guard + the inline atomic counter upsert, WITHOUT 0129's
--      tenant-ownership check and WITHOUT the helper delegation. Re-issues
--      `grant execute ... to authenticated` exactly as 0065 did.
--   3. DROP FUNCTION public._generate_invoice_number_internal(uuid)
--      (plain, NOT cascade -- restored in steps 1-2 nothing calls it).
--   4. DROP FUNCTION public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)
--   5. DROP FUNCTION public.cancel_dispatch(uuid,text)
--
-- WHAT IT DOES NOT DO:
--   * ZERO INSERT/UPDATE/DELETE against any table. No customer/business row
--     is read-modified. 0129 wrote no rows, so there is nothing to unwind.
--   * does NOT touch the 0054 partial unique indexes, guard_dispatch_org
--     (0055), the 0125 proceeds/financial-controller objects, the
--     auto_generate_invoice_on_delivery TRIGGER binding, RLS, or any
--     migration file 0125-0129 on disk.
--   * does NOT touch invoice_number_counters rows -- any numbers already
--     minted (by either the trigger or the manual path) stay minted.
--
-- ORDERING -- do this FIRST, before running this script:
--   Set  DISPATCH_WRITES_DISABLED=1  in the app environment and redeploy
--   (same commit). That makes createDispatch / cancelDispatch fail closed
--   with a maintenance message and stop calling the RPCs. Only then is it
--   safe to DROP them here. (This script cannot verify the app state; the
--   DROP FUNCTION calls are plain -- NOT `... CASCADE` -- so any unexpected
--   DATABASE dependent would abort the whole transaction, fail-closed.)
--
-- Explicit BEGIN ... COMMIT: any exception (a precondition RAISE, a DROP
-- that hits a dependent, a postcondition RAISE) aborts the transaction
-- before COMMIT and rolls back everything.
-- ============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS =================
do $rb$
declare
  v_inv text;
  v_gin text;
begin
  -- 0129 IS currently applied (otherwise there is nothing to roll back)
  if to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null
     or to_regprocedure('public.cancel_dispatch(uuid,text)') is null then
    raise exception 'ROLLBACK_0129 precondition: create_dispatch / cancel_dispatch are not present -- 0129 is not applied. Nothing to roll back. STOP.';
  end if;
  if to_regprocedure('public._generate_invoice_number_internal(uuid)') is null then
    raise exception 'ROLLBACK_0129 precondition: public._generate_invoice_number_internal(uuid) is not present -- 0129 is not applied (or the invoice-number split was already rolled back). STOP and inspect.';
  end if;

  v_inv := lower(regexp_replace(pg_get_functiondef(
             'public.auto_generate_invoice_from_delivered_load()'::regprocedure), '\s+', ' ', 'g'));
  if v_inv not like '%new.financial_dispatch_id%' then
    raise exception 'ROLLBACK_0129 precondition: auto_generate_invoice_from_delivered_load() does not carry the 0129 selection (references no financial_dispatch_id) -- 0129 was not applied, or was already rolled back. STOP.';
  end if;
  if v_inv not like '%_generate_invoice_number_internal(new.organization_id)%' then
    raise exception 'ROLLBACK_0129 precondition: auto_generate_invoice_from_delivered_load() does not mint via _generate_invoice_number_internal -- unexpected state. STOP and inspect.';
  end if;

  v_gin := lower(regexp_replace(pg_get_functiondef(
             'public.generate_invoice_number(uuid)'::regprocedure), '\s+', ' ', 'g'));
  if v_gin not like '%_generate_invoice_number_internal(p_organization_id)%' then
    raise exception 'ROLLBACK_0129 precondition: public.generate_invoice_number(uuid) does not delegate to the helper -- 0129 was not applied, or was already rolled back. STOP.';
  end if;

  -- the auto-invoice TRIGGER must still be bound (we only replace the body)
  if not exists (select 1 from pg_trigger where tgrelid='public.loads'::regclass
                   and tgname='auto_generate_invoice_on_delivery' and not tgisinternal) then
    raise exception 'ROLLBACK_0129 precondition: trigger auto_generate_invoice_on_delivery is missing. STOP -- inspect before rolling back.';
  end if;

  -- objects that MUST survive the rollback untouched. The rollback does not
  -- touch the 0054 indexes at all; this asserts all three are still present
  -- AND still real guarantees (UNIQUE + partial). Deep, rendering-
  -- independent predicate validation lives in VERIFY_ROLLBACK_0129.sql
  -- (same semantic rule as migration 0129 PHASE 1).
  if (select count(*) from pg_class ic join pg_index i on i.indexrelid = ic.oid
      where ic.relkind='i' and ic.relnamespace='public'::regnamespace
        and ic.relname in ('dispatches_active_driver_unique','dispatches_active_truck_unique','dispatches_active_trailer_unique')
        and i.indisunique and i.indpred is not null) <> 3
     or not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_guard_org' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal) then
    raise exception 'ROLLBACK_0129 precondition: a protected object (0054 unique partial index / guard_dispatch_org / 0125 controller trigger) is already missing or altered. STOP.';
  end if;

  -- no DATABASE object depends on the functions we are about to DROP
  -- (rules, triggers, defaults, constraints, other routines). App-code
  -- `supabase.rpc(...)` calls are NOT database dependencies -- neutralise
  -- those via DISPATCH_WRITES_DISABLED first, per the header. plpgsql
  -- function-to-function calls also create no pg_depend row, so the helper
  -- is safe to drop after steps 1-2 restore its two callers.
  if exists (
    select 1
    from pg_depend d
    join pg_proc p on p.oid = d.refobjid
    where p.oid in (
            'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure,
            'public.cancel_dispatch(uuid,text)'::regprocedure,
            'public._generate_invoice_number_internal(uuid)'::regprocedure)
      and d.deptype <> 'i'                      -- ignore the internal self-dependency
      and d.classid <> 'pg_proc'::regclass      -- ignore the function's own rows
  ) then
    raise exception 'ROLLBACK_0129 precondition: a database object depends on create_dispatch / cancel_dispatch / _generate_invoice_number_internal -- a plain DROP would fail. Inspect pg_depend before proceeding. STOP.';
  end if;

  raise notice 'ROLLBACK_0129 PHASE 1 preconditions passed.';
end
$rb$;

-- ======================= PHASE 2 -- RESTORE / DROP (DDL only) ===============

-- 1. Restore auto_generate_invoice_from_delivered_load() to the EXACT LIVE
--    migration-0068 body (verbatim from 0068_financial_function_cutover.sql,
--    lines 480-555) -- reinstates `select id ... limit 1` and the
--    role-guarded public.generate_invoice_number() call.
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

  select id into v_dispatch_id from public.dispatches where load_id = NEW.id limit 1;
  select rate into v_rate from public.load_financials where load_id = NEW.id;
  v_rate := coalesce(v_rate, 0);
  v_invoice_number := public.generate_invoice_number(NEW.organization_id);

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

-- 2. Restore public.generate_invoice_number(uuid) to the EXACT migration-0065
--    body (verbatim from 0065_billing_readiness.sql, lines 143-167) -- the
--    owner/admin/accountant guard + inline atomic counter upsert, with NO
--    0129 tenant-ownership check and NO helper delegation.
create or replace function public.generate_invoice_number(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year integer := extract(year from current_date)::integer;
  v_number integer;
begin
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    raise exception 'Only owner, admin, or accountant roles can generate invoice numbers.';
  end if;

  insert into public.invoice_number_counters (organization_id, year, last_number)
  values (p_organization_id, v_year, 1)
  on conflict (organization_id, year)
  do update set last_number = invoice_number_counters.last_number + 1, updated_at = now()
  returning last_number into v_number;

  return 'INV-' || v_year || '-' || lpad(v_number::text, 5, '0');
end;
$$;

grant execute on function public.generate_invoice_number(uuid) to authenticated;

-- 3. Drop the private mechanism (plain; both callers restored above).
drop function public._generate_invoice_number_internal(uuid);

-- 4 & 5. Drop the two 0129 dispatch functions (exact signatures; NOT cascade).
drop function public.create_dispatch(uuid, uuid, uuid, uuid, uuid, numeric, text);
drop function public.cancel_dispatch(uuid, text);

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $rb$
declare
  v_inv text;
  v_gin text;
begin
  if to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is not null then
    raise exception 'ROLLBACK_0129 postcondition: create_dispatch still exists.';
  end if;
  if to_regprocedure('public.cancel_dispatch(uuid,text)') is not null then
    raise exception 'ROLLBACK_0129 postcondition: cancel_dispatch still exists.';
  end if;
  if to_regprocedure('public._generate_invoice_number_internal(uuid)') is not null then
    raise exception 'ROLLBACK_0129 postcondition: _generate_invoice_number_internal still exists.';
  end if;

  -- auto-invoice restored to the EXACT 0068 shape
  v_inv := lower(regexp_replace(pg_get_functiondef(
             'public.auto_generate_invoice_from_delivered_load()'::regprocedure), '\s+', ' ', 'g'));
  if v_inv not like '%select id into v_dispatch_id from public.dispatches where load_id = new.id limit 1%' then
    raise exception 'ROLLBACK_0129 postcondition: the 0068 `select id ... limit 1` dispatch selection was not restored.';
  end if;
  if v_inv like '%financial_dispatch_id%' then
    raise exception 'ROLLBACK_0129 postcondition: auto_generate_invoice_from_delivered_load() still references financial_dispatch_id.';
  end if;
  if v_inv like '%_generate_invoice_number_internal%' then
    raise exception 'ROLLBACK_0129 postcondition: auto_generate_invoice_from_delivered_load() still mints via the (now-dropped) internal helper.';
  end if;
  if v_inv not like '%public.generate_invoice_number(new.organization_id)%' then
    raise exception 'ROLLBACK_0129 postcondition: auto_generate_invoice_from_delivered_load() does not call the role-guarded public.generate_invoice_number() again.';
  end if;
  if v_inv like '%new.rate%' then
    raise exception 'ROLLBACK_0129 postcondition: auto_generate_invoice_from_delivered_load() references NEW.rate -- 0068 reads load_financials (0069 removed loads.rate).';
  end if;
  if v_inv not like '%from public.load_financials where load_id = new.id%'
     or v_inv not like '%public.broker_financials%'
     or v_inv not like '%on conflict (load_id)%' then
    raise exception 'ROLLBACK_0129 postcondition: a 0068 invariant (load_financials rate / broker_financials / on conflict (load_id)) is missing after restore.';
  end if;
  if not exists (select 1 from pg_proc p where p.oid='public.auto_generate_invoice_from_delivered_load()'::regprocedure and p.prosecdef) then
    raise exception 'ROLLBACK_0129 postcondition: auto_generate_invoice_from_delivered_load() is no longer SECURITY DEFINER.';
  end if;

  -- generate_invoice_number restored to the EXACT 0065 shape
  v_gin := lower(regexp_replace(pg_get_functiondef(
             'public.generate_invoice_number(uuid)'::regprocedure), '\s+', ' ', 'g'));
  if v_gin not like '%has_role(array[''owner'', ''admin'', ''accountant'']::public.org_role[])%' then
    raise exception 'ROLLBACK_0129 postcondition: public.generate_invoice_number lost its owner/admin/accountant guard.';
  end if;
  if v_gin not like '%insert into public.invoice_number_counters%' then
    raise exception 'ROLLBACK_0129 postcondition: public.generate_invoice_number did not get its inline counter upsert back.';
  end if;
  if v_gin like '%_generate_invoice_number_internal%' or v_gin like '%current_org_id%' then
    raise exception 'ROLLBACK_0129 postcondition: public.generate_invoice_number still carries a 0129 addition (helper delegation / tenant check).';
  end if;
  if not exists (select 1 from pg_proc p where p.oid='public.generate_invoice_number(uuid)'::regprocedure and p.prosecdef) then
    raise exception 'ROLLBACK_0129 postcondition: public.generate_invoice_number is no longer SECURITY DEFINER.';
  end if;
  if not has_function_privilege('authenticated', 'public.generate_invoice_number(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'ROLLBACK_0129 postcondition: authenticated lost EXECUTE on public.generate_invoice_number.';
  end if;

  -- protected objects survived (0054: all three still present AND still
  -- UNIQUE + partial; deep predicate validation is in VERIFY_ROLLBACK_0129.sql)
  if (select count(*) from pg_class ic join pg_index i on i.indexrelid = ic.oid
      where ic.relkind='i' and ic.relnamespace='public'::regnamespace
        and ic.relname in ('dispatches_active_driver_unique','dispatches_active_truck_unique','dispatches_active_trailer_unique')
        and i.indisunique and i.indpred is not null) <> 3
     or not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_guard_org' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid='public.loads'::regclass and tgname='auto_generate_invoice_on_delivery' and not tgisinternal) then
    raise exception 'ROLLBACK_0129 postcondition: a protected object (0054 unique partial index / guard_dispatch_org / 0125 controller / auto-invoice trigger) is missing after rollback.';
  end if;

  raise notice 'ROLLBACK_0129 complete: create_dispatch / cancel_dispatch / _generate_invoice_number_internal dropped; auto_generate_invoice_from_delivered_load() restored to the EXACT 0068 body; public.generate_invoice_number(uuid) restored to the EXACT 0065 body (guard + inline counter upsert). ZERO rows written. 0054 indexes, guard_dispatch_org, 0125 controller trigger, and the auto-invoice trigger all intact. NOTE: revert the app (or keep DISPATCH_WRITES_DISABLED=1) so nothing calls the now-absent RPCs.';
end
$rb$;

commit;
