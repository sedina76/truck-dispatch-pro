-- Synthetic authorization model ONLY. No application migrations, issuance or factoring enabled.
create schema f30_probe;
comment on schema f30_probe is 'F30_SYNTHETIC_ROLE_MODEL_V1';
revoke all on schema f30_probe from public, anon, authenticated, service_role;
create table f30_probe.organizations (id uuid primary key, label text not null unique);
create table f30_probe.memberships (
  id uuid primary key, organization_id uuid not null references f30_probe.organizations,
  role text not null check (role in ('owner','admin','dispatcher','accountant','driver','viewer')),
  label text not null, unique (organization_id,id)
);
create table f30_probe.carriers (id uuid primary key, organization_id uuid not null references f30_probe.organizations, unique(organization_id,id));
create table f30_probe.parties (id uuid primary key, organization_id uuid not null references f30_probe.organizations, kind text not null check(kind in ('broker','customer')), unique(organization_id,id));
create table f30_probe.factors (id uuid primary key, organization_id uuid not null references f30_probe.organizations, unique(organization_id,id));
create table f30_probe.relationships (
  id uuid primary key, organization_id uuid not null, carrier_id uuid not null, factor_id uuid not null,
  routing text not null, terms jsonb not null, unique(organization_id,carrier_id,id),
  foreign key(organization_id,factor_id) references f30_probe.factors(organization_id,id),
  foreign key(organization_id,carrier_id) references f30_probe.carriers(organization_id,id)
);
create table f30_probe.loads (
  id uuid primary key, organization_id uuid not null, carrier_id uuid not null, recipient_id uuid not null,
  freight_amount numeric(12,2) not null check(freight_amount>0), unique(organization_id,carrier_id,id),
  foreign key(organization_id,carrier_id) references f30_probe.carriers(organization_id,id),
  foreign key(organization_id,recipient_id) references f30_probe.parties(organization_id,id)
);
create table f30_probe.dispatches (
  id uuid primary key, organization_id uuid not null, carrier_id uuid not null, load_id uuid not null,
  foreign key(organization_id,carrier_id,load_id) references f30_probe.loads(organization_id,carrier_id,id)
);
create table f30_probe.invoices (
  id uuid primary key, organization_id uuid not null, carrier_id uuid not null, load_id uuid not null, relationship_id uuid not null,
  issuance_status text not null check(issuance_status in ('draft','ready_for_issue','issued')),
  unique(organization_id,id),
  foreign key(organization_id,carrier_id,load_id) references f30_probe.loads(organization_id,carrier_id,id),
  foreign key(organization_id,carrier_id,relationship_id) references f30_probe.relationships(organization_id,carrier_id,id)
);
create table f30_probe.carrier_grants (
  organization_id uuid not null, carrier_id uuid not null, profile_id uuid not null,
  primary key(organization_id,carrier_id,profile_id),
  foreign key(organization_id,carrier_id) references f30_probe.carriers(organization_id,id),
  foreign key(organization_id,profile_id) references f30_probe.memberships(organization_id,id)
);
-- Intent receipts exercise the freeze without issuing an invoice or enabling factoring.
create table f30_probe.receipts (
  organization_id uuid not null, request_key text not null, invoice_id uuid not null, actor_id uuid not null,
  action text not null, resolved jsonb not null,
  primary key(organization_id,request_key),
  foreign key(organization_id,invoice_id) references f30_probe.invoices(organization_id,id),
  foreign key(organization_id,actor_id) references f30_probe.memberships(organization_id,id)
);
create table f30_probe.manifest (singleton boolean primary key check(singleton), source_hash text not null, seed_hash text not null, catalog_hash text not null);

create function f30_probe.check_target() returns void language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $fn$
declare m record;
begin
  if to_regclass('f30_test_control.marker') is null then raise exception using errcode='P0001', message='F30_TEST_MARKER_REQUIRED'; end if;
  select * into strict m from f30_test_control.marker;
  if m.environment is distinct from 'nonproduction-f30' or m.database_name is distinct from current_database()
     or m.project_ref is null
     or m.project_ref in ('zteixenjpcygjvznueuo','fjmrvvyjvqdyopnyetez')
     or m.project_ref like 'fjmrvvyjvqd%' or m.project_ref !~ '^[a-z0-9]{20}$'
     or m.fixture_id is distinct from 'F30_SYNTHETIC_ROLE_MODEL_V1'
     or (m.project_ref = 'localdisposablef30xx' and (inet_server_addr() is not null or current_database() <> 'frz_lab')) then
    raise exception using errcode='P0001', message='F30_TEST_TARGET_REFUSED';
  end if;
  if exists(select 1 from pg_class c where c.oid='f30_test_control.marker'::regclass and c.relowner <> (select oid from pg_roles where rolname=current_user))
     or exists(select 1 from pg_class c cross join lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
               where c.oid='f30_test_control.marker'::regclass and a.grantee<>c.relowner) then
    raise exception using errcode='P0001', message='F30_MARKER_OWNERSHIP_OR_ACL_DRIFT';
  end if;
end $fn$;

create function public.f30_probe_action(p_invoice_id uuid, p_action text, p_request_key text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,pg_temp as $fn$
declare u uuid:=auth.uid(); m record; i record; old record; context jsonb;
begin
  perform f30_probe.check_target();
  if u is null then return jsonb_build_object('code','FORBIDDEN'); end if;
  select * into m from f30_probe.memberships where id=u;
  if m.id is null then return jsonb_build_object('code','FORBIDDEN'); end if;
  select * into i from f30_probe.invoices where id=p_invoice_id and organization_id=m.organization_id;
  if i.id is null then return jsonb_build_object('code','NOT_FOUND'); end if;
  if p_action is null or p_action not in ('preview','prepare','ready','discard','issue','reissue','submit') then
    return jsonb_build_object('code','INVALID_REQUEST');
  end if;
  if m.role not in ('owner','admin') and not (
    m.role='dispatcher' and p_action in ('preview','prepare','ready','discard') and
    exists(select 1 from f30_probe.carrier_grants g where g.organization_id=m.organization_id and g.carrier_id=i.carrier_id and g.profile_id=u)
  ) then return jsonb_build_object('code','FORBIDDEN'); end if;
  -- Authorization and tenant lookup MUST precede idempotency, including factoring replay.
  if p_action='preview' then return jsonb_build_object('code','OK','synthetic',true); end if;
  if p_request_key is null or p_request_key !~ '^[a-zA-Z0-9_-]{8,80}$' then return jsonb_build_object('code','INVALID_REQUEST'); end if;
  perform pg_advisory_xact_lock(hashtextextended(m.organization_id::text||':'||p_request_key,0));
  select * into old from f30_probe.receipts where organization_id=m.organization_id and request_key=p_request_key;
  if old.invoice_id is not null then
    if old.invoice_id<>i.id or old.action<>p_action then return jsonb_build_object('code','IDEMPOTENCY_KEY_REUSED'); end if;
    return jsonb_build_object('code','OK','synthetic',true,'replay',true);
  end if;
  select jsonb_build_object('organization',i.organization_id,'carrier',i.carrier_id,'relationship',r.id,'factor',r.factor_id,
    'routing',r.routing,'terms',r.terms,'recipient',l.recipient_id,'amount',l.freight_amount)
    into strict context from f30_probe.loads l join f30_probe.relationships r on r.id=i.relationship_id and r.organization_id=i.organization_id
    where l.id=i.load_id and l.organization_id=i.organization_id;
  insert into f30_probe.receipts values(m.organization_id,p_request_key,i.id,u,p_action,context);
  return jsonb_build_object('code','OK','synthetic',true,'replay',false);
end $fn$;

create function public.f30_probe_context() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $fn$
begin
  perform f30_probe.check_target();
  if not exists(select 1 from f30_probe.memberships where id=auth.uid() and role in ('owner','admin')) then
    return jsonb_build_object('code','FORBIDDEN');
  end if;
  return (select jsonb_build_object('code','OK','project_ref',m.project_ref,'environment',m.environment,
    'fixture_id',m.fixture_id,'source_hash',f.source_hash,'postgres_version',current_setting('server_version'),
    'seed_matches',f.seed_hash=(__SEED_FP__),'catalog_matches',f.catalog_hash=(__CATALOG_FP__))
    from f30_test_control.marker m cross join f30_probe.manifest f);
end $fn$;
revoke all on function public.f30_probe_action(uuid,text,text),public.f30_probe_context() from public,anon,authenticated,service_role;
grant execute on function public.f30_probe_action(uuid,text,text),public.f30_probe_context() to authenticated;
revoke all on all functions in schema f30_probe from public,anon,authenticated,service_role;
revoke all on all tables in schema f30_probe from public,anon,authenticated,service_role;
