-- =============================================================================
-- 0118_quickbooks_payment_imports.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- QuickBooks Online "payment sync" MVP (SANDBOX phase).
-- Adds ONE table: quickbooks_payment_imports -- durable provenance +
-- HARD idempotency for QuickBooks Payments that an owner/admin explicitly
-- imports against an already-synced local invoice.
--
-- WHY A NEW TABLE (audited, not assumed):
--   public.payments (0006 + 0026) has NO column that could carry a QBO
--   Payment id / QBO invoice id / "source = quickbooks", and therefore no
--   way to express a UNIQUE database constraint that stops the same QBO
--   payment allocation being imported twice. UI logic alone is not
--   acceptable per spec. So provenance + the hard duplicate guard live
--   here, alongside payments, exactly the way quickbooks_invoice_syncs
--   (0117) lives alongside invoices. The imported payment itself is still
--   a perfectly ordinary row in public.payments, created through the
--   existing authoritative path (INSERT -> guard_payment_amount() ->
--   apply_payment_to_invoice()); this table only records that it came
--   from QuickBooks and which QBO transaction it corresponds to.
--
-- MULTI-INVOICE PAYMENTS: a single QBO Payment can be split across many
-- invoices. We NEVER import Payment.TotalAmt. applied_amount is the amount
-- QuickBooks applied to THIS invoice (the sum of that Payment's Line
-- Amounts whose LinkedTxn is this QBO invoice). The idempotency key is
-- (organization_id, quickbooks_payment_id, quickbooks_invoice_id) -- one
-- QBO payment's allocation to one QBO invoice, per org, is importable
-- exactly once. quickbooks_invoice_id (not local_invoice_id) is in the key
-- on purpose: it is the QBO side's stable allocation identity, and it maps
-- 1:1 to a local invoice via quickbooks_invoice_syncs. Adding
-- local_invoice_id to the key would WEAKEN it (it would let the same QBO
-- allocation be imported against two different local invoices).
--
-- These rows hold QuickBooks IDs, a date, a reference string, a method
-- label, and local FK ids -- NO token, NO secret, NO encrypted value.
-- owner/admin RLS covers SELECT/INSERT/UPDATE directly (same shape as
-- 0117). No DELETE policy. service_role keeps its normal access.
--
-- Does not modify public.payments, public.invoices, 0117, 0116, or 0115.
-- Does not add automatic import, polling, webhooks, refunds, or reversals.
-- =============================================================================

create table public.quickbooks_payment_imports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,

  -- QuickBooks side (opaque strings, NOT credentials).
  quickbooks_payment_id text not null check (btrim(quickbooks_payment_id) <> ''),
  quickbooks_invoice_id text not null check (btrim(quickbooks_invoice_id) <> ''),

  -- Local side.
  local_invoice_id uuid not null references public.invoices (id) on delete cascade,
  -- Nullable so the row can be inserted as a claim/lock BEFORE the
  -- public.payments row exists (mirrors the pending-row lock in
  -- quickbooks_invoice_syncs, 0117). Once import_state = 'imported' it
  -- must be set -- see quickbooks_payment_imports_imported_shape.
  local_payment_id uuid references public.payments (id) on delete set null,

  -- The amount QuickBooks applied to THIS invoice (never Payment.TotalAmt).
  applied_amount numeric(10, 2) not null check (applied_amount > 0),

  -- Non-secret QBO metadata, snapshotted at import time for the receipt.
  quickbooks_txn_date date,
  quickbooks_reference text,
  quickbooks_payment_method text,

  import_state text not null default 'pending'
    check (import_state in ('pending', 'imported', 'failed')),
  -- Set by the READ-ONLY "Refresh QuickBooks Status" action when a
  -- previously-imported QBO payment later looks voided / deleted /
  -- materially changed / re-allocated. Never triggers an automatic
  -- reversal -- it only surfaces "Reconciliation required" and is logged.
  reconciliation_state text not null default 'ok'
    check (reconciliation_state in ('ok', 'reconciliation_required')),
  reconciliation_detail text,
  last_error text,
  last_verified_at timestamptz,

  imported_by uuid references public.profiles (id) on delete set null,
  imported_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- HARD duplicate guard (spec: DB UNIQUE, not UI logic).
  constraint quickbooks_payment_imports_alloc_unique
    unique (organization_id, quickbooks_payment_id, quickbooks_invoice_id),
  -- One local payment row corresponds to exactly one QBO import.
  -- (Multiple NULLs are allowed by SQL -- only real payment ids collide.)
  constraint quickbooks_payment_imports_local_payment_unique
    unique (local_payment_id),
  -- A completed import must point at the local payment it created.
  constraint quickbooks_payment_imports_imported_shape
    check (import_state <> 'imported' or local_payment_id is not null)
);

comment on table public.quickbooks_payment_imports is
  'Durable, tenant-scoped provenance + idempotency for QuickBooks Payments explicitly imported into Truck Dispatch Pro. One row per (org, QBO payment, QBO invoice) allocation. applied_amount is what QuickBooks applied to THIS invoice, never Payment.TotalAmt. Stores QuickBooks IDs + non-secret metadata only -- never a token. The imported payment lives in public.payments and is rolled up by apply_payment_to_invoice() exactly like any other payment.';

create index quickbooks_payment_imports_org_idx
  on public.quickbooks_payment_imports (organization_id);
create index quickbooks_payment_imports_invoice_idx
  on public.quickbooks_payment_imports (organization_id, local_invoice_id);

drop trigger if exists set_updated_at on public.quickbooks_payment_imports;
create trigger set_updated_at before update on public.quickbooks_payment_imports
  for each row execute function public.set_updated_at();

alter table public.quickbooks_payment_imports enable row level security;

create policy quickbooks_payment_imports_select on public.quickbooks_payment_imports
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
create policy quickbooks_payment_imports_insert on public.quickbooks_payment_imports
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
create policy quickbooks_payment_imports_update on public.quickbooks_payment_imports
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
-- No delete policy: an import is corrected via reconciliation_state /
-- void of the underlying payment, never silently removed.

-- Explicit table privileges (Supabase default privileges would otherwise
-- grant ALL -- incl. DELETE -- to anon + authenticated). Same shape as
-- 0117. RLS above still restricts every authenticated row to the current
-- org's owner/admin. service_role is deliberately untouched.
revoke all on public.quickbooks_payment_imports from public, anon, authenticated;
grant select, insert, update on public.quickbooks_payment_imports to authenticated;
-- No DELETE grant to authenticated; anon + public get nothing.

-- Same-org FK guard for the polymorphic-ish local links. Mirrors
-- guard_quickbooks_customer_mapping() / guard_quickbooks_invoice_sync()
-- (0117). Also enforces that the linked payment actually belongs to the
-- linked invoice -- so a row can never claim a payment that was applied
-- to some other invoice.
create or replace function public.guard_quickbooks_payment_import()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (
    select 1 from public.invoices i
    where i.id = new.local_invoice_id and i.organization_id = new.organization_id
  ) then
    raise exception 'Imported payment references an invoice that does not exist in this organization.';
  end if;

  if new.local_payment_id is not null then
    if not exists (
      select 1 from public.payments p
      where p.id = new.local_payment_id
        and p.organization_id = new.organization_id
        and p.invoice_id = new.local_invoice_id
    ) then
      raise exception 'Imported payment must link to a payment on the same invoice in this organization.';
    end if;
  end if;

  return new;
end;
$$;

create trigger quickbooks_payment_imports_guard
  before insert or update on public.quickbooks_payment_imports
  for each row execute function public.guard_quickbooks_payment_import();

revoke execute on function public.guard_quickbooks_payment_import() from public, anon, authenticated;
