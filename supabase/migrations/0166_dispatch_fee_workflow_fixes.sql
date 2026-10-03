-- ============================================================================
-- 0166_dispatch_fee_workflow_fixes.sql
--
-- Workflow review of Dispatch Fee Invoices (0165) against the rest of the
-- TMS found these gaps; each is fixed here:
--
--   A. A load marked Delivered on the LOAD page left its dispatch at its old
--      status ("assigned"), so the dispatch fee never reached a Dispatch Fee
--      Invoice, the board kept showing it as active, and pay periods used
--      the dispatch date. (Board/driver delivery already updated the load;
--      the reverse direction was missing.) Now the load's live dispatch is
--      marked delivered at that moment, exactly as the board does it.
--   B. Correcting a load's rate after dispatch never reached the dispatch
--      fee (dispatch_financials kept the rate from dispatch time): 7500 ->
--      8000 still billed 10% of 7500. Now the fee follows the load rate.
--   C. A DRAFT Dispatch Fee Invoice follows that change too (like customer
--      draft invoices, 0164); a fee that drops to zero leaves the draft.
--      Sent invoices are never changed -- the screen flags the difference.
--   D. A load could be billed twice: once on a carrier settlement (the
--      dispatch company received the freight and kept its fee) and again on
--      a Dispatch Fee Invoice -- and the other way round. Each load now goes
--      on only one of the two. Loads already billed through the older
--      dispatch-service invoice ledger (0145) and cancelled loads are
--      excluded too. Loads delivered via the load page (status delivered,
--      POD received, invoiced, closed) count even if their dispatch was
--      never moved.
--
-- One transaction; safe to re-run. Nothing already billed is changed.
-- ============================================================================

begin;

-- get_payable_carrier_loads must be exactly 0163's version (or this one).
do $pre$
declare v text;
begin
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v
  from pg_proc where oid = to_regprocedure('public.get_payable_carrier_loads(uuid,date,date)');
  if v is null then raise exception '0166 precondition: get_payable_carrier_loads is missing. STOP -- nothing changed.'; end if;
  if v not in ('3adaf51180076e2c4113c131cab166ae', 'c44df229660ca80485ec482616d812a8') then
    raise exception '0166 precondition: get_payable_carrier_loads is not the expected version (md5 %). STOP -- nothing changed.', v;
  end if;
  if to_regclass('public.carrier_fee_invoice_lines') is null then
    raise exception '0166 precondition: run 0165 first. STOP -- nothing changed.';
  end if;
end $pre$;

-- ---- A. load delivered on the load page -> its live dispatch is delivered ----
create or replace function public.sync_dispatch_from_delivered_load()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.status::text in ('delivered', 'pod_received', 'invoiced', 'closed')
     and old.status::text not in ('delivered', 'pod_received', 'invoiced', 'closed', 'cancelled') then
    update public.dispatches
       set status = 'delivered', delivered_at = coalesce(delivered_at, now())
     where load_id = new.id and organization_id = new.organization_id
       and status not in ('delivered', 'completed', 'cancelled');
  end if;
  return null;
end $$;
revoke all on function public.sync_dispatch_from_delivered_load() from public, anon, authenticated;
drop trigger if exists loads_sync_dispatch_delivered on public.loads;
create trigger loads_sync_dispatch_delivered after update of status on public.loads
  for each row execute function public.sync_dispatch_from_delivered_load();

-- ---- B. load rate change -> dispatch fee follows --------------------------------
create or replace function public.sync_dispatch_fee_from_load_rate()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.rate is not null and new.rate > 0 and (tg_op = 'INSERT' or new.rate is distinct from old.rate) then
    update public.dispatch_financials df
       set load_rate = new.rate, updated_at = now()
      from public.dispatches d
     where d.id = df.dispatch_id and d.load_id = new.load_id and d.status <> 'cancelled'
       and df.load_rate is distinct from new.rate;
  end if;
  return null;
end $$;
revoke all on function public.sync_dispatch_fee_from_load_rate() from public, anon, authenticated;
drop trigger if exists load_financials_sync_dispatch_fee on public.load_financials;
create trigger load_financials_sync_dispatch_fee after insert or update of rate on public.load_financials
  for each row execute function public.sync_dispatch_fee_from_load_rate();

-- ---- C. draft Dispatch Fee Invoices follow the fee --------------------------------
create or replace function public._carrier_fee_line_description(p_load_number text, p_pct numeric, p_rate numeric)
returns text language sql immutable set search_path = pg_catalog as $$
  select 'Dispatch fee -- Load ' || p_load_number || ' (' || trim(to_char(p_pct, 'FM990.###')) || '% of ' || to_char(p_rate, 'FM$999,999,990.00') || ')';
$$;

-- identity of a line never changes; on a DRAFT the dispatch fee amount may
create or replace function public.guard_carrier_fee_invoice_line()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare v_status text; v_org uuid;
begin
  select status, organization_id into v_status, v_org from public.carrier_fee_invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if tg_op = 'INSERT' and (v_status is distinct from 'draft' or v_org is distinct from new.organization_id) then
    raise exception 'Lines can only be added to a draft invoice of the same organization.';
  end if;
  if tg_op = 'DELETE' and v_status is distinct from 'draft' then
    raise exception 'Lines can only be removed from a draft invoice.';
  end if;
  if tg_op = 'UPDATE' then
    if (new.line_type, new.invoice_id, new.dispatch_id, new.dispatch_advance_id, new.linked_fuel_log_id, new.linked_maintenance_id)
       is distinct from (old.line_type, old.invoice_id, old.dispatch_id, old.dispatch_advance_id, old.linked_fuel_log_id, old.linked_maintenance_id)
    or ((new.amount, new.load_rate, new.fee_percentage) is distinct from (old.amount, old.load_rate, old.fee_percentage)
        and (v_status is distinct from 'draft' or new.line_type <> 'dispatch_fee')) then
      raise exception 'Invoice lines cannot be changed; void and re-create the invoice instead.';
    end if;
  end if;
  return coalesce(new, old);
end $$;

create or replace function public.sync_draft_fee_invoice_from_dispatch_fee()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if (new.dispatch_fee_amount, new.load_rate, new.dispatch_fee_percentage)
     is not distinct from (old.dispatch_fee_amount, old.load_rate, old.dispatch_fee_percentage) then
    return null;
  end if;
  if new.dispatch_fee_amount > 0 then
    update public.carrier_fee_invoice_lines x
       set amount = new.dispatch_fee_amount, load_rate = new.load_rate, fee_percentage = new.dispatch_fee_percentage,
           description = public._carrier_fee_line_description(x.load_number, new.dispatch_fee_percentage, new.load_rate)
      from public.carrier_fee_invoices i
     where i.id = x.invoice_id and i.status = 'draft'
       and x.dispatch_id = new.dispatch_id and x.line_type = 'dispatch_fee' and not x.voided
       and x.amount is distinct from new.dispatch_fee_amount;
  else
    delete from public.carrier_fee_invoice_lines x
     using public.carrier_fee_invoices i
     where i.id = x.invoice_id and i.status = 'draft'
       and x.dispatch_id = new.dispatch_id and x.line_type = 'dispatch_fee' and not x.voided;
  end if;
  return null;
end $$;
revoke all on function public.sync_draft_fee_invoice_from_dispatch_fee() from public, anon, authenticated;
drop trigger if exists dispatch_financials_sync_draft_fee_invoice on public.dispatch_financials;
create trigger dispatch_financials_sync_draft_fee_invoice after update on public.dispatch_financials
  for each row execute function public.sync_draft_fee_invoice_from_dispatch_fee();

-- ---- D. which loads are billable, and never on both settlement and invoice ----
create or replace function public._carrier_fee_invoice_candidates(p_org uuid, p_carrier_id uuid, p_period_start date, p_period_end date)
returns table (line_type text, description text, amount numeric, service_date date, load_id uuid, dispatch_id uuid, load_number text,
               load_rate numeric, fee_percentage numeric, dispatch_advance_id uuid, linked_fuel_log_id uuid, linked_maintenance_id uuid, sort_key text)
language sql stable security definer set search_path = pg_catalog, public as $$
  -- dispatch fees: loads delivered in the period, not yet billed anywhere
  select 'dispatch_fee', public._carrier_fee_line_description(l.load_number, df.dispatch_fee_percentage, df.load_rate),
         df.dispatch_fee_amount, coalesce(d.completed_at, d.delivered_at, d.dispatched_at)::date, d.load_id, d.id, l.load_number,
         df.load_rate, df.dispatch_fee_percentage, null::uuid, null::uuid, null::uuid,
         '1|' || to_char(coalesce(d.completed_at, d.delivered_at, d.dispatched_at), 'YYYYMMDDHH24MISS') || l.load_number
  from public.dispatches d
  join public.loads l on l.id = d.load_id
  join public.dispatch_financials df on df.dispatch_id = d.id
  where d.organization_id = p_org and d.carrier_id = p_carrier_id
    and d.status <> 'cancelled' and l.status <> 'cancelled'
    and (d.status in ('delivered', 'completed') or l.status::text in ('delivered', 'pod_received', 'invoiced', 'closed'))
    and coalesce(d.completed_at, d.delivered_at, d.dispatched_at)::date between p_period_start and p_period_end
    and df.dispatch_fee_amount > 0
    and not exists (select 1 from public.carrier_fee_invoice_lines x where x.dispatch_id = d.id and x.line_type = 'dispatch_fee' and not x.voided)
    and not exists (select 1 from public.carrier_fee_invoice_lines x where x.load_id = d.load_id and x.line_type = 'dispatch_fee' and not x.voided)
    and not exists (select 1 from public.settlement_line_items sli join public.settlements s on s.id = sli.settlement_id
                     where sli.item_type = 'load_pay' and sli.load_id = d.load_id and s.status <> 'void')
    and not exists (select 1 from public.carrier_dispatch_service_billing_lines b where b.load_id = d.load_id)
  union all
  -- advances paid for the carrier, still pending, up to the period end
  select 'advance', initcap(replace(a.expense_type::text, '_', ' ')) || ' advance' || coalesce(' -- Load ' || l.load_number, '') || coalesce(': ' || a.description, ''),
         a.amount, a.paid_date, a.load_id, null, l.load_number, null, null, a.id, null, null,
         '2|' || to_char(a.paid_date, 'YYYYMMDD') || a.id::text
  from public.dispatch_advances a
  left join public.loads l on l.id = a.load_id
  where a.organization_id = p_org and a.carrier_id = p_carrier_id and a.status = 'pending' and a.paid_date <= p_period_end
    and not exists (select 1 from public.carrier_fee_invoice_lines x where x.dispatch_advance_id = a.id and x.line_type = 'advance' and not x.voided)
  union all
  -- fuel paid by the dispatch company, to be recovered from the carrier
  select 'fuel', 'Fuel' || coalesce(' -- ' || f.station_name, '') || coalesce(', ' || f.state, '') || ' (' || to_char(f.purchased_at, 'Mon DD') || ')',
         r.remaining_amount, f.purchased_at::date, null, null, null, null, null, null, f.id, null,
         '3|' || to_char(f.purchased_at, 'YYYYMMDDHH24MISS') || f.id::text
  from public.fuel_logs f
  cross join lateral public.get_fuel_recovery_status(f.id) r
  where f.organization_id = p_org and f.carrier_id = p_carrier_id and f.recovery_type = 'carrier_settlement'
    and f.purchased_at::date <= p_period_end and r.remaining_amount > 0.004
  union all
  -- repairs/maintenance paid by the dispatch company, to be recovered from the carrier
  select 'maintenance', coalesce(nullif(m.service_type, ''), 'Repair') || coalesce(' -- ' || m.vendor_name, '') || ' (' || to_char(m.service_date, 'Mon DD') || ')',
         r.remaining_amount, m.service_date, null, null, null, null, null, null, null, m.id,
         '4|' || to_char(m.service_date, 'YYYYMMDD') || m.id::text
  from public.maintenance_records m
  cross join lateral public.get_maintenance_recovery_status(m.id) r
  where m.organization_id = p_org and m.carrier_id = p_carrier_id and m.recovery_type = 'carrier_settlement'
    and m.service_date <= p_period_end and r.remaining_amount > 0.004;
$$;
revoke all on function public._carrier_fee_invoice_candidates(uuid, uuid, date, date) from public, anon, authenticated, service_role;

-- carrier settlements: 0163's body + "not already on a Dispatch Fee Invoice"
CREATE OR REPLACE FUNCTION public.get_payable_carrier_loads(p_carrier_id uuid, p_period_start date, p_period_end date)
 RETURNS TABLE(load_id uuid, dispatch_id uuid, load_number text, pickup_city text, pickup_state text, delivery_city text, delivery_state text, delivery_date date, miles numeric, customer_revenue numeric, carrier_rate numeric, gross_margin numeric, margin_percent numeric, driver_name text, truck_unit text)
 LANGUAGE sql
 STABLE
AS $function$
  with candidates as (
    select disp.id as dispatch_id, l.id as load_id
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.carrier_id = p_carrier_id
      and l.status in ('delivered', 'pod_received')
      and coalesce(disp.completed_at, disp.delivered_at, disp.dispatched_at)::date between p_period_start and p_period_end
      and not exists (
        select 1 from public.settlement_line_items sli
        join public.settlements s on s.id = sli.settlement_id
        where sli.item_type = 'load_pay' and sli.load_id = l.id and s.status <> 'void'
      )
      and not exists (
        select 1 from public.carrier_fee_invoice_lines x
        where x.line_type = 'dispatch_fee' and x.load_id = l.id and not x.voided
      )
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as pickup_city,
           max(state) filter (where stop_type = 'pickup') as pickup_state,
           max(city) filter (where stop_type = 'delivery') as delivery_city,
           max(state) filter (where stop_type = 'delivery') as delivery_state
    from public.load_stops
    where load_id in (select load_id from candidates)
    group by load_id
  )
  select
    c.load_id, c.dispatch_id, p.load_number, s.pickup_city, s.pickup_state, s.delivery_city, s.delivery_state,
    p.delivery_date, p.miles, p.customer_revenue, p.carrier_rate, p.gross_margin, p.margin_percent, p.driver_name, p.truck_unit
  from candidates c
  left join stops s on s.load_id = c.load_id
  cross join lateral public.calculate_carrier_load_settlement(p_carrier_id, c.load_id) p
  order by p.delivery_date asc nulls last;
$function$;

-- a load billed on a Dispatch Fee Invoice cannot be added to a carrier settlement by hand either
create or replace function public.guard_settlement_load_not_fee_invoiced()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.item_type = 'load_pay' and new.load_id is not null and exists (
       select 1 from public.carrier_fee_invoice_lines x where x.line_type = 'dispatch_fee' and x.load_id = new.load_id and not x.voided) then
    raise exception 'This load is already billed to the carrier on a Dispatch Fee Invoice (the broker pays the carrier), so it cannot also go on a carrier settlement.';
  end if;
  return new;
end $$;
revoke all on function public.guard_settlement_load_not_fee_invoiced() from public, anon, authenticated;
drop trigger if exists settlement_line_items_guard_fee_invoiced on public.settlement_line_items;
create trigger settlement_line_items_guard_fee_invoiced before insert or update of item_type, load_id on public.settlement_line_items
  for each row execute function public.guard_settlement_load_not_fee_invoiced();

-- ---- postconditions --------------------------------------------------------------
do $post$
begin
  if (select count(*) from pg_trigger where not tgisinternal and tgname in
      ('loads_sync_dispatch_delivered', 'load_financials_sync_dispatch_fee', 'dispatch_financials_sync_draft_fee_invoice', 'settlement_line_items_guard_fee_invoiced')) <> 4 then
    raise exception '0166 postcondition: triggers missing.';
  end if;
  if has_function_privilege('authenticated', 'public._carrier_fee_invoice_candidates(uuid,uuid,date,date)', 'execute')
     or has_function_privilege('anon', 'public.sync_dispatch_from_delivered_load()', 'execute') then
    raise exception '0166 postcondition: function privileges wrong.';
  end if;
end $post$;

commit;
