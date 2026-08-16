-- =============================================================================
-- 0027_collections.sql
-- Collections & Overdue Management. Builds entirely on the A/R architecture
-- from 0026_accounts_receivable.sql -- invoice_effective_status(),
-- ar_aging_bucket(), get_ar_summary(), get_ar_invoices(),
-- get_party_ar_summary() are all reused, not reimplemented. No second A/R
-- calculation system, no change to the working payment/invoice/POD/
-- billing-packet workflow (the one extension to apply_payment_to_invoice()
-- below is strictly additive -- see that section).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Collections status: a separate concept from invoices.status (financial
-- state). Lives directly on invoices as a mutable "current state" column,
-- the same way invoices.status/amount_paid/paid_at already do -- consistent
-- with this schema's existing convention rather than a new 1:1 side table.
-- Staff-driven (advanced by collections actions, not derived), except the
-- 'resolved' transition on full payment (see apply_payment_to_invoice below).
-- ---------------------------------------------------------------------------
create type public.collection_status as enum (
  'not_started', 'contacted', 'follow_up', 'promise_to_pay', 'disputed', 'escalated', 'resolved'
);

alter table public.invoices
  add column collection_status public.collection_status not null default 'not_started',
  add column assigned_collector_id uuid references public.profiles (id) on delete set null;

create index idx_invoices_collection_status on public.invoices (collection_status) where status not in ('paid', 'void');
create index idx_invoices_assigned_collector on public.invoices (assigned_collector_id) where assigned_collector_id is not null;

-- A collector must belong to the SAME organization as the invoice -- a
-- cross-org profile id must never be assignable, checked at the DB level
-- (not just by only offering same-org options in the UI dropdown).
create or replace function public.guard_invoice_collector_assignment()
returns trigger
language plpgsql
as $$
declare
  v_collector_org uuid;
begin
  if new.assigned_collector_id is not null and old.assigned_collector_id is distinct from new.assigned_collector_id then
    select organization_id into v_collector_org from public.profiles where id = new.assigned_collector_id;
    if v_collector_org is null or v_collector_org <> new.organization_id then
      raise exception 'Assigned collector must belong to the same organization as the invoice.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_guard_collector_assignment on public.invoices;
create trigger invoices_guard_collector_assignment
  before insert or update on public.invoices
  for each row execute function public.guard_invoice_collector_assignment();

-- ---------------------------------------------------------------------------
-- apply_payment_to_invoice(): ADDITIVE extension only -- every existing
-- line (amount_paid rollup, status transitions draft/void/disputed-safe,
-- sent/partially_paid/paid, paid_at) is byte-for-byte unchanged from
-- 0026_accounts_receivable.sql. The only new line sets collection_status
-- to 'resolved' once an invoice becomes fully paid, satisfying "a paid
-- invoice leaves the active collection queue" (the queue itself already
-- excludes paid/void invoices via get_ar_invoices()'s own filter, this
-- just keeps the visible collection_status label in sync too). Never
-- touches collection_status in any other case -- an escalated/disputed
-- invoice that receives a partial payment keeps its collection_status
-- exactly as collectors left it.
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
    return null;
  end if;

  update public.invoices
  set amount_paid = v_total_paid,
      status = case
        when v_current_status in ('draft', 'void', 'disputed') then v_current_status
        when v_total_paid <= 0 then 'sent'
        when v_invoice_total > 0 and v_total_paid >= v_invoice_total then 'paid'
        else 'partially_paid'
      end,
      paid_at = case when v_invoice_total > 0 and v_total_paid >= v_invoice_total then now() else null end,
      collection_status = case
        when v_invoice_total > 0 and v_total_paid >= v_invoice_total then 'resolved'::public.collection_status
        else collection_status
      end
  where id = v_invoice_id;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- invoice_collection_activity: the contact log / collection notes (spec
-- sections 4 and 5 are the same data from two angles -- one table serves
-- both). Append-only: no update/delete RLS policy is granted at all, the
-- same pattern activity_logs already uses (0007/0010) for an audit trail
-- that must never be edited from the client, not just "append-only by UI
-- convention".
-- ---------------------------------------------------------------------------
create type public.collection_contact_method as enum ('phone', 'email', 'sms', 'portal', 'other');

create table public.invoice_collection_activity (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  contact_method public.collection_contact_method not null default 'other',
  contact_name text,
  note text not null,
  next_follow_up_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create index idx_collection_activity_invoice on public.invoice_collection_activity (invoice_id, created_at desc);
create index idx_collection_activity_org on public.invoice_collection_activity (organization_id);
create index idx_collection_activity_followup on public.invoice_collection_activity (next_follow_up_at) where next_follow_up_at is not null;

alter table public.invoice_collection_activity enable row level security;

create policy invoice_collection_activity_select on public.invoice_collection_activity
  for select using (organization_id = public.current_org_id());

create policy invoice_collection_activity_insert on public.invoice_collection_activity
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- payment_promises: status column stores ONLY the two states a human
-- actually decides ('open' at creation, 'cancelled' if a collector calls
-- it off) -- kept/partially_kept/broken are derived on every read by
-- promise_effective_status(), never stored, so they can never go stale.
-- Documented rule (mirrors the exact worked examples in the spec):
--   1. status = 'cancelled'                          -> cancelled
--   2. applied_amount >= promised_amount              -> kept
--   3. expected_payment_date < as_of                  -> broken
--      (covers both zero AND partial payment once the expected date has
--      passed -- a partial payment does not protect a promise past its date)
--   4. applied_amount > 0 (and not yet past due)       -> partially_kept
--   5. otherwise                                       -> open
-- applied_amount = payment_promise_applied_amount() below: posted payments
-- on the invoice received ON OR AFTER promise_date, capped at
-- promised_amount -- payments that predate the promise never count toward
-- it (a promise can't be "kept" by money that arrived before it existed),
-- and a promise can never show more applied than it asked for.
-- ---------------------------------------------------------------------------
create type public.payment_promise_status as enum ('open', 'kept', 'partially_kept', 'broken', 'cancelled');

create table public.payment_promises (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  promised_amount numeric(10, 2) not null check (promised_amount > 0),
  promise_date date not null default current_date,
  expected_payment_date date not null,
  contact_person text,
  notes text,
  status public.payment_promise_status not null default 'open' check (status in ('open', 'cancelled')),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_by uuid references public.profiles (id) on delete set null,
  cancelled_at timestamptz,
  cancelled_reason text
);

create index idx_payment_promises_invoice on public.payment_promises (invoice_id, created_at desc);
create index idx_payment_promises_org on public.payment_promises (organization_id);
create index idx_payment_promises_expected_date on public.payment_promises (expected_payment_date);

alter table public.payment_promises enable row level security;

create policy payment_promises_select on public.payment_promises
  for select using (organization_id = public.current_org_id());

create policy payment_promises_insert on public.payment_promises
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- update: the only mutation ever performed is cancellation (status ->
-- 'cancelled' + cancelled_by/at/reason) -- promised_amount/expected date/
-- promise_date are never edited in place, matching "avoid hard-delete /
-- avoid silently overwriting collection history". No delete policy.
create policy payment_promises_update on public.payment_promises
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

drop trigger if exists set_updated_at on public.payment_promises;
create trigger set_updated_at before update on public.payment_promises
  for each row execute function public.set_updated_at();

create or replace function public.payment_promise_applied_amount(
  p_invoice_id uuid,
  p_promise_date date,
  p_promised_amount numeric
) returns numeric
language sql
stable
as $$
  select least(
    coalesce(
      (select sum(amount) from public.payments
       where invoice_id = p_invoice_id
         and status = 'posted'
         and received_at >= p_promise_date::timestamptz),
      0
    ),
    p_promised_amount
  );
$$;

grant execute on function public.payment_promise_applied_amount(uuid, date, numeric) to authenticated;

create or replace function public.promise_effective_status(
  p_status public.payment_promise_status,
  p_applied_amount numeric,
  p_promised_amount numeric,
  p_expected_payment_date date,
  p_as_of date default current_date
) returns public.payment_promise_status
language sql
stable
as $$
  select case
    when p_status = 'cancelled' then 'cancelled'::public.payment_promise_status
    when p_applied_amount >= p_promised_amount then 'kept'::public.payment_promise_status
    when p_expected_payment_date < p_as_of then 'broken'::public.payment_promise_status
    when p_applied_amount > 0 then 'partially_kept'::public.payment_promise_status
    else 'open'::public.payment_promise_status
  end;
$$;

grant execute on function public.promise_effective_status(public.payment_promise_status, numeric, numeric, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- invoice_disputes: multiple rows per invoice are allowed over time (a
-- dispute can be reopened) -- "current" disputed amount is the sum of
-- still-open ones (status in open/under_review), computed inline wherever
-- needed, never a separately-maintained running total that could drift.
-- Resolution is an UPDATE to the SAME row (status/resolved_at/resolved_by/
-- resolution), not a delete -- the full history of what was disputed, why,
-- and how it was resolved stays on that one row permanently.
-- ---------------------------------------------------------------------------
create type public.invoice_dispute_status as enum ('open', 'under_review', 'resolved', 'rejected');
create type public.invoice_dispute_reason as enum (
  'rate_discrepancy', 'missing_pod', 'missing_rate_confirmation', 'lumper', 'detention',
  'shortage', 'damage', 'late_delivery', 'duplicate_invoice', 'billing_error', 'other'
);

create table public.invoice_disputes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  status public.invoice_dispute_status not null default 'open',
  reason public.invoice_dispute_reason not null default 'other',
  disputed_amount numeric(10, 2) not null check (disputed_amount > 0),
  broker_contact text,
  notes text,
  opened_by uuid references public.profiles (id) on delete set null,
  opened_at timestamptz not null default now(),
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  resolution text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_invoice_disputes_invoice on public.invoice_disputes (invoice_id, created_at desc);
create index idx_invoice_disputes_org on public.invoice_disputes (organization_id);
create index idx_invoice_disputes_status on public.invoice_disputes (status);

alter table public.invoice_disputes enable row level security;

create policy invoice_disputes_select on public.invoice_disputes
  for select using (organization_id = public.current_org_id());

create policy invoice_disputes_insert on public.invoice_disputes
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy invoice_disputes_update on public.invoice_disputes
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

drop trigger if exists set_updated_at on public.invoice_disputes;
create trigger set_updated_at before update on public.invoice_disputes
  for each row execute function public.set_updated_at();

-- Per-invoice dispute totals, reused by get_collections_queue() and the
-- Invoice Detail Collections section so "Total Balance / Disputed /
-- Undisputed" is computed identically everywhere.
create or replace function public.invoice_dispute_summary(p_invoice_id uuid)
returns table (disputed_amount numeric, dispute_status public.invoice_dispute_status)
language sql
stable
as $$
  select
    coalesce((select sum(disputed_amount) from public.invoice_disputes
              where invoice_id = p_invoice_id and status in ('open', 'under_review')), 0),
    (select status from public.invoice_disputes
     where invoice_id = p_invoice_id order by created_at desc limit 1);
$$;

grant execute on function public.invoice_dispute_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- invoice_reminders: state/history for reminder stages. No email provider
-- exists in this project (confirmed in 0024/billing-packet-actions.ts) --
-- rows are created in 'pending' and the send action attempts + records the
-- real outcome, exactly like sendBillingPacket()'s honest-failure pattern.
-- Nothing here ever marks a reminder 'sent' without an actual provider
-- succeeding. No unique constraint on (invoice_id, stage) -- that would
-- make an intentional, staff-requested resend impossible; the app layer
-- checks for an existing non-failed row first and requires an explicit
-- resend confirmation instead (see queueReminder in collections/actions.ts).
-- ---------------------------------------------------------------------------
create type public.invoice_reminder_stage as enum (
  'before_due', 'due_today', 'overdue_7', 'overdue_15', 'overdue_30', 'overdue_60', 'overdue_90_plus'
);
create type public.invoice_reminder_status as enum ('pending', 'sent', 'failed');

create table public.invoice_reminders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  stage public.invoice_reminder_stage not null,
  recipient_email text,
  status public.invoice_reminder_status not null default 'pending',
  error_message text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create index idx_invoice_reminders_invoice on public.invoice_reminders (invoice_id, created_at desc);
create index idx_invoice_reminders_org on public.invoice_reminders (organization_id);

alter table public.invoice_reminders enable row level security;

create policy invoice_reminders_select on public.invoice_reminders
  for select using (organization_id = public.current_org_id());

create policy invoice_reminders_insert on public.invoice_reminders
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy invoice_reminders_update on public.invoice_reminders
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- Which stage an invoice is currently at, purely for display/reminder-
-- eligibility purposes -- independent of whether any reminder has actually
-- been sent for it. "Highest milestone reached" (descending threshold
-- checks), the same style ar_aging_bucket()/invoice_collection_priority()
-- already use -- not equal-width ranges. Days 1-6 overdue haven't reached
-- any named milestone yet (the stages are exactly before_due/due_today/7/
-- 15/30/60/90+, nothing named for 1-6) so they stay at 'due_today', the
-- last milestone actually reached, rather than being awkwardly folded into
-- the 7-day stage before day 7 has actually arrived.
create or replace function public.invoice_reminder_stage_for(p_due_date date, p_as_of date default current_date)
returns public.invoice_reminder_stage
language sql
stable
as $$
  select case
    when p_due_date is null or p_due_date > p_as_of then 'before_due'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 90 then 'overdue_90_plus'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 60 then 'overdue_60'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 30 then 'overdue_30'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 15 then 'overdue_15'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 7 then 'overdue_7'::public.invoice_reminder_stage
    else 'due_today'::public.invoice_reminder_stage
  end;
$$;

grant execute on function public.invoice_reminder_stage_for(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- invoice_collection_priority: ONE deterministic function, used by
-- get_collections_queue() below and nowhere else recomputes it -- so the
-- Collections queue and any future consumer (e.g. the Dashboard alert)
-- can never disagree. IMMUTABLE: a pure function of its two inputs, no
-- current_date/table access inside it.
--
-- Formula (documented, not tunable from the UI):
--   URGENT : an active promise is BROKEN, OR 90+ days past due
--   HIGH   : 61-89 days past due
--   NORMAL : 1-60 days past due
--   LOW    : not yet due (current)
-- This intentionally mirrors the exact priority-group ordering the spec
-- asks the queue to sort by. Balance size and invoice age are NOT folded
-- into the tier itself -- they're the documented tie-breaker used only to
-- order rows *within* a tier (largest balance / oldest first), matching
-- "within a priority group, prefer larger balances/older invoices" instead
-- of secretly bumping a tier for a big balance. Disputes and contact
-- recency are deliberately NOT folded into the tier either: a disputed
-- invoice isn't necessarily "more urgent to collect" (it may need to PAUSE
-- pressure, not increase it) -- dispute_status and last_contact_at are
-- surfaced as their own queue columns/filters instead of being silently
-- baked into this score.
-- ---------------------------------------------------------------------------
create or replace function public.invoice_collection_priority(
  p_promise_effective_status public.payment_promise_status,
  p_days_past_due integer
) returns text
language sql
immutable
as $$
  select case
    when p_promise_effective_status = 'broken' then 'urgent'
    when p_days_past_due >= 90 then 'urgent'
    when p_days_past_due >= 61 then 'high'
    when p_days_past_due >= 1 then 'normal'
    else 'low'
  end;
$$;

grant execute on function public.invoice_collection_priority(public.payment_promise_status, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- broker_payment_risk: an explicitly INTERNAL, operational signal computed
-- only from this org's own payment history -- never call this a credit
-- score/rating anywhere in the UI (no external credit bureau is involved).
-- Documented formula (score 0-8, thresholds below):
--   +2 avg days to pay > 45          | +1 avg days to pay > 30
--   +1 has any past-due balance
--   +2 has any 90+ day balance
--   +2 has any BROKEN promise (ever, via promise_effective_status())
--   +1 has any OPEN/UNDER_REVIEW dispute
--   score >= 4 -> HIGH, score >= 2 -> MEDIUM, else LOW
-- Reuses get_party_ar_summary() for avg_days_to_pay/past_due rather than
-- recomputing them -- same single A/R source as everywhere else.
-- ---------------------------------------------------------------------------
create or replace function public.broker_payment_risk(p_broker_id uuid)
returns text
language sql
stable
as $$
  with party as (
    select * from public.get_party_ar_summary(p_broker_id, null)
  ),
  bal_90 as (
    select coalesce(sum(i.balance_due), 0) as amt
    from public.invoices i
    where i.broker_id = p_broker_id
      and i.status not in ('paid', 'void')
      and i.balance_due > 0
      and public.ar_aging_bucket(i.due_date) = '90_plus'
  ),
  broken as (
    select count(*) as cnt
    from public.payment_promises pp
    join public.invoices i on i.id = pp.invoice_id
    where i.broker_id = p_broker_id
      and public.promise_effective_status(
            pp.status,
            public.payment_promise_applied_amount(pp.invoice_id, pp.promise_date, pp.promised_amount),
            pp.promised_amount, pp.expected_payment_date
          ) = 'broken'
  ),
  disputes as (
    select count(*) as cnt
    from public.invoice_disputes d
    join public.invoices i on i.id = d.invoice_id
    where i.broker_id = p_broker_id and d.status in ('open', 'under_review')
  )
  select case
    when score >= 4 then 'high'
    when score >= 2 then 'medium'
    else 'low'
  end
  from (
    select
      (case when party.avg_days_to_pay > 45 then 2 when party.avg_days_to_pay > 30 then 1 else 0 end)
      + (case when party.past_due > 0 then 1 else 0 end)
      + (case when bal_90.amt > 0 then 2 else 0 end)
      + (case when broken.cnt > 0 then 2 else 0 end)
      + (case when disputes.cnt > 0 then 1 else 0 end)
      as score
    from party, bal_90, broken, disputes
  ) scored;
$$;

grant execute on function public.broker_payment_risk(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_collections_queue: THE canonical query for both the Collections
-- queue table and the Invoice Detail Collections section (pass p_invoice_id
-- to get exactly one row, status included, for a paid/void invoice too --
-- the queue-mode paid/void exclusion only applies when p_invoice_id is
-- null). Deliberately NOT security definer, same reasoning as
-- get_ar_invoices() -- runs with the caller's own RLS, so this can never
-- see another organization's collections data. Reuses
-- invoice_effective_status()/ar_aging_bucket() from 0026 rather than
-- recomputing balance/aging logic.
-- ---------------------------------------------------------------------------
create or replace function public.get_collections_queue(
  p_invoice_id uuid default null,
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_collector_id uuid default null,
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
  days_past_due integer,
  collection_status public.collection_status,
  assigned_collector_id uuid,
  assigned_collector_name text,
  last_contact_at timestamptz,
  last_contact_method public.collection_contact_method,
  next_follow_up_at timestamptz,
  promise_id uuid,
  promise_amount numeric,
  promise_expected_date date,
  promise_effective_status public.payment_promise_status,
  dispute_status public.invoice_dispute_status,
  disputed_amount numeric,
  undisputed_amount numeric,
  priority text
)
language sql
stable
as $$
  with base as (
    select i.*, l.load_number, b.company_name as broker_name, c.company_name as customer_name
    from public.invoices i
    left join public.loads l on l.id = i.load_id
    left join public.brokers b on b.id = i.broker_id
    left join public.customers c on c.id = i.customer_id
    where (p_invoice_id is null or i.id = p_invoice_id)
      and (p_invoice_id is not null or i.status not in ('paid', 'void'))
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
      and (p_collector_id is null or i.assigned_collector_id = p_collector_id)
  ),
  latest_activity as (
    select distinct on (invoice_id) invoice_id, contact_method, created_at, next_follow_up_at
    from public.invoice_collection_activity
    order by invoice_id, created_at desc
  ),
  latest_promise as (
    select distinct on (invoice_id) *
    from public.payment_promises
    order by invoice_id, created_at desc
  ),
  latest_dispute as (
    select distinct on (invoice_id) invoice_id, status
    from public.invoice_disputes
    order by invoice_id, created_at desc
  ),
  dispute_totals as (
    select invoice_id, sum(disputed_amount) as disputed_amount
    from public.invoice_disputes
    where status in ('open', 'under_review')
    group by invoice_id
  ),
  rows as (
    select
      base.id, base.invoice_number, base.load_id, base.load_number,
      base.broker_id, base.broker_name, base.customer_id, base.customer_name,
      base.bill_to_name, base.issue_date, base.due_date,
      base.total_amount, base.amount_paid, base.balance_due,
      base.status,
      public.invoice_effective_status(base.status, base.due_date, base.balance_due, p_as_of_date) as effective_status,
      public.ar_aging_bucket(base.due_date, p_as_of_date) as aging_bucket,
      (case when base.due_date is not null and base.due_date < p_as_of_date then (p_as_of_date - base.due_date) else 0 end) as days_past_due,
      base.collection_status,
      base.assigned_collector_id,
      prof.full_name as assigned_collector_name,
      la.created_at as last_contact_at,
      la.contact_method as last_contact_method,
      la.next_follow_up_at,
      lp.id as promise_id,
      lp.promised_amount as promise_amount,
      lp.expected_payment_date as promise_expected_date,
      (case when lp.id is null then null else
        public.promise_effective_status(
          lp.status,
          public.payment_promise_applied_amount(lp.invoice_id, lp.promise_date, lp.promised_amount),
          lp.promised_amount, lp.expected_payment_date, p_as_of_date
        )
      end) as promise_effective_status,
      ld.status as dispute_status,
      coalesce(dt.disputed_amount, 0) as disputed_amount,
      base.balance_due - coalesce(dt.disputed_amount, 0) as undisputed_amount
    from base
    left join public.profiles prof on prof.id = base.assigned_collector_id
    left join latest_activity la on la.invoice_id = base.id
    left join latest_promise lp on lp.invoice_id = base.id
    left join latest_dispute ld on ld.invoice_id = base.id
    left join dispute_totals dt on dt.invoice_id = base.id
  )
  select rows.*, public.invoice_collection_priority(rows.promise_effective_status, rows.days_past_due) as priority
  from rows
  -- Six-way sort group, finer-grained than the 4-tier priority column
  -- above (broken promises are pulled out ahead of plain 90+ overdue, and
  -- current-tier is additionally split into 1-30/due-soon) -- matching
  -- the exact ordering the spec lists for the queue's default sort.
  order by
    case
      when rows.promise_effective_status = 'broken' then 0
      when rows.aging_bucket = '90_plus' then 1
      when rows.aging_bucket = '61_90' then 2
      when rows.aging_bucket = '31_60' then 3
      when rows.aging_bucket = '1_30' then 4
      else 5
    end,
    rows.balance_due desc,
    rows.days_past_due desc;
$$;

grant execute on function public.get_collections_queue(uuid, uuid, uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_collections_summary: Collections dashboard KPIs. Reuses
-- get_ar_summary() (overdue amount/count, collected this month) and
-- get_party_ar_summary() (org-wide avg days to pay, via null/null) rather
-- than recomputing either -- only due_this_week/promises_due/
-- disputed_amount are genuinely new aggregates.
-- ---------------------------------------------------------------------------
create or replace function public.get_collections_summary(p_as_of_date date default current_date)
returns table (
  total_overdue numeric,
  overdue_invoices bigint,
  due_this_week numeric,
  promises_due bigint,
  disputed_amount numeric,
  collected_this_month numeric,
  avg_days_to_pay numeric
)
language sql
stable
as $$
  with ar as (
    select * from public.get_ar_summary(null, null, p_as_of_date)
  ),
  party as (
    select * from public.get_party_ar_summary(null, null)
  ),
  due_week as (
    select coalesce(sum(i.balance_due), 0) as amt
    from public.invoices i
    where i.status not in ('paid', 'void')
      and i.balance_due > 0
      and i.due_date is not null
      and i.due_date >= p_as_of_date
      and i.due_date <= p_as_of_date + 7
  ),
  promises_due as (
    select count(*) as cnt
    from public.payment_promises pp
    where pp.expected_payment_date <= p_as_of_date + 7
      and public.promise_effective_status(
            pp.status,
            public.payment_promise_applied_amount(pp.invoice_id, pp.promise_date, pp.promised_amount),
            pp.promised_amount, pp.expected_payment_date, p_as_of_date
          ) = 'open'
  ),
  disputes as (
    select coalesce(sum(disputed_amount), 0) as amt
    from public.invoice_disputes
    where status in ('open', 'under_review')
  )
  select ar.overdue_amount, ar.overdue_invoice_count, due_week.amt, promises_due.cnt, disputes.amt, ar.collected_this_month, party.avg_days_to_pay
  from ar, party, due_week, promises_due, disputes;
$$;

grant execute on function public.get_collections_summary(date) to authenticated;
