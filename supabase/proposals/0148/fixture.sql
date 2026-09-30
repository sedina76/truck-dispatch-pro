-- NOT APPROVED FOR PRODUCTION. Disposable synthetic model only.
CREATE SCHEMA auth;
CREATE TYPE public.org_role AS ENUM ('owner','admin','dispatcher','accountant','driver','viewer');
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;
CREATE FUNCTION public.current_org_id() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT md5('org1')::uuid $$;
CREATE FUNCTION public.has_role(public.org_role[]) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT 'owner'::public.org_role = ANY($1) $$;
CREATE FUNCTION public.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := now(); RETURN NEW; END $$;
CREATE TABLE public.organizations(id uuid PRIMARY KEY);
CREATE TABLE public.profiles(id uuid PRIMARY KEY, organization_id uuid REFERENCES public.organizations);
CREATE TABLE public.carriers(id uuid PRIMARY KEY, organization_id uuid REFERENCES public.organizations);
CREATE TABLE public.documents(id uuid PRIMARY KEY, organization_id uuid REFERENCES public.organizations);
CREATE TYPE public.integration_provider AS ENUM ('dat','stripe');
CREATE TABLE public.integration_settings(id uuid PRIMARY KEY, organization_id uuid REFERENCES public.organizations, provider public.integration_provider NOT NULL, is_enabled boolean NOT NULL DEFAULT false);
CREATE TABLE public.unresolved_carrier_records(id uuid PRIMARY KEY, record_type text, payload jsonb);
CREATE TABLE public.carrier_brokers(carrier_id uuid REFERENCES public.carriers, broker_id uuid, status text, factoring_eligible boolean);
CREATE TABLE public.carrier_customers(carrier_id uuid REFERENCES public.carriers, customer_id uuid, status text, factoring_eligible boolean);
CREATE TABLE public.loads(id uuid PRIMARY KEY, organization_id uuid REFERENCES public.organizations, carrier_id uuid REFERENCES public.carriers, broker_id uuid, customer_id uuid);
CREATE TABLE public.dispatches(id uuid PRIMARY KEY, organization_id uuid REFERENCES public.organizations, carrier_id uuid REFERENCES public.carriers);
CREATE TABLE public.invoices(id uuid PRIMARY KEY, organization_id uuid REFERENCES public.organizations, status text NOT NULL, total_amount numeric(12,2), amount_paid numeric(12,2), load_id uuid REFERENCES public.loads, dispatch_id uuid REFERENCES public.dispatches, broker_id uuid, customer_id uuid);
CREATE TABLE public.payments(id uuid PRIMARY KEY, invoice_id uuid REFERENCES public.invoices, status text, amount numeric(12,2));
create table public.factoring_companies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  legal_name text,
  contact_name text,
  email text,
  phone text,
  website text,
  address_line1 text,
  city text,
  state text,
  postal_code text,
  account_number text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists set_updated_at on public.factoring_companies;
create trigger set_updated_at before update on public.factoring_companies
  for each row execute function public.set_updated_at();

alter table public.factoring_companies enable row level security;

create policy factoring_companies_select on public.factoring_companies
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_companies_insert on public.factoring_companies
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_companies_update on public.factoring_companies
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy factoring_companies_delete on public.factoring_companies
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));

create table public.factoring_relationships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  factoring_company_id uuid not null references public.factoring_companies (id) on delete restrict,
  relationship_name text,
  default_advance_percentage numeric(5, 2) not null check (default_advance_percentage >= 0 and default_advance_percentage <= 100),
  default_factoring_fee_percentage numeric(5, 2) not null check (default_factoring_fee_percentage >= 0 and default_factoring_fee_percentage <= 100),
  default_reserve_percentage numeric(5, 2) not null check (default_reserve_percentage >= 0 and default_reserve_percentage <= 100),
  fee_timing text not null check (fee_timing in ('deducted_at_funding', 'deducted_from_reserve')),
  recourse_type text not null check (recourse_type in ('recourse', 'non_recourse')),
  payment_terms_days integer,
  minimum_fee numeric(10, 2) check (minimum_fee is null or minimum_fee >= 0),
  wire_fee numeric(10, 2) check (wire_fee is null or wire_fee >= 0),
  ach_fee numeric(10, 2) check (ach_fee is null or ach_fee >= 0),
  other_fee_default numeric(10, 2) check (other_fee_default is null or other_fee_default >= 0),
  is_default boolean not null default false,
  is_active boolean not null default true,
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint factoring_relationships_valid_effective_range check (
    effective_to is null or effective_from is null or effective_to >= effective_from
  ),
  constraint factoring_relationships_default_must_be_active check (not is_default or is_active)
);

create unique index factoring_relationships_one_default_per_org
  on public.factoring_relationships (organization_id)
  where is_default and is_active;

drop trigger if exists set_updated_at on public.factoring_relationships;
create trigger set_updated_at before update on public.factoring_relationships
  for each row execute function public.set_updated_at();

create or replace function public.guard_factoring_relationship_org()
returns trigger
language plpgsql
as $$
declare
  v_company_org uuid;
begin
  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factoring relationship must reference a factoring company in the same organization.';
  end if;
  return new;
end;
$$;

drop trigger if exists factoring_relationships_guard_org on public.factoring_relationships;
create trigger factoring_relationships_guard_org
  before insert on public.factoring_relationships
  for each row execute function public.guard_factoring_relationship_org();

alter table public.factoring_relationships enable row level security;

create policy factoring_relationships_select on public.factoring_relationships
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_relationships_insert on public.factoring_relationships
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_relationships_update on public.factoring_relationships
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy factoring_relationships_delete on public.factoring_relationships
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));


create or replace function public.set_default_factoring_relationship(p_relationship_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_relationship record;
  v_company_active boolean;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to change factoring settings.';
  end if;

  perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:' || v_org_id::text));

  select id, organization_id, factoring_company_id, is_active
    into v_relationship
  from public.factoring_relationships
  where id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org_id then
    raise exception 'This factoring relationship is not available.';
  end if;

  if not v_relationship.is_active then
    raise exception 'This factoring relationship is inactive.';
  end if;

  select is_active into v_company_active from public.factoring_companies where id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'This factoring relationship''s factoring company is inactive.';
  end if;

  update public.factoring_relationships
  set is_default = false
  where organization_id = v_org_id and is_default = true and id <> p_relationship_id;

  update public.factoring_relationships
  set is_default = true
  where id = p_relationship_id;
end;
$$;

grant execute on function public.set_default_factoring_relationship(uuid) to authenticated;

create or replace function public.guard_factoring_company_deactivation()
returns trigger
language plpgsql
as $$
declare
  v_has_active_default boolean;
begin
  if old.is_active and not new.is_active then
    perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:' || old.organization_id::text));

    select exists (
      select 1 from public.factoring_relationships
      where factoring_company_id = old.id and is_active = true and is_default = true
    ) into v_has_active_default;

    if v_has_active_default then
      raise exception 'This factoring company cannot be deactivated while one of its relationships is the default. Choose another default relationship first.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists factoring_companies_guard_deactivation on public.factoring_companies;
create trigger factoring_companies_guard_deactivation
  before update of is_active on public.factoring_companies
  for each row execute function public.guard_factoring_company_deactivation();

CREATE TABLE public.factored_invoices(id uuid PRIMARY KEY, invoice_id uuid REFERENCES public.invoices, factoring_relationship_id uuid REFERENCES public.factoring_relationships ON DELETE RESTRICT, status text, amount numeric(12,2));
CREATE TABLE public.factoring_events(id uuid PRIMARY KEY, factored_invoice_id uuid REFERENCES public.factored_invoices ON DELETE RESTRICT, event_type text, payload jsonb);
CREATE TABLE public.activity_logs(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.brokers(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.customers(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.drivers(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.invoice_line_items(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.load_stops(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.settlement_line_items(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.settlements(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.trailers(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.trucks(id uuid PRIMARY KEY, payload jsonb NOT NULL);
DROP POLICY factoring_companies_delete ON public.factoring_companies;
CREATE POLICY factoring_companies_delete ON public.factoring_companies FOR DELETE USING (organization_id = public.current_org_id() AND public.has_role(array['owner','admin']::public.org_role[]));
DROP POLICY factoring_relationships_delete ON public.factoring_relationships;
CREATE POLICY factoring_relationships_delete ON public.factoring_relationships FOR DELETE USING (organization_id = public.current_org_id() AND public.has_role(array['owner','admin']::public.org_role[]));
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.activity_logs TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.brokers TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.carriers TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.customers TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.dispatches TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.documents TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.drivers TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factored_invoices TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_companies TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_events TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_relationships TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.integration_settings TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.invoice_line_items TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.invoices TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.load_stops TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.loads TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.organizations TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.payments TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.profiles TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.settlement_line_items TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.settlements TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.trailers TO anon, authenticated;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.trucks TO anon, authenticated;
INSERT INTO public.organizations SELECT md5('org'||g)::uuid FROM generate_series(1,2) g;
INSERT INTO public.carriers VALUES (md5('carrier1')::uuid,md5('org1')::uuid),(md5('carrier2')::uuid,md5('org2')::uuid),(md5('carrier3')::uuid,md5('org2')::uuid);
INSERT INTO public.factoring_companies(id,organization_id,name,created_at,updated_at) SELECT md5('factor'||g)::uuid, md5('org'||g)::uuid, 'synthetic factor '||g, '2020-01-01', '2020-01-01' FROM generate_series(1,2) g;
INSERT INTO public.factoring_relationships(id,organization_id,factoring_company_id,default_advance_percentage,default_factoring_fee_percentage,default_reserve_percentage,fee_timing,recourse_type,is_default,effective_from,created_at,updated_at)
SELECT md5('relationship'||g)::uuid,md5('org'||CASE WHEN g=1 THEN 1 ELSE 2 END)::uuid,md5('factor'||CASE WHEN g=1 THEN 1 ELSE 2 END)::uuid,80,2,18,'deducted_at_funding','recourse',g<3,'2020-01-01','2020-01-01','2020-01-01' FROM generate_series(1,4) g;
INSERT INTO public.loads SELECT md5('load'||g)::uuid,md5('org2')::uuid,md5('carrier'||CASE WHEN g=2 THEN 3 ELSE 2 END)::uuid,md5('broker')::uuid,md5('customer')::uuid FROM generate_series(1,3) g;
INSERT INTO public.dispatches SELECT md5('dispatch'||g)::uuid,organization_id,carrier_id FROM public.loads CROSS JOIN LATERAL (SELECT CASE id WHEN md5('load1')::uuid THEN 1 WHEN md5('load2')::uuid THEN 2 ELSE 3 END g) n;
INSERT INTO public.invoices SELECT md5('invoice'||g)::uuid,md5('org2')::uuid,CASE WHEN g<=6 THEN 'draft' WHEN g<=27 THEN 'sent' WHEN g=28 THEN 'viewed' WHEN g<=30 THEN 'partially_paid' WHEN g<=36 THEN 'paid' ELSE 'void' END,100,CASE WHEN g BETWEEN 29 AND 30 THEN 50 WHEN g BETWEEN 31 AND 36 THEN 100 ELSE 0 END,md5('load'||CASE WHEN g=2 THEN 2 ELSE 1 END)::uuid,md5('dispatch'||CASE WHEN g=2 THEN 2 ELSE 1 END)::uuid,md5('broker')::uuid,CASE WHEN g<=3 THEN md5('customer')::uuid END FROM generate_series(1,38) g;
INSERT INTO public.payments SELECT md5('payment'||g)::uuid,md5('invoice'||(g+20))::uuid,CASE WHEN g<=15 THEN 'posted' ELSE 'voided' END,10 FROM generate_series(1,17) g;
INSERT INTO public.factored_invoices SELECT md5('factored'||g)::uuid,md5('invoice'||g)::uuid,md5('relationship'||CASE WHEN g<=2 THEN 2 ELSE 3 END)::uuid,CASE WHEN g<=3 THEN 'pending' WHEN g=4 THEN 'rejected' ELSE 'partially_settled' END,80 FROM generate_series(1,6) g;
INSERT INTO public.factoring_events SELECT md5('event'||g)::uuid,md5('factored'||g)::uuid,'synthetic_history',jsonb_build_object('amount',80,'synthetic',true) FROM generate_series(1,6) g;
INSERT INTO public.activity_logs VALUES(md5('activity_logs')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.brokers VALUES(md5('brokers')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.customers VALUES(md5('customers')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.drivers VALUES(md5('drivers')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.invoice_line_items VALUES(md5('invoice_line_items')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.load_stops VALUES(md5('load_stops')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.settlement_line_items VALUES(md5('settlement_line_items')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.settlements VALUES(md5('settlements')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.trailers VALUES(md5('trailers')::uuid,'{"synthetic":true,"amount":100}');
INSERT INTO public.trucks VALUES(md5('trucks')::uuid,'{"synthetic":true,"amount":100}');

-- Additional synthetic witnesses exercise non-table ACLs, generated expressions,
-- defaults and sequence metadata; these are NOT claimed production objects.
CREATE SEQUENCE public.synthetic_audit_sequence;
GRANT USAGE, SELECT ON SEQUENCE public.synthetic_audit_sequence TO authenticated;
ALTER TABLE public.activity_logs ADD COLUMN synthetic_sequence bigint DEFAULT nextval('public.synthetic_audit_sequence');
ALTER TABLE public.activity_logs ADD COLUMN synthetic_size integer GENERATED ALWAYS AS (length(payload::text)) STORED;
GRANT SELECT(synthetic_size) ON public.activity_logs TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE ON SEQUENCES TO authenticated;

-- Catalog-serializer regression witnesses (harness.sql _td0148.catalog()).
-- Each pair below shares the first 63 bytes of its composite catalog key
-- ("kind:schema.object[...]") and differs only afterward -- the exact shape
-- PostgreSQL's fixed-length "name" type (NAMEDATALEN=64, a 63-byte usable
-- identifier) can silently collapse if any UNION branch in _td0148.catalog()
-- inherits that type instead of unbounded text. NOT claimed production
-- objects: never granted, revoked, or referenced by any modeled 0148 table
-- list, and untouched by proposed_0148.sql/rollback.sql.
CREATE TABLE public.td0148_collision_rel_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz_a_tail(id uuid PRIMARY KEY, payload jsonb NOT NULL);
CREATE TABLE public.td0148_collision_rel_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz_b_tail(id uuid PRIMARY KEY, payload jsonb NOT NULL);
INSERT INTO public.td0148_collision_rel_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz_a_tail VALUES(md5('collision_rel_a')::uuid,'{"synthetic":true,"witness":"relation_a"}');
INSERT INTO public.td0148_collision_rel_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz_b_tail VALUES(md5('collision_rel_b')::uuid,'{"synthetic":true,"witness":"relation_b"}');

CREATE TABLE public.td0148_collision_columns(
  id uuid PRIMARY KEY,
  zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz_col_a_tail text,
  zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz_col_b_tail text
);
INSERT INTO public.td0148_collision_columns VALUES(md5('collision_columns')::uuid,'column_a_value','column_b_value');
