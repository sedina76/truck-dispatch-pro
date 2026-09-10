-- =============================================================================
-- 0125_dispatch_proceeds_and_financial_controller.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
--
-- FOUNDATION for the Carrier Statement vs Dispatch-Fee Invoice architecture
-- (Model A "carrier_paid_directly" / Model B "dispatcher_receives_funds").
-- DORMANT: Model A stays disabled, no accounting behavior changes, and
-- auto_generate_invoice_from_delivered_load() is NOT touched here (that is a
-- later migration, after 0126's controller backfill is verified).
--
-- WHAT THIS MIGRATION DOES
--   * enums   public.proceeds_model, public.proceeds_payer
--   * table   public.platform_settings  -- single-row, authoritative DB
--             capability state. model_a_enabled = false initially.
--   * columns
--       organizations.load_proceeds_model  proceeds_model NOT NULL
--                                          DEFAULT 'dispatcher_receives_funds'
--       carriers.load_proceeds_model       proceeds_model NULL
--       dispatches.proceeds_model          proceeds_model NULL  (legacy = NULL)
--       dispatches.proceeds_payer          proceeds_payer NULL
--       dispatches.proceeds_payer_note     text NULL
--       loads.financial_dispatch_id        uuid NULL
--                                          FK -> dispatches(id) ON DELETE RESTRICT
--   * partial UNIQUE index on loads.financial_dispatch_id -- a dispatch may
--     control at most one load
--   * resolve_dispatch_proceeds_model(uuid) -- reads ONLY
--     dispatches.proceeds_model; never a carrier/org default, never
--     capability state, never a document
--   * BEFORE INSERT trigger on dispatches (dispatches_stamp_proceeds):
--     creation-time proceeds_model resolution (carrier default -> org
--     default -> dispatcher_receives_funds), payer-note rule, capability-gate
--     rejection of carrier_paid_directly. DOES NOT touch
--     loads.financial_dispatch_id.
--   * AFTER INSERT trigger on dispatches (dispatches_assign_financial_controller):
--     locks the parent loads row FOR UPDATE, verifies org match, sets
--     loads.financial_dispatch_id = NEW.id ONLY when currently NULL. Never
--     replaces an existing controller. The FK is valid here because NEW.id
--     now exists (this is why controller assignment is AFTER, not BEFORE).
--   * BEFORE INSERT OR UPDATE guard on loads (loads_financial_dispatch_ref_guard):
--     financial_dispatch_id must reference a dispatch of the SAME load and
--     SAME organization.
--   * BEFORE UPDATE guards on organizations / carriers: cannot set
--     load_proceeds_model = 'carrier_paid_directly' while model_a_enabled = false.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does NOT backfill any dispatch -- proceeds_model stays NULL on every
--     existing dispatch row
--   * does NOT populate loads.financial_dispatch_id for any existing load
--     (that is migration 0126)
--   * does NOT create/replace/drop auto_generate_invoice_from_delivered_load()
--   * does NOT touch invoices, invoice_line_items, payments, settlements,
--     settlement_line_items, carrier_settlement_payments, dispatch_financials,
--     load_financials, carrier_financials, billing_records,
--     organization_subscriptions, subscription_plans, any Stripe object, any
--     QuickBooks object, middleware, migration 0115, or migrations 0119-0124
--   * does NOT add a code/env capability flag
--   * does NOT create Model A document tables (carrier_fee_invoices, etc.)
--   * does NOT change RLS/grants on any existing table
--
-- DATA EFFECT (honest -- NOT "no data effect")
--   * organizations.load_proceeds_model is added NOT NULL DEFAULT
--     'dispatcher_receives_funds'. On PostgreSQL >= 11 this is a catalog-only
--     change (no table rewrite; organizations.updated_at is NOT touched),
--     BUT every existing organization row now OBSERVES
--     load_proceeds_model = 'dispatcher_receives_funds'. That is a real
--     logical assignment of a value to existing rows. It preserves current
--     behavior exactly -- dispatcher_receives_funds is today's only model.
--   * every other new column is nullable with no default: existing rows
--     observe NULL; no logical assignment.
--   * this migration UPDATEs no existing row and INSERTs exactly one row
--     (the single public.platform_settings row).
--   * FUTURE effect (after this migration is live, not during it): creating a
--     load's FIRST dispatch will set that load's financial_dispatch_id and
--     therefore bump loads.updated_at via the pre-existing shared
--     set_updated_at trigger on loads. No amount / status / document change.
--
-- STRUCTURE: leading DO block = PHASE 1 read-only preconditions + baseline
-- count capture. Plain top-level DDL = PHASE 2 mutation. Trailing DO block =
-- PHASE 3 postconditions. The whole file is one transaction; any RAISE rolls
-- everything back. NOT idempotent: a re-run RAISEs in PHASE 1 at
-- "type / table / column already exists".
-- =============================================================================

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
declare
  v_missing text;
begin
  -- --- required existing objects (correct baseline) ---
  if to_regclass('public.organizations') is null then raise exception '0125 precondition: public.organizations is missing. STOP.'; end if;
  if to_regclass('public.carriers')      is null then raise exception '0125 precondition: public.carriers is missing. STOP.'; end if;
  if to_regclass('public.dispatches')    is null then raise exception '0125 precondition: public.dispatches is missing. STOP.'; end if;
  if to_regclass('public.loads')         is null then raise exception '0125 precondition: public.loads is missing. STOP.'; end if;

  select string_agg(c, ', ') into v_missing
  from unnest(array['id','organization_id','load_id','carrier_id','status']) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dispatches' and column_name = c
  );
  if v_missing is not null then
    raise exception '0125 precondition: public.dispatches is missing expected column(s): %. STOP.', v_missing;
  end if;

  select string_agg(c, ', ') into v_missing
  from unnest(array['id','organization_id','status']) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'loads' and column_name = c
  );
  if v_missing is not null then
    raise exception '0125 precondition: public.loads is missing expected column(s): %. STOP.', v_missing;
  end if;

  if not exists (
    select 1 from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'dispatch_status' and e.enumlabel = 'cancelled'
  ) then
    raise exception '0125 precondition: enum public.dispatch_status has no ''cancelled'' member. STOP.';
  end if;

  if to_regprocedure('public.set_updated_at()') is null then
    raise exception '0125 precondition: function public.set_updated_at() is missing. STOP.';
  end if;

  -- 0124 landmark -- prove we are on the expected baseline; NOT touched here.
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'stripe_checkout_attempt_id'
  ) then
    raise exception '0125 precondition: 0124 landmark organization_subscriptions.stripe_checkout_attempt_id is missing -- wrong baseline. STOP.';
  end if;

  -- protected tables must exist (this migration never writes to them).
  perform 1;
  if to_regclass('public.invoices')                   is null then raise exception '0125 precondition: public.invoices missing. STOP.'; end if;
  if to_regclass('public.invoice_line_items')         is null then raise exception '0125 precondition: public.invoice_line_items missing. STOP.'; end if;
  if to_regclass('public.payments')                   is null then raise exception '0125 precondition: public.payments missing. STOP.'; end if;
  if to_regclass('public.settlements')                is null then raise exception '0125 precondition: public.settlements missing. STOP.'; end if;
  if to_regclass('public.settlement_line_items')      is null then raise exception '0125 precondition: public.settlement_line_items missing. STOP.'; end if;
  if to_regclass('public.carrier_settlement_payments') is null then raise exception '0125 precondition: public.carrier_settlement_payments missing. STOP.'; end if;
  if to_regclass('public.billing_records')            is null then raise exception '0125 precondition: public.billing_records missing. STOP.'; end if;
  if to_regclass('public.organization_subscriptions') is null then raise exception '0125 precondition: public.organization_subscriptions missing. STOP.'; end if;
  if to_regclass('public.subscription_plans')         is null then raise exception '0125 precondition: public.subscription_plans missing. STOP.'; end if;

  -- --- objects this migration CREATES must be ABSENT (fail closed) ---
  if exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
             where n.nspname = 'public' and t.typname = 'proceeds_model') then
    raise exception '0125 precondition: type public.proceeds_model already exists -- partial apply? STOP.';
  end if;
  if exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
             where n.nspname = 'public' and t.typname = 'proceeds_payer') then
    raise exception '0125 precondition: type public.proceeds_payer already exists -- partial apply? STOP.';
  end if;
  if to_regclass('public.platform_settings') is not null then
    raise exception '0125 precondition: table public.platform_settings already exists -- partial apply? STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='load_proceeds_model') then
    raise exception '0125 precondition: organizations.load_proceeds_model already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='load_proceeds_model') then
    raise exception '0125 precondition: carriers.load_proceeds_model already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='dispatches' and column_name='proceeds_model') then
    raise exception '0125 precondition: dispatches.proceeds_model already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='dispatches' and column_name='proceeds_payer') then
    raise exception '0125 precondition: dispatches.proceeds_payer already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='dispatches' and column_name='proceeds_payer_note') then
    raise exception '0125 precondition: dispatches.proceeds_payer_note already exists. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id') then
    raise exception '0125 precondition: loads.financial_dispatch_id already exists. STOP.';
  end if;

  if to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)') is not null then
    raise exception '0125 precondition: function public.resolve_dispatch_proceeds_model(uuid) already exists. STOP.';
  end if;
  if to_regprocedure('public.stamp_dispatch_proceeds_model()')  is not null then raise exception '0125 precondition: function public.stamp_dispatch_proceeds_model() already exists. STOP.'; end if;
  if to_regprocedure('public.assign_load_financial_dispatch()') is not null then raise exception '0125 precondition: function public.assign_load_financial_dispatch() already exists. STOP.'; end if;
  if to_regprocedure('public.guard_load_financial_dispatch_ref()') is not null then raise exception '0125 precondition: function public.guard_load_financial_dispatch_ref() already exists. STOP.'; end if;
  if to_regprocedure('public.guard_org_load_proceeds_model()')  is not null then raise exception '0125 precondition: function public.guard_org_load_proceeds_model() already exists. STOP.'; end if;
  if to_regprocedure('public.guard_carrier_load_proceeds_model()') is not null then raise exception '0125 precondition: function public.guard_carrier_load_proceeds_model() already exists. STOP.'; end if;

  if exists (select 1 from pg_trigger where not tgisinternal and tgname in (
    'dispatches_stamp_proceeds', 'dispatches_assign_financial_controller',
    'loads_financial_dispatch_ref_guard', 'organizations_load_proceeds_model_guard',
    'carriers_load_proceeds_model_guard'
  )) then
    raise exception '0125 precondition: one of the 0125 triggers already exists -- partial apply? STOP.';
  end if;

  -- --- capture baseline counts for PHASE 3 comparison ---
  create temp table _mig0125_baseline on commit drop as
  select
    (select count(*) from public.organizations)              as n_org,
    (select count(*) from public.carriers)                   as n_carrier,
    (select count(*) from public.dispatches)                 as n_dispatch,
    (select count(*) from public.loads)                      as n_load,
    (select count(*) from public.invoices)                   as n_invoice,
    (select count(*) from public.invoice_line_items)         as n_invoice_li,
    (select count(*) from public.payments)                   as n_payment,
    (select count(*) from public.settlements)                as n_settlement,
    (select count(*) from public.settlement_line_items)      as n_sli,
    (select count(*) from public.carrier_settlement_payments) as n_csp,
    (select count(*) from public.billing_records)            as n_billing_records,
    (select count(*) from public.organization_subscriptions) as n_orgsub,
    (select count(*) from public.subscription_plans)         as n_plan;

  raise notice '0125 PHASE 1 preconditions passed. Baseline captured.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- A. Enums --------------------------------------------------------------------
create type public.proceeds_model as enum (
  'dispatcher_receives_funds',
  'carrier_paid_directly'
);

create type public.proceeds_payer as enum (
  'broker',
  'factoring_company',
  'shipper',
  'dispatcher',
  'other'
);

-- B. Authoritative DB capability state --------------------------------------
-- Single-row table (the `id boolean primary key check (id = true)` idiom
-- forces exactly one row). Separate from Stripe/billing settings and from
-- organizations.* -- do not add tenant-facing config here.
create table public.platform_settings (
  id             boolean primary key default true,
  model_a_enabled boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint platform_settings_singleton check (id = true)
);

insert into public.platform_settings (id) values (true);

alter table public.platform_settings enable row level security;

-- Feature-flag boolean, not secret: readable by any authenticated user so
-- the future Settings UI can reflect availability. NO tenant write policy --
-- model_a_enabled is flipped only by a reviewed platform action / service
-- role, never by a tenant.
create policy platform_settings_select on public.platform_settings
  for select using (true);

revoke all on public.platform_settings from anon;
grant select on public.platform_settings to authenticated;

create trigger set_updated_at
  before update on public.platform_settings
  for each row execute function public.set_updated_at();

comment on table public.platform_settings is
  'Authoritative single-row platform capability state. model_a_enabled gates ALL Model A (carrier_paid_directly) creation at the database layer. Not tenant config; not Stripe/billing config.';

-- C. Columns ---------------------------------------------------------------
-- Org default: NOT NULL DEFAULT -> every existing organization OBSERVES
-- 'dispatcher_receives_funds' (see DATA EFFECT in the header). Preserves
-- current behavior exactly.
alter table public.organizations
  add column load_proceeds_model public.proceeds_model not null default 'dispatcher_receives_funds';

-- Carrier default: nullable (no override by default).
alter table public.carriers
  add column load_proceeds_model public.proceeds_model;

-- Dispatch: nullable, no default -> every existing dispatch stays NULL
-- (never backfilled). New dispatches are stamped by the BEFORE INSERT
-- trigger below.
alter table public.dispatches add column proceeds_model      public.proceeds_model;
alter table public.dispatches add column proceeds_payer       public.proceeds_payer;
alter table public.dispatches add column proceeds_payer_note  text;

-- Load: the single controlling-dispatch reference every accounting consumer
-- will read. Nullable, no default. FK ON DELETE RESTRICT so a controlling
-- dispatch cannot be deleted out from under finalized accounting.
alter table public.loads
  add column financial_dispatch_id uuid references public.dispatches (id) on delete restrict;

comment on column public.loads.financial_dispatch_id is
  'The dispatch that owns this load''s carrier-money accounting identity (Model A/B, carrier, fee %). Set for new loads by the dispatches AFTER INSERT trigger; legacy loads pending deterministic backfill by migration 0126. NULL = no dispatch / genuinely uncontrolled.';

-- A dispatch may control at most one load (defense-in-depth on top of the
-- same-load guard trigger). Serves as the reverse-lookup index too.
create unique index uq_loads_financial_dispatch_one_per_dispatch
  on public.loads (financial_dispatch_id)
  where financial_dispatch_id is not null;

-- D. Resolver -------------------------------------------------------------
-- Reads ONLY dispatches.proceeds_model. Contract:
--   * stored non-NULL value  -> that value
--   * stored NULL            -> 'dispatcher_receives_funds'
--   * dispatch does not exist -> NULL   (fail closed: NULL is treated by
--     every consumer as non-Model-A; combined with the ON DELETE RESTRICT
--     FK on loads.financial_dispatch_id a missing dispatch cannot arise in
--     practice; if it ever did, the safe non-Model-A path is taken.)
-- Never reads a carrier default, an org default, platform_settings, or any
-- document. security definer + fixed search_path per repo standard.
create or replace function public.resolve_dispatch_proceeds_model(p_dispatch_id uuid)
returns public.proceeds_model
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(d.proceeds_model, 'dispatcher_receives_funds'::public.proceeds_model)
  from public.dispatches d
  where d.id = p_dispatch_id;
$fn$;

grant execute on function public.resolve_dispatch_proceeds_model(uuid) to authenticated;

comment on function public.resolve_dispatch_proceeds_model(uuid) is
  'Post-creation proceeds-model resolver. Reads ONLY dispatches.proceeds_model. NULL-stored -> dispatcher_receives_funds. Missing dispatch -> NULL (fail closed). Never consults carrier/org defaults, capability state, or documents.';

-- E. BEFORE INSERT trigger on dispatches ---------------------------------
-- Creation-time proceeds_model stamping ONLY. Never touches
-- loads.financial_dispatch_id (the referenced dispatch row does not exist
-- yet at BEFORE INSERT; that assignment is AFTER INSERT, trigger F).
create or replace function public.stamp_dispatch_proceeds_model()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_carrier_default public.proceeds_model;
  v_org_default     public.proceeds_model;
  v_gate            boolean;
begin
  -- payer note required when payer = 'other'
  if new.proceeds_payer = 'other'
     and (new.proceeds_payer_note is null or btrim(new.proceeds_payer_note) = '') then
    raise exception 'dispatches.proceeds_payer_note is required when proceeds_payer = ''other''.'
      using errcode = '23514';
  end if;

  -- resolve the model at creation time only if not explicitly supplied:
  -- carrier default -> organization default -> dispatcher_receives_funds
  if new.proceeds_model is null then
    select load_proceeds_model into v_carrier_default
    from public.carriers where id = new.carrier_id;

    if v_carrier_default is not null then
      new.proceeds_model := v_carrier_default;
    else
      select load_proceeds_model into v_org_default
      from public.organizations where id = new.organization_id;
      new.proceeds_model := coalesce(v_org_default, 'dispatcher_receives_funds'::public.proceeds_model);
    end if;
  end if;

  -- capability gate: carrier_paid_directly only while Model A is enabled
  if new.proceeds_model = 'carrier_paid_directly' then
    select model_a_enabled into v_gate from public.platform_settings where id = true;
    if coalesce(v_gate, false) is not true then
      raise exception 'Model A (carrier_paid_directly) is not enabled for this platform. Dispatch rejected.'
        using errcode = '0A000';
    end if;
  end if;

  return new;
end;
$fn$;

create trigger dispatches_stamp_proceeds
  before insert on public.dispatches
  for each row execute function public.stamp_dispatch_proceeds_model();

-- F. AFTER INSERT controller trigger on dispatches ----------------------
-- Locks the always-present parent loads row FOR UPDATE (serializes
-- concurrent dispatch inserts for the same load), verifies org match, and
-- sets loads.financial_dispatch_id = NEW.id ONLY when it is currently NULL.
-- Never replaces an existing controller. The FK is valid here because
-- NEW.id now exists.
create or replace function public.assign_load_financial_dispatch()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_load_org uuid;
begin
  select organization_id into v_load_org
  from public.loads where id = new.load_id
  for update;

  if v_load_org is null then
    raise exception 'dispatches AFTER INSERT: load % does not exist.', new.load_id
      using errcode = '23503';
  end if;
  if v_load_org <> new.organization_id then
    raise exception 'dispatches AFTER INSERT: dispatch org % <> load org % (load %).',
      new.organization_id, v_load_org, new.load_id using errcode = '23514';
  end if;

  update public.loads
  set financial_dispatch_id = new.id
  where id = new.load_id
    and financial_dispatch_id is null;
  -- 0 rows updated => a controller already exists => NEW dispatch stays
  -- non-controlling. Never overwrite.

  return null; -- AFTER trigger: return value ignored
end;
$fn$;

create trigger dispatches_assign_financial_controller
  after insert on public.dispatches
  for each row execute function public.assign_load_financial_dispatch();

-- G. loads.financial_dispatch_id consistency guard --------------------
-- The referenced dispatch must belong to the SAME load and SAME org.
create or replace function public.guard_load_financial_dispatch_ref()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_d_load uuid;
  v_d_org  uuid;
begin
  if new.financial_dispatch_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.financial_dispatch_id is not distinct from old.financial_dispatch_id then
    return new;
  end if;

  select load_id, organization_id into v_d_load, v_d_org
  from public.dispatches where id = new.financial_dispatch_id;

  if v_d_load is null then
    raise exception 'loads.financial_dispatch_id % references a non-existent dispatch.', new.financial_dispatch_id
      using errcode = '23503';
  end if;
  if v_d_load <> new.id then
    raise exception 'loads.financial_dispatch_id % belongs to load %, not load %.', new.financial_dispatch_id, v_d_load, new.id
      using errcode = '23514';
  end if;
  if v_d_org <> new.organization_id then
    raise exception 'loads.financial_dispatch_id % org % <> load org %.', new.financial_dispatch_id, v_d_org, new.organization_id
      using errcode = '23514';
  end if;

  return new;
end;
$fn$;

create trigger loads_financial_dispatch_ref_guard
  before insert or update on public.loads
  for each row execute function public.guard_load_financial_dispatch_ref();

-- H. Organization / carrier default-change guards ------------------
-- While Model A is disabled, load_proceeds_model may not be set to
-- carrier_paid_directly.
create or replace function public.guard_org_load_proceeds_model()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_gate boolean;
begin
  if new.load_proceeds_model = 'carrier_paid_directly'
     and old.load_proceeds_model is distinct from new.load_proceeds_model then
    select model_a_enabled into v_gate from public.platform_settings where id = true;
    if coalesce(v_gate, false) is not true then
      raise exception 'Cannot set organizations.load_proceeds_model = carrier_paid_directly while Model A is disabled for this platform.'
        using errcode = '0A000';
    end if;
  end if;
  return new;
end;
$fn$;

create trigger organizations_load_proceeds_model_guard
  before update on public.organizations
  for each row execute function public.guard_org_load_proceeds_model();

create or replace function public.guard_carrier_load_proceeds_model()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_gate boolean;
begin
  if new.load_proceeds_model = 'carrier_paid_directly'
     and old.load_proceeds_model is distinct from new.load_proceeds_model then
    select model_a_enabled into v_gate from public.platform_settings where id = true;
    if coalesce(v_gate, false) is not true then
      raise exception 'Cannot set carriers.load_proceeds_model = carrier_paid_directly while Model A is disabled for this platform.'
        using errcode = '0A000';
    end if;
  end if;
  return new;
end;
$fn$;

create trigger carriers_load_proceeds_model_guard
  before update on public.carriers
  for each row execute function public.guard_carrier_load_proceeds_model();

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare
  v_labels text;
  v_n integer;
  b record;
begin
  select * into b from _mig0125_baseline;

  -- enums exact
  select string_agg(e.enumlabel, ',' order by e.enumsortorder) into v_labels
  from pg_enum e join pg_type t on t.oid = e.enumtypid join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'proceeds_model';
  if v_labels is distinct from 'dispatcher_receives_funds,carrier_paid_directly' then
    raise exception '0125 postcondition: proceeds_model members = "%", expected "dispatcher_receives_funds,carrier_paid_directly".', v_labels;
  end if;
  select string_agg(e.enumlabel, ',' order by e.enumsortorder) into v_labels
  from pg_enum e join pg_type t on t.oid = e.enumtypid join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'proceeds_payer';
  if v_labels is distinct from 'broker,factoring_company,shipper,dispatcher,other' then
    raise exception '0125 postcondition: proceeds_payer members = "%", expected "broker,factoring_company,shipper,dispatcher,other".', v_labels;
  end if;

  -- platform_settings
  if to_regclass('public.platform_settings') is null then
    raise exception '0125 postcondition: public.platform_settings was not created.';
  end if;
  if (select count(*) from public.platform_settings) <> 1 then
    raise exception '0125 postcondition: public.platform_settings does not have exactly 1 row.';
  end if;
  if (select model_a_enabled from public.platform_settings where id = true) is not false then
    raise exception '0125 postcondition: platform_settings.model_a_enabled is not FALSE.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.platform_settings'::regclass) then
    raise exception '0125 postcondition: RLS not enabled on platform_settings.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='platform_settings' and policyname='platform_settings_select' and cmd='SELECT') then
    raise exception '0125 postcondition: platform_settings_select policy missing.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='platform_settings' and cmd in ('INSERT','UPDATE','DELETE','ALL')) then
    raise exception '0125 postcondition: platform_settings has an unexpected write policy.';
  end if;

  -- columns exact shape
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='organizations' and column_name='load_proceeds_model'
      and udt_name='proceeds_model' and is_nullable='NO' and column_default like '%dispatcher_receives_funds%') then
    raise exception '0125 postcondition: organizations.load_proceeds_model is not (proceeds_model, NOT NULL, DEFAULT dispatcher_receives_funds).';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='carriers' and column_name='load_proceeds_model'
      and udt_name='proceeds_model' and is_nullable='YES' and column_default is null) then
    raise exception '0125 postcondition: carriers.load_proceeds_model is not (proceeds_model, nullable, no default).';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='dispatches' and column_name='proceeds_model'
      and udt_name='proceeds_model' and is_nullable='YES' and column_default is null) then
    raise exception '0125 postcondition: dispatches.proceeds_model is not (proceeds_model, nullable, no default).';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='dispatches' and column_name='proceeds_payer'
      and udt_name='proceeds_payer' and is_nullable='YES' and column_default is null) then
    raise exception '0125 postcondition: dispatches.proceeds_payer is not (proceeds_payer, nullable, no default).';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='dispatches' and column_name='proceeds_payer_note'
      and data_type='text' and is_nullable='YES' and column_default is null) then
    raise exception '0125 postcondition: dispatches.proceeds_payer_note is not (text, nullable, no default).';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id'
      and data_type='uuid' and is_nullable='YES' and column_default is null) then
    raise exception '0125 postcondition: loads.financial_dispatch_id is not (uuid, nullable, no default).';
  end if;

  -- FK + ON DELETE RESTRICT
  if not exists (
    select 1 from pg_constraint c
    where c.conrelid = 'public.loads'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.dispatches'::regclass
      and c.confdeltype = 'r'
      and (select array_agg(a.attname order by k.ord)
           from unnest(c.conkey) with ordinality as k(attnum, ord)
           join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum)
          = array['financial_dispatch_id']::name[]
  ) then
    raise exception '0125 postcondition: loads.financial_dispatch_id FK to dispatches(id) ON DELETE RESTRICT is missing/wrong.';
  end if;

  -- unique partial index
  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and tablename='loads' and indexname='uq_loads_financial_dispatch_one_per_dispatch'
  ) then
    raise exception '0125 postcondition: index uq_loads_financial_dispatch_one_per_dispatch missing.';
  end if;
  if not exists (
    select 1 from pg_index i join pg_class ic on ic.oid = i.indexrelid
    where ic.relname = 'uq_loads_financial_dispatch_one_per_dispatch' and i.indisunique and i.indpred is not null
  ) then
    raise exception '0125 postcondition: uq_loads_financial_dispatch_one_per_dispatch is not a UNIQUE partial index.';
  end if;

  -- resolver
  if to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)') is null then
    raise exception '0125 postcondition: resolve_dispatch_proceeds_model(uuid) missing.';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='resolve_dispatch_proceeds_model'
      and p.provolatile='s' and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%'
  ) then
    raise exception '0125 postcondition: resolve_dispatch_proceeds_model is not (stable, security definer, search_path=public).';
  end if;
  -- behavior: an existing (unstamped) dispatch resolves to dispatcher_receives_funds
  if (select count(*) from public.dispatches) > 0 then
    if (select public.resolve_dispatch_proceeds_model((select id from public.dispatches order by id limit 1)))
       is distinct from 'dispatcher_receives_funds'::public.proceeds_model then
      raise exception '0125 postcondition: resolver did not return dispatcher_receives_funds for an unstamped dispatch.';
    end if;
  end if;
  -- behavior: missing dispatch -> NULL
  if (select public.resolve_dispatch_proceeds_model('00000000-0000-0000-0000-000000000000'::uuid)) is not null then
    raise exception '0125 postcondition: resolver did not return NULL for a missing dispatch id.';
  end if;

  -- trigger functions + triggers present with correct timing
  if to_regprocedure('public.stamp_dispatch_proceeds_model()')     is null then raise exception '0125 postcondition: stamp_dispatch_proceeds_model() missing.'; end if;
  if to_regprocedure('public.assign_load_financial_dispatch()')    is null then raise exception '0125 postcondition: assign_load_financial_dispatch() missing.'; end if;
  if to_regprocedure('public.guard_load_financial_dispatch_ref()') is null then raise exception '0125 postcondition: guard_load_financial_dispatch_ref() missing.'; end if;
  if to_regprocedure('public.guard_org_load_proceeds_model()')     is null then raise exception '0125 postcondition: guard_org_load_proceeds_model() missing.'; end if;
  if to_regprocedure('public.guard_carrier_load_proceeds_model()') is null then raise exception '0125 postcondition: guard_carrier_load_proceeds_model() missing.'; end if;

  if not exists (select 1 from pg_trigger where tgname='dispatches_stamp_proceeds' and tgrelid='public.dispatches'::regclass and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT%') then
    raise exception '0125 postcondition: trigger dispatches_stamp_proceeds (BEFORE INSERT on dispatches) missing/wrong.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass and not tgisinternal and pg_get_triggerdef(oid) ilike '%AFTER INSERT%') then
    raise exception '0125 postcondition: trigger dispatches_assign_financial_controller (AFTER INSERT on dispatches) missing/wrong.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='loads_financial_dispatch_ref_guard' and tgrelid='public.loads'::regclass and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%') then
    raise exception '0125 postcondition: trigger loads_financial_dispatch_ref_guard (BEFORE INSERT OR UPDATE on loads) missing/wrong.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='organizations_load_proceeds_model_guard' and tgrelid='public.organizations'::regclass and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE UPDATE%') then
    raise exception '0125 postcondition: trigger organizations_load_proceeds_model_guard (BEFORE UPDATE on organizations) missing/wrong.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='carriers_load_proceeds_model_guard' and tgrelid='public.carriers'::regclass and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE UPDATE%') then
    raise exception '0125 postcondition: trigger carriers_load_proceeds_model_guard (BEFORE UPDATE on carriers) missing/wrong.';
  end if;

  -- LEGACY data untouched
  execute 'select count(*) from public.dispatches where proceeds_model is not null' into v_n;
  if v_n <> 0 then raise exception '0125 postcondition: % dispatch row(s) have a non-NULL proceeds_model -- must be 0.', v_n; end if;
  execute 'select count(*) from public.dispatches where proceeds_payer is not null' into v_n;
  if v_n <> 0 then raise exception '0125 postcondition: % dispatch row(s) have a non-NULL proceeds_payer -- must be 0.', v_n; end if;
  execute 'select count(*) from public.dispatches where proceeds_payer_note is not null' into v_n;
  if v_n <> 0 then raise exception '0125 postcondition: % dispatch row(s) have a non-NULL proceeds_payer_note -- must be 0.', v_n; end if;
  execute 'select count(*) from public.loads where financial_dispatch_id is not null' into v_n;
  if v_n <> 0 then raise exception '0125 postcondition: % load row(s) have a non-NULL financial_dispatch_id -- must be 0 immediately after 0125 (0126 does the backfill).', v_n; end if;
  if (select count(*) from public.carriers where load_proceeds_model is not null) <> 0 then
    raise exception '0125 postcondition: a carrier row has a non-NULL load_proceeds_model -- must be 0.';
  end if;
  if (select count(*) from public.organizations where load_proceeds_model <> 'dispatcher_receives_funds') <> 0 then
    raise exception '0125 postcondition: an organization row observes load_proceeds_model <> dispatcher_receives_funds -- expected all default.';
  end if;

  -- COUNTS preserved vs captured baseline
  if (select count(*) from public.organizations)              <> b.n_org             then raise exception '0125 postcondition: organizations count changed.'; end if;
  if (select count(*) from public.carriers)                   <> b.n_carrier         then raise exception '0125 postcondition: carriers count changed.'; end if;
  if (select count(*) from public.dispatches)                 <> b.n_dispatch        then raise exception '0125 postcondition: dispatches count changed.'; end if;
  if (select count(*) from public.loads)                      <> b.n_load            then raise exception '0125 postcondition: loads count changed.'; end if;
  if (select count(*) from public.invoices)                   <> b.n_invoice         then raise exception '0125 postcondition: invoices count changed.'; end if;
  if (select count(*) from public.invoice_line_items)         <> b.n_invoice_li      then raise exception '0125 postcondition: invoice_line_items count changed.'; end if;
  if (select count(*) from public.payments)                   <> b.n_payment         then raise exception '0125 postcondition: payments count changed.'; end if;
  if (select count(*) from public.settlements)                <> b.n_settlement      then raise exception '0125 postcondition: settlements count changed.'; end if;
  if (select count(*) from public.settlement_line_items)      <> b.n_sli             then raise exception '0125 postcondition: settlement_line_items count changed.'; end if;
  if (select count(*) from public.carrier_settlement_payments) <> b.n_csp            then raise exception '0125 postcondition: carrier_settlement_payments count changed.'; end if;
  if (select count(*) from public.billing_records)            <> b.n_billing_records then raise exception '0125 postcondition: billing_records count changed.'; end if;
  if (select count(*) from public.organization_subscriptions) <> b.n_orgsub          then raise exception '0125 postcondition: organization_subscriptions count changed.'; end if;
  if (select count(*) from public.subscription_plans)         <> b.n_plan            then raise exception '0125 postcondition: subscription_plans count changed.'; end if;

  -- 0124 landmark still intact (not touched)
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions' and column_name='stripe_checkout_attempt_id') then
    raise exception '0125 postcondition: 0124 landmark organization_subscriptions.stripe_checkout_attempt_id disappeared.';
  end if;

  -- auto-invoice trigger NOT touched: it must still exist with its 0068 body
  if not exists (select 1 from pg_trigger where tgname='auto_generate_invoice_on_delivery' and tgrelid='public.loads'::regclass and not tgisinternal) then
    raise exception '0125 postcondition: auto_generate_invoice_on_delivery trigger disappeared -- 0125 must not touch it.';
  end if;

  raise notice '0125 complete: proceeds_model/proceeds_payer enums, platform_settings (model_a_enabled=false), org/carrier/dispatch/load columns, resolver, and 5 triggers created. NO dispatch classified, NO load controller assigned, auto-invoice trigger untouched, all protected counts preserved.';
end
$mig$;
