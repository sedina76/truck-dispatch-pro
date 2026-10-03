-- ============================================================================
-- 0167_broker_pays_carrier_setting.sql
--
-- Owner decision (2026-10-02): who the broker pays is set PER CARRIER.
--   * "Broker pays the carrier"  (proceeds model carrier_paid_directly):
--     no invoice to the broker; the dispatch fee is billed to the carrier on
--     a Dispatch Fee Invoice; the load is not paid out on a carrier
--     settlement.
--   * "Broker pays us"           (dispatcher_receives_funds, the default):
--     invoice the broker (auto draft on delivery), pay the carrier on a
--     carrier settlement; no dispatch fee invoice for the load.
--
-- 0125 already built the foundation, switched off: carriers.load_proceeds_model
-- (the carrier's setting), dispatches.proceeds_model (stamped from it when the
-- dispatch is created, so each load keeps the arrangement it was dispatched
-- under) and a platform switch (model_a_enabled = false). This migration:
--   A. switches the option on;
--   B. set_carrier_broker_pays(carrier, model): owner/admin only; saves the
--      setting and moves the carrier's OPEN loads to it -- loads not yet on a
--      carrier settlement or a Dispatch Fee Invoice, and not invoiced to the
--      broker beyond an untouched auto-created draft (no payments, never
--      sent; that draft is removed). Returns what it changed and kept;
--   C. the carrier setting can only change through B (owner/admin);
--   D. broker invoices: none auto-created, and none can be created by hand,
--      for a load whose dispatch is "broker pays the carrier"; such loads are
--      not listed in Ready to Bill;
--   E. Dispatch Fee Invoices bill the fee only for "broker pays the carrier"
--      loads; carrier settlements only pay out the other loads.
-- One transaction; safe to re-run.
-- ============================================================================

begin;

do $pre$
declare v text;
begin
  if to_regprocedure('public.sync_dispatch_from_delivered_load()') is null then
    raise exception '0167 precondition: run 0166 first. STOP -- nothing changed.';
  end if;
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v
  from pg_proc where oid = to_regprocedure('public.get_payable_carrier_loads(uuid,date,date)');
  if v not in ('c44df229660ca80485ec482616d812a8', 'e020b2167d2ef696406608915188bc2f') then
    raise exception '0167 precondition: get_payable_carrier_loads is not the expected version (md5 %). STOP -- nothing changed.', v;
  end if;
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v
  from pg_proc where oid = to_regprocedure('public.get_ready_to_bill_loads()');
  if v not in ('10b0740419bb14518c805b4a3d0c0715', '6b6751b5fc3b4004b0526b89b9af553b') then
    raise exception '0167 precondition: get_ready_to_bill_loads is not the expected version (md5 %). STOP -- nothing changed.', v;
  end if;
end $pre$;

-- ---- A. switch the option on ------------------------------------------------------
update public.platform_settings set model_a_enabled = true, updated_at = now() where id = true and not model_a_enabled;

-- ---- which arrangement a load is under -----------------------------------------------
-- the load's controlling dispatch (as the auto-invoice picks it), else its
-- newest live dispatch; null when it has no live dispatch ("broker pays us")
create or replace function public.load_proceeds_model(p_load_id uuid)
returns public.proceeds_model language sql stable security definer set search_path = pg_catalog, public as $$
  select d.proceeds_model
  from public.dispatches d
  join public.loads l on l.id = d.load_id
  where d.load_id = p_load_id and d.status <> 'cancelled'
  order by (d.id = l.financial_dispatch_id) desc, d.dispatched_at desc nulls last, d.created_at desc, d.id desc
  limit 1;
$$;
revoke all on function public.load_proceeds_model(uuid) from public, anon;
grant execute on function public.load_proceeds_model(uuid) to authenticated;

create or replace function public.load_bills_broker(p_load_id uuid)
returns boolean language sql stable security definer set search_path = pg_catalog, public as $$
  select public.load_proceeds_model(p_load_id) is distinct from 'carrier_paid_directly'::public.proceeds_model;
$$;
revoke all on function public.load_bills_broker(uuid) from public, anon;
grant execute on function public.load_bills_broker(uuid) to authenticated;

-- ---- B + C. the carrier setting --------------------------------------------------------
create or replace function public.guard_carrier_broker_pays_change()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.load_proceeds_model is distinct from old.load_proceeds_model
     and coalesce(current_setting('app.carrier_broker_pays_change', true), '') <> 'on' then
    raise exception 'Use the carrier''s "Who does the broker pay?" setting to change this (owner or admin).' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists carriers_guard_broker_pays_change on public.carriers;
create trigger carriers_guard_broker_pays_change before update of load_proceeds_model on public.carriers
  for each row execute function public.guard_carrier_broker_pays_change();

create or replace function public.set_carrier_broker_pays(p_carrier_id uuid, p_model public.proceeds_model)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_org uuid := public.current_org_id();
  v_old public.proceeds_model;
  d record;
  v_inv record;
  v_switched int := 0; v_removed int := 0; v_kept text[] := '{}';
begin
  if auth.uid() is null or v_org is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only an owner or admin can change who the broker pays.' using errcode = '42501';
  end if;
  if p_model is null then raise exception 'Choose who the broker pays.'; end if;
  select load_proceeds_model into v_old from public.carriers where id = p_carrier_id and organization_id = v_org for update;
  if not found then raise exception 'Carrier not found.'; end if;

  perform set_config('app.carrier_broker_pays_change', 'on', true);
  update public.carriers set load_proceeds_model = p_model where id = p_carrier_id;
  perform set_config('app.carrier_broker_pays_change', '', true);

  -- open loads follow the new setting
  for d in
    select x.id, x.load_id, l.load_number
    from public.dispatches x join public.loads l on l.id = x.load_id
    where x.organization_id = v_org and x.carrier_id = p_carrier_id and x.status <> 'cancelled' and l.status <> 'cancelled'
      and x.proceeds_model is distinct from p_model
    order by l.load_number
    for update of x
  loop
    if exists (select 1 from public.settlement_line_items sli join public.settlements s on s.id = sli.settlement_id
                where sli.item_type = 'load_pay' and sli.load_id = d.load_id and s.status <> 'void')
       or exists (select 1 from public.carrier_fee_invoice_lines x where x.line_type = 'dispatch_fee' and x.load_id = d.load_id and not x.voided) then
      v_kept := v_kept || (d.load_number || ' (already settled or fee-invoiced)');
      continue;
    end if;
    select i.id, i.status, i.amount_paid, i.sent_at into v_inv from public.invoices i where i.load_id = d.load_id;
    if v_inv.id is not null then
      if p_model = 'carrier_paid_directly' and v_inv.status = 'draft' and coalesce(v_inv.amount_paid, 0) = 0 and v_inv.sent_at is null
         and not exists (select 1 from public.payments p where p.invoice_id = v_inv.id) then
        begin
          delete from public.invoice_line_items where invoice_id = v_inv.id;
          delete from public.invoices where id = v_inv.id;
          v_removed := v_removed + 1;
          perform public.log_activity('load'::public.entity_type, d.load_id, 'broker_invoice_draft_removed',
            jsonb_build_object('invoice_id', v_inv.id, 'reason', 'broker pays the carrier'), v_org);
        exception when foreign_key_violation then
          v_kept := v_kept || (d.load_number || ' (its broker invoice is in use)');
          continue;
        end;
      elsif p_model = 'carrier_paid_directly' then
        v_kept := v_kept || (d.load_number || ' (already invoiced to the broker)');
        continue;
      end if;
    end if;
    update public.dispatches set proceeds_model = p_model where id = d.id;
    v_switched := v_switched + 1;
  end loop;

  perform public.log_activity('carrier'::public.entity_type, p_carrier_id, 'broker_pays_changed',
    jsonb_build_object('from', v_old, 'to', p_model, 'loads_switched', v_switched, 'broker_drafts_removed', v_removed, 'kept', to_jsonb(v_kept)), v_org);
  return jsonb_build_object('loads_switched', v_switched, 'broker_drafts_removed', v_removed, 'kept', to_jsonb(v_kept));
end $$;
revoke all on function public.set_carrier_broker_pays(uuid, public.proceeds_model) from public, anon;
grant execute on function public.set_carrier_broker_pays(uuid, public.proceeds_model) to authenticated;

-- ---- D. broker invoices --------------------------------------------------------------------
drop trigger if exists auto_generate_invoice_on_delivery on public.loads;
create trigger auto_generate_invoice_on_delivery after update on public.loads
  for each row when (public.load_bills_broker(new.id)) execute function public.auto_generate_invoice_from_delivered_load();

create or replace function public.guard_invoice_load_bills_broker()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.load_id is not null and not public.load_bills_broker(new.load_id) then
    raise exception 'The broker pays the carrier for this load, so it is not invoiced to the broker. Bill the dispatch fee on a Dispatch Fee Invoice instead.';
  end if;
  return new;
end $$;
revoke all on function public.guard_invoice_load_bills_broker() from public, anon, authenticated;
drop trigger if exists invoices_guard_load_bills_broker on public.invoices;
create trigger invoices_guard_load_bills_broker before insert on public.invoices
  for each row execute function public.guard_invoice_load_bills_broker();

-- Ready to Bill: 0069's body + only loads billed to the broker
create or replace function public.get_ready_to_bill_loads()
returns table (
  load_id uuid,
  load_number text,
  status public.load_status,
  customer_id uuid,
  customer_name text,
  broker_id uuid,
  broker_name text,
  origin_city text,
  origin_state text,
  destination_city text,
  destination_state text,
  delivered_at timestamptz,
  rate numeric,
  has_verified_pod boolean,
  has_bol boolean,
  bol_required boolean,
  has_rate_confirmation boolean,
  rate_confirmation_required boolean,
  ready_to_bill boolean
)
language sql
stable
as $$
  with pickup_stop as (
    select distinct on (load_id) load_id, city, state
    from public.load_stops
    where stop_type = 'pickup'
    order by load_id, scheduled_at asc nulls last
  ),
  delivery_stop as (
    select distinct on (load_id) load_id, city, state
    from public.load_stops
    where stop_type = 'delivery'
    order by load_id, scheduled_at desc nulls last
  ),
  latest_dispatch as (
    select distinct on (load_id) load_id, delivered_at
    from public.dispatches
    where delivered_at is not null
    order by load_id, delivered_at desc
  )
  select
    l.id, l.load_number, l.status,
    l.customer_id, c.company_name,
    l.broker_id, b.company_name,
    ps.city, ps.state,
    ds.city, ds.state,
    ld.delivered_at,
    lf.rate,
    r.has_verified_pod, r.has_bol, r.bol_required, r.has_rate_confirmation, r.rate_confirmation_required, r.ready_to_bill
  from public.loads l
  join public.load_financials lf on lf.load_id = l.id
  left join public.customers c on c.id = l.customer_id
  left join public.brokers b on b.id = l.broker_id
  left join pickup_stop ps on ps.load_id = l.id
  left join delivery_stop ds on ds.load_id = l.id
  left join latest_dispatch ld on ld.load_id = l.id
  left join public.invoices i on i.load_id = l.id
  cross join lateral public.get_load_billing_readiness(l.id) r
  where l.status in ('delivered', 'pod_received')
    and i.id is null
    and public.load_bills_broker(l.id)
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  order by ld.delivered_at asc nulls last, l.load_number asc;
$$;

-- ---- E. fees only for "broker pays the carrier"; settlements only the rest ---------------------
create or replace function public._carrier_fee_invoice_candidates(p_org uuid, p_carrier_id uuid, p_period_start date, p_period_end date)
returns table (line_type text, description text, amount numeric, service_date date, load_id uuid, dispatch_id uuid, load_number text,
               load_rate numeric, fee_percentage numeric, dispatch_advance_id uuid, linked_fuel_log_id uuid, linked_maintenance_id uuid, sort_key text)
language sql stable security definer set search_path = pg_catalog, public as $$
  -- dispatch fees: "broker pays the carrier" loads delivered in the period, not yet billed anywhere
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
    and d.proceeds_model = 'carrier_paid_directly'   -- 0167: only loads where the broker pays the carrier
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

-- carrier settlements: 0166's body + not for "broker pays the carrier" loads
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
      and disp.proceeds_model is distinct from 'carrier_paid_directly'
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

-- ---- postconditions ------------------------------------------------------------------------------
do $post$
begin
  if not (select model_a_enabled from public.platform_settings where id = true) then
    raise exception '0167 postcondition: option not switched on.';
  end if;
  if (select count(*) from pg_trigger where not tgisinternal and tgname in
      ('carriers_guard_broker_pays_change', 'invoices_guard_load_bills_broker', 'auto_generate_invoice_on_delivery')) <> 3 then
    raise exception '0167 postcondition: triggers missing.';
  end if;
  if pg_get_triggerdef((select oid from pg_trigger where tgname = 'auto_generate_invoice_on_delivery')) not like '%load_bills_broker%' then
    raise exception '0167 postcondition: auto invoice is not limited to loads billed to the broker.';
  end if;
  if has_function_privilege('anon', 'public.set_carrier_broker_pays(uuid,public.proceeds_model)', 'execute') then
    raise exception '0167 postcondition: function privileges wrong.';
  end if;
end $post$;

commit;
