-- ---------------------------------------------------------------------------
-- Automatic invoice generation on delivery.
--
-- Implemented as a database trigger on public.loads, not application code,
-- so it fires no matter which code path flips a load to 'delivered' --
-- the load edit form, the dispatch board's drag-and-drop status update, a
-- future API integration, or a direct REST call all go through the same
-- table write and therefore the same trigger. "Do not simply add a
-- frontend button" is the whole reason for this approach.
--
-- Uses the single literal 'delivered' status, matching the trigger
-- condition described in the request and the COMPLETED_LOAD_STATUSES
-- primary value in src/lib/loads/status.ts -- no separate/independent
-- status classification is introduced here.
-- ---------------------------------------------------------------------------

-- Duplicate protection, database-level: partial unique index means even two
-- concurrent transactions racing to insert an invoice for the same load
-- cannot both succeed, regardless of application-level checks.
create unique index invoices_load_id_unique_idx on public.invoices (load_id) where load_id is not null;

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
  v_invoice_number text;
  v_dispatch_id uuid;
  v_invoice_id uuid;
begin
  -- Only a genuine transition INTO 'delivered' fires this -- not every
  -- update to an already-delivered load (editing notes, re-saving, etc.).
  if NEW.status is distinct from 'delivered' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status is not distinct from 'delivered' then
    return NEW;
  end if;

  -- Belt-and-suspenders idempotency check before even attempting the
  -- insert (the unique index above is the real guarantee under a race).
  if exists (select 1 from public.invoices where load_id = NEW.id) then
    return NEW;
  end if;

  -- Bill-to party: broker first (brokered freight), else the direct
  -- customer. Never the driver/carrier -- they're paid via settlements,
  -- a completely separate flow from customer/broker invoicing.
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
    -- No broker or customer on file to bill -- leave the load delivered
    -- without fabricating a bill-to party. A dispatcher can still create
    -- the invoice manually once the load is linked to one.
    return NEW;
  end if;

  select id into v_dispatch_id from public.dispatches where load_id = NEW.id limit 1;
  v_invoice_number := public.generate_invoice_number(NEW.organization_id);

  insert into public.invoices (
    organization_id, invoice_number, load_id, dispatch_id, broker_id, customer_id,
    status, bill_to_name, bill_to_email, bill_to_address,
    subtotal_amount, total_amount, issue_date, due_date, notes
  ) values (
    NEW.organization_id, v_invoice_number, NEW.id, v_dispatch_id, NEW.broker_id, NEW.customer_id,
    'draft', v_bill_to_name, v_bill_to_email, v_bill_to_address,
    NEW.rate, NEW.rate, current_date, current_date + coalesce(v_payment_terms, 30),
    'Auto-generated on delivery for load ' || NEW.load_number
  )
  on conflict (load_id) where load_id is not null do nothing
  returning id into v_invoice_id;

  -- v_invoice_id is null if the on-conflict branch fired (a concurrent
  -- request won the race) -- skip the line item entirely in that case.
  if v_invoice_id is not null then
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (NEW.organization_id, v_invoice_id, 'Freight charges -- Load ' || NEW.load_number, 1, NEW.rate, 0);

    perform public.log_activity('invoice', v_invoice_id, 'created');
  end if;

  return NEW;
end;
$$;

create trigger auto_generate_invoice_on_delivery
  after update on public.loads
  for each row execute function public.auto_generate_invoice_from_delivered_load();
