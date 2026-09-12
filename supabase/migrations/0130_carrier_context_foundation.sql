-- =============================================================================
-- 0130_carrier_context_foundation.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0001-0129 live. First slice of the multi-carrier dispatch-agency
-- upgrade (Phase 3A). ADDITIVE ONLY. No existing row is UPDATEd except the
-- single platform_settings row (three new columns observe their NOT NULL
-- defaults) and the one-row-per-carrier seed of carrier_remittance_profiles.
--
-- WHAT THIS MIGRATION DOES
--   * enum   public.unresolved_record_status ('unresolved','manually_resolved','archived_legacy')
--   * columns
--       carriers.invoice_code                text  NULL  (+ format CHECK)
--       carriers.dispatch_service_terms_days integer NULL (+ range CHECK)
--       platform_settings.dispatch_service_terms_days integer NOT NULL DEFAULT 15
--       platform_settings.multi_carrier_ui_enabled   boolean NOT NULL DEFAULT false
--       platform_settings.carrier_dashboards_enabled boolean NOT NULL DEFAULT false
--   * partial UNIQUE index carriers_org_invoice_code_uq (organization_id, invoice_code)
--       WHERE invoice_code IS NOT NULL
--   * table  public.carrier_remittance_profiles  -- 1:1 with carriers; the
--       source the later invoice-issuance RPC snapshots. SEEDED one row per
--       existing carrier from carriers.* (address/email/legal_name).
--       show_ein_on_pdf / show_bank_details_on_pdf default FALSE (decision 4).
--   * table  public.unresolved_carrier_records   -- append-mostly exception
--       log. Rows are NEVER auto-deleted (decision 7). No INSERT policy for
--       authenticated -- rows are written only via
--       public.record_unresolved_carrier_record(...).
--   * table  public.financial_idempotency_keys   -- (organization_id, scope,
--       idempotency_key) UNIQUE, per-org (correction G). state machine
--       processing/succeeded/blocked/failed (correction 11). No client
--       write policy; managed by later SECURITY DEFINER RPCs.
--   * function public.carrier_ids_authorized_for_current_user() -> setof uuid
--       ALL carriers (active + inactive) the caller may VIEW in their org --
--       the future hook for per-user carrier scoping (decision 6/8). Today
--       identical to "every carrier in current_org_id()"; callers that need
--       historical visibility (invoices/payments/factoring/settlements/
--       documents/reports/audit trail for an inactive carrier) MUST use this
--       one, never the selectable-only helper below.
--   * function public.carrier_ids_selectable_for_new_records() -> setof uuid
--       ACTIVE carriers only, in the caller's org. For NEW-record pickers
--       ONLY (load/dispatch carrier selection, new carrier-party setup).
--       Deliberately a SEPARATE function from the one above so "active-only"
--       can never silently leak into a historical-visibility call site.
--   * function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)
--       -> uuid. SECURITY DEFINER, pinned search_path, EXECUTE revoked from
--       PUBLIC, granted to authenticated. Idempotent via the partial unique
--       index (one open row per (record_type, record_id)).
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does NOT add loads.carrier_id / invoices.carrier_id / payments.carrier_id
--     / factoring carrier scope (later slices)
--   * does NOT create carrier_brokers / carrier_customers (that is 0131)
--   * does NOT touch loads, dispatches, invoices, invoice_line_items,
--     payments, settlements, factored_invoices, factoring_relationships,
--     documents, or any RPC on them
--   * does NOT create/replace/drop auto_generate_invoice_from_delivered_load(),
--     create_dispatch(), cancel_dispatch(), generate_invoice_number(), or any
--     0125 trigger/function
--   * does NOT enable Model A (platform_settings.model_a_enabled stays false)
--   * does NOT weaken any existing RLS policy or grant
--
-- DATA EFFECT (honest)
--   * platform_settings: 3 columns added NOT NULL DEFAULT -> the single row
--     observes dispatch_service_terms_days = 15 (Net 15, decision 6),
--     multi_carrier_ui_enabled = false, carrier_dashboards_enabled = false.
--     Catalog-only on PG >= 11; platform_settings.updated_at is NOT bumped.
--   * carrier_remittance_profiles: exactly (SELECT count(*) FROM carriers)
--     rows INSERTed. carriers.updated_at is NOT touched.
--   * every other new column is nullable with no default: existing rows
--     observe NULL.
--   * unresolved_carrier_records and financial_idempotency_keys are created
--     EMPTY.
--
-- STRUCTURE: explicit BEGIN/COMMIT. Leading DO $mig$ = PHASE 1 read-only
-- preconditions + baseline capture. Plain DDL = PHASE 2. Trailing DO $mig$ =
-- PHASE 3 postconditions. Any RAISE anywhere aborts the whole transaction
-- (COMMIT is the last line and is never reached on error). NOT idempotent:
-- a re-run RAISEs in PHASE 1 at "type/table/column already exists".
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
declare
  v_missing text;
begin
  -- --- required existing objects (correct baseline) ---
  if to_regclass('public.organizations')    is null then raise exception '0130 precondition: public.organizations missing. STOP.'; end if;
  if to_regclass('public.profiles')         is null then raise exception '0130 precondition: public.profiles missing. STOP.'; end if;
  if to_regclass('public.carriers')         is null then raise exception '0130 precondition: public.carriers missing. STOP.'; end if;
  if to_regclass('public.brokers')          is null then raise exception '0130 precondition: public.brokers missing. STOP.'; end if;
  if to_regclass('public.customers')        is null then raise exception '0130 precondition: public.customers missing. STOP.'; end if;
  if to_regclass('public.loads')            is null then raise exception '0130 precondition: public.loads missing. STOP.'; end if;
  if to_regclass('public.dispatches')       is null then raise exception '0130 precondition: public.dispatches missing. STOP.'; end if;
  if to_regclass('public.invoices')         is null then raise exception '0130 precondition: public.invoices missing. STOP.'; end if;
  if to_regclass('public.payments')         is null then raise exception '0130 precondition: public.payments missing. STOP.'; end if;
  if to_regclass('public.settlements')      is null then raise exception '0130 precondition: public.settlements missing. STOP.'; end if;
  if to_regclass('public.platform_settings') is null then raise exception '0130 precondition: public.platform_settings missing (apply 0125). STOP.'; end if;

  -- helper functions
  if to_regprocedure('public.current_org_id()')                  is null then raise exception '0130 precondition: public.current_org_id() missing. STOP.'; end if;
  if to_regprocedure('public.has_role(public.org_role[])')       is null then raise exception '0130 precondition: public.has_role(org_role[]) missing. STOP.'; end if;
  if to_regprocedure('public.set_updated_at()')                  is null then raise exception '0130 precondition: public.set_updated_at() missing. STOP.'; end if;

  -- 0125 landmark: financial controller foundation present
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id') then
    raise exception '0130 precondition: loads.financial_dispatch_id missing (apply 0125). STOP.';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='platform_settings' and column_name='model_a_enabled') then
    raise exception '0130 precondition: platform_settings.model_a_enabled missing (apply 0125). STOP.';
  end if;

  -- 0129 landmark: prove we are at or past the atomic dispatch lifecycle
  if to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null then
    raise exception '0130 precondition: public.create_dispatch(...) missing -- wrong baseline (need 0129). STOP.';
  end if;

  -- carriers must have the columns we read for the remittance seed
  select string_agg(c, ', ') into v_missing
  from unnest(array['id','organization_id','legal_name','address_line1','address_line2','city','state','postal_code','country','email','is_active']) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='carriers' and column_name=c
  );
  if v_missing is not null then
    raise exception '0130 precondition: public.carriers is missing expected column(s): %. STOP.', v_missing;
  end if;

  -- --- objects this migration CREATES must be ABSENT (fail closed) ---
  if exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
             where n.nspname='public' and t.typname='unresolved_record_status') then
    raise exception '0130 precondition: type public.unresolved_record_status already exists -- partial apply? STOP.';
  end if;
  if to_regclass('public.carrier_remittance_profiles') is not null then raise exception '0130 precondition: table public.carrier_remittance_profiles already exists. STOP.'; end if;
  if to_regclass('public.unresolved_carrier_records')  is not null then raise exception '0130 precondition: table public.unresolved_carrier_records already exists. STOP.'; end if;
  if to_regclass('public.financial_idempotency_keys')  is not null then raise exception '0130 precondition: table public.financial_idempotency_keys already exists. STOP.'; end if;
  if to_regprocedure('public.carrier_ids_authorized_for_current_user()') is not null then raise exception '0130 precondition: function public.carrier_ids_authorized_for_current_user() already exists. STOP.'; end if;
  if to_regprocedure('public.carrier_ids_selectable_for_new_records()') is not null then raise exception '0130 precondition: function public.carrier_ids_selectable_for_new_records() already exists. STOP.'; end if;
  if to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is not null then raise exception '0130 precondition: function public.record_unresolved_carrier_record(...) already exists. STOP.'; end if;

  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='invoice_code') then
    raise exception '0130 precondition: carriers.invoice_code already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='dispatch_service_terms_days') then
    raise exception '0130 precondition: carriers.dispatch_service_terms_days already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='dispatch_service_terms_days') then
    raise exception '0130 precondition: platform_settings.dispatch_service_terms_days already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='multi_carrier_ui_enabled') then
    raise exception '0130 precondition: platform_settings.multi_carrier_ui_enabled already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='carrier_dashboards_enabled') then
    raise exception '0130 precondition: platform_settings.carrier_dashboards_enabled already exists. STOP.';
  end if;

  -- --- capture baseline counts for PHASE 3 comparison ---
  create temp table _mig0130_baseline on commit drop as
  select
    (select count(*) from public.organizations) as n_org,
    (select count(*) from public.carriers)      as n_carrier,
    (select count(*) from public.brokers)       as n_broker,
    (select count(*) from public.customers)     as n_customer,
    (select count(*) from public.loads)         as n_load,
    (select count(*) from public.dispatches)    as n_dispatch,
    (select count(*) from public.invoices)      as n_invoice,
    (select count(*) from public.payments)      as n_payment,
    (select count(*) from public.settlements)   as n_settlement,
    (select count(*) from public.platform_settings) as n_platform_settings,
    (select model_a_enabled from public.platform_settings where id = true) as model_a_enabled;

  raise notice '0130 PHASE 1 preconditions passed. Baseline captured.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- A. Enum -------------------------------------------------------------------
-- Lifecycle of an exception row. 'manually_resolved' = an authorized user
-- linked it to the right carrier; 'archived_legacy' = deliberately parked
-- as pre-multi-carrier with no further automation expected. NEVER implies a
-- financial write-off (decision 7).
create type public.unresolved_record_status as enum (
  'unresolved',
  'manually_resolved',
  'archived_legacy'
);

-- B. carriers columns ----------------------------------------------------
-- invoice_code: the stable per-carrier freight-invoice prefix used by the
-- later carrier-scoped numbering (e.g. 'CARA'). Nullable now; the numbering
-- cutover is a later slice. Constrained to a short, filename/PDF-safe token.
alter table public.carriers
  add column invoice_code text
    constraint carriers_invoice_code_format
    check (invoice_code is null or invoice_code ~ '^[A-Z0-9][A-Z0-9-]{0,15}$');

-- dispatch_service_terms_days: optional carrier-specific contract override
-- for dispatch-service (dispatcher -> carrier) invoice payment terms. NULL
-- => fall back to platform_settings.dispatch_service_terms_days (decision 6).
alter table public.carriers
  add column dispatch_service_terms_days integer
    constraint carriers_dispatch_service_terms_range
    check (dispatch_service_terms_days is null or dispatch_service_terms_days between 0 and 365);

comment on column public.carriers.invoice_code is
  'Stable per-carrier freight-invoice prefix for carrier-scoped numbering (later slice). NULL until the numbering cutover assigns one.';
comment on column public.carriers.dispatch_service_terms_days is
  'Carrier-specific override for dispatch-service invoice payment terms. NULL => use platform_settings.dispatch_service_terms_days.';

create unique index carriers_org_invoice_code_uq
  on public.carriers (organization_id, invoice_code)
  where invoice_code is not null;

-- C. platform_settings columns ----------------------------------------
-- Net 15 organization-level default for dispatch-service invoices (decision 6).
alter table public.platform_settings
  add column dispatch_service_terms_days integer not null default 15
    constraint platform_settings_dispatch_service_terms_range
    check (dispatch_service_terms_days between 0 and 365);

-- Feature flags: gate UI / rollout ONLY. They never gate a cross-carrier DB
-- constraint or guard (Output 6 / correction D).
alter table public.platform_settings
  add column multi_carrier_ui_enabled boolean not null default false;
alter table public.platform_settings
  add column carrier_dashboards_enabled boolean not null default false;

comment on column public.platform_settings.dispatch_service_terms_days is
  'Organization-level default payment terms (days) for dispatch-service invoices. Net 15. Carriers.dispatch_service_terms_days overrides per carrier.';
comment on column public.platform_settings.multi_carrier_ui_enabled is
  'UI/rollout flag ONLY. Carrier-first load creation, filtered pickers, carrier switcher/badges. Does NOT gate any DB constraint or guard.';
comment on column public.platform_settings.carrier_dashboards_enabled is
  'UI/rollout flag ONLY. Carrier-scoped dashboards and report filters. Does NOT gate any DB constraint or guard.';

-- D. carrier_remittance_profiles -----------------------------------------
create table public.carrier_remittance_profiles (
  carrier_id       uuid primary key references public.carriers (id) on delete cascade,
  organization_id  uuid not null references public.organizations (id) on delete cascade,
  remittance_name          text,
  remittance_address_line1 text,
  remittance_address_line2 text,
  remittance_city          text,
  remittance_state         text,
  remittance_postal_code   text,
  remittance_country       text not null default 'US',
  remittance_email         text,
  remittance_instructions  text,
  show_ein_on_pdf          boolean not null default false,
  show_bank_details_on_pdf boolean not null default false,
  logo_url                 text,
  invoice_footer_text      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.carrier_remittance_profiles is
  '1:1 with carriers. Billing identity / remittance display config that the later invoice-issuance RPC snapshots into an immutable invoice carrier_snapshot. EIN and bank details are OFF by default (decision 4).';

create trigger set_updated_at
  before update on public.carrier_remittance_profiles
  for each row execute function public.set_updated_at();

-- same-org guard (correction R): organization_id must equal the carrier's org.
create or replace function public.guard_carrier_remittance_profile_org()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_carrier_org uuid;
begin
  select organization_id into v_carrier_org from public.carriers where id = new.carrier_id;
  if v_carrier_org is null then
    raise exception 'carrier_remittance_profiles.carrier_id % references a non-existent carrier.', new.carrier_id
      using errcode = '23503';
  end if;
  if v_carrier_org <> new.organization_id then
    raise exception 'carrier_remittance_profiles.organization_id % <> carrier % org %.',
      new.organization_id, new.carrier_id, v_carrier_org using errcode = '23514';
  end if;
  return new;
end;
$fn$;

create trigger carrier_remittance_profiles_guard_org
  before insert or update on public.carrier_remittance_profiles
  for each row execute function public.guard_carrier_remittance_profile_org();

alter table public.carrier_remittance_profiles enable row level security;

create policy carrier_remittance_profiles_select on public.carrier_remittance_profiles
  for select using (organization_id = public.current_org_id());

-- owner/admin ONLY (correction #6: "remittance identity" is explicitly
-- listed as requiring owner/admin authority, not delegated to accountant --
-- it is the legal/billing identity later snapshotted onto issued invoices,
-- distinct from the day-to-day AP/AR fields on carrier_brokers/customers).
create policy carrier_remittance_profiles_insert on public.carrier_remittance_profiles
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin']::public.org_role[])
  );

create policy carrier_remittance_profiles_update on public.carrier_remittance_profiles
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());
-- No DELETE policy: a remittance profile is config, not a deletable record.

revoke all on public.carrier_remittance_profiles from anon;
grant select, insert, update on public.carrier_remittance_profiles to authenticated;

-- SEED: exactly one row per existing carrier, from carriers.* .
insert into public.carrier_remittance_profiles (
  carrier_id, organization_id,
  remittance_name, remittance_address_line1, remittance_address_line2,
  remittance_city, remittance_state, remittance_postal_code, remittance_country,
  remittance_email
)
select
  c.id, c.organization_id,
  c.legal_name, c.address_line1, c.address_line2,
  c.city, c.state, c.postal_code, coalesce(c.country, 'US'),
  c.email
from public.carriers c;

-- E. unresolved_carrier_records ----------------------------------------
create table public.unresolved_carrier_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  record_type text not null
    check (record_type in (
      'load','invoice','payment','document',
      'factoring_relationship','factored_invoice',
      'trailer','dispatch_fee_candidate','other'
    )),
  record_id uuid not null,
  reason text not null,
  detail jsonb not null default '{}'::jsonb,
  status public.unresolved_record_status not null default 'unresolved',
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.unresolved_carrier_records is
  'Append-mostly exception log for records whose carrier ownership could not be proven. Rows are NEVER auto-deleted (decision 7): they retain their original financial history, stay visible in exception reports, and are excluded from carrier-specific totals unless shown as unallocated. Written only via public.record_unresolved_carrier_record().';

create trigger set_updated_at
  before update on public.unresolved_carrier_records
  for each row execute function public.set_updated_at();

-- At most one OPEN row per (record_type, record_id). Separate CREATE UNIQUE
-- INDEX ... WHERE, never an inline constraint (correction E).
create unique index unresolved_carrier_records_one_open_per_record
  on public.unresolved_carrier_records (record_type, record_id)
  where status = 'unresolved';

create index unresolved_carrier_records_org_status_idx
  on public.unresolved_carrier_records (organization_id, status);

alter table public.unresolved_carrier_records enable row level security;

create policy unresolved_carrier_records_select on public.unresolved_carrier_records
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
  );

-- Only a status/resolution transition by an admin. No org change, no re-open
-- past what the app allows (enforced app-side; RLS keeps it owner/admin).
create policy unresolved_carrier_records_update on public.unresolved_carrier_records
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());
-- No INSERT policy: rows are created only by record_unresolved_carrier_record().
-- No DELETE policy: history is retained (decision 7).

revoke all on public.unresolved_carrier_records from anon;
grant select, update on public.unresolved_carrier_records to authenticated;

-- F. financial_idempotency_keys --------------------------------------
create table public.financial_idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  scope text not null
    check (scope in (
      'freight_invoice','invoice_issuance','dispatch_service_invoice',
      'factoring_submission','factoring_package','payment_import','settlement_deduction'
    )),
  idempotency_key text not null,
  state text not null default 'processing'
    check (state in ('processing','succeeded','blocked','failed')),
  result jsonb,
  last_error text,
  attempts integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint financial_idempotency_keys_org_scope_key_uq
    unique (organization_id, scope, idempotency_key)
);

comment on table public.financial_idempotency_keys is
  'Retry-safe claim table for automated financial operations. Uniqueness is per-org: (organization_id, scope, idempotency_key) (correction G). state: processing (in flight) / succeeded (return stored result) / blocked (business validation failed -- MAY be retried after config changes) / failed (technical error -- retry re-runs validation). Managed exclusively by later SECURITY DEFINER RPCs; no client write policy.';

create trigger set_updated_at
  before update on public.financial_idempotency_keys
  for each row execute function public.set_updated_at();

alter table public.financial_idempotency_keys enable row level security;

create policy financial_idempotency_keys_select on public.financial_idempotency_keys
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','accountant']::public.org_role[])
  );
-- No INSERT/UPDATE/DELETE policy for authenticated: claim/settle happens only
-- inside SECURITY DEFINER RPCs added by later slices.

revoke all on public.financial_idempotency_keys from anon;
grant select on public.financial_idempotency_keys to authenticated;

-- G. carrier_ids_authorized_for_current_user() / carrier_ids_selectable_for_new_records()
-- TWO deliberately separate functions (never one "active only" helper reused
-- for both purposes -- a prior draft of this migration had a single
-- carrier_ids_visible_to_current_user() that would have silently hidden
-- inactive carriers from historical read paths the day it got reused there).
--
--   * _authorized_for_current_user(): every carrier (active OR inactive) the
--     caller may VIEW -- the future per-user-allowlist hook (decision 6).
--     Historical loads/invoices/payments/factoring/settlements/documents/
--     reports/audit trail for an inactive carrier MUST filter through this
--     one so deactivating a carrier never erases its history from view.
--   * _selectable_for_new_records(): ACTIVE carriers only -- for NEW-record
--     pickers (load/dispatch carrier selection, new carrier-party setup).
--     Inactive carriers are excluded from THIS helper only (decision 8).
--
-- Both are SECURITY DEFINER + pinned search_path + PUBLIC execute revoked.
create or replace function public.carrier_ids_authorized_for_current_user()
returns setof uuid
language sql
stable
security definer
set search_path = pg_catalog, public
as $fn$
  select c.id
  from public.carriers c
  where c.organization_id = public.current_org_id()
$fn$;

revoke all on function public.carrier_ids_authorized_for_current_user() from public;
grant execute on function public.carrier_ids_authorized_for_current_user() to authenticated;

comment on function public.carrier_ids_authorized_for_current_user() is
  'ALL carriers (active + inactive) the caller may view in their org -- the extension point for a future per-user carrier allowlist. Use for historical visibility: loads/invoices/payments/factoring/settlements/documents/reports/audit trail. NEVER use for a new-record picker -- see carrier_ids_selectable_for_new_records().';

create or replace function public.carrier_ids_selectable_for_new_records()
returns setof uuid
language sql
stable
security definer
set search_path = pg_catalog, public
as $fn$
  select c.id
  from public.carriers c
  where c.organization_id = public.current_org_id()
    and c.is_active
$fn$;

revoke all on function public.carrier_ids_selectable_for_new_records() from public;
grant execute on function public.carrier_ids_selectable_for_new_records() to authenticated;

comment on function public.carrier_ids_selectable_for_new_records() is
  'ACTIVE carriers only, in the caller''s org. For NEW-record pickers ONLY (load/dispatch carrier selection, new carrier-party setup). NEVER use this for historical visibility -- see carrier_ids_authorized_for_current_user().';

-- H. record_unresolved_carrier_record(...) --------------------------
-- The one audited entry point that writes unresolved_carrier_records.
-- SECURITY DEFINER (the table has no INSERT policy on purpose). Idempotent:
-- if an OPEN row already exists for (p_record_type, p_record_id) it is
-- returned unchanged (matches the partial unique index predicate exactly).
create or replace function public.record_unresolved_carrier_record(
  p_organization_id uuid,
  p_record_type text,
  p_record_id uuid,
  p_reason text,
  p_detail jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if p_organization_id is null or p_record_type is null or p_record_id is null
     or p_reason is null or btrim(p_reason) = '' then
    raise exception 'record_unresolved_carrier_record: organization_id, record_type, record_id and reason are all required.'
      using errcode = '22023';
  end if;

  -- Interactive caller (has a JWT): must be same-org and privileged. A
  -- migration / service context has auth.uid() = NULL and is trusted (this
  -- is how 0133's own backfill calls it, for every record_type it needs).
  if v_uid is not null then
    if p_organization_id is distinct from public.current_org_id() then
      raise exception 'record_unresolved_carrier_record: cross-organization write rejected.'
        using errcode = '42501';
    end if;
    if not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
      raise exception 'record_unresolved_carrier_record: caller role is not permitted.'
        using errcode = '42501';
    end if;

    -- record_id is POLYMORPHIC (record_type decides which table it points
    -- into) and carries no FK, so an interactive caller could otherwise
    -- fabricate an exception "about" a record_id belonging to a DIFFERENT
    -- organization's load/invoice/document/trailer/factoring relationship.
    -- Phase 3A can only verify this for record_type='load' (the only type
    -- it actually has a caller for -- 0133's own backfill, which is trusted
    -- and never reaches this branch). Every OTHER record_type is therefore
    -- REJECTED for interactive callers until its own slice adds the matching
    -- validation -- restricting the function per correction #2 rather than
    -- leaving the other 8 record_types unverifiable.
    if p_record_type = 'load' then
      if (select organization_id from public.loads where id = p_record_id) is distinct from p_organization_id then
        raise exception 'record_unresolved_carrier_record: record_id does not belong to the caller''s organization.'
          using errcode = '42501';
      end if;
    else
      raise exception 'record_unresolved_carrier_record: interactive callers may report record_type=''load'' only in this phase; record_type ''%'' requires a trusted internal (migration/service) caller until its own slice adds record_id validation.', p_record_type
        using errcode = '42501';
    end if;
  end if;

  insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason, detail)
  values (p_organization_id, p_record_type, p_record_id, p_reason, coalesce(p_detail, '{}'::jsonb))
  on conflict (record_type, record_id) where (status = 'unresolved')
  do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
    from public.unresolved_carrier_records
    where record_type = p_record_type and record_id = p_record_id and status = 'unresolved';
  end if;

  return v_id;
end;
$fn$;

revoke all on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) from public;
grant execute on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) to authenticated;

comment on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) is
  'Idempotent audited writer for unresolved_carrier_records. Returns the existing OPEN row id when one already exists for (record_type, record_id). Interactive callers are org- and role-checked, AND (Phase 3A) restricted to record_type=''load'' with record_id verified against loads.organization_id -- every other record_type is rejected for interactive callers until its own slice adds matching validation, so a caller can never fabricate an exception about another organization''s record. A NULL auth.uid() (migration/service) is trusted for any record_type.';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare
  b record;
  v_labels text;
  v_n integer;
begin
  select * into b from _mig0130_baseline;

  -- enum exact
  select string_agg(e.enumlabel, ',' order by e.enumsortorder) into v_labels
  from pg_enum e join pg_type t on t.oid = e.enumtypid join pg_namespace n on n.oid = t.typnamespace
  where n.nspname='public' and t.typname='unresolved_record_status';
  if v_labels is distinct from 'unresolved,manually_resolved,archived_legacy' then
    raise exception '0130 postcondition: unresolved_record_status members = "%", expected "unresolved,manually_resolved,archived_legacy".', v_labels;
  end if;

  -- carriers columns
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='carriers' and column_name='invoice_code'
      and data_type='text' and is_nullable='YES' and column_default is null) then
    raise exception '0130 postcondition: carriers.invoice_code is not (text, nullable, no default).';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='carriers' and column_name='dispatch_service_terms_days'
      and data_type='integer' and is_nullable='YES' and column_default is null) then
    raise exception '0130 postcondition: carriers.dispatch_service_terms_days is not (integer, nullable, no default).';
  end if;
  if not exists (select 1 from pg_constraint where conname='carriers_invoice_code_format' and conrelid='public.carriers'::regclass) then
    raise exception '0130 postcondition: CHECK carriers_invoice_code_format missing.';
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and tablename='carriers' and indexname='carriers_org_invoice_code_uq') then
    raise exception '0130 postcondition: index carriers_org_invoice_code_uq missing.';
  end if;
  if not exists (select 1 from pg_index i join pg_class ic on ic.oid=i.indexrelid
                 where ic.relname='carriers_org_invoice_code_uq' and i.indisunique and i.indpred is not null) then
    raise exception '0130 postcondition: carriers_org_invoice_code_uq is not a UNIQUE partial index.';
  end if;

  -- platform_settings columns + values
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='platform_settings' and column_name='dispatch_service_terms_days'
      and data_type='integer' and is_nullable='NO' and column_default='15') then
    raise exception '0130 postcondition: platform_settings.dispatch_service_terms_days is not (integer, NOT NULL, DEFAULT 15).';
  end if;
  if (select dispatch_service_terms_days from public.platform_settings where id=true) <> 15 then
    raise exception '0130 postcondition: platform_settings row does not observe dispatch_service_terms_days = 15.';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='platform_settings' and column_name='multi_carrier_ui_enabled'
      and data_type='boolean' and is_nullable='NO' and column_default='false') then
    raise exception '0130 postcondition: platform_settings.multi_carrier_ui_enabled is not (boolean, NOT NULL, DEFAULT false).';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='platform_settings' and column_name='carrier_dashboards_enabled'
      and data_type='boolean' and is_nullable='NO' and column_default='false') then
    raise exception '0130 postcondition: platform_settings.carrier_dashboards_enabled is not (boolean, NOT NULL, DEFAULT false).';
  end if;
  if (select multi_carrier_ui_enabled or carrier_dashboards_enabled from public.platform_settings where id=true) then
    raise exception '0130 postcondition: a platform_settings rollout flag is not FALSE.';
  end if;
  if (select model_a_enabled from public.platform_settings where id=true) is distinct from b.model_a_enabled then
    raise exception '0130 postcondition: platform_settings.model_a_enabled changed.';
  end if;

  -- carrier_remittance_profiles: table, RLS, policies, seed
  if to_regclass('public.carrier_remittance_profiles') is null then raise exception '0130 postcondition: carrier_remittance_profiles missing.'; end if;
  if not (select relrowsecurity from pg_class where oid='public.carrier_remittance_profiles'::regclass) then
    raise exception '0130 postcondition: RLS not enabled on carrier_remittance_profiles.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_remittance_profiles' and cmd in ('DELETE','ALL')) then
    raise exception '0130 postcondition: carrier_remittance_profiles has an unexpected DELETE/ALL policy.';
  end if;
  if (select count(*) from public.carrier_remittance_profiles) <> b.n_carrier then
    raise exception '0130 postcondition: carrier_remittance_profiles has % rows, expected one per carrier (%).',
      (select count(*) from public.carrier_remittance_profiles), b.n_carrier;
  end if;
  select count(*) into v_n
  from public.carrier_remittance_profiles p
  join public.carriers c on c.id = p.carrier_id
  where p.organization_id <> c.organization_id;
  if v_n <> 0 then raise exception '0130 postcondition: % carrier_remittance_profiles row(s) have organization_id <> carrier org.', v_n; end if;
  if exists (select 1 from public.carrier_remittance_profiles where show_ein_on_pdf or show_bank_details_on_pdf) then
    raise exception '0130 postcondition: a seeded carrier_remittance_profiles row has show_ein_on_pdf/show_bank_details_on_pdf TRUE -- must default FALSE.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='carrier_remittance_profiles_guard_org'
                 and tgrelid='public.carrier_remittance_profiles'::regclass and not tgisinternal
                 and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%') then
    raise exception '0130 postcondition: trigger carrier_remittance_profiles_guard_org (BEFORE INSERT OR UPDATE) missing/wrong.';
  end if;

  -- unresolved_carrier_records
  if to_regclass('public.unresolved_carrier_records') is null then raise exception '0130 postcondition: unresolved_carrier_records missing.'; end if;
  if (select count(*) from public.unresolved_carrier_records) <> 0 then
    raise exception '0130 postcondition: unresolved_carrier_records is not empty -- 0130 creates no rows.';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.unresolved_carrier_records'::regclass) then
    raise exception '0130 postcondition: RLS not enabled on unresolved_carrier_records.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='unresolved_carrier_records' and cmd in ('INSERT','DELETE','ALL')) then
    raise exception '0130 postcondition: unresolved_carrier_records has an unexpected INSERT/DELETE/ALL policy.';
  end if;
  if not exists (select 1 from pg_index i join pg_class ic on ic.oid=i.indexrelid
                 where ic.relname='unresolved_carrier_records_one_open_per_record' and i.indisunique and i.indpred is not null) then
    raise exception '0130 postcondition: unresolved_carrier_records_one_open_per_record is not a UNIQUE partial index.';
  end if;

  -- financial_idempotency_keys
  if to_regclass('public.financial_idempotency_keys') is null then raise exception '0130 postcondition: financial_idempotency_keys missing.'; end if;
  if (select count(*) from public.financial_idempotency_keys) <> 0 then
    raise exception '0130 postcondition: financial_idempotency_keys is not empty.';
  end if;
  if not exists (select 1 from pg_constraint where conname='financial_idempotency_keys_org_scope_key_uq'
                 and conrelid='public.financial_idempotency_keys'::regclass and contype='u') then
    raise exception '0130 postcondition: UNIQUE (organization_id, scope, idempotency_key) missing.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='financial_idempotency_keys' and cmd in ('INSERT','UPDATE','DELETE','ALL')) then
    raise exception '0130 postcondition: financial_idempotency_keys has an unexpected write policy.';
  end if;

  -- functions: security definer, pinned search_path, not PUBLIC-executable
  if to_regprocedure('public.carrier_ids_authorized_for_current_user()') is null then raise exception '0130 postcondition: carrier_ids_authorized_for_current_user() missing.'; end if;
  if to_regprocedure('public.carrier_ids_selectable_for_new_records()') is null then raise exception '0130 postcondition: carrier_ids_selectable_for_new_records() missing.'; end if;
  if to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is null then raise exception '0130 postcondition: record_unresolved_carrier_record(...) missing.'; end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('carrier_ids_authorized_for_current_user','carrier_ids_selectable_for_new_records','record_unresolved_carrier_record','guard_carrier_remittance_profile_org')
      and (not p.prosecdef
           or array_to_string(coalesce(p.proconfig,'{}'::text[]), ',') not like '%search_path=%')
  ) then
    raise exception '0130 postcondition: a 0130 function is not (security definer + pinned search_path).';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('carrier_ids_authorized_for_current_user','carrier_ids_selectable_for_new_records','record_unresolved_carrier_record')
      and has_function_privilege('public', p.oid, 'execute')
  ) then
    raise exception '0130 postcondition: a 0130 function is still EXECUTE-able by PUBLIC.';
  end if;
  -- the two carrier-visibility helpers must differ ONLY by is_active (an
  -- inactive carrier is in the authorized set but not the selectable set;
  -- every selectable carrier is also authorized)
  if exists (
    select c.id from public.carriers c
    where c.id in (select * from public.carrier_ids_selectable_for_new_records())
      and c.id not in (select * from public.carrier_ids_authorized_for_current_user())
  ) then
    raise exception '0130 postcondition: a carrier is selectable but not authorized -- the two helpers have drifted.';
  end if;

  -- baseline counts preserved (nothing else written)
  if (select count(*) from public.organizations) <> b.n_org       then raise exception '0130 postcondition: organizations count changed.'; end if;
  if (select count(*) from public.carriers)      <> b.n_carrier   then raise exception '0130 postcondition: carriers count changed.'; end if;
  if (select count(*) from public.brokers)       <> b.n_broker    then raise exception '0130 postcondition: brokers count changed.'; end if;
  if (select count(*) from public.customers)     <> b.n_customer  then raise exception '0130 postcondition: customers count changed.'; end if;
  if (select count(*) from public.loads)         <> b.n_load      then raise exception '0130 postcondition: loads count changed.'; end if;
  if (select count(*) from public.dispatches)    <> b.n_dispatch  then raise exception '0130 postcondition: dispatches count changed.'; end if;
  if (select count(*) from public.invoices)      <> b.n_invoice   then raise exception '0130 postcondition: invoices count changed.'; end if;
  if (select count(*) from public.payments)      <> b.n_payment   then raise exception '0130 postcondition: payments count changed.'; end if;
  if (select count(*) from public.settlements)   <> b.n_settlement then raise exception '0130 postcondition: settlements count changed.'; end if;
  if (select count(*) from public.platform_settings) <> b.n_platform_settings then raise exception '0130 postcondition: platform_settings row count changed.'; end if;

  -- landmarks intact
  if to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null then
    raise exception '0130 postcondition: create_dispatch(...) disappeared -- 0130 must not touch it.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='auto_generate_invoice_on_delivery' and tgrelid='public.loads'::regclass and not tgisinternal) then
    raise exception '0130 postcondition: auto_generate_invoice_on_delivery trigger disappeared -- 0130 must not touch it.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass and not tgisinternal) then
    raise exception '0130 postcondition: 0125 dispatches_assign_financial_controller trigger disappeared.';
  end if;

  raise notice '0130 complete: unresolved_record_status enum; carriers.invoice_code + dispatch_service_terms_days; platform_settings Net-15 + 2 rollout flags; carrier_remittance_profiles seeded % row(s); unresolved_carrier_records + financial_idempotency_keys created empty; carrier_ids_authorized_for_current_user() + carrier_ids_selectable_for_new_records() + record_unresolved_carrier_record() created. All protected counts preserved; Model A still %.',
    (select count(*) from public.carrier_remittance_profiles),
    (select model_a_enabled from public.platform_settings where id=true);
end
$mig$;

commit;
