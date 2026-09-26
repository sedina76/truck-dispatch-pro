#!/usr/bin/env python3
"""Deterministic, offline artifact generator. No connections; never writes migrations."""
import hashlib
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
TABLES = ['organizations','memberships','carriers','parties','factors','relationships','loads','dispatches','invoices','carrier_grants']
ALL_TABLES = TABLES + ['receipts','manifest']
ROLES = ['owner','admin','granted_dispatcher','ungranted_dispatcher','accountant','driver','viewer']

def uid(n):
    return f'f3000000-0000-0000-0000-{n:012d}'

def quote(s):
    return "'" + s.replace("'", "''") + "'"

def seed_sql():
    lines=[]
    for org in (1,2):
        n=org*1000
        def ins(table, values):
            lines.append(f'insert into f30_probe.{table} values ({values});')
        ins('organizations',f"'{uid(n)}','F30 synthetic organization {org}'")
        for k,role in enumerate(ROLES,1):
            actual='dispatcher' if 'dispatcher' in role else role
            ins('memberships',f"'{uid(n+k)}','{uid(n)}','{actual}','org{org}_{role}'")
        ins('carriers',f"'{uid(n+10)}','{uid(n)}'")
        for k,kind in ((11,'broker'),(12,'customer')):
            ins('parties',f"'{uid(n+k)}','{uid(n)}','{kind}'")
        ins('factors',f"'{uid(n+14)}','{uid(n)}'")
        ins('relationships',f"'{uid(n+13)}','{uid(n)}','{uid(n+10)}','{uid(n+14)}','SYNTHETIC ONLY org {org}',"+"'{\"advance\":80,\"fee\":3,\"reserve\":20,\"currency\":\"USD\"}'")
        for k,status in enumerate(('draft','ready_for_issue','issued')):
            ins('loads',f"'{uid(n+20+k)}','{uid(n)}','{uid(n+10)}','{uid(n+11+(k%2))}',{1000+org*100+k*10}")
            ins('dispatches',f"'{uid(n+30+k)}','{uid(n)}','{uid(n+10)}','{uid(n+20+k)}'")
            ins('invoices',f"'{uid(n+40+k)}','{uid(n)}','{uid(n+10)}','{uid(n+20+k)}','{uid(n+13)}','{status}'")
        ins('carrier_grants',f"'{uid(n)}','{uid(n+10)}','{uid(n+3)}'")
    return '\n'.join(lines)

SEED_FP = 'select md5(' + " || '|' || ".join(f"coalesce((select string_agg(to_jsonb(t)::text,'|' order by to_jsonb(t)::text) from f30_probe.{t} t),'')" for t in TABLES) + ')'
CATALOG_FP = """select md5(
  coalesce((select string_agg(concat_ws('|',c.relname,c.relkind,c.relowner::regrole::text,c.relacl::text,c.relrowsecurity::text),';' order by c.relname) from pg_class c where c.relnamespace='f30_probe'::regnamespace),'') ||
  coalesce((select string_agg(concat_ws('|',c.relname,a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull::text,a.attacl::text),';' order by c.relname,a.attnum) from pg_attribute a join pg_class c on c.oid=a.attrelid where c.relnamespace='f30_probe'::regnamespace and a.attnum>0 and not a.attisdropped),'') ||
  coalesce((select string_agg(concat_ws('|',conname,pg_get_constraintdef(oid)), ';' order by conname) from pg_constraint where connamespace='f30_probe'::regnamespace),'') ||
  coalesce((select string_agg(concat_ws('|',p.pronamespace::regnamespace::text||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',pg_get_functiondef(p.oid),p.proowner::regrole::text,p.proacl::text),';' order by p.pronamespace::regnamespace::text||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')') from pg_proc p where p.pronamespace='f30_probe'::regnamespace or (p.pronamespace='public'::regnamespace and p.proname in ('f30_probe_action','f30_probe_context'))),'') ||
  coalesce((select string_agg(pg_get_triggerdef(t.oid),';' order by t.tgname,c.relname) from pg_trigger t join pg_class c on c.oid=t.tgrelid where c.relnamespace='f30_probe'::regnamespace and not t.tgisinternal and t.tgname<>'0_ops_freeze_block_writes'),'') ||
  coalesce((select string_agg(concat_ws('|',polname,polcmd,polroles::text,pg_get_expr(polqual,polrelid),pg_get_expr(polwithcheck,polrelid)),';' order by polname) from pg_policy where polrelid in(select oid from pg_class where relnamespace='f30_probe'::regnamespace)),'') ||
  (select concat_ws('|',nspowner::regrole::text,nspacl::text,obj_description(oid,'pg_namespace')) from pg_namespace where nspname='f30_probe'))"""

def artifacts():
    model=(HERE/'model.sql').read_text()
    seed=seed_sql()
    source_hash=hashlib.sha256((model+seed+Path(__file__).read_text()).encode()).hexdigest()
    model=model.replace('__SEED_FP__',SEED_FP).replace('__CATALOG_FP__',CATALOG_FP)
    body=model.split('declare m record;\nbegin\n',1)[1].split('end $fn$;',1)[0]
    guard="""do $guard$ declare m record; begin
  if current_user<>session_user then raise exception 'F30_OPERATOR_REQUIRED'; end if;
"""+body+"""
  if current_setting('f30.expected_project_ref',true) is distinct from m.project_ref then raise exception 'F30_EXPLICIT_TARGET_REQUIRED'; end if;
  if to_regclass('ops_freeze_v2.freeze_run') is not null then
    if exists(select 1 from ops_freeze_v2.freeze_run where status='frozen') then raise exception 'F30_ACTIVE_FREEZE_REFUSED'; end if;
  end if;
  if exists(select 1 from pg_trigger where tgname='0_ops_freeze_block_writes' and not tgisinternal) then raise exception 'F30_ORPHAN_FREEZE_TRIGGER_REFUSED'; end if;
  perform pg_advisory_xact_lock(303030157);
end $guard$;
"""
    verify=f"""if (select source_hash from f30_probe.manifest where singleton) is distinct from '{source_hash}' then raise exception 'F30_SOURCE_DRIFT'; end if;
    execute {quote(CATALOG_FP)} into actual;
    if actual is distinct from (select catalog_hash from f30_probe.manifest where singleton) then raise exception 'F30_CATALOG_DRIFT'; end if;
    execute {quote(SEED_FP)} into actual;
    if actual is distinct from (select seed_hash from f30_probe.manifest where singleton) then raise exception 'F30_SEED_DRIFT'; end if;
"""
    empty="if exists(select 1 from f30_probe.receipts) then raise exception 'F30_RECEIPTS_REQUIRE_RESET'; end if;"
    header='-- GENERATED by role_fixture/build_fixture.py. SYNTHETIC ONLY; NOT APPROVED FOR PRODUCTION.\n'
    install=header+'begin;\n'+guard+f"""do $install$ declare actual text; begin
  if to_regnamespace('f30_probe') is not null then
    {verify}
    {empty}
    return;
  end if;
  if exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname in ('f30_probe_action','f30_probe_context')) then raise exception 'F30_RPC_COLLISION'; end if;
  execute {quote(model)};
  execute {quote(seed)};
  execute {quote(SEED_FP)} into actual;
  insert into f30_probe.manifest values(true,'{source_hash}',actual,'pending');
  execute {quote(CATALOG_FP)} into actual;
  update f30_probe.manifest set catalog_hash=actual;
end $install$;
commit;
"""
    reset=header+'begin;\n'+guard+f"""do $reset$ declare actual text; begin
  {verify}
  delete from f30_probe.receipts;
  {empty}
end $reset$;
commit;
"""
    drops='\n'.join('drop table f30_probe.'+t+';' for t in reversed(ALL_TABLES))
    cleanup=header+'begin;\n'+guard+f"""do $cleanup$ declare actual text; begin
  if to_regnamespace('f30_probe') is null then
    if exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname in ('f30_probe_action','f30_probe_context')) then raise exception 'F30_ORPHAN_RPC_REFUSED'; end if;
    return;
  end if;
  {verify}
  {empty}
  drop function public.f30_probe_context();
  drop function public.f30_probe_action(uuid,text,text);
  drop function f30_probe.check_target();
  {drops}
  drop schema f30_probe; -- RESTRICT: any unowned object or external dependency aborts atomically.
end $cleanup$;
commit;
"""
    topology={'fixture_id':'F30_SYNTHETIC_ROLE_MODEL_V1','source_hash':source_hash,'null_identity':None,'database_roles':['anon','authenticated','service_role'],'organizations':[]}
    for org in (1,2):
        n=org*1000
        topology['organizations'].append({'id':uid(n),'carrier':uid(n+10),'broker':uid(n+11),'customer':uid(n+12),'relationship':uid(n+13),'factor':uid(n+14),'identities':{r:uid(n+k) for k,r in enumerate(ROLES,1)},'loads':[uid(n+20+k) for k in range(3)],'dispatches':[uid(n+30+k) for k in range(3)],'invoices':{s:uid(n+40+k) for k,s in enumerate(('draft','ready_for_issue','issued'))}})
    verification=header+"select "+',\n'.join(f"(select count(*) from f30_probe.{t}) as {t}_count" for t in ALL_TABLES)+f",\n({SEED_FP}) as seed_hash,\n({CATALOG_FP}) as catalog_hash,\n(select seed_hash from f30_probe.manifest) = ({SEED_FP}) as seed_matches,\n(select catalog_hash from f30_probe.manifest) = ({CATALOG_FP}) as catalog_matches;\n"
    return {'fixture.sql':install,'reset.sql':reset,'cleanup.sql':cleanup,'verify.sql':verification,'topology.json':json.dumps(topology,indent=2)+'\n'}

if __name__=='__main__':
    output=artifacts()
    if sys.argv[1:]==['--check']:
        bad=[name for name,text in output.items() if not (HERE/name).exists() or (HERE/name).read_text()!=text]
        print('F30 generated artifacts '+('STALE: '+', '.join(bad) if bad else 'PASS (5 files)'))
        sys.exit(bool(bad))
    if sys.argv[1:]: raise SystemExit('Only --check or no arguments are accepted')
    for name,text in output.items(): (HERE/name).write_text(text)
    print('Generated 5 F30 fixture artifacts')
