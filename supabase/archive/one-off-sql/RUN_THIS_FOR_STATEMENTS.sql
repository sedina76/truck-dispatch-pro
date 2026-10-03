-- =============================================================================
-- 0029_statements.sql
-- Broker/Customer Statements. Reuses the existing invoice/payment schema
-- and the canonical A/R functions from 0026_accounts_receivable.sql
-- (invoice_effective_status, ar_aging_bucket, get_ar_summary,
-- get_ar_invoices, get_party_ar_summary) -- no second financial system, no
-- duplicate balance/aging calculation. Only two genuinely new aggregates
-- are added (opening balance reconstruction + the period ledger), since
-- nothing existing can answer "what did this party owe as of a past date".
-- =============================================================================

create type public.statement_party_type as enum ('broker', 'customer');
create type public.statement_type as enum ('open_balance', 'period', 'aging');
create type public.statement_status as enum ('draft', 'generated', 'sent');

-- Concurrency-safe numbering, identical pattern to generate_payment_number()
-- (0026_accounts_receivable.sql) -- nextval() on a sequence is atomic under
-- concurrent inserts by construction.
create sequence public.statement_number_seq;

create or replace function public.generate_statement_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return 'STM-' || lpad(nextval('public.statement_number_seq')::text, 6, '0');
end;
$$;

grant execute on function public.generate_statement_number() to authenticated;

-- ---------------------------------------------------------------------------
-- statements: one row per generated statement (a version/snapshot), never
-- edited in place -- same "append, don't overwrite history" pattern as
-- billing_packets (0024_billing_packets.sql). snapshot freezes exactly
-- which invoice/payment IDs were included and the computed totals, so a
-- previously-sent statement can never silently change if invoices/payments
-- are edited afterward.
-- ---------------------------------------------------------------------------
create table public.statements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  statement_number text not null default public.generate_statement_number(),
  party_type public.statement_party_type not null,
  broker_id uuid references public.brokers (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  statement_type public.statement_type not null,
  period_start date,
  period_end date,
  as_of_date date not null default current_date,
  opening_balance numeric(12, 2) not null default 0,
  closing_balance numeric(12, 2) not null default 0,
  status public.statement_status not null default 'generated',
  storage_path text,
  snapshot jsonb not null default '{}'::jsonb,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz,
  sent_by uuid references public.profiles (id) on delete set null,
  recipient_email text,
  created_at timestamptz not null default now(),
  unique (statement_number),
  constraint statements_exactly_one_party check (
    (party_type = 'broker' and broker_id is not null and customer_id is null)
    or (party_type = 'customer' and customer_id is not null and broker_id is null)
  ),
  constraint statements_period_bounds check (
    statement_type <> 'period' or (period_start is not null and period_end is not null and period_start <= period_end)
  )
);

comment on table public.statements is
  'One row per generated statement (a snapshot), never overwritten -- regenerating creates a new row. snapshot freezes the exact invoice/payment IDs and totals a party saw at generation time.';

create index idx_statements_org on public.statements (organization_id, generated_at desc);
create index idx_statements_broker on public.statements (broker_id, generated_at desc) where broker_id is not null;
create index idx_statements_customer on public.statements (customer_id, generated_at desc) where customer_id is not null;

alter table public.statements enable row level security;

-- Same access tier as invoices/billing_packets: select any org member,
-- write owner/admin/accountant. Delete is granted only for the same
-- reason billing_packets_delete exists (0025_billing_packet_race_hardening.sql)
-- -- app-level rollback of a reservation whose PDF upload failed, never
-- used to remove a successfully generated statement.
create policy statements_select on public.statements
  for select using (organization_id = public.current_org_id());

create policy statements_insert on public.statements
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy statements_update on public.statements
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy statements_delete on public.statements
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Private storage bucket for generated statement PDFs. Same shape as
-- billing-packets (0024/0025): org-folder-prefix RLS, signed URLs only,
-- delete policy included from the start (learned from having to add it
-- retroactively for billing_packets) so the reserve-then-upload-then-
-- rollback-on-failure pattern works immediately.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('statements', 'statements', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

create policy statements_storage_select on storage.objects
  for select using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

create policy statements_storage_insert on storage.objects
  for insert with check (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy statements_storage_delete on storage.objects
  for delete using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- get_statement_opening_balance: what a party owed at the END of the day
-- BEFORE a given date -- i.e. the balance carried into a period statement
-- starting on that date. Reconstructed from history (every non-void
-- invoice issued on/before the cutoff, minus every posted payment received
-- on/before the cutoff), NOT read from invoices.balance_due (which is only
-- ever the CURRENT live balance, not a point-in-time figure). Deliberately
-- NOT security definer -- runs with the caller's own RLS, identical
-- reasoning to get_ar_summary()/get_ar_invoices() (0026): this cannot see
-- another organization's invoices/payments, because the underlying SELECTs
-- are subject to the exact same RLS policies any other query would be.
-- ---------------------------------------------------------------------------
create or replace function public.get_statement_opening_balance(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_cutoff_date date default current_date - 1
)
returns numeric
language sql
stable
as $$
  with scoped_invoices as (
    select i.id, i.total_amount
    from public.invoices i
    where i.status <> 'void'
      and i.issue_date <= p_cutoff_date
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  charges as (
    select coalesce(sum(total_amount), 0) as amt from scoped_invoices
  ),
  posted_payments as (
    select coalesce(sum(p.amount), 0) as amt
    from public.payments p
    join scoped_invoices si on si.id = p.invoice_id
    where p.status = 'posted'
      and p.received_at::date <= p_cutoff_date
  )
  select (select amt from charges) - (select amt from posted_payments);
$$;

grant execute on function public.get_statement_opening_balance(uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_statement_period_summary: Opening Balance + Period Charges - Period
-- Payments = Closing Balance, exactly the formula in the spec. Period
-- Charges = non-void invoices ISSUED within [start, end]; Period Payments
-- = POSTED payments RECEIVED within [start, end] (voided payments never
-- reduce the balance, matching apply_payment_to_invoice()'s own posted-only
-- rollup). Closing balance necessarily reconciles to the live A/R balance
-- for that party as of period_end, because both are built from the same
-- underlying invoices/payments rows filtered the same way.
-- ---------------------------------------------------------------------------
create or replace function public.get_statement_period_summary(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_period_start date default date_trunc('month', current_date)::date,
  p_period_end date default current_date
)
returns table (opening_balance numeric, period_charges numeric, period_payments numeric, closing_balance numeric)
language sql
stable
as $$
  with charges as (
    select coalesce(sum(i.total_amount), 0) as amt
    from public.invoices i
    where i.status <> 'void'
      and i.issue_date >= p_period_start
      and i.issue_date <= p_period_end
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  pmts as (
    select coalesce(sum(p.amount), 0) as amt
    from public.payments p
    join public.invoices i on i.id = p.invoice_id
    where p.status = 'posted'
      and p.received_at::date >= p_period_start
      and p.received_at::date <= p_period_end
      and i.status <> 'void'
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  opening as (
    select public.get_statement_opening_balance(p_broker_id, p_customer_id, p_period_start - 1) as amt
  )
  select
    opening.amt,
    charges.amt,
    pmts.amt,
    opening.amt + charges.amt - pmts.amt
  from opening, charges, pmts;
$$;

grant execute on function public.get_statement_period_summary(uuid, uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_statement_transactions: the chronological ledger for a Period
-- Statement -- one row per invoice issued and per payment (posted or
-- voided) received within the window, running_balance computed as
-- opening_balance + a cumulative window sum. Voided payments are included
-- for visibility (spec section 13, "reversals must remain visible") but
-- contribute 0 to both payment_amount and the running balance -- shown
-- with is_voided=true so the UI can render "VOIDED" without them ever
-- affecting the math. Sort order is chronological with invoices before
-- same-day payments (a same-day invoice+payment reads naturally as
-- charge-then-payment), a stable secondary key on id.
-- ---------------------------------------------------------------------------
create or replace function public.get_statement_transactions(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_period_start date default date_trunc('month', current_date)::date,
  p_period_end date default current_date
)
returns table (
  txn_date date,
  txn_type text,
  reference text,
  load_id uuid,
  load_number text,
  description text,
  charge_amount numeric,
  payment_amount numeric,
  is_voided boolean,
  running_balance numeric
)
language sql
stable
as $$
  with opening as (
    select public.get_statement_opening_balance(p_broker_id, p_customer_id, p_period_start - 1) as amt
  ),
  rows as (
    select
      i.issue_date as txn_date,
      'invoice'::text as txn_type,
      i.invoice_number as reference,
      i.load_id,
      l.load_number,
      'Freight Charges'::text as description,
      i.total_amount as charge_amount,
      0::numeric as payment_amount,
      false as is_voided,
      0 as sort_order,
      i.id as tie_break
    from public.invoices i
    left join public.loads l on l.id = i.load_id
    where i.status <> 'void'
      and i.issue_date >= p_period_start
      and i.issue_date <= p_period_end
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)

    union all

    select
      p.received_at::date as txn_date,
      case when p.status = 'voided' then 'payment_void' else 'payment' end as txn_type,
      p.payment_number as reference,
      i.load_id,
      l.load_number,
      initcap(replace(p.method::text, '_', ' ')) || ' Payment' || (case when p.status = 'voided' then ' (Voided)' else '' end) as description,
      0::numeric as charge_amount,
      case when p.status = 'posted' then p.amount else 0 end as payment_amount,
      (p.status = 'voided') as is_voided,
      1 as sort_order,
      p.id as tie_break
    from public.payments p
    join public.invoices i on i.id = p.invoice_id
    left join public.loads l on l.id = i.load_id
    where i.status <> 'void'
      and p.received_at::date >= p_period_start
      and p.received_at::date <= p_period_end
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  )
  select
    rows.txn_date, rows.txn_type, rows.reference, rows.load_id, rows.load_number, rows.description,
    rows.charge_amount, rows.payment_amount, rows.is_voided,
    (select amt from opening) + sum(rows.charge_amount - rows.payment_amount)
      over (order by rows.txn_date, rows.sort_order, rows.tie_break rows between unbounded preceding and current row)
      as running_balance
  from rows
  order by rows.txn_date, rows.sort_order, rows.tie_break;
$$;

grant execute on function public.get_statement_transactions(uuid, uuid, date, date) to authenticated;
