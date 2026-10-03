-- =============================================================================
-- 0026_accounts_receivable.sql
-- Accounts Receivable & Payment Tracking. Builds entirely on the existing
-- invoices/invoice_line_items/payments schema from 0006_financials.sql and
-- the existing apply_payment_to_invoice()/recalculate_invoice_totals()
-- triggers from 0009_functions_triggers.sql -- no competing tables, no new
-- invoice_status values, no change to POD/billing-packet behavior.
--
-- balance_due stays the single source of truth exactly as it already was
-- (generated column: total_amount - amount_paid, 0006) -- nothing here
-- introduces a second, driftable balance field.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- payments: add what's needed for numbering, void/reversal, and the extra
-- reference fields the Record Payment form asks for. Nothing here touches
-- amount/method/invoice_id -- those already exist from 0006.
-- ---------------------------------------------------------------------------
create type public.payment_status as enum ('posted', 'voided');

-- Concurrency-safe numbering: nextval() on a sequence is atomic under
-- concurrent inserts by construction (unlike generate_invoice_number()'s
-- count(*)+1, which 0009 already documents as not concurrency-safe). Wrapped
-- in a SECURITY DEFINER function, matching generate_invoice_number()'s own
-- shape, so the function owner's implicit sequence privileges are used
-- instead of granting USAGE on the sequence directly to authenticated.
create sequence public.payment_number_seq;

create or replace function public.generate_payment_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return 'PAY-' || lpad(nextval('public.payment_number_seq')::text, 6, '0');
end;
$$;

grant execute on function public.generate_payment_number() to authenticated;

alter table public.payments
  add column payment_number text not null default public.generate_payment_number(),
  add column status public.payment_status not null default 'posted',
  add column check_number text,
  add column bank_reference text,
  add column voided_by uuid references public.profiles (id) on delete set null,
  add column voided_at timestamptz,
  add column void_reason text,
  add column updated_at timestamptz not null default now(),
  add constraint payments_payment_number_key unique (payment_number),
  add constraint payments_void_requires_reason check (status <> 'voided' or void_reason is not null);

comment on column public.payments.status is
  'posted = counts toward amount_paid/balance_due via apply_payment_to_invoice(). voided = an auditable reversal/correction, excluded from that rollup but never deleted -- see voided_by/voided_at/void_reason.';

-- payments already has organization_id NOT NULL (0006) and RLS from 0010's
-- child_tables loop (select: any org member; insert/update/delete:
-- owner/admin/accountant) -- unchanged by this migration. The blanket
-- `grant select, insert, update, delete on all tables ... to authenticated`
-- from 0010 already covers these new columns; no column-level grants
-- needed (payments/invoices were never part of the driver-PII
-- column-restriction pattern).

drop trigger if exists set_updated_at on public.payments;
create trigger set_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Overpayment guard (defense-in-depth, not just the app form): rejects a
-- posted payment whose amount exceeds the invoice's CURRENT balance_due.
-- No credits/unapplied-cash table exists anywhere in this schema, so per
-- spec this blocks rather than inventing one.
--
-- `select ... for update` locks the invoice row for the rest of this
-- transaction, so two concurrent payment inserts against the same invoice
-- can never both read the same pre-payment balance and both pass -- the
-- second waits for the first's transaction (and the AFTER INSERT
-- apply_payment_to_invoice() rollup it fires) to commit before evaluating
-- its own check. This is what makes the overpayment guard concurrency-safe,
-- not just correct for a single request.
-- ---------------------------------------------------------------------------
create or replace function public.guard_payment_amount()
returns trigger
language plpgsql
as $$
declare
  v_balance numeric(10, 2);
  v_invoice_status public.invoice_status;
begin
  -- old.status is distinct from new.status covers BOTH the normal INSERT
  -- case (OLD is NULL for an INSERT-triggered call, so OLD.status IS
  -- DISTINCT FROM anything) and the one UPDATE case that actually needs
  -- re-validating: a payment transitioning back to 'posted' from 'voided'
  -- (there is no un-void path in the app today, but the DB should not
  -- silently trust it if one is ever added or called directly). Excluding
  -- updates where status stays 'posted' unchanged is what keeps this from
  -- re-rejecting a harmless notes-only edit on an already-posted payment --
  -- new.amount always exceeds "the balance due after this same payment is
  -- already applied" for any real payment, so re-checking on every update
  -- would be a false positive, not a real one.
  if new.status = 'posted' and old.status is distinct from new.status then
    if new.amount is null or new.amount <= 0 then
      raise exception 'Payment amount must be greater than zero.';
    end if;

    select balance_due, status into v_balance, v_invoice_status
    from public.invoices
    where id = new.invoice_id
    for update;

    if v_invoice_status is null then
      raise exception 'Invoice not found.';
    end if;

    if v_invoice_status = 'void' then
      raise exception 'Cannot record a payment against a void invoice.';
    end if;

    if new.amount > v_balance then
      raise exception 'Payment amount ($%) exceeds the invoice balance due ($%). Overpayment is not supported -- record a partial payment for the remaining balance instead.', new.amount, v_balance;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists payments_guard_amount on public.payments;
create trigger payments_guard_amount
  before insert or update on public.payments
  for each row execute function public.guard_payment_amount();

-- ---------------------------------------------------------------------------
-- apply_payment_to_invoice(): replaces the 0009 version to (a) only count
-- status = 'posted' payments -- a voided payment must stop counting toward
-- amount_paid the moment it's voided, since this trigger also fires on
-- UPDATE -- and (b) correctly revert status back to 'sent' when total_paid
-- drops back to 0 (e.g. the only payment on an invoice gets voided), which
-- the original version left stuck at whatever it was. Never auto-transitions
-- draft/void/disputed -- those are workflow states this rollup has no
-- business overriding.
-- ---------------------------------------------------------------------------
create or replace function public.apply_payment_to_invoice()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid;
  v_total_paid numeric(10, 2);
  v_invoice_total numeric(10, 2);
  v_current_status public.invoice_status;
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);

  select coalesce(sum(amount) filter (where status = 'posted'), 0) into v_total_paid
  from public.payments
  where invoice_id = v_invoice_id;

  select total_amount, status into v_invoice_total, v_current_status
  from public.invoices where id = v_invoice_id;

  if v_current_status is null then
    return null; -- invoice row itself is gone (cascade delete); nothing to update
  end if;

  update public.invoices
  set amount_paid = v_total_paid,
      status = case
        when v_current_status in ('draft', 'void', 'disputed') then v_current_status
        when v_total_paid <= 0 then 'sent'
        when v_invoice_total > 0 and v_total_paid >= v_invoice_total then 'paid'
        else 'partially_paid'
      end,
      paid_at = case when v_invoice_total > 0 and v_total_paid >= v_invoice_total then now() else null end
  where id = v_invoice_id;

  return null;
end;
$$;

-- Trigger definition itself (name/table/timing/columns) is unchanged from
-- 0009 -- only the function body above changed, via create or replace.
drop trigger if exists payments_apply_to_invoice on public.payments;
create trigger payments_apply_to_invoice
  after insert or update or delete on public.payments
  for each row execute function public.apply_payment_to_invoice();

-- ---------------------------------------------------------------------------
-- Guard against contradictory manually-set invoice statuses (e.g. staff
-- picking "Paid" from the status dropdown on an invoice with a positive
-- balance). Only re-validates when status is actually CHANGING to a
-- payment-derived value -- never fires for recalculate_invoice_totals()'s
-- own updates (which never touch status) or any other unrelated edit, so
-- existing line-item editing keeps working exactly as before.
-- ---------------------------------------------------------------------------
create or replace function public.guard_invoice_status()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'paid' and new.amount_paid < new.total_amount then
      raise exception 'Cannot set invoice status to Paid: amount paid ($%) is less than the invoice total ($%). Record a payment for the remaining balance instead of setting this manually.', new.amount_paid, new.total_amount;
    end if;
    if new.status = 'partially_paid' and (new.amount_paid <= 0 or new.amount_paid >= new.total_amount) then
      raise exception 'Cannot set invoice status to Partially Paid manually -- this status is set automatically when a payment is recorded.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_guard_status on public.invoices;
create trigger invoices_guard_status
  before update on public.invoices
  for each row execute function public.guard_invoice_status();

-- ---------------------------------------------------------------------------
-- Overdue: derived, never stored. due_date < as-of AND balance_due > 0,
-- for any invoice not already paid/void/disputed/draft. Nothing mutates
-- invoices.status to 'overdue' on a schedule -- that would depend on a
-- cron job actually running and can go stale; deriving it on every read
-- instead means it's always correct the instant due_date passes, with zero
-- dependency on anyone opening the invoice page or a cron firing.
-- ---------------------------------------------------------------------------
create or replace function public.invoice_effective_status(
  p_status public.invoice_status,
  p_due_date date,
  p_balance_due numeric,
  p_as_of date default current_date
) returns public.invoice_status
language sql
stable
as $$
  select case
    when p_status in ('paid', 'void', 'disputed', 'draft') then p_status
    when p_due_date is not null and p_due_date < p_as_of and p_balance_due > 0 then 'overdue'::public.invoice_status
    else p_status
  end;
$$;

grant execute on function public.invoice_effective_status(public.invoice_status, date, numeric, date) to authenticated;

-- Aging bucket by due_date, relative to an as-of date (defaults to today).
-- Unpaid/no due date and not yet due both land in 'current'.
create or replace function public.ar_aging_bucket(p_due_date date, p_as_of date default current_date)
returns text
language sql
stable
as $$
  select case
    when p_due_date is null or p_due_date >= p_as_of then 'current'
    when p_as_of - p_due_date <= 30 then '1_30'
    when p_as_of - p_due_date <= 60 then '31_60'
    when p_as_of - p_due_date <= 90 then '61_90'
    else '90_plus'
  end;
$$;

grant execute on function public.ar_aging_bucket(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_ar_summary: the ONE canonical A/R aggregate -- Finance dashboard,
-- main Dashboard KPIs, and the Reports aging page all call this same
-- function so the same metric can never disagree across pages. Deliberately
-- NOT security definer (same reasoning as get_load_summary, 0021): it runs
-- with the caller's own privileges, so the existing RLS policy on
-- public.invoices/public.payments (organization_id = current_org_id())
-- applies exactly as it would to any other query -- this cannot see another
-- organization's receivables. p_broker_id/p_customer_id optionally scope it
-- to one party (used by Broker/Customer A/R sections); both null means the
-- whole org. p_as_of_date lets Reports ask "as of" a past date; defaults to
-- today for the live dashboard.
-- ---------------------------------------------------------------------------
create or replace function public.get_ar_summary(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_as_of_date date default current_date
)
returns table (
  total_receivables numeric,
  current_amount numeric,
  bucket_1_30 numeric,
  bucket_31_60 numeric,
  bucket_61_90 numeric,
  bucket_90_plus numeric,
  overdue_invoice_count bigint,
  overdue_amount numeric,
  collected_this_month numeric
)
language sql
stable
as $$
  with outstanding as (
    select i.balance_due, i.due_date
    from public.invoices i
    where i.status not in ('paid', 'void')
      and i.balance_due > 0
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  collected as (
    select coalesce(sum(p.amount), 0) as amt
    from public.payments p
    join public.invoices i on i.id = p.invoice_id
    where p.status = 'posted'
      and p.received_at >= date_trunc('month', p_as_of_date)
      and p.received_at < date_trunc('month', p_as_of_date) + interval '1 month'
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  )
  select
    coalesce(sum(o.balance_due), 0) as total_receivables,
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = 'current'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '1_30'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '31_60'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '61_90'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '90_plus'), 0),
    count(*) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) <> 'current')::bigint,
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) <> 'current'), 0),
    (select amt from collected)
  from outstanding o;
$$;

grant execute on function public.get_ar_summary(uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_ar_invoices: the row source behind the Accounts Receivable table,
-- Reports drill-down, and Broker/Customer "Open Invoices" lists -- one
-- shared query so effective_status/aging_bucket/days_past_due can never be
-- computed differently on different pages. Excludes void invoices always;
-- p_status filters by the *effective* status (e.g. 'overdue'), not the
-- raw stored one, so filtering by "Overdue" actually matches what the
-- badge shows. Sorted oldest-due-first with a balance, matching the "most
-- overdue / oldest collectible invoices first" default the spec asks for.
-- ---------------------------------------------------------------------------
create or replace function public.get_ar_invoices(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_status text default null,
  p_as_of_date date default current_date
)
returns table (
  id uuid,
  invoice_number text,
  load_id uuid,
  load_number text,
  broker_id uuid,
  broker_name text,
  customer_id uuid,
  customer_name text,
  bill_to_name text,
  issue_date date,
  due_date date,
  total_amount numeric,
  amount_paid numeric,
  balance_due numeric,
  status public.invoice_status,
  effective_status public.invoice_status,
  aging_bucket text,
  days_past_due integer
)
language sql
stable
as $$
  select
    i.id, i.invoice_number, i.load_id, l.load_number,
    i.broker_id, b.company_name, i.customer_id, c.company_name,
    i.bill_to_name, i.issue_date, i.due_date,
    i.total_amount, i.amount_paid, i.balance_due,
    i.status,
    public.invoice_effective_status(i.status, i.due_date, i.balance_due, p_as_of_date),
    public.ar_aging_bucket(i.due_date, p_as_of_date),
    case when i.due_date is not null and i.due_date < p_as_of_date then (p_as_of_date - i.due_date) else 0 end
  from public.invoices i
  left join public.loads l on l.id = i.load_id
  left join public.brokers b on b.id = i.broker_id
  left join public.customers c on c.id = i.customer_id
  where i.status <> 'void'
    and (p_broker_id is null or i.broker_id = p_broker_id)
    and (p_customer_id is null or i.customer_id = p_customer_id)
    and (
      p_status is null
      or public.invoice_effective_status(i.status, i.due_date, i.balance_due, p_as_of_date)::text = p_status
    )
  order by
    case when i.balance_due > 0 then 0 else 1 end,
    i.due_date asc nulls last,
    i.issue_date asc;
$$;

grant execute on function public.get_ar_invoices(uuid, uuid, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_party_ar_summary: Broker/Customer A/R + payment-behavior metrics.
-- avg_days_to_pay is computed ONLY from invoices that actually reached
-- 'paid', using that invoice's own latest posted payment date -- i.e. only
-- from data that actually exists, never estimated/fabricated. Returns null
-- (not 0) when there's no paid history yet; render that as "Not enough
-- data" rather than a fake 0-day average.
-- ---------------------------------------------------------------------------
create or replace function public.get_party_ar_summary(p_broker_id uuid default null, p_customer_id uuid default null)
returns table (
  total_billed numeric,
  total_paid numeric,
  outstanding numeric,
  past_due numeric,
  open_invoices bigint,
  paid_invoices bigint,
  oldest_unpaid_due_date date,
  avg_days_to_pay numeric
)
language sql
stable
as $$
  with scoped as (
    select i.*
    from public.invoices i
    where i.status <> 'void'
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  paid_durations as (
    select s.id, s.issue_date, max(p.received_at)::date as paid_date
    from scoped s
    join public.payments p on p.invoice_id = s.id and p.status = 'posted'
    where s.status = 'paid'
    group by s.id, s.issue_date
  )
  select
    coalesce((select sum(total_amount) from scoped), 0),
    coalesce((select sum(amount_paid) from scoped), 0),
    coalesce((select sum(balance_due) from scoped where balance_due > 0), 0),
    coalesce((select sum(balance_due) from scoped where balance_due > 0 and due_date is not null and due_date < current_date), 0),
    (select count(*) from scoped where balance_due > 0)::bigint,
    (select count(*) from scoped where status = 'paid')::bigint,
    (select min(due_date) from scoped where balance_due > 0),
    (select round(avg(paid_date - issue_date), 1) from paid_durations);
$$;

grant execute on function public.get_party_ar_summary(uuid, uuid) to authenticated;
