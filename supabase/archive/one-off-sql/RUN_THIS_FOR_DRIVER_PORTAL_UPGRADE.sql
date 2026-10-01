-- =============================================================================
-- 0044_driver_portal_upgrade.sql
-- Driver Portal upgrade. Almost everything in this pass is pure
-- application code reusing existing tables/enums/triggers/RLS/storage
-- exactly as instructed -- no new dispatch/document/expense/settlement
-- structures. Exactly ONE real database fix was required, found live
-- (Test: "Dispatch -> Load -> Invoice Regression").
--
-- BUG: marking a dispatch "Delivered" from the Driver Portal uses the
-- service-role client (drivers have no Supabase Auth session/auth.uid()
-- at all -- see src/lib/driver-portal/session.ts, unchanged this pass).
-- That UPDATE correctly cascades through the EXISTING, untouched trigger
-- chain: dispatches_sync_load_status -> loads.status = 'delivered' ->
-- auto_generate_invoice_on_delivery -> auto_generate_invoice_from_
-- delivered_load() (0028_auto_invoice_dispatch_sync_fix.sql), which calls
-- public.log_activity('invoice', v_invoice_id, 'created'). log_activity()
-- (0009_functions_triggers.sql) inserts into activity_logs using
-- public.current_org_id(), which reads `select organization_id from
-- profiles where id = auth.uid()`. Under the driver portal's service-role
-- client there is no auth.uid() at all, so current_org_id() returns NULL,
-- and the insert into activity_logs (organization_id not null) throws --
-- which aborts the ENTIRE triggering UPDATE, including the dispatches.status
-- write itself. Confirmed live: before this fix, a driver marking a trip
-- Delivered failed outright with "null value in column organization_id of
-- relation activity_logs violates not-null constraint" -- the dispatch
-- never actually reached 'delivered', the load never synced, and no
-- invoice was created.
--
-- FIX: log_activity() gets one new, backward-compatible optional
-- parameter, p_organization_id default null. Every EXISTING call site
-- (staff-side, always under a real Supabase Auth session) is untouched
-- and keeps resolving it from current_org_id() exactly as before.
-- auto_generate_invoice_from_delivered_load() is the only call site
-- updated to pass NEW.organization_id explicitly, so it no longer depends
-- on a session that may not exist -- this makes the trigger itself
-- correct for ANY caller (service-role driver portal, staff RLS session,
-- or a future integration), not just a driver-portal-specific carve-out.
-- =============================================================================

create or replace function public.log_activity(
  p_entity_type public.entity_type,
  p_entity_id uuid,
  p_action text,
  p_changes jsonb default null,
  p_organization_id uuid default null
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
  values (coalesce(p_organization_id, public.current_org_id()), p_entity_type, p_entity_id, p_action, auth.uid(), p_changes)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.log_activity(public.entity_type, uuid, text, jsonb, uuid) to authenticated;

-- Same body as 0028, only the log_activity() call now passes NEW.organization_id.
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
           nullif(trim(both ', ' from concat_ws(', ', address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.brokers where id = NEW.broker_id;
  elsif NEW.customer_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', billing_address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.customers where id = NEW.customer_id;
  else
    return NEW;
  end if;

  select default_payment_terms_days into v_org_default_terms
  from public.organizations where id = NEW.organization_id;

  select id into v_dispatch_id from public.dispatches where load_id = NEW.id limit 1;
  v_invoice_number := public.generate_invoice_number(NEW.organization_id);

  insert into public.invoices (
    organization_id, invoice_number, load_id, dispatch_id, broker_id, customer_id,
    status, bill_to_name, bill_to_email, bill_to_address,
    subtotal_amount, total_amount, issue_date, due_date, notes
  ) values (
    NEW.organization_id, v_invoice_number, NEW.id, v_dispatch_id, NEW.broker_id, NEW.customer_id,
    'draft', v_bill_to_name, v_bill_to_email, v_bill_to_address,
    NEW.rate, NEW.rate, current_date,
    current_date + coalesce(v_payment_terms, v_org_default_terms, 30),
    'Auto-generated on delivery for load ' || NEW.load_number
  )
  on conflict (load_id) where load_id is not null do nothing
  returning id into v_invoice_id;

  if v_invoice_id is not null then
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (NEW.organization_id, v_invoice_id, 'Freight charges -- Load ' || NEW.load_number, 1, NEW.rate, 0);

    -- p_organization_id explicit -- see header comment. This is the one
    -- real functional fix in this migration.
    perform public.log_activity('invoice', v_invoice_id, 'created', null, NEW.organization_id);
  end if;

  return NEW;
end;
$$;

-- Trigger definition itself (name/table/timing/columns) is unchanged --
-- only the function body above changed, via create or replace.
drop trigger if exists auto_generate_invoice_on_delivery on public.loads;
create trigger auto_generate_invoice_on_delivery
  after update on public.loads
  for each row execute function public.auto_generate_invoice_from_delivered_load();

-- ---------------------------------------------------------------------------
-- Defensive re-run: found live while testing driver-portal expense receipt
-- upload (which reuses this exact bucket, spec section 14) that the
-- expense-documents bucket does not exist on this database, even though
-- 0041_expense_cost_management_fix.sql already contains this identical
-- block. Unrelated to anything in this pass -- re-included here, fully
-- idempotent (on conflict do nothing / drop policy if exists), so this
-- migration guarantees the bucket exists regardless of what happened with
-- 0041 on this specific database.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-documents', 'expense-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists expense_documents_select on storage.objects;
create policy expense_documents_select on storage.objects
  for select using (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

drop policy if exists expense_documents_insert on storage.objects;
create policy expense_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );
