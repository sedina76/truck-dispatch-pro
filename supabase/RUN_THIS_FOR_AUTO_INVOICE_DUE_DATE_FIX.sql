-- =============================================================================
-- 0028_auto_invoice_dispatch_sync_fix.sql
-- Fixes the root cause of a real delivered load (LD-100014) never getting
-- its auto-generated draft invoice. The existing trigger from
-- 0022_auto_invoice_on_delivery.sql -- auto_generate_invoice_from_delivered_load(),
-- firing AFTER UPDATE on public.loads when status transitions into
-- 'delivered' -- is untouched and remains the single canonical automation.
-- Nothing here duplicates it, replaces it, or moves it into application code.
--
-- Two real, narrowly-scoped fixes:
--   1. ROOT CAUSE: dispatches.status and loads.status are two separate
--      columns on two separate tables. The Dispatch Board's drag-and-drop
--      (updateDispatchStatus) and the Dispatch Detail page's status field
--      (updateDispatch) both write ONLY dispatches.status -- neither ever
--      touches loads.status. So a dispatcher marking a dispatch
--      "Completed"/"Delivered" (a real, everyday action) never flips the
--      load itself to 'delivered', and the existing invoice trigger --
--      which only ever watches loads.status -- correctly never fires,
--      because that transition genuinely never happens on the loads table.
--      This is exactly what happened to LD-100014: its dispatch reached
--      status = 'completed' while the load itself stayed at 'dispatched'.
--      Fix: a new trigger on dispatches that, only when a dispatch
--      transitions into a delivered-equivalent status, updates the linked
--      load to 'delivered' (and only if the load hasn't already moved
--      past that point) -- which then fires the EXISTING loads trigger
--      exactly as if a dispatcher had set it by hand. Not security
--      definer: the loads/dispatches RLS update policies already grant
--      the identical role tier (owner/admin/dispatcher) on both tables
--      (0010_rls_policies.sql), so there is nothing to bypass.
--   2. Payment-terms fallback gap: the existing trigger fell back straight
--      to a hard-coded 30 when a broker/customer had no payment_terms_days
--      on file, silently skipping the organization's own
--      default_payment_terms_days column (added in 0014, already exists
--      for exactly this purpose). Fixed to consult it as the middle tier:
--      broker/customer terms -> organization default -> 30 as a final,
--      practically-unreachable safety net (organizations.default_payment_terms_days
--      is itself NOT NULL DEFAULT 30, so the bare literal only matters if
--      that column were ever nulled out directly).
-- =============================================================================

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

  -- Organization default terms, used only when the broker/customer has no
  -- explicit payment_terms_days of their own -- see header comment.
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

    perform public.log_activity('invoice', v_invoice_id, 'created');
  end if;

  return NEW;
end;
$$;

-- Trigger definition itself (name/table/timing/columns) is unchanged from
-- 0022 -- only the function body above changed, via create or replace.
drop trigger if exists auto_generate_invoice_on_delivery on public.loads;
create trigger auto_generate_invoice_on_delivery
  after update on public.loads
  for each row execute function public.auto_generate_invoice_from_delivered_load();

-- ---------------------------------------------------------------------------
-- The actual root-cause fix: propagate a dispatch reaching a
-- delivered-equivalent status onto its load, so the existing loads trigger
-- above has a real transition to fire on. Deliberately narrow: only fires
-- on a genuine transition INTO ('delivered', 'completed'), and only
-- touches the load if it hasn't already moved past 'delivered' on its own
-- (pod_received/invoiced/closed) or been cancelled -- never regresses a
-- load backwards, never overrides a status a dispatcher/accountant set
-- more specifically by hand afterward.
-- ---------------------------------------------------------------------------
create or replace function public.sync_load_status_from_dispatch()
returns trigger
language plpgsql
as $$
begin
  if NEW.status in ('delivered', 'completed') and OLD.status is distinct from NEW.status then
    update public.loads
    set status = 'delivered'
    where id = NEW.load_id
      and status not in ('delivered', 'pod_received', 'invoiced', 'closed', 'cancelled');
  end if;
  return NEW;
end;
$$;

drop trigger if exists dispatches_sync_load_status on public.dispatches;
create trigger dispatches_sync_load_status
  after update on public.dispatches
  for each row execute function public.sync_load_status_from_dispatch();
