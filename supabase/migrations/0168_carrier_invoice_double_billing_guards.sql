-- ============================================================================
-- 0168_carrier_invoice_double_billing_guards.sql
--
-- Carrier freight invoices (0142-0157: the carrier's own invoice to the
-- broker, the one a factoring company buys) were built before the per-carrier
-- "Who does the broker pay?" setting (0167) and Dispatch Fee Invoices (0165).
-- Nothing tied them together, so a load could be billed twice. Guards:
--   A. a carrier freight invoice can only include "broker pays the carrier"
--      loads (a "broker pays us" load is invoiced to the broker by you);
--   B. a broker invoice cannot be created for a load that is on a live
--      carrier freight invoice;
--   C. the older dispatch-service fee ledger (0145) refuses a load whose fee
--      is already on a live Dispatch Fee Invoice (0165 already refuses the
--      other way round);
--   D. changing who the broker pays keeps loads that are on a live carrier
--      freight invoice where they are.
-- Nothing existing is changed. One transaction; safe to re-run.
-- ============================================================================

begin;

do $pre$
begin
  if to_regprocedure('public.load_bills_broker(uuid)') is null or to_regclass('public.carrier_invoice_billable_ledger_0157') is null then
    raise exception '0168 precondition: run 0157 and 0167 first. STOP -- nothing changed.';
  end if;
end $pre$;

-- ---- A ------------------------------------------------------------------------------------
create or replace function public.guard_carrier_freight_invoice_load()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_type text; v_number text;
begin
  select invoice_document_type::text into v_type from public.carrier_invoices where id = new.invoice_id;
  if v_type = 'carrier_freight_invoice' and public.load_bills_broker(new.load_id) then
    select load_number into v_number from public.loads where id = new.load_id;
    raise exception 'Load % is set to "Broker pays us" -- you invoice the broker for it, so it cannot go on the carrier''s own invoice. Change who the broker pays on the carrier first.', v_number
      using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.guard_carrier_freight_invoice_load() from public, anon, authenticated;
drop trigger if exists carrier_invoice_loads_guard_broker_pays on public.carrier_invoice_loads;
create trigger carrier_invoice_loads_guard_broker_pays before insert on public.carrier_invoice_loads
  for each row execute function public.guard_carrier_freight_invoice_load();

-- ---- B ------------------------------------------------------------------------------------
create or replace function public.guard_invoice_not_on_carrier_invoice()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.load_id is not null and exists (select 1 from public.carrier_invoice_billable_ledger_0157 g where g.load_id = new.load_id and g.released_at is null) then
    raise exception 'This load is on the carrier''s own invoice to the broker (carrier freight invoice), so you cannot invoice the broker for it as well.';
  end if;
  return new;
end $$;
revoke all on function public.guard_invoice_not_on_carrier_invoice() from public, anon, authenticated;
drop trigger if exists invoices_guard_not_on_carrier_invoice on public.invoices;
create trigger invoices_guard_not_on_carrier_invoice before insert on public.invoices
  for each row execute function public.guard_invoice_not_on_carrier_invoice();

-- ---- C ------------------------------------------------------------------------------------
create or replace function public.guard_dispatch_service_line_not_fee_invoiced()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if exists (select 1 from public.carrier_fee_invoice_lines x where x.line_type = 'dispatch_fee' and x.load_id = new.load_id and not x.voided) then
    raise exception 'This load''s dispatch fee is already on a Dispatch Fee Invoice.';
  end if;
  return new;
end $$;
revoke all on function public.guard_dispatch_service_line_not_fee_invoiced() from public, anon, authenticated;
drop trigger if exists cdsbl_guard_not_fee_invoiced on public.carrier_dispatch_service_billing_lines;
create trigger cdsbl_guard_not_fee_invoiced before insert on public.carrier_dispatch_service_billing_lines
  for each row execute function public.guard_dispatch_service_line_not_fee_invoiced();

-- ---- D: 0167's body + "on a carrier freight invoice" is kept ---------------------------------
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
    if exists (select 1 from public.carrier_invoice_billable_ledger_0157 g where g.load_id = d.load_id and g.released_at is null) then
      v_kept := v_kept || (d.load_number || ' (on a carrier freight invoice)');
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

do $post$
begin
  if (select count(*) from pg_trigger where not tgisinternal and tgname in
      ('carrier_invoice_loads_guard_broker_pays', 'invoices_guard_not_on_carrier_invoice', 'cdsbl_guard_not_fee_invoiced')) <> 3 then
    raise exception '0168 postcondition: triggers missing.';
  end if;
  if pg_get_functiondef('public.set_carrier_broker_pays(uuid,public.proceeds_model)'::regprocedure) not like '%on a carrier freight invoice%' then
    raise exception '0168 postcondition: set_carrier_broker_pays not updated.';
  end if;
end $post$;

commit;
