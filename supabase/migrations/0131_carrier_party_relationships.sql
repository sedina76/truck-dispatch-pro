-- =============================================================================
-- 0131_carrier_party_relationships.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0130 live. Phase 3A slice 2. ADDITIVE ONLY. Creates NO rows; every
-- existing table is untouched.
--
-- WHAT THIS MIGRATION DOES
--   * enum   public.carrier_party_status ('draft','active','inactive')
--   * table  public.carrier_brokers   -- per-(carrier, broker) billing setup
--   * table  public.carrier_customers -- per-(carrier, customer) billing setup
--       Both hold: status, billing_email, payment_terms_days,
--       external_account_number, billing_instructions, document_instructions,
--       document_requirements public.document_type[] (correction L),
--       factoring_eligible, quickbooks_customer_ref, activated_at/by.
--       UNIQUE (carrier_id, broker_id) / (carrier_id, customer_id).
--       A row can only be 'active' when billing_email + payment_terms_days
--       are set (CHECK). document_requirements may not contain NULL (CHECK).
--   * function + triggers public.guard_carrier_party_org() BEFORE INSERT OR
--       UPDATE on both tables: organization_id must equal the carrier's org
--       AND the broker's / customer's org (correction R).
--   * function public.activate_carrier_party(uuid,uuid,uuid,jsonb) -> jsonb
--       SECURITY DEFINER, pinned search_path, EXECUTE revoked from PUBLIC,
--       granted to authenticated. Upserts + activates one relationship for
--       the caller's org. Returns a STRUCTURED result; on incomplete billing
--       setup it returns {success:false,status:'blocked',...} and writes
--       nothing (correction B) -- it does not RAISE for business validation.
--   * RLS on both tables: select = same org (any role, including viewer);
--       insert/update = owner/admin/dispatcher/accountant. Accountant is
--       included deliberately: billing_email/payment_terms_days/
--       external_account_number/document_requirements/factoring_eligible/
--       quickbooks_customer_ref are accounts-payable/receivable data, and
--       decision 4's setup workflow is explicitly billing/terms/QuickBooks-
--       mapping work an accountant should be able to perform, not just a
--       dispatcher. Dispatcher is ALSO included because decision 4 has the
--       dispatcher trigger first-time setup while selecting a carrier for a
--       load. NO delete policy (inactivate, not delete -- Output 4 /
--       correction F).
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does NOT auto-create a relationship during invoicing / dispatch (that
--     is a later server-slice concern; here only the explicit RPC creates one)
--   * does NOT add carrier_id to invoices/payments/factoring (later slices)
--   * does NOT touch loads, dispatches, invoices, payments, settlements,
--     factoring_*, documents, or any RPC on them
--   * does NOT change any existing RLS policy or grant
--
-- DATA EFFECT: none. Two empty tables, one enum, one function, two triggers.
--
-- STRUCTURE: explicit BEGIN/COMMIT. DO $mig$ PHASE 1 preconditions -> plain
-- DDL PHASE 2 -> DO $mig$ PHASE 3 postconditions. Any RAISE rolls back all.
-- NOT idempotent (re-run RAISEs in PHASE 1).
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
begin
  if to_regclass('public.organizations') is null then raise exception '0131 precondition: public.organizations missing. STOP.'; end if;
  if to_regclass('public.carriers')      is null then raise exception '0131 precondition: public.carriers missing. STOP.'; end if;
  if to_regclass('public.brokers')       is null then raise exception '0131 precondition: public.brokers missing. STOP.'; end if;
  if to_regclass('public.customers')     is null then raise exception '0131 precondition: public.customers missing. STOP.'; end if;
  if to_regclass('public.profiles')      is null then raise exception '0131 precondition: public.profiles missing. STOP.'; end if;

  if to_regprocedure('public.current_org_id()')            is null then raise exception '0131 precondition: public.current_org_id() missing. STOP.'; end if;
  if to_regprocedure('public.has_role(public.org_role[])') is null then raise exception '0131 precondition: public.has_role(org_role[]) missing. STOP.'; end if;
  if to_regprocedure('public.set_updated_at()')            is null then raise exception '0131 precondition: public.set_updated_at() missing. STOP.'; end if;

  -- 0130 landmark
  if to_regclass('public.carrier_remittance_profiles') is null then
    raise exception '0131 precondition: public.carrier_remittance_profiles missing -- apply 0130 first. STOP.';
  end if;
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
                 where n.nspname='public' and t.typname='unresolved_record_status') then
    raise exception '0131 precondition: type public.unresolved_record_status missing -- apply 0130 first. STOP.';
  end if;

  -- document_type enum must exist (document_requirements array element type)
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
                 where n.nspname='public' and t.typname='document_type') then
    raise exception '0131 precondition: enum public.document_type missing. STOP.';
  end if;

  -- objects 0131 CREATES must be ABSENT
  if exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
             where n.nspname='public' and t.typname='carrier_party_status') then
    raise exception '0131 precondition: type public.carrier_party_status already exists -- partial apply? STOP.';
  end if;
  if to_regclass('public.carrier_brokers')   is not null then raise exception '0131 precondition: table public.carrier_brokers already exists. STOP.'; end if;
  if to_regclass('public.carrier_customers') is not null then raise exception '0131 precondition: table public.carrier_customers already exists. STOP.'; end if;
  if to_regprocedure('public.guard_carrier_party_org()') is not null then raise exception '0131 precondition: function public.guard_carrier_party_org() already exists. STOP.'; end if;
  if to_regprocedure('public.activate_carrier_party(uuid,uuid,uuid,jsonb)') is not null then raise exception '0131 precondition: function public.activate_carrier_party(...) already exists. STOP.'; end if;

  create temp table _mig0131_baseline on commit drop as
  select
    (select count(*) from public.organizations) as n_org,
    (select count(*) from public.carriers)      as n_carrier,
    (select count(*) from public.brokers)       as n_broker,
    (select count(*) from public.customers)     as n_customer,
    (select count(*) from public.loads)         as n_load,
    (select count(*) from public.invoices)      as n_invoice;

  raise notice '0131 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

create type public.carrier_party_status as enum ('draft','active','inactive');

-- carrier_brokers ----------------------------------------------------------
create table public.carrier_brokers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  broker_id  uuid not null references public.brokers (id)  on delete restrict,
  status public.carrier_party_status not null default 'draft',
  billing_email text,
  payment_terms_days integer
    check (payment_terms_days is null or payment_terms_days between 0 and 365),
  external_account_number text,
  billing_instructions text,
  document_instructions text,
  document_requirements public.document_type[] not null default '{}'::public.document_type[],
  factoring_eligible boolean not null default false,
  quickbooks_customer_ref text,
  activated_at timestamptz,
  activated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint carrier_brokers_carrier_broker_uq unique (carrier_id, broker_id),
  constraint carrier_brokers_active_requires_billing
    check (status <> 'active'
           or (billing_email is not null and btrim(billing_email) <> '' and payment_terms_days is not null)),
  constraint carrier_brokers_doc_req_no_nulls
    check (array_position(document_requirements, null) is null)
);

comment on table public.carrier_brokers is
  'Per-(carrier, broker) billing relationship. The same broker can have different terms/instructions per carrier. A row must be explicitly activated (status=active) before dispatch completion / invoice issuance / factoring for that carrier+broker is allowed by later slices. Never auto-created during invoicing.';

create trigger set_updated_at
  before update on public.carrier_brokers
  for each row execute function public.set_updated_at();

-- carrier_customers ------------------------------------------------------
create table public.carrier_customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id  uuid not null references public.carriers (id)  on delete cascade,
  customer_id uuid not null references public.customers (id) on delete restrict,
  status public.carrier_party_status not null default 'draft',
  billing_email text,
  payment_terms_days integer
    check (payment_terms_days is null or payment_terms_days between 0 and 365),
  external_account_number text,
  billing_instructions text,
  document_instructions text,
  document_requirements public.document_type[] not null default '{}'::public.document_type[],
  factoring_eligible boolean not null default false,
  quickbooks_customer_ref text,
  activated_at timestamptz,
  activated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint carrier_customers_carrier_customer_uq unique (carrier_id, customer_id),
  constraint carrier_customers_active_requires_billing
    check (status <> 'active'
           or (billing_email is not null and btrim(billing_email) <> '' and payment_terms_days is not null)),
  constraint carrier_customers_doc_req_no_nulls
    check (array_position(document_requirements, null) is null)
);

comment on table public.carrier_customers is
  'Per-(carrier, customer) billing relationship. Same shape and rules as carrier_brokers.';

create trigger set_updated_at
  before update on public.carrier_customers
  for each row execute function public.set_updated_at();

-- same-org guard (correction R) ---------------------------------------
create or replace function public.guard_carrier_party_org()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_carrier_org uuid;
  v_party_org uuid;
begin
  select organization_id into v_carrier_org from public.carriers where id = new.carrier_id;
  if v_carrier_org is null then
    raise exception '%.carrier_id % references a non-existent carrier.', tg_table_name, new.carrier_id using errcode = '23503';
  end if;
  if v_carrier_org <> new.organization_id then
    raise exception '%.organization_id % <> carrier % org %.', tg_table_name, new.organization_id, new.carrier_id, v_carrier_org using errcode = '23514';
  end if;

  if tg_table_name = 'carrier_brokers' then
    select organization_id into v_party_org from public.brokers where id = new.broker_id;
    if v_party_org is null then
      raise exception 'carrier_brokers.broker_id % references a non-existent broker.', new.broker_id using errcode = '23503';
    end if;
    if v_party_org <> new.organization_id then
      raise exception 'carrier_brokers.organization_id % <> broker % org %.', new.organization_id, new.broker_id, v_party_org using errcode = '23514';
    end if;
  elsif tg_table_name = 'carrier_customers' then
    select organization_id into v_party_org from public.customers where id = new.customer_id;
    if v_party_org is null then
      raise exception 'carrier_customers.customer_id % references a non-existent customer.', new.customer_id using errcode = '23503';
    end if;
    if v_party_org <> new.organization_id then
      raise exception 'carrier_customers.organization_id % <> customer % org %.', new.organization_id, new.customer_id, v_party_org using errcode = '23514';
    end if;
  else
    raise exception 'guard_carrier_party_org attached to unexpected table %.', tg_table_name;
  end if;

  return new;
end;
$fn$;

create trigger carrier_brokers_guard_org
  before insert or update on public.carrier_brokers
  for each row execute function public.guard_carrier_party_org();

create trigger carrier_customers_guard_org
  before insert or update on public.carrier_customers
  for each row execute function public.guard_carrier_party_org();

-- RLS -----------------------------------------------------------------
alter table public.carrier_brokers   enable row level security;
alter table public.carrier_customers enable row level security;

create policy carrier_brokers_select on public.carrier_brokers
  for select using (organization_id = public.current_org_id());
create policy carrier_brokers_insert on public.carrier_brokers
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
  );
create policy carrier_brokers_update on public.carrier_brokers
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy carrier_customers_select on public.carrier_customers
  for select using (organization_id = public.current_org_id());
create policy carrier_customers_insert on public.carrier_customers
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
  );
create policy carrier_customers_update on public.carrier_customers
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());
-- No DELETE policy on either table: relationships are inactivated, not deleted.

revoke all on public.carrier_brokers   from anon;
revoke all on public.carrier_customers from anon;
grant select, insert, update on public.carrier_brokers   to authenticated;
grant select, insert, update on public.carrier_customers to authenticated;

-- activate_carrier_party(...) -------------------------------------
-- Exactly one of p_broker_id / p_customer_id must be non-NULL. Upserts the
-- relationship for the caller's org and sets status='active'. Business
-- validation failure (missing billing_email / payment_terms_days) returns a
-- structured blocked result and writes NOTHING (correction B). Auth / not
-- found / cross-org are hard errors (they SHOULD roll back).
create or replace function public.activate_carrier_party(
  p_carrier_id uuid,
  p_broker_id uuid,
  p_customer_id uuid,
  p_settings jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid := public.current_org_id();
  v_carrier_org uuid;
  v_party_org uuid;
  v_is_broker boolean := p_broker_id is not null;
  v_billing_email text;
  v_terms integer;
  v_doc_reqs public.document_type[];
  v_row public.carrier_brokers%rowtype;
  v_crow public.carrier_customers%rowtype;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'activate_carrier_party: authentication required.' using errcode = '42501';
  end if;
  if v_org is null then
    raise exception 'activate_carrier_party: caller has no organization.' using errcode = '42501';
  end if;
  if not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
    raise exception 'activate_carrier_party: caller role is not permitted.' using errcode = '42501';
  end if;
  if (p_broker_id is not null) = (p_customer_id is not null) then
    raise exception 'activate_carrier_party: pass exactly one of p_broker_id / p_customer_id.' using errcode = '22023';
  end if;

  select organization_id into v_carrier_org from public.carriers where id = p_carrier_id;
  if v_carrier_org is null or v_carrier_org <> v_org then
    raise exception 'activate_carrier_party: carrier % is not in the caller''s organization.', p_carrier_id using errcode = '42501';
  end if;

  if v_is_broker then
    select organization_id into v_party_org from public.brokers where id = p_broker_id;
  else
    select organization_id into v_party_org from public.customers where id = p_customer_id;
  end if;
  if v_party_org is null or v_party_org <> v_org then
    raise exception 'activate_carrier_party: broker/customer is not in the caller''s organization.' using errcode = '42501';
  end if;

  v_billing_email := nullif(btrim(coalesce(p_settings->>'billing_email','')), '');
  v_terms := nullif(p_settings->>'payment_terms_days','')::integer;

  if p_settings ? 'document_requirements' then
    select coalesce(array_agg(value::public.document_type), '{}'::public.document_type[])
    into v_doc_reqs
    from jsonb_array_elements_text(p_settings->'document_requirements') as t(value);
  else
    v_doc_reqs := '{}'::public.document_type[];
  end if;

  -- business validation -> structured blocked result, no write
  if v_billing_email is null or v_terms is null then
    return jsonb_build_object(
      'success', false,
      'status', 'blocked',
      'reason', 'incomplete_billing_setup',
      'message', 'billing_email and payment_terms_days are required to activate this relationship.'
    );
  end if;

  if v_is_broker then
    insert into public.carrier_brokers (
      organization_id, carrier_id, broker_id, status,
      billing_email, payment_terms_days, external_account_number,
      billing_instructions, document_instructions, document_requirements,
      factoring_eligible, quickbooks_customer_ref, activated_at, activated_by
    ) values (
      v_org, p_carrier_id, p_broker_id, 'active',
      v_billing_email, v_terms, nullif(btrim(coalesce(p_settings->>'external_account_number','')), ''),
      nullif(btrim(coalesce(p_settings->>'billing_instructions','')), ''),
      nullif(btrim(coalesce(p_settings->>'document_instructions','')), ''),
      v_doc_reqs,
      coalesce((p_settings->>'factoring_eligible')::boolean, false),
      nullif(btrim(coalesce(p_settings->>'quickbooks_customer_ref','')), ''),
      now(), v_uid
    )
    on conflict (carrier_id, broker_id) do update set
      status = 'active',
      billing_email = excluded.billing_email,
      payment_terms_days = excluded.payment_terms_days,
      external_account_number = excluded.external_account_number,
      billing_instructions = excluded.billing_instructions,
      document_instructions = excluded.document_instructions,
      document_requirements = excluded.document_requirements,
      factoring_eligible = excluded.factoring_eligible,
      quickbooks_customer_ref = excluded.quickbooks_customer_ref,
      activated_at = coalesce(public.carrier_brokers.activated_at, now()),
      activated_by = coalesce(public.carrier_brokers.activated_by, excluded.activated_by)
    returning id into v_id;

    return jsonb_build_object('success', true, 'status', 'active', 'relationship_id', v_id, 'relationship_table', 'carrier_brokers');
  else
    insert into public.carrier_customers (
      organization_id, carrier_id, customer_id, status,
      billing_email, payment_terms_days, external_account_number,
      billing_instructions, document_instructions, document_requirements,
      factoring_eligible, quickbooks_customer_ref, activated_at, activated_by
    ) values (
      v_org, p_carrier_id, p_customer_id, 'active',
      v_billing_email, v_terms, nullif(btrim(coalesce(p_settings->>'external_account_number','')), ''),
      nullif(btrim(coalesce(p_settings->>'billing_instructions','')), ''),
      nullif(btrim(coalesce(p_settings->>'document_instructions','')), ''),
      v_doc_reqs,
      coalesce((p_settings->>'factoring_eligible')::boolean, false),
      nullif(btrim(coalesce(p_settings->>'quickbooks_customer_ref','')), ''),
      now(), v_uid
    )
    on conflict (carrier_id, customer_id) do update set
      status = 'active',
      billing_email = excluded.billing_email,
      payment_terms_days = excluded.payment_terms_days,
      external_account_number = excluded.external_account_number,
      billing_instructions = excluded.billing_instructions,
      document_instructions = excluded.document_instructions,
      document_requirements = excluded.document_requirements,
      factoring_eligible = excluded.factoring_eligible,
      quickbooks_customer_ref = excluded.quickbooks_customer_ref,
      activated_at = coalesce(public.carrier_customers.activated_at, now()),
      activated_by = coalesce(public.carrier_customers.activated_by, excluded.activated_by)
    returning id into v_id;

    return jsonb_build_object('success', true, 'status', 'active', 'relationship_id', v_id, 'relationship_table', 'carrier_customers');
  end if;
end;
$fn$;

revoke all on function public.activate_carrier_party(uuid,uuid,uuid,jsonb) from public;
grant execute on function public.activate_carrier_party(uuid,uuid,uuid,jsonb) to authenticated;

comment on function public.activate_carrier_party(uuid,uuid,uuid,jsonb) is
  'Explicit setup RPC: upserts and activates one carrier<->broker or carrier<->customer billing relationship for the caller''s org. Returns {success:true,status:active,...} or, on incomplete billing setup, {success:false,status:blocked,reason:incomplete_billing_setup} with no write.';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare
  b record;
  v_labels text;
  t text;
begin
  select * into b from _mig0131_baseline;

  select string_agg(e.enumlabel, ',' order by e.enumsortorder) into v_labels
  from pg_enum e join pg_type t2 on t2.oid=e.enumtypid join pg_namespace n on n.oid=t2.typnamespace
  where n.nspname='public' and t2.typname='carrier_party_status';
  if v_labels is distinct from 'draft,active,inactive' then
    raise exception '0131 postcondition: carrier_party_status members = "%", expected "draft,active,inactive".', v_labels;
  end if;

  foreach t in array array['carrier_brokers','carrier_customers'] loop
    if to_regclass('public.'||t) is null then raise exception '0131 postcondition: table public.% missing.', t; end if;
    if (select count(*) from pg_class where oid = ('public.'||t)::regclass and relrowsecurity) <> 1 then
      raise exception '0131 postcondition: RLS not enabled on public.%.', t;
    end if;
    if exists (select 1 from pg_policies where schemaname='public' and tablename=t and cmd in ('DELETE','ALL')) then
      raise exception '0131 postcondition: public.% has an unexpected DELETE/ALL policy.', t;
    end if;
    if (select count(*) from pg_policies where schemaname='public' and tablename=t) <> 3 then
      raise exception '0131 postcondition: public.% does not have exactly 3 policies (select/insert/update).', t;
    end if;
    if not exists (select 1 from pg_constraint where conrelid = ('public.'||t)::regclass and contype='c' and conname like '%active_requires_billing') then
      raise exception '0131 postcondition: public.% missing the active_requires_billing CHECK.', t;
    end if;
    if not exists (select 1 from pg_constraint where conrelid = ('public.'||t)::regclass and contype='c' and conname like '%doc_req_no_nulls') then
      raise exception '0131 postcondition: public.% missing the doc_req_no_nulls CHECK.', t;
    end if;
    if not exists (select 1 from pg_constraint where conrelid = ('public.'||t)::regclass and contype='u') then
      raise exception '0131 postcondition: public.% missing its (carrier_id, party) UNIQUE constraint.', t;
    end if;
    execute format('select count(*) from public.%I', t) into strict v_labels;
    if v_labels <> '0' then raise exception '0131 postcondition: public.% is not empty.', t; end if;
  end loop;

  -- document_requirements is the enum array type
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='carrier_brokers' and column_name='document_requirements'
      and udt_name='_document_type') then
    raise exception '0131 postcondition: carrier_brokers.document_requirements is not public.document_type[].';
  end if;

  -- triggers
  if not exists (select 1 from pg_trigger where tgname='carrier_brokers_guard_org' and tgrelid='public.carrier_brokers'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%') then
    raise exception '0131 postcondition: trigger carrier_brokers_guard_org (BEFORE INSERT OR UPDATE) missing/wrong.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='carrier_customers_guard_org' and tgrelid='public.carrier_customers'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%') then
    raise exception '0131 postcondition: trigger carrier_customers_guard_org (BEFORE INSERT OR UPDATE) missing/wrong.';
  end if;

  -- function hardening
  if to_regprocedure('public.activate_carrier_party(uuid,uuid,uuid,jsonb)') is null then
    raise exception '0131 postcondition: activate_carrier_party(...) missing.';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('activate_carrier_party','guard_carrier_party_org')
      and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'::text[]),',') not like '%search_path=%')
  ) then
    raise exception '0131 postcondition: a 0131 function is not (security definer + pinned search_path).';
  end if;
  if has_function_privilege('public', 'public.activate_carrier_party(uuid,uuid,uuid,jsonb)', 'execute') then
    raise exception '0131 postcondition: activate_carrier_party is still EXECUTE-able by PUBLIC.';
  end if;

  -- nothing else changed
  if (select count(*) from public.organizations) <> b.n_org      then raise exception '0131 postcondition: organizations count changed.'; end if;
  if (select count(*) from public.carriers)      <> b.n_carrier  then raise exception '0131 postcondition: carriers count changed.'; end if;
  if (select count(*) from public.brokers)       <> b.n_broker   then raise exception '0131 postcondition: brokers count changed.'; end if;
  if (select count(*) from public.customers)     <> b.n_customer then raise exception '0131 postcondition: customers count changed.'; end if;
  if (select count(*) from public.loads)         <> b.n_load     then raise exception '0131 postcondition: loads count changed.'; end if;
  if (select count(*) from public.invoices)      <> b.n_invoice  then raise exception '0131 postcondition: invoices count changed.'; end if;

  -- 0130 landmark intact
  if to_regclass('public.carrier_remittance_profiles') is null then
    raise exception '0131 postcondition: 0130 carrier_remittance_profiles disappeared.';
  end if;

  raise notice '0131 complete: carrier_party_status enum; carrier_brokers + carrier_customers (empty, RLS on, no DELETE policy); guard_carrier_party_org on both; activate_carrier_party(...) created. No existing data touched.';
end
$mig$;

commit;
