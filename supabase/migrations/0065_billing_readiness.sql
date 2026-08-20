-- =============================================================================
-- 0065_billing_readiness.sql
-- Phase 2G: Billing Foundation -- "Ready to Bill" queue + safe invoice
-- numbering.
--
-- INSPECTION FIRST (see the Phase 2G pre-migration report for the full
-- writeup): this codebase already has a production-grade invoicing/
-- payments/AR/collections system (0006_financials.sql,
-- 0009_functions_triggers.sql, 0023_pod_workflow.sql,
-- 0026_accounts_receivable.sql, 0027_collections.sql) -- invoices,
-- invoice_line_items, payments (with payment_number, void/reversal,
-- concurrency-safe overpayment guard), invoice_status/payment_method
-- enums covering the full requested lifecycle, a DERIVED (never stored)
-- overdue status, full AR aging, and an extensive Collections module.
-- Live UI already exists at /invoices, /invoices/[id], /invoices/new,
-- /payments, /accounts-receivable, /collections.
--
-- NONE of that is duplicated here. This migration adds exactly the two
-- real gaps found:
--
-- 1. generate_invoice_number() (0009) uses `count(*) + 1` -- exactly the
--    race condition the spec warns against -- and is ALSO dead code (grep
--    confirms no app code calls it; the real invoice_number today is a
--    client-computed `count+1` suggestion typed into an editable form
--    field). Replaced with an atomic, year-scoped, per-organization
--    counter (INSERT ... ON CONFLICT DO UPDATE -- Postgres's own
--    documented safe atomic-upsert idiom, the same class of fix already
--    used for payment_number_seq in 0026), producing INV-YYYY-NNNNN.
--    invoices.invoice_number keeps its existing
--    unique (organization_id, invoice_number) constraint (0006) as the
--    final backstop; the number remains a user-editable form field
--    (unchanged UX) -- only the DEFAULT SUGGESTION now comes from this
--    safe function instead of a racy client-side count.
--
-- 2. There is no "Ready to Bill" queue anywhere -- delivered loads
--    awaiting invoicing aren't surfaced as a distinct operational view.
--    Added below, reusing get_latest_document-equivalent logic already
--    established for POD/BOL/Rate Confirmation (public.documents,
--    entity_type='load'), and load status buckets already canonicalized
--    in src/lib/loads/status.ts (COMPLETED_LOAD_STATUSES).
--
-- Billing-readiness document requirements are DELIBERATELY configurable
-- (own table, org-scoped) for Rate Confirmation/BOL, but POD stays a
-- hardcoded, always-required floor -- never read from the configurable
-- table -- so this new "ready to bill" signal can never drift out of
-- sync with the ALREADY-LIVE, unchanged DB trigger
-- check_invoice_ready_to_send() (0023), which also hard-requires a
-- verified POD and is NOT modified by this migration. Rate
-- Confirmation/BOL default to NOT required, matching exactly what's
-- enforced in production today -- this migration changes no existing
-- invoice's ability to be created or sent.
--
-- TENANT-SCOPED INVOICE NUMBER UNIQUENESS (reviewed against
-- 0006_financials.sql): `unique (organization_id, invoice_number)` already
-- exists as a table constraint on public.invoices (line 39 of 0006) --
-- Postgres backs this with a real unique index. Two organizations may
-- reuse the same number; the same organization cannot, at the database
-- level, regardless of whether the number came from generate_invoice_number()
-- below, a manual edit on the invoice form, a future import, or a bug --
-- createInvoice()/updateInvoice() (src/app/(app)/invoices/actions.ts) both
-- write invoice_number as plain user-editable text with no separate
-- application-level uniqueness check, and none is needed: the constraint
-- itself rejects the insert/update. Nothing is added or duplicated here.
--
-- REVISION PASS (this version): three corrections made after the first
-- pre-migration report --
--   1. get_ready_to_bill_loads()'s delivered gate is confirmed to be
--      loads.status alone (COMPLETED_LOAD_STATUSES), never
--      dispatches.delivered_at -- see that function's own header comment
--      for the full audit trail.
--   2. get_load_billing_readiness() now checks the SINGLE MOST RECENT pod
--      document row (matching getLatestDocument()'s exact semantics)
--      instead of "any verified pod row exists" -- and documents a real,
--      confirmed, NOT-fixed-here inconsistency with
--      check_invoice_ready_to_send() (0023), which still uses the weaker
--      "any verified row exists" rule.
--   3. generate_invoice_number() now rejects any caller who is not
--      owner/admin/accountant -- the same role set the invoices table's
--      own INSERT policy already requires (0010_rls_policies.sql) -- so a
--      role that can never create an invoice (dispatcher included) can no
--      longer consume a counter value it could never use.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- invoice_number_counters: one row per (organization, year). Touched only
-- by generate_invoice_number() below via its SECURITY DEFINER privileges
-- -- no direct client select/insert/update/delete policy, matching how
-- payment_number_seq (a raw sequence, 0026) is never exposed to
-- authenticated directly either.
-- ---------------------------------------------------------------------------
create table if not exists public.invoice_number_counters (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  year integer not null,
  last_number integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (organization_id, year)
);

alter table public.invoice_number_counters enable row level security;

-- Phase 2G.6 review: select narrowed to the same FINANCIAL_ROLES tier as
-- every other financial table (src/lib/auth/require-role.ts,
-- 0066_financial_rls_hardening.sql) -- nothing reads this table directly
-- except the SECURITY DEFINER generate_invoice_number() function above,
-- so this is belt-and-suspenders, not a functional requirement, but it
-- keeps this migration internally consistent with the hardening pass
-- rather than needing a follow-up fix for a migration that was never
-- applied yet.
drop policy if exists invoice_number_counters_select on public.invoice_number_counters;
create policy invoice_number_counters_select
  on public.invoice_number_counters for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- generate_invoice_number: atomic, year-scoped, per-organization.
-- INSERT ... ON CONFLICT DO UPDATE ... RETURNING is a single statement --
-- Postgres serializes concurrent conflicting upserts against the same
-- (organization_id, year) row internally, so two simultaneous callers for
-- the same org/year can never receive the same last_number. Different
-- organizations (or different years for the same organization) proceed
-- fully independently -- no cross-tenant contention, no shared sequence.
--
-- Role guard added after review: the `invoices` table's own INSERT RLS
-- policy (0010_rls_policies.sql, the `financial_tables` loop) already
-- restricts creating an invoice to owner/admin/accountant -- dispatcher is
-- NOT permitted to insert into invoices. This function must not hand out
-- numbers to a role that can never spend them (every call otherwise
-- consumes a counter value even when the RLS insert would then fail,
-- widening gaps for no reason and implying a permission that doesn't
-- exist). The check is placed BEFORE the counter is touched, so a
-- rejected call never mutates invoice_number_counters at all -- an
-- unauthorized call raises and rolls back, exactly like every other
-- guard_*() function in this schema (guard_payment_amount(),
-- guard_invoice_status(), guard_invoice_collector_assignment()).
-- Server code that calls this (src/app/(app)/invoices/new/page.tsx)
-- already only reads `data` from the RPC result and falls back to an
-- empty suggested number on any error, so this raises cleanly instead of
-- crashing the page for a role that hits it directly.
-- ---------------------------------------------------------------------------
create or replace function public.generate_invoice_number(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year integer := extract(year from current_date)::integer;
  v_number integer;
begin
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    raise exception 'Only owner, admin, or accountant roles can generate invoice numbers.';
  end if;

  insert into public.invoice_number_counters (organization_id, year, last_number)
  values (p_organization_id, v_year, 1)
  on conflict (organization_id, year)
  do update set last_number = invoice_number_counters.last_number + 1, updated_at = now()
  returning last_number into v_number;

  return 'INV-' || v_year || '-' || lpad(v_number::text, 5, '0');
end;
$$;

grant execute on function public.generate_invoice_number(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- billing_document_requirements: per-organization, per-document-type
-- override of whether a document is required before a load is considered
-- "Ready to Bill". Absent row = not required (the default, matching
-- today's real behavior for every document type). POD is NEVER read from
-- this table -- see the header comment on why it stays a hardcoded floor
-- in get_load_billing_readiness() below.
-- ---------------------------------------------------------------------------
create table if not exists public.billing_document_requirements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  document_type public.document_type not null,
  is_required boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, document_type)
);

create index if not exists idx_billing_document_requirements_org on public.billing_document_requirements (organization_id);

alter table public.billing_document_requirements enable row level security;

-- Phase 2G.6 review: narrowed to FINANCIAL_ROLES, same reasoning as
-- invoice_number_counters above -- this is billing configuration, not
-- something driver/viewer have a reason to read.
drop policy if exists billing_document_requirements_select on public.billing_document_requirements;
create policy billing_document_requirements_select
  on public.billing_document_requirements for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

-- Write access matches every other financial-configuration table in this
-- schema (0026/0027): owner/admin/accountant, never dispatcher/driver/
-- viewer -- configuring what blocks billing is a financial-policy
-- decision, not an operational one.
drop policy if exists billing_document_requirements_insert on public.billing_document_requirements;
create policy billing_document_requirements_insert
  on public.billing_document_requirements for insert
  with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

drop policy if exists billing_document_requirements_update on public.billing_document_requirements;
create policy billing_document_requirements_update
  on public.billing_document_requirements for update
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

drop trigger if exists set_updated_at on public.billing_document_requirements;
create trigger set_updated_at before update on public.billing_document_requirements
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- get_load_billing_readiness: the one canonical per-load readiness check,
-- reused by get_ready_to_bill_loads() below and available for the Load
-- Detail / Invoice Detail pages to call directly for a single load. NOT
-- security definer -- runs with the caller's own RLS on
-- documents/loads/billing_document_requirements, exactly like
-- get_ar_invoices()/get_collections_queue() (0026/0027), so this can
-- never see another organization's documents.
--
-- CURRENT-DOCUMENT SEMANTICS (reviewed against src/lib/documents/latest-document.ts
-- and src/lib/documents/pod-status.ts): the app-wide rule for "what is a
-- load's POD status" is ALWAYS "most recent documents row of that type
-- wins" -- getLatestDocument() orders by created_at desc limit 1 and
-- never falls back to an older verified row once a newer upload (even an
-- unverified or rejected one) exists for the same load+type. This
-- function mirrors that exactly via latest_pod below: has_verified_pod is
-- true only when the SINGLE MOST RECENT pod document row is verified, not
-- merely "a verified pod row exists somewhere in this load's history".
-- An older verified POD superseded by a newer rejected/unverified one is
-- correctly NOT current here -- same as every other POD surface (Load
-- Detail, Invoice Detail's Billing Documents panel, driver trip history,
-- dashboard alert, billing packet).
--
-- KNOWN INCONSISTENCY, NOT FIXED HERE: check_invoice_ready_to_send()
-- (0023_pod_workflow.sql), the live BEFORE UPDATE trigger that actually
-- blocks an invoice from being sent, uses the WEAKER
-- `exists (... where is_verified = true)` semantics -- i.e. "a verified
-- POD exists anywhere in this load's document history", not "the current
-- (latest) POD is verified". Concretely: load has an old verified POD,
-- then a corrected POD is uploaded and is rejected -- every UI surface in
-- this app (and this new function) would report POD as "Rejected" /
-- not ready, but check_invoice_ready_to_send() would still allow that
-- invoice to be sent, because it only ever checks "does any verified row
-- exist", never which row is current. Per instruction this trigger is
-- NOT modified in this migration. Recommended alignment strategy for a
-- future, dedicated hardening migration: replace its
-- `exists (select 1 from documents where ... is_verified = true)` body
-- with the same "order by created_at desc limit 1, check is_verified on
-- that one row" pattern used in latest_pod below, so "ready to send" and
-- "ready to bill" (and every display surface) can never disagree about
-- what a load's current POD state is again.
-- ---------------------------------------------------------------------------
create or replace function public.get_load_billing_readiness(p_load_id uuid)
returns table (
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
  with reqs as (
    select
      coalesce(bool_or(is_required) filter (where document_type = 'bol'), false) as bol_required,
      coalesce(bool_or(is_required) filter (where document_type = 'rate_confirmation'), false) as rate_confirmation_required
    from public.billing_document_requirements
    where organization_id = (select l.organization_id from public.loads l where l.id = p_load_id)
  ),
  -- One row max each -- "most recent document of this type", exactly
  -- getLatestDocument()'s own ordering. BOL/Rate Confirmation have no
  -- verified/rejected concept applied anywhere in the app today (the
  -- billing packet's supporting-docs loop includes the latest row
  -- unconditionally, see src/lib/billing-packet/generate.ts) -- presence
  -- of the latest row is the full and correct definition of "has" for
  -- those two types, matching that existing behavior exactly.
  latest_pod as (
    select is_verified
    from public.documents
    where entity_type = 'load' and entity_id = p_load_id and document_type = 'pod'
    order by created_at desc
    limit 1
  ),
  latest_bol as (
    select 1
    from public.documents
    where entity_type = 'load' and entity_id = p_load_id and document_type = 'bol'
    order by created_at desc
    limit 1
  ),
  latest_rate_confirmation as (
    select 1
    from public.documents
    where entity_type = 'load' and entity_id = p_load_id and document_type = 'rate_confirmation'
    order by created_at desc
    limit 1
  )
  select
    coalesce((select lp.is_verified from latest_pod lp), false) as has_verified_pod,
    exists (select 1 from latest_bol) as has_bol,
    reqs.bol_required,
    exists (select 1 from latest_rate_confirmation) as has_rate_confirmation,
    reqs.rate_confirmation_required,
    -- POD is an unconditional hard requirement, matching
    -- check_invoice_ready_to_send() (0023) exactly -- never gated by the
    -- configurable table.
    (coalesce((select lp.is_verified from latest_pod lp), false)
      and (not reqs.bol_required or exists (select 1 from latest_bol))
      and (not reqs.rate_confirmation_required or exists (select 1 from latest_rate_confirmation))
    ) as ready_to_bill
  from reqs;
$$;

grant execute on function public.get_load_billing_readiness(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_ready_to_bill_loads: the row source for the new /billing queue.
--
-- AUTHORITATIVE DELIVERED CONDITION (reviewed against 0004_operations.sql,
-- 0028_auto_invoice_dispatch_sync_fix.sql, src/lib/loads/status.ts, and
-- src/app/(app)/dispatch/board-actions.ts): the gate below is
-- `l.status in ('delivered', 'pod_received')` -- loads.status itself,
-- the exact COMPLETED_LOAD_STATUSES bucket already canonicalized in
-- src/lib/loads/status.ts and already used, unchanged, by /invoices/new's
-- own candidate-loads query, /loads' "missing POD" filter, and the driver
-- portal's trip history. This is deliberately the ONLY gate. It is
-- authoritative, not a guess, for two confirmed reasons:
--   1. loads.status is kept in sync automatically: dispatches_sync_load_status
--      (0028) fires AFTER UPDATE on dispatches and flips the linked load to
--      'delivered' the moment its dispatch reaches a delivered-equivalent
--      status (Dispatch Board drag-and-drop, Dispatch Detail's status
--      field) -- and that same transition is what
--      auto_generate_invoice_from_delivered_load() (0022/0028) watches to
--      immediately create a draft invoice. In practice this means most
--      delivered loads with a broker/customer on file already get
--      auto-invoiced the instant they're delivered -- this queue mostly
--      surfaces the real exceptions: loads delivered with no broker/
--      customer on file (auto-invoice trigger has nothing to bill,
--      returns early) and loads moved to 'pod_received' (a
--      post-delivery milestone the auto-invoice trigger does NOT watch).
--   2. loads.status can also be set directly and intentionally by a human
--      via the Load Detail page's own status field
--      (src/app/(app)/loads/[id]/page.tsx), independent of any dispatch
--      existing at all -- a real, legitimate path, not a bug.
-- `dispatches.delivered_at` is explicitly NOT used as a gate -- it is
-- documented in 0057 as "Operational only", is not written by the manual
-- Load Detail status path at all, and a load can be genuinely delivered
-- with zero dispatch rows (case 2 above). It is joined below (LEFT JOIN
-- latest_dispatch) purely for cosmetic display of a delivered date on
-- rows that have one; a delivered load with no dispatch row still
-- correctly appears in this queue, just with a null Delivered column --
-- never hidden for having one optional relationship missing, and never
-- surfaced for merely having documents/a rate/no invoice, none of which
-- factor into this WHERE clause at all.
--
-- Delivered-or-later loads with NO existing invoice yet -- the exact same
-- "candidate loads" definition /invoices/new already uses (status in
-- delivered/pod_received/invoiced/closed AND invoices.id is null),
-- narrowed to the two pre-invoice statuses since a load already
-- 'invoiced'/'closed' isn't awaiting billing anymore. NOT security
-- definer, same reasoning as every other get_*() reporting function in
-- this schema.
-- ---------------------------------------------------------------------------
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
    l.rate,
    r.has_verified_pod, r.has_bol, r.bol_required, r.has_rate_confirmation, r.rate_confirmation_required, r.ready_to_bill
  from public.loads l
  left join public.customers c on c.id = l.customer_id
  left join public.brokers b on b.id = l.broker_id
  left join pickup_stop ps on ps.load_id = l.id
  left join delivery_stop ds on ds.load_id = l.id
  left join latest_dispatch ld on ld.load_id = l.id
  left join public.invoices i on i.load_id = l.id
  cross join lateral public.get_load_billing_readiness(l.id) r
  where l.status in ('delivered', 'pod_received')
    and i.id is null
    -- Phase 2G.6 review: this function returns l.rate directly, and
    -- public.loads' own SELECT policy is deliberately NOT restricted by
    -- role (0066_financial_rls_hardening.sql explains why -- Operations
    -- needs every role to be able to query loads at the row level).
    -- Without this line, a driver/viewer calling this RPC directly would
    -- still get real rate data back even after that hardening migration,
    -- because this function isn't security definer and loads itself stays
    -- open. Gated here, at the one function that actually surfaces rate,
    -- rather than by touching loads' own policy.
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  order by ld.delivered_at asc nulls last, l.load_number asc;
$$;

grant execute on function public.get_ready_to_bill_loads() to authenticated;
