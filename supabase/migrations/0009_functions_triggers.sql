-- =============================================================================
-- 0009_functions_triggers.sql
-- Business-logic functions and the triggers that wire them up:
--   - updated_at maintenance, auto-attached to every table with that column
--   - dispatch fee calculation from load rate x fee %
--   - invoice totals rollup from line items, and amount_paid rollup from payments
--   - settlement gross/deductions rollup from settlement line items
--   - new-user -> profile provisioning
--   - compliance status refresh (scheduled) + expiring-items lookup
--   - invoice numbering helper
--   - append-only activity logging helper
-- =============================================================================

-- ---------------------------------------------------------------------------
-- updated_at: attach public.set_updated_at() (defined in 0001) to every
-- table in the public schema that has an updated_at column. Re-running this
-- migration is idempotent and will also pick up any future table.
-- ---------------------------------------------------------------------------
do $$
declare
  t record;
begin
  for t in
    select c.table_name
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.column_name = 'updated_at'
  loop
    execute format(
      'drop trigger if exists set_updated_at on public.%I;
       create trigger set_updated_at before update on public.%I
       for each row execute function public.set_updated_at();',
      t.table_name, t.table_name
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Dispatch financials: dispatch_fee_amount / carrier_net_amount are derived,
-- never entered by hand. load_rate is snapshotted from loads.rate the first
-- time it is unset, then locked in for historical accuracy.
-- ---------------------------------------------------------------------------
create or replace function public.sync_dispatch_financials()
returns trigger
language plpgsql
as $$
declare
  v_load_rate numeric(10, 2);
begin
  if new.load_rate is null or new.load_rate = 0 then
    select rate into v_load_rate from public.loads where id = new.load_id;
    new.load_rate := coalesce(v_load_rate, 0);
  end if;

  new.dispatch_fee_amount := round(new.load_rate * (new.dispatch_fee_percentage / 100.0), 2);
  new.carrier_net_amount := new.load_rate - new.dispatch_fee_amount;

  return new;
end;
$$;

drop trigger if exists dispatches_sync_financials on public.dispatches;
create trigger dispatches_sync_financials
  before insert or update of load_rate, dispatch_fee_percentage, load_id
  on public.dispatches
  for each row execute function public.sync_dispatch_financials();

-- ---------------------------------------------------------------------------
-- Invoice totals: recompute subtotal/total whenever line items change.
-- ---------------------------------------------------------------------------
create or replace function public.recalculate_invoice_totals()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid;
  v_subtotal numeric(10, 2);
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);

  select coalesce(sum(line_total), 0) into v_subtotal
  from public.invoice_line_items
  where invoice_id = v_invoice_id;

  update public.invoices
  set subtotal_amount = v_subtotal,
      total_amount = v_subtotal - discount_amount + tax_amount
  where id = v_invoice_id;

  return null;
end;
$$;

drop trigger if exists invoice_line_items_recalculate on public.invoice_line_items;
create trigger invoice_line_items_recalculate
  after insert or update or delete on public.invoice_line_items
  for each row execute function public.recalculate_invoice_totals();

-- ---------------------------------------------------------------------------
-- Invoice payment rollup: keep amount_paid and status in sync with payments.
-- ---------------------------------------------------------------------------
create or replace function public.apply_payment_to_invoice()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid;
  v_total_paid numeric(10, 2);
  v_invoice_total numeric(10, 2);
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);

  select coalesce(sum(amount), 0) into v_total_paid
  from public.payments
  where invoice_id = v_invoice_id;

  select total_amount into v_invoice_total
  from public.invoices where id = v_invoice_id;

  update public.invoices
  set amount_paid = v_total_paid,
      status = case
        when v_total_paid <= 0 then status
        when v_total_paid >= v_invoice_total then 'paid'
        else 'partially_paid'
      end,
      paid_at = case when v_total_paid >= v_invoice_total then now() else paid_at end
  where id = v_invoice_id;

  return null;
end;
$$;

drop trigger if exists payments_apply_to_invoice on public.payments;
create trigger payments_apply_to_invoice
  after insert or update or delete on public.payments
  for each row execute function public.apply_payment_to_invoice();

-- ---------------------------------------------------------------------------
-- Settlement totals: recompute gross/deductions from settlement_line_items.
-- ---------------------------------------------------------------------------
create or replace function public.recalculate_settlement_totals()
returns trigger
language plpgsql
as $$
declare
  v_settlement_id uuid;
  v_gross numeric(10, 2);
  v_deductions numeric(10, 2);
begin
  v_settlement_id := coalesce(new.settlement_id, old.settlement_id);

  select coalesce(sum(amount) filter (where item_type = 'earning'), 0),
         coalesce(sum(amount) filter (where item_type = 'deduction'), 0)
  into v_gross, v_deductions
  from public.settlement_line_items
  where settlement_id = v_settlement_id;

  update public.settlements
  set gross_amount = v_gross,
      deductions_amount = v_deductions
  where id = v_settlement_id;

  return null;
end;
$$;

drop trigger if exists settlement_line_items_recalculate on public.settlement_line_items;
create trigger settlement_line_items_recalculate
  after insert or update or delete on public.settlement_line_items
  for each row execute function public.recalculate_settlement_totals();

-- ---------------------------------------------------------------------------
-- New-user provisioning: auto-create a profile row when a Supabase Auth
-- user is created. organization_id starts null; the app's onboarding flow
-- either creates a new organization (making this user 'owner') or accepts
-- an invite (assigning an existing organization_id + role).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    new.email,
    'dispatcher'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Compliance status refresh: intended to run daily via pg_cron, e.g.
--   select cron.schedule('refresh-compliance-statuses', '0 6 * * *',
--     $$select public.refresh_compliance_statuses();$$);
-- ---------------------------------------------------------------------------
create or replace function public.refresh_compliance_statuses()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.compliance_items
  set status = case
    when expiry_date is null then status
    when expiry_date < current_date then 'expired'
    when expiry_date <= current_date + interval '30 days' then 'expiring_soon'
    else 'valid'
  end
  where expiry_date is not null
    and status not in ('waived');
end;
$$;

-- Convenience read helper for the current org's Compliance dashboard.
create or replace function public.get_expiring_compliance_items(p_days_ahead integer default 30)
returns setof public.compliance_items
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.compliance_items
  where organization_id = public.current_org_id()
    and expiry_date is not null
    and expiry_date <= current_date + (p_days_ahead || ' days')::interval
    and status <> 'waived'
  order by expiry_date asc;
$$;

grant execute on function public.get_expiring_compliance_items(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Invoice numbering helper: simple per-org sequential number (INV-000123).
-- Not concurrency-safe under heavy simultaneous inserts for the same org;
-- upgrade to a per-org sequence/counter table if that becomes a problem.
-- ---------------------------------------------------------------------------
create or replace function public.generate_invoice_number(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  select count(*) + 1 into v_count
  from public.invoices
  where organization_id = p_organization_id;

  return 'INV-' || lpad(v_count::text, 6, '0');
end;
$$;

grant execute on function public.generate_invoice_number(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Activity logging helper: the only sanctioned way to write to
-- activity_logs from client code (SECURITY DEFINER; table has no direct
-- insert policy for authenticated users -- see 0010).
-- ---------------------------------------------------------------------------
create or replace function public.log_activity(
  p_entity_type public.entity_type,
  p_entity_id uuid,
  p_action text,
  p_changes jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.activity_logs (organization_id, entity_type, entity_id, action, actor_id, changes)
  values (public.current_org_id(), p_entity_type, p_entity_id, p_action, auth.uid(), p_changes)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.log_activity(public.entity_type, uuid, text, jsonb) to authenticated;
