#!/usr/bin/env python3
"""Generator for proposal 0154 (F-05: record_unresolved_carrier_record exposure). Standard library only. `python3 build.py` writes; `python3 build.py --check` verifies.
The reviewed baseline body is EXTRACTED from supabase/migrations/0130_carrier_context_foundation.sql (never retyped); its normalised md5 is pinned in the preflight and in the rollback."""
import hashlib
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
SIG = "public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)"
TRUSTED_SIG = "public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)"
ARGS = "p_organization_id uuid, p_record_type text, p_record_id uuid, p_reason text, p_detail jsonb"
HEADER = """-- {name}
-- PROPOSAL 0154 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> 0154 (this) -> 0155 -> 0156. Numbers 0154-0156 are taken by the blocker proposals; the unrelated proposal 0148 MUST be
-- renumbered to 0153 (unused) or to 0157 or higher before promotion -- never to 0154, 0155 or 0156. Finding F-05 of ADVERSARIAL_REVIEW.md.
"""


def norm_md5(text):
    return hashlib.md5(re.sub(r"\s+", "", re.sub(r"--[^\n]*", "", text).lower()).encode()).hexdigest()


def baseline():
    s = (SUPA / "migrations" / "0130_carrier_context_foundation.sql").read_text()
    m = re.search(r"(create or replace function public\.record_unresolved_carrier_record\(.*?\n\$fn\$;)", s, re.S)
    block = m.group(1)
    body = re.search(r"as \$fn\$(.*?)\$fn\$;", block, re.S).group(1)
    return block, body


# ------------------------------------------------------------------------------------------------ the replacement bodies
TRUSTED_BLOCK = """create or replace function public._record_unresolved_carrier_record_trusted(
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
$fn$;"""

PUBLIC_BLOCK = """create or replace function public.record_unresolved_carrier_record(
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
$fn$;"""


def body_of(block):
    return re.search(r"as \$fn\$(.*?)\$fn\$;", block, re.S).group(1)


def facts():
    base_block, base_body = baseline()
    return {"base_block": base_block, "base_md5": norm_md5(base_body), "new_md5": norm_md5(body_of(PUBLIC_BLOCK)), "trusted_md5": norm_md5(body_of(TRUSTED_BLOCK))}


# ------------------------------------------------------------------------------------------------ files
def proposed(f):
    return HEADER.format(name="proposed_0154.sql -- F-05: fail-closed record_unresolved_carrier_record + owner-only trusted writer + explicit REVOKEs") + f"""--
-- WHAT IT DOES: (1) creates public._record_unresolved_carrier_record_trusted() (owner-only); (2) replaces public.record_unresolved_carrier_record() (same signature, same return type,
-- SECURITY DEFINER, same pinned search_path) so a NULL auth.uid() FAILS CLOSED; (3) REVOKEs EXECUTE from PUBLIC, anon, authenticated and service_role on BOTH functions explicitly (no reliance on
-- default privileges, current or future). The application never calls the function (no call site in src/); the only callers in the chain are migrations 0133 and 0137, which already ran as the owner.
-- WHAT IT NEVER DOES: create, update or delete any unresolved_carrier_records row; change any table, policy, trigger or other function.
-- Refuses (nothing changed) on: an unexpected overload (any schema), wrong identity arguments, wrong owner/definer/search_path, a body that is not the reviewed 0130 definition, a pre-existing trusted function.
-- One transaction. Body md5s: baseline {f['base_md5']}, replacement {f['new_md5']}.
begin;
set local lock_timeout = '15s';

do $mig$
declare
  v_n integer; v_owner text; v_md5 text;
begin
  select count(*) into v_n from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted');
  if v_n <> 1 then raise exception '0154 precondition: expected exactly ONE function named record_unresolved_carrier_record (any schema) and no trusted twin; found % -- an unexpected overload/twin exists. STOP.', v_n; end if;
  if to_regprocedure('{SIG}') is null then raise exception '0154 precondition: {SIG} missing. STOP.'; end if;
  if (select pg_get_function_identity_arguments(oid) from pg_proc where oid = to_regprocedure('{SIG}')) is distinct from '{ARGS}' then
    raise exception '0154 precondition: identity arguments differ from the reviewed signature. STOP.';
  end if;
  select pg_get_userbyid(p.proowner) into v_owner from pg_proc p where p.oid = to_regprocedure('{SIG}');
  if v_owner in ('anon', 'authenticated', 'service_role', 'authenticator', 'public') or not pg_has_role(current_user, v_owner, 'usage') then
    raise exception '0154 precondition: function owner % is a client role or is not the migration operator (%). STOP.', v_owner, current_user;
  end if;
  if not (select p.prosecdef and p.proconfig::text = '{{"search_path=pg_catalog, public"}}' and p.prorettype = 'uuid'::regtype from pg_proc p where p.oid = to_regprocedure('{SIG}')) then
    raise exception '0154 precondition: the function is not SECURITY DEFINER / pinned search_path / returns uuid as reviewed. STOP.';
  end if;
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure('{SIG}');
  if v_md5 is distinct from '{f['base_md5']}' then raise exception '0154 precondition: live body (md5 %) is not the reviewed 0130 baseline -- already repaired or drifted. STOP.', v_md5; end if;
  if to_regclass('public.unresolved_carrier_records') is null then raise exception '0154 precondition: unresolved_carrier_records missing. STOP.'; end if;
  create temp table _mig0154_snap on commit drop as
    select (select count(*) from public.unresolved_carrier_records) as n, (select md5(coalesce(string_agg(to_jsonb(u)::text, '|' order by u.id), '')) from public.unresolved_carrier_records u) as digest;
  raise notice '0154 PHASE 1 preconditions passed.';
end
$mig$;

{TRUSTED_BLOCK}

{PUBLIC_BLOCK}

revoke all on function {TRUSTED_SIG} from public, anon, authenticated, service_role;
revoke all on function {SIG} from public, anon, authenticated, service_role;

-- Concern F-15: the application never reads or writes unresolved_carrier_records directly (no call site in src/), so authenticated keeps UPDATE ONLY on the resolution columns
-- (RLS still restricts UPDATE to owner/admin of the organization). record_type / record_id / organization_id / reason / detail become immutable for every client role.
revoke update on public.unresolved_carrier_records from authenticated;
grant update (status, resolved_by, resolved_at, resolution_note) on public.unresolved_carrier_records to authenticated;

comment on function {SIG} is
  '0154: fail-closed (null auth.uid() is refused). EXECUTE is revoked from PUBLIC, anon, authenticated and service_role -- callable only by the owner (migrations/operator) until the Owner names an application caller. Delegates to _record_unresolved_carrier_record_trusted().';
comment on function {TRUSTED_SIG} is
  '0154: owner-only writer for unresolved_carrier_records. Verifies the record exists in the stated organization for every supported record_type; refuses unverifiable types and cross-tenant identifiers. Never granted to any client role.';

do $mig$
declare v_bad integer; r record; v_snap record;
begin
  select * into v_snap from _mig0154_snap;
  if (select count(*) from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted')) <> 2 then raise exception '0154 postcondition: expected exactly the two reviewed functions.'; end if;
  for r in select sig from (values ('{SIG}'), ('{TRUSTED_SIG}')) t(sig) loop
    if has_function_privilege('anon', to_regprocedure(r.sig), 'execute') or has_function_privilege('authenticated', to_regprocedure(r.sig), 'execute')
       or has_function_privilege('service_role', to_regprocedure(r.sig), 'execute')
       or (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure(r.sig)) then
      raise exception '0154 postcondition: % is still executable by PUBLIC/anon/authenticated/service_role.', r.sig;
    end if;
  end loop;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')) <> '{f['new_md5']}' then raise exception '0154 postcondition: replacement body mismatch.'; end if;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{TRUSTED_SIG}')) <> '{f['trusted_md5']}' then raise exception '0154 postcondition: trusted body mismatch.'; end if;
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
"""


VERIFY_HEAD = """-- {name}
-- PROPOSAL 0154 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 (this) -> 0155 -> 0156; unrelated 0148 -> 0153 or 0157+ (never 0154-0156).
-- READ-ONLY: ONE select statement over catalogs; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row; otherwise the
-- statement RAISES (invalid input syntax for type integer: "{tag} FAIL ...") whose text is the complete report.
"""
VERDICT = """verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('{tag} FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\\n' order by ord))::int
         end as gate
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', '{tag}: {what}', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
"""
ACL_ROWS = """
  union all select 300 + g.n, 'ACL', g.sig || ': EXECUTE for ' || g.who, 'INFO', case g.who when 'PUBLIC' then (coalesce((select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure(g.sig)), false))::text
                                                              else has_function_privilege(g.who, to_regprocedure(g.sig), 'execute')::text end
  from (values (1, '{SIG}', 'anon'), (2, '{SIG}', 'authenticated'), (3, '{SIG}', 'service_role'), (4, '{SIG}', 'PUBLIC')) g(n, sig, who) where to_regprocedure(g.sig) is not null"""


def preflight(f):
    return VERIFY_HEAD.format(name="preflight.sql", tag="PREFLIGHT 0154") + f"""with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'PRECONDITION', 'exactly one function named record_unresolved_carrier_record exists in ANY schema and no trusted twin', case when (select count(*) from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted')) = 1 then 'PASS' else 'FAIL' end, (select count(*)::text from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted')) || ' matching function(s)'
  union all select 111, 'PRECONDITION', 'identity arguments are exactly the reviewed signature', case when (select pg_get_function_identity_arguments(oid) from pg_proc where oid = to_regprocedure('{SIG}')) = '{ARGS}' then 'PASS' else 'FAIL' end, coalesce((select pg_get_function_identity_arguments(oid) from pg_proc where oid = to_regprocedure('{SIG}')), 'MISSING')
  union all select 112, 'PRECONDITION', 'owner is not a client role and is usable by the migration operator', case when (select pg_get_userbyid(p.proowner) not in ('anon', 'authenticated', 'service_role', 'authenticator') and pg_has_role(current_user, p.proowner, 'usage') from pg_proc p where p.oid = to_regprocedure('{SIG}')) then 'PASS' else 'FAIL' end, coalesce((select pg_get_userbyid(p.proowner)::text from pg_proc p where p.oid = to_regprocedure('{SIG}')), 'MISSING') || ' / operator ' || current_user
  union all select 113, 'PRECONDITION', 'SECURITY DEFINER with the pinned search_path, returns uuid', case when (select p.prosecdef and p.proconfig::text = '{{"search_path=pg_catalog, public"}}' and p.prorettype = 'uuid'::regtype from pg_proc p where p.oid = to_regprocedure('{SIG}')) then 'PASS' else 'FAIL' end, coalesce((select p.proconfig::text from pg_proc p where p.oid = to_regprocedure('{SIG}')), 'MISSING')
  union all select 114, 'PRECONDITION', 'body is the reviewed 0130 baseline definition (0154 not yet applied)', case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')) = '{f['base_md5']}' then 'PASS' else 'FAIL' end, coalesce((select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')), 'MISSING')
  union all select 115, 'PRECONDITION', 'unresolved_carrier_records exists', case when to_regclass('public.unresolved_carrier_records') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 116, 'PRECONDITION', 'authenticated currently holds table-level UPDATE on unresolved_carrier_records (0130 grant; F-15)', case when has_table_privilege('authenticated', 'public.unresolved_carrier_records', 'UPDATE') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120, 'EXPOSURE (informational; F-05)', 'open exception rows (0154 never touches them)', 'INFO', coalesce((select count(*)::text from public.unresolved_carrier_records where status = 'unresolved'), 'table missing')
  union all select 121, 'EXPOSURE (informational; F-05)', 'default privileges in schema public granting EXECUTE on functions (why REVOKE FROM PUBLIC alone was not enough)', 'INFO', coalesce((select string_agg(pg_get_userbyid(d.defaclrole) || ': ' || d.defaclacl::text, '; ') from pg_default_acl d where d.defaclobjtype = 'f'), '(none)'){ACL_ROWS.format(SIG=SIG)}
),
""" + VERDICT.format(tag="PREFLIGHT 0154", what="live definition is the reviewed baseline")


def post_apply(f):
    return VERIFY_HEAD.format(name="post_apply.sql", tag="POST-APPLY 0154") + f"""with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'STATE', 'exactly the two reviewed functions exist (no overload, no twin)', case when (select count(*) from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted')) = 2 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'STATE', 'record_unresolved_carrier_record body is the reviewed 0154 replacement', case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')) = '{f['new_md5']}' then 'PASS' else 'FAIL' end, 'md5'
  union all select 112, 'STATE', '_record_unresolved_carrier_record_trusted body is the reviewed 0154 definition', case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{TRUSTED_SIG}')) = '{f['trusted_md5']}' then 'PASS' else 'FAIL' end, 'md5'
  union all select 113, 'STATE', 'both are SECURITY DEFINER; public one keeps search_path pg_catalog, public; trusted one is pg_catalog, pg_temp', case when (select bool_and(p.prosecdef) and bool_or(p.proconfig::text = '{{"search_path=pg_catalog, public"}}') and bool_or(p.proconfig::text = '{{"search_path=pg_catalog, pg_temp"}}') from pg_proc p where p.oid in (to_regprocedure('{SIG}'), to_regprocedure('{TRUSTED_SIG}'))) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120 + g.n, 'ACL', g.sig || ' is NOT executable by ' || g.who, case when (case g.who when 'PUBLIC' then coalesce((select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure(g.sig)), true)
                                                     else coalesce(has_function_privilege(g.who, to_regprocedure(g.sig), 'execute'), true) end) then 'FAIL' else 'PASS' end, 'explicit REVOKE; independent of default privileges'
  from (values (1, '{SIG}', 'anon'), (2, '{SIG}', 'authenticated'), (3, '{SIG}', 'service_role'), (4, '{SIG}', 'PUBLIC'), (5, '{TRUSTED_SIG}', 'anon'), (6, '{TRUSTED_SIG}', 'authenticated'), (7, '{TRUSTED_SIG}', 'service_role'), (8, '{TRUSTED_SIG}', 'PUBLIC')) g(n, sig, who)
  union all select 130, 'ACL', 'unresolved_carrier_records: authenticated has NO table-level UPDATE and no UPDATE on record_id/detail/organization_id; UPDATE on status/resolution columns only', case when not has_table_privilege('authenticated', 'public.unresolved_carrier_records', 'UPDATE') and not has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'record_id', 'UPDATE') and not has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'organization_id', 'UPDATE') and not has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'detail', 'UPDATE') and has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'status', 'UPDATE') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 200, 'DATA', 'open exception rows (informational; compare with the preflight value: 0154 changes none)', 'INFO', (select count(*)::text from public.unresolved_carrier_records where status = 'unresolved')
),
""" + VERDICT.format(tag="POST-APPLY 0154", what="F-05 closed: fail-closed body, owner-only functions")


def rollback(f):
    return HEADER.format(name="rollback.sql -- EMERGENCY reversal of proposal 0154 (re-introduces the F-05 exposure)") + f"""-- Restores the EXACT 0130 definition (extracted from the migration) and the ACL 0130 itself declared (revoke PUBLIC, grant authenticated). NOTE: that ACL is the intended 0130 state, not the accidental
-- default-privilege exposure to anon/service_role. REFUSES (changing nothing) unless the live functions are exactly the reviewed 0154 definitions AND proposal 0155 (which depends on the trusted
-- writer) is not applied. Drops only the trusted function. Single transaction; run once.
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regprocedure('{TRUSTED_SIG}') is null then raise exception 'ROLLBACK 0154 REFUSED: trusted writer missing (0154 not applied, or already rolled back). Nothing changed.'; end if;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')) is distinct from '{f['new_md5']}' then raise exception 'ROLLBACK 0154 REFUSED: live record_unresolved_carrier_record is not the reviewed 0154 definition. Nothing changed.'; end if;
  if to_regclass('public.carrier_inference_review_0155') is not null then raise exception 'ROLLBACK 0154 REFUSED: proposal 0155 is applied and depends on the trusted writer -- roll back 0155 first. Nothing changed.'; end if;
end
$mig$;

{f['base_block']}

revoke all on function {SIG} from public;
grant execute on function {SIG} to authenticated;
drop function {TRUSTED_SIG};
grant update on public.unresolved_carrier_records to authenticated;

do $mig$
begin
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')) <> '{f['base_md5']}' then raise exception 'ROLLBACK 0154 postcondition: body is not the 0130 baseline.'; end if;
  if to_regprocedure('{TRUSTED_SIG}') is not null then raise exception 'ROLLBACK 0154 postcondition: trusted writer still present.'; end if;
  raise notice 'ROLLBACK 0154 complete: the 0130 definition is restored (F-05 exposure is BACK; anon may again reach it if default privileges grant it).';
end
$mig$;
commit;
"""


def all_files():
    f = facts()
    return {"proposed_0154.sql": proposed(f), "preflight.sql": preflight(f), "post_apply.sql": post_apply(f), "rollback.sql": rollback(f)}


if __name__ == "__main__":
    files = all_files()
    if "--check" in sys.argv:
        bad = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t]
        print("generated files are current" if not bad else "STALE: " + ", ".join(bad))
        sys.exit(1 if bad else 0)
    for n, t in files.items():
        (HERE / n).write_text(t)
        print(f"wrote {n} ({len(t)} bytes, sha256 {hashlib.sha256(t.encode()).hexdigest()[:16]})")
