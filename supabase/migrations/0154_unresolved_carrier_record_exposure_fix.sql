-- proposed_0154.sql -- F-05: fail-closed record_unresolved_carrier_record + owner-only trusted writer + explicit REVOKEs
-- PROPOSAL 0154 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> 0154 (this) -> 0155 -> 0156. Numbers 0154-0156 are taken by the blocker proposals; the unrelated proposal 0148 MUST be
-- renumbered to 0153 (unused) or to 0157 or higher before promotion -- never to 0154, 0155 or 0156. Finding F-05 of ADVERSARIAL_REVIEW.md.
--
-- WHAT IT DOES: (1) creates public._record_unresolved_carrier_record_trusted() (owner-only); (2) replaces public.record_unresolved_carrier_record() (same signature, same return type,
-- SECURITY DEFINER, same pinned search_path) so a NULL auth.uid() FAILS CLOSED; (3) REVOKEs EXECUTE from PUBLIC, anon, authenticated and service_role on BOTH functions explicitly (no reliance on
-- default privileges, current or future). The application never calls the function (no call site in src/); the only callers in the chain are migrations 0133 and 0137, which already ran as the owner.
-- WHAT IT NEVER DOES: create, update or delete any unresolved_carrier_records row; change any table, policy, trigger or other function.
-- Refuses (nothing changed) on: an unexpected overload (any schema), wrong identity arguments, wrong owner/definer/search_path, a body that is not the reviewed 0130 definition, a pre-existing trusted function.
-- One transaction. Body md5s: baseline 25982afd9f6a4da0d2c18b0315a8eec9, replacement c7f9a4c2c34fc44639b2ee96cd348c4e.
begin;
set local lock_timeout = '15s';

do $mig$
declare
  v_n integer; v_owner text; v_md5 text;
begin
  select count(*) into v_n from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted');
  if v_n <> 1 then raise exception '0154 precondition: expected exactly ONE function named record_unresolved_carrier_record (any schema) and no trusted twin; found % -- an unexpected overload/twin exists. STOP.', v_n; end if;
  if to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is null then raise exception '0154 precondition: public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) missing. STOP.'; end if;
  if (select pg_get_function_identity_arguments(oid) from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')) is distinct from 'p_organization_id uuid, p_record_type text, p_record_id uuid, p_reason text, p_detail jsonb' then
    raise exception '0154 precondition: identity arguments differ from the reviewed signature. STOP.';
  end if;
  select pg_get_userbyid(p.proowner) into v_owner from pg_proc p where p.oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)');
  if v_owner in ('anon', 'authenticated', 'service_role', 'authenticator', 'public') or not pg_has_role(current_user, v_owner, 'usage') then
    raise exception '0154 precondition: function owner % is a client role or is not the migration operator (%). STOP.', v_owner, current_user;
  end if;
  if not (select p.prosecdef and p.proconfig::text = '{"search_path=pg_catalog, public"}' and p.prorettype = 'uuid'::regtype from pg_proc p where p.oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')) then
    raise exception '0154 precondition: the function is not SECURITY DEFINER / pinned search_path / returns uuid as reviewed. STOP.';
  end if;
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)');
  if v_md5 is distinct from '25982afd9f6a4da0d2c18b0315a8eec9' then raise exception '0154 precondition: live body (md5 %) is not the reviewed 0130 baseline -- already repaired or drifted. STOP.', v_md5; end if;
  if to_regclass('public.unresolved_carrier_records') is null then raise exception '0154 precondition: unresolved_carrier_records missing. STOP.'; end if;
  create temp table _mig0154_snap on commit drop as
    select (select count(*) from public.unresolved_carrier_records) as n, (select md5(coalesce(string_agg(to_jsonb(u)::text, '|' order by u.id), '')) from public.unresolved_carrier_records u) as digest;
  raise notice '0154 PHASE 1 preconditions passed.';
end
$mig$;

create or replace function public._record_unresolved_carrier_record_trusted(
  p_organization_id uuid,
  p_record_type text,
  p_record_id uuid,
  p_reason text,
  p_detail jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_id uuid;
  v_target_org uuid;
  v_open_org uuid;
begin
  -- Owner-only (EXECUTE is revoked from PUBLIC, anon, authenticated and service_role): reachable by migrations / the SQL-Editor operator and by other reviewed
  -- SECURITY DEFINER functions of the same owner ONLY. It never trusts the caller-supplied organization: the record must EXIST and belong to that organization.
  if p_organization_id is null or p_record_type is null or p_record_id is null or p_reason is null or pg_catalog.btrim(p_reason) = '' then
    raise exception '_record_unresolved_carrier_record_trusted: organization_id, record_type, record_id and reason are all required.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.organizations o where o.id = p_organization_id) then
    raise exception '_record_unresolved_carrier_record_trusted: unknown organization.' using errcode = '42501';
  end if;
  -- fully schema-qualified: no unqualified relation name is resolved through search_path (temporary objects cannot shadow anything here)
  v_target_org := case p_record_type
    when 'load' then (select x.organization_id from public.loads x where x.id = p_record_id)
    when 'invoice' then (select x.organization_id from public.invoices x where x.id = p_record_id)
    when 'payment' then (select x.organization_id from public.payments x where x.id = p_record_id)
    when 'document' then (select x.organization_id from public.documents x where x.id = p_record_id)
    when 'factoring_relationship' then (select x.organization_id from public.factoring_relationships x where x.id = p_record_id)
    when 'factored_invoice' then (select x.organization_id from public.factored_invoices x where x.id = p_record_id)
    when 'trailer' then (select x.organization_id from public.trailers x where x.id = p_record_id)
    else null
  end;
  if p_record_type not in ('load', 'invoice', 'payment', 'document', 'factoring_relationship', 'factored_invoice', 'trailer') then
    raise exception '_record_unresolved_carrier_record_trusted: record_type ''%'' has no verifiable target table and is refused.', p_record_type using errcode = '42501';
  end if;
  if v_target_org is null or v_target_org <> p_organization_id then
    raise exception '_record_unresolved_carrier_record_trusted: the record does not exist in the stated organization (forged or cross-tenant identifier refused).' using errcode = '42501';
  end if;

  select u.organization_id into v_open_org from public.unresolved_carrier_records u
   where u.record_type = p_record_type and u.record_id = p_record_id and u.status = 'unresolved';
  if v_open_org is not null and v_open_org <> p_organization_id then
    raise exception '_record_unresolved_carrier_record_trusted: an open exception for this record belongs to another organization (refused).' using errcode = '42501';
  end if;

  insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason, detail)
  values (p_organization_id, p_record_type, p_record_id, p_reason, coalesce(p_detail, '{}'::jsonb))
  on conflict (record_type, record_id) where (status = 'unresolved')
  do nothing
  returning id into v_id;

  if v_id is null then
    select u.id into v_id from public.unresolved_carrier_records u
     where u.record_type = p_record_type and u.record_id = p_record_id and u.status = 'unresolved';
  end if;
  return v_id;
end;
$fn$;

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
begin
  -- 0154: FAIL CLOSED. A null identity (anon, a JWT without `sub`, service_role, any client without a session) is NEVER trusted. Migrations and the operator use
  -- public._record_unresolved_carrier_record_trusted() (owner-only). This function is additionally unreachable by every client role (EXECUTE revoked) until the Owner names a caller.
  if v_uid is null then
    raise exception 'record_unresolved_carrier_record: authentication required.' using errcode = '42501';
  end if;
  if p_organization_id is null or p_record_type is null or p_record_id is null
     or p_reason is null or btrim(p_reason) = '' then
    raise exception 'record_unresolved_carrier_record: organization_id, record_type, record_id and reason are all required.'
      using errcode = '22023';
  end if;
  if p_organization_id is distinct from public.current_org_id() then
    raise exception 'record_unresolved_carrier_record: cross-organization write rejected.'
      using errcode = '42501';
  end if;
  if not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
    raise exception 'record_unresolved_carrier_record: caller role is not permitted.'
      using errcode = '42501';
  end if;
  if p_record_type <> 'load' then
    raise exception 'record_unresolved_carrier_record: interactive callers may report record_type=''load'' only; record_type ''%'' requires a trusted internal caller.', p_record_type
      using errcode = '42501';
  end if;
  if (select l.organization_id from public.loads l where l.id = p_record_id) is distinct from p_organization_id then
    raise exception 'record_unresolved_carrier_record: record_id does not belong to the caller''s organization.'
      using errcode = '42501';
  end if;
  return public._record_unresolved_carrier_record_trusted(p_organization_id, p_record_type, p_record_id, p_reason, p_detail);
end;
$fn$;

revoke all on function public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb) from public, anon, authenticated, service_role;
revoke all on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) from public, anon, authenticated, service_role;

-- Concern F-15: the application never reads or writes unresolved_carrier_records directly (no call site in src/), so authenticated keeps UPDATE ONLY on the resolution columns
-- (RLS still restricts UPDATE to owner/admin of the organization). record_type / record_id / organization_id / reason / detail become immutable for every client role.
revoke update on public.unresolved_carrier_records from authenticated;
grant update (status, resolved_by, resolved_at, resolution_note) on public.unresolved_carrier_records to authenticated;

comment on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) is
  '0154: fail-closed (null auth.uid() is refused). EXECUTE is revoked from PUBLIC, anon, authenticated and service_role -- callable only by the owner (migrations/operator) until the Owner names an application caller. Delegates to _record_unresolved_carrier_record_trusted().';
comment on function public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb) is
  '0154: owner-only writer for unresolved_carrier_records. Verifies the record exists in the stated organization for every supported record_type; refuses unverifiable types and cross-tenant identifiers. Never granted to any client role.';

do $mig$
declare v_bad integer; r record; v_snap record;
begin
  select * into v_snap from _mig0154_snap;
  if (select count(*) from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted')) <> 2 then raise exception '0154 postcondition: expected exactly the two reviewed functions.'; end if;
  for r in select sig from (values ('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)'), ('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)')) t(sig) loop
    if has_function_privilege('anon', to_regprocedure(r.sig), 'execute') or has_function_privilege('authenticated', to_regprocedure(r.sig), 'execute')
       or has_function_privilege('service_role', to_regprocedure(r.sig), 'execute')
       or (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure(r.sig)) then
      raise exception '0154 postcondition: % is still executable by PUBLIC/anon/authenticated/service_role.', r.sig;
    end if;
  end loop;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')) <> 'c7f9a4c2c34fc44639b2ee96cd348c4e' then raise exception '0154 postcondition: replacement body mismatch.'; end if;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)')) <> '37655d439bb9cef6225b6f65c1358a8b' then raise exception '0154 postcondition: trusted body mismatch.'; end if;
  if has_table_privilege('authenticated', 'public.unresolved_carrier_records', 'UPDATE') or has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'record_id', 'UPDATE') or has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'detail', 'UPDATE')
     or not has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'status', 'UPDATE') then
    raise exception '0154 postcondition: authenticated UPDATE on unresolved_carrier_records is not limited to the resolution columns.';
  end if;
  select count(*) into v_bad from (select count(*) as n, md5(coalesce(string_agg(to_jsonb(u)::text, '|' order by u.id), '')) as digest from public.unresolved_carrier_records u) x where x.n <> v_snap.n or x.digest <> v_snap.digest;
  if v_bad <> 0 then raise exception '0154 postcondition: unresolved_carrier_records changed (0154 never writes it).'; end if;
  raise notice '0154 complete: record_unresolved_carrier_record fails closed on a null identity; both functions are owner-only; no exception record was touched.';
end
$mig$;

commit;
