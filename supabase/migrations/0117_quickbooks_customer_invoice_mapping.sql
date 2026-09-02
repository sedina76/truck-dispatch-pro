-- =============================================================================
-- 0117_quickbooks_customer_invoice_mapping.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- QuickBooks Online "customer mapping + invoice send" MVP (SANDBOX phase).
-- Adds ONLY the durable, tenant-scoped mapping/idempotency tables:
--   * quickbooks_customer_mappings -- one local customer/broker  <->  one QBO Customer
--   * quickbooks_invoice_syncs     -- one local invoice          <->  at most one QBO Invoice
--
-- These rows hold QuickBooks IDs and non-secret display metadata ONLY --
-- never a token, never an encrypted value. Unlike quickbooks_connections
-- (0116) there is nothing sensitive here, so owner/admin RLS covers
-- SELECT/INSERT/UPDATE directly (same shape as integration_settings, 0008/
-- 0010) -- no service_role-only RPC is needed. All writes still happen from
-- trusted server actions that resolve organization_id from the
-- authenticated session; the RLS `with check (organization_id =
-- current_org_id())` is the backstop.
--
-- The QuickBooks service Item id ("Freight Transportation") is stored per
-- org in the EXISTING integration_settings.config jsonb (0008) -- no new
-- column. See src/lib/integrations/providers/quickbooks.ts for the
-- find-or-create-one-item strategy.
--
-- Nothing here modifies an existing table's data or an existing function.
-- Does not touch 0116 or 0115.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PART 1 -- quickbooks_customer_mappings
-- One row per (organization, local receivable entity). local_entity_type is
-- 'customer' or 'broker' -- the two distinct receivable-party concepts an
-- invoice can carry (public.invoices.customer_id / broker_id). A local
-- entity maps to exactly one QBO Customer, and a QBO Customer is claimed by
-- exactly one local entity within the org.
-- -----------------------------------------------------------------------------
create table public.quickbooks_customer_mappings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  local_entity_type text not null check (local_entity_type in ('customer', 'broker')),
  local_entity_id uuid not null,
  -- QuickBooks Customer.Id (opaque string, NOT a credential).
  quickbooks_customer_id text not null check (btrim(quickbooks_customer_id) <> ''),
  -- QuickBooks Customer.DisplayName at map time -- non-secret, for the UI.
  quickbooks_display_name text,
  -- QuickBooks row-version token for safe future updates (optimistic
  -- concurrency on the QBO side). Non-secret.
  quickbooks_sync_token text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- One QBO customer per local entity.
  constraint quickbooks_customer_mappings_local_unique unique (organization_id, local_entity_type, local_entity_id),
  -- One local entity per QBO customer (no accidental fan-in within an org).
  constraint quickbooks_customer_mappings_qbo_unique unique (organization_id, quickbooks_customer_id)
);

comment on table public.quickbooks_customer_mappings is
  'Durable, tenant-scoped map between a Truck Dispatch Pro receivable entity (customers or brokers) and a QuickBooks Online Customer. Stores QuickBooks IDs + display metadata only -- never a token. Truck Dispatch Pro stays authoritative for operations; QuickBooks stays authoritative for the accounting customer record.';

create index quickbooks_customer_mappings_org_idx on public.quickbooks_customer_mappings (organization_id);
create index quickbooks_customer_mappings_entity_idx on public.quickbooks_customer_mappings (organization_id, local_entity_type, local_entity_id);

drop trigger if exists set_updated_at on public.quickbooks_customer_mappings;
create trigger set_updated_at before update on public.quickbooks_customer_mappings
  for each row execute function public.set_updated_at();

alter table public.quickbooks_customer_mappings enable row level security;

create policy quickbooks_customer_mappings_select on public.quickbooks_customer_mappings
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
create policy quickbooks_customer_mappings_insert on public.quickbooks_customer_mappings
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
create policy quickbooks_customer_mappings_update on public.quickbooks_customer_mappings
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());
-- No delete policy: a mapping is corrected via update, never silently removed.

-- Polymorphic FK guard: local_entity_id must be a real customers/brokers
-- row in the SAME organization. Mirrors guard_document_carrier_link()
-- (0095) / guard_broker_document_link() (0094).
create or replace function public.guard_quickbooks_customer_mapping()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.local_entity_type = 'customer' then
    if not exists (select 1 from public.customers c where c.id = new.local_entity_id and c.organization_id = new.organization_id) then
      raise exception 'Mapped customer does not exist in this organization.';
    end if;
  elsif new.local_entity_type = 'broker' then
    if not exists (select 1 from public.brokers b where b.id = new.local_entity_id and b.organization_id = new.organization_id) then
      raise exception 'Mapped broker does not exist in this organization.';
    end if;
  end if;
  return new;
end;
$$;

create trigger quickbooks_customer_mappings_guard
  before insert or update on public.quickbooks_customer_mappings
  for each row execute function public.guard_quickbooks_customer_mapping();

-- -----------------------------------------------------------------------------
-- PART 2 -- quickbooks_invoice_syncs
-- One row per local invoice. The UNIQUE(invoice_id) is the hard guarantee
-- that one Truck Dispatch Pro invoice can never spawn two QuickBooks
-- invoices: the send action INSERTs a 'pending' row first (the lock); a
-- concurrent/second click hits 23505, re-reads this row, and returns its
-- state instead of POSTing again.
-- -----------------------------------------------------------------------------
create table public.quickbooks_invoice_syncs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  -- QuickBooks Invoice.Id / DocNumber / SyncToken -- opaque, non-secret.
  quickbooks_invoice_id text,
  quickbooks_doc_number text,
  quickbooks_sync_token text,
  sync_status text not null default 'pending' check (sync_status in ('pending', 'synced', 'failed')),
  -- Idempotency marker: sha-256 of the normalized payload we would POST.
  -- Lets a retry detect "nothing changed" vs "content drifted".
  payload_hash text,
  last_synced_at timestamptz,
  last_error_code text,
  last_error_message text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- THE duplicate-prevention constraint.
  constraint quickbooks_invoice_syncs_invoice_unique unique (invoice_id),
  -- A synced row must carry the QBO id.
  constraint quickbooks_invoice_syncs_synced_shape check (sync_status <> 'synced' or quickbooks_invoice_id is not null)
);

comment on table public.quickbooks_invoice_syncs is
  'Durable, tenant-scoped sync state for exporting a Truck Dispatch Pro invoice to QuickBooks Online. UNIQUE(invoice_id) guarantees one local invoice -> at most one QBO invoice. Stores QuickBooks IDs + status/error only -- never a token. Payment reconciliation and automatic sync are later phases; this MVP is a manual, one-way invoice create.';

create index quickbooks_invoice_syncs_org_idx on public.quickbooks_invoice_syncs (organization_id);
create index quickbooks_invoice_syncs_status_idx on public.quickbooks_invoice_syncs (organization_id, sync_status);

drop trigger if exists set_updated_at on public.quickbooks_invoice_syncs;
create trigger set_updated_at before update on public.quickbooks_invoice_syncs
  for each row execute function public.set_updated_at();

alter table public.quickbooks_invoice_syncs enable row level security;

create policy quickbooks_invoice_syncs_select on public.quickbooks_invoice_syncs
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
create policy quickbooks_invoice_syncs_insert on public.quickbooks_invoice_syncs
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
create policy quickbooks_invoice_syncs_update on public.quickbooks_invoice_syncs
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());
-- No delete policy.

-- Polymorphic guard: invoice must belong to the same organization.
create or replace function public.guard_quickbooks_invoice_sync()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from public.invoices i where i.id = new.invoice_id and i.organization_id = new.organization_id) then
    raise exception 'Synced invoice does not exist in this organization.';
  end if;
  return new;
end;
$$;

create trigger quickbooks_invoice_syncs_guard
  before insert or update on public.quickbooks_invoice_syncs
  for each row execute function public.guard_quickbooks_invoice_sync();

revoke execute on function public.guard_quickbooks_customer_mapping() from public, anon, authenticated;
revoke execute on function public.guard_quickbooks_invoice_sync() from public, anon, authenticated;
