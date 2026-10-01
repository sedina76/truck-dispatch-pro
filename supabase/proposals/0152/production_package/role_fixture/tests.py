#!/usr/bin/env python3
"""LOCAL ONLY: disposable Unix-socket PostgreSQL, no connection parameters, no hosted client.
Synthetic authorization model, not a replacement for 0157's integration tests.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

fz=load('f30_freeze',HERE.parents[1]/'freeze/tests_freeze.py')
build=load('f30_build',HERE/'build_fixture.py')
checks=[]
evidence={'scope':'LOCAL SYNTHETIC MODEL ONLY','hosted_requests':0,'results':[]}

def check(label,condition,detail=''):
    if not condition: raise AssertionError(f'{label}: {detail}')
    checks.append(label); print('  ok '+label,flush=True)

REF='localdisposablef30xx'
TARGET="set f30.expected_project_ref = '"+REF+"';\n"

def artifact(name): return (HERE/name).read_text()

def op(lab,name,ok=True): return lab.run('operator',TARGET+artifact(name),ok=ok,extra_args=fz.V)

class Session:
    """A persistent physical backend. Reuse models transaction-pool role/identity reset."""
    def __init__(self,lab,login):
        self.p=subprocess.Popen([fz.t149.PSQL,'-X','-w','-q','-A','-t','-v','ON_ERROR_STOP=0','-v','VERBOSITY=verbose','-h',str(lab.c.sock),'-p',str(fz.t149.PORT),'-U',login,'-d',lab.db],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=lab.c.env)
        self.buf=b''
        self.pid=int(self.run('select pg_backend_pid();').strip())
    def run(self,sql):
        marker=b'__F30_END__\n'
        self.p.stdin.write((sql+'\n\\echo __F30_END__\n').encode()); self.p.stdin.flush()
        end=time.monotonic()+15
        while marker not in self.buf:
            if time.monotonic()>end: raise TimeoutError('local psql response timeout')
            if select.select([self.p.stdout],[],[],1)[0]:
                b=os.read(self.p.stdout.fileno(),65536)
                if not b: raise RuntimeError('local psql exited')
                self.buf+=b
        out,self.buf=self.buf.split(marker,1)
        return out.decode()
    def call(self,uid,invoice,action,key='f30-test-key',role='authenticated',commit=False):
        assert role in ('authenticated','anon','service_role')
        for value in (uid or '',invoice,action,key): assert "'" not in value
        # SET LOCAL cannot leak a user's claims into the next pooled transaction.
        sql=f"begin; set local role {role}; set local request.jwt.claim.sub='{uid or ''}'; select public.f30_probe_action('{invoice}','{action}','{key}'); "+('commit;' if commit else 'rollback;')
        out=self.run(sql)
        for line in out.splitlines():
            if line.startswith('{'): return json.loads(line),None,out
        m=re.search(r'ERROR:\s+([A-Z0-9]{5}):',out)
        return None,m.group(1) if m else None,out
    def close(self):
        if self.p.poll() is None:
            self.p.stdin.write(b'\\q\n');self.p.stdin.flush();self.p.wait(timeout=5)


def setup(lab):
    fz.setup2(lab)
    lab.run('postgres',"""
create role f30_direct login noinherit;
grant authenticated,anon,service_role to f30_direct;
create schema auth authorization operator;
grant usage on schema auth to authenticated,anon,service_role;
""")
    lab.run('operator',"""
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
-- Model Supabase's broad defaults; fixture must explicitly remove them.
alter default privileges grant execute on functions to anon,authenticated,service_role;
""")

def marker(lab):
    lab.run('operator',f"""
create schema f30_test_control;
revoke all on schema f30_test_control from public,anon,authenticated,service_role;
create table f30_test_control.marker(project_ref text,environment text,database_name text,fixture_id text);
revoke all on f30_test_control.marker from public,anon,authenticated,service_role;
insert into f30_test_control.marker values('{REF}','nonproduction-f30','frz_lab','F30_SYNTHETIC_ROLE_MODEL_V1');
""")

def fingerprint(lab):
    return {'seed':lab.scalar(build.SEED_FP),'catalog':lab.scalar(build.CATALOG_FP),'receipts':lab.scalar("select md5(coalesce(string_agg(to_jsonb(t)::text,'|' order by to_jsonb(t)::text),'')) from f30_probe.receipts t")}

def matrix(lab,s,orgs,label):
    for org in orgs:
        invoice=org['invoices']['issued']; foreign=next(o for o in orgs if o!=org)['invoices']['issued']
        ids={**org['identities'],'null':None,'anon':None,'service_role':None}
        for role,uid in ids.items():
            sqlrole=role if role in ('anon','service_role') else 'authenticated'
            for action in ('preview','prepare','ready','discard','issue','reissue','submit'):
                allowed=role in ('owner','admin') or (role=='granted_dispatcher' and action in ('preview','prepare','ready','discard'))
                actual,state,out=s.call(uid,invoice,action,role=sqlrole)
                want='OK' if allowed else 'FORBIDDEN'
                check(f'{label} {org["id"][-4:]} {role} {action}',state=='42501' if sqlrole!='authenticated' else actual is not None and actual.get('code')==want,out)
                if not allowed and sqlrole=='authenticated': check(f'{label} {role} {action} no identifiers',actual=={'code':'FORBIDDEN'})
                evidence['results'].append({'transport':label,'role':role,'action':action,'expected':'42501' if sqlrole!='authenticated' else want,'actual':state or actual['code']})
            if uid:
                foreign_result=s.call(uid,foreign,'submit')[0]
                unknown_result=s.call(uid,build.uid(999999),'submit')[0]
                check(f'{label} {role} foreign/unknown invoice indistinguishable',foreign_result==unknown_result=={'code':'NOT_FOUND'})
        check(label+' pooled claims reset after transaction',s.run("select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),'EMPTY');").strip()=='EMPTY')

def main():
    for name,text in build.artifacts().items(): check('generated '+name,artifact(name)==text)
    topo=json.loads(artifact('topology.json')); orgs=topo['organizations']; a,b=orgs
    lab=fz.Lab(); live=[]; good=False
    try:
        lab.c.start();setup(lab)
        initial=fz.catalog_fp(lab)
        result=op(lab,'fixture.sql',ok=False)
        check('missing marker refuses before creating any fixture',result.returncode!=0 and 'F30_TEST_MARKER_REQUIRED' in result.stderr and lab.scalar("select to_regnamespace('f30_probe') is null")=='t')
        marker(lab)
        # Guards fail atomically; not even fixture schema may be created.
        for name,change in [('production',"project_ref='zteixenjpcygjvznueuo'"),('deleted',"project_ref='fjmrvvyjvqdyopnyetez'"),('wrong label',"environment='production'"),('wrong DB',"database_name='other'"),('missing fixture marker',"fixture_id='other'"),('null marker',"project_ref=null,environment=null,database_name=null,fixture_id=null")]:
            result=lab.run('operator','begin; update f30_test_control.marker set '+change+'; '+TARGET+artifact('fixture.sql'),ok=False)
            check('target guard '+name,result.returncode!=0 and lab.scalar("select to_regnamespace('f30_probe') is null")=='t')
        result=lab.run('operator',artifact('fixture.sql'),ok=False)
        check('explicit target required even with valid marker',result.returncode!=0 and 'F30_EXPLICIT_TARGET_REQUIRED' in result.stderr)
        op(lab,'fixture.sql'); base=fingerprint(lab); evidence['baseline']=base
        op(lab,'fixture.sql');check('install idempotent and fingerprint identical',fingerprint(lab)==base)
        counts={t:int(lab.scalar('select count(*) from f30_probe.'+t)) for t in build.ALL_TABLES}
        check('complete deterministic two-organization topology',counts=={'organizations':2,'memberships':14,'carriers':2,'parties':4,'factors':2,'relationships':2,'loads':6,'dispatches':6,'invoices':6,'carrier_grants':2,'receipts':0,'manifest':1},str(counts))
        evidence['counts']=counts
        for table,column,value in [('invoices','relationship_id',b['relationship']),('loads','recipient_id',b['broker']),('carrier_grants','profile_id',b['identities']['granted_dispatcher'])]:
            r=lab.run('operator',f"begin; update f30_probe.{table} set {column}='{value}' where organization_id='{a['id']}'; rollback;",ok=False,extra_args=fz.V)
            check('composite foreign key prevents cross-tenant '+table,r.returncode!=0 and '23503' in r.stderr and fingerprint(lab)==base)
        check('RPC inputs exclude every server-resolved financial field',lab.scalar("select pg_get_function_arguments('public.f30_probe_action(uuid,text,text)'::regprocedure)")=="p_invoice_id uuid, p_action text, p_request_key text DEFAULT NULL::text")
        for login,label in [('f30_direct','direct'),('authenticator','pooled')]:
            s=Session(lab,login);live.append(s);matrix(lab,s,orgs,label)
        direct,pool=live
        check('distinct non-exempt direct and pooled backends',direct.pid!=pool.pid)
        # Marker removal/ACL drift fails closed on installed probes, not only installation.
        for mutation in ('delete from f30_test_control.marker', 'grant select on f30_test_control.marker to authenticated'):
            r=lab.run('operator',f"begin; {mutation}; set local request.jwt.claim.sub='{a['identities']['owner']}'; select public.f30_probe_action('{a['invoices']['issued']}','prepare','marker-test'); rollback;",ok=False)
            check('installed probe refuses missing/untrusted marker',r.returncode!=0 and fingerprint(lab)==base)
        # SQL-level substitution rejected by missing signature, not ignored.
        for field in ('organization','relationship','factor','routing','recipient','terms','amount'):
            out=pool.run(f"begin; set local role authenticated; select public.f30_probe_action(p_invoice_id=>'{a['invoices']['issued']}',p_action=>'submit',p_request_key=>'safe-key',p_{field}=>'forged'); rollback;")
            check('extra caller-supplied '+field+' rejected', '42883' in out)
        out=pool.run(f"begin; set local role authenticated; set local request.jwt.claim.sub='{a['identities']['owner']}'; select public.f30_probe_context(); rollback;")
        ctx=next(json.loads(line) for line in out.splitlines() if line.startswith('{'))
        check('context attests exact source, seed and catalog fingerprints',ctx['source_hash']==topo['source_hash'] and ctx['seed_matches'] and ctx['catalog_matches'],str(ctx))
        for denied in ('anon','authenticated','service_role'):
            out=pool.run(f'begin; set local role {denied}; select * from f30_probe.invoices; rollback;')
            check('no raw table access '+denied,'42501' in out)
        owner=a['identities']['owner']; inv=a['invoices']['issued']
        result=pool.call(owner,inv,'submit','shared-key',commit=True)[0]
        check('owner synthetic submit receipt only',result['code']=='OK' and lab.scalar('select count(*) from f30_probe.receipts')=='1')
        check('owner replay is idempotent',pool.call(owner,inv,'submit','shared-key',commit=True)[0]['replay'] and lab.scalar('select count(*) from f30_probe.receipts')=='1')
        check('granted dispatcher cannot replay factoring',pool.call(a['identities']['granted_dispatcher'],inv,'submit','shared-key',commit=True)[0]=={'code':'FORBIDDEN'})
        check('key reuse with changed operation refuses',pool.call(owner,inv,'issue','shared-key')[0]=={'code':'IDEMPOTENCY_KEY_REUSED'})
        check('same key in separate tenant is independent',pool.call(b['identities']['owner'],b['invoices']['issued'],'submit','shared-key',commit=True)[0]['replay'] is False)
        check('server resolves organization/relationship/factor/routing/recipient/terms/amount',lab.scalar(f"select (resolved->>'organization'='{a['id']}' and resolved->>'relationship'='{a['relationship']}' and resolved->>'factor'='{a['factor']}' and resolved->>'recipient'='{a['broker']}' and resolved->>'amount'='1120.00' and resolved->>'routing'='SYNTHETIC ONLY org 1' and resolved->'terms'->>'advance'='80')::text from f30_probe.receipts where organization_id='{a['id']}'")=='true')
        check('dirty reinstall refuses instead of overwriting',op(lab,'fixture.sql',ok=False).returncode!=0)
        check('cleanup refuses outstanding receipts',op(lab,'cleanup.sql',ok=False).returncode!=0)
        op(lab,'reset.sql');op(lab,'reset.sql');check('receipt reset idempotent and restores exact baseline',fingerprint(lab)==base)
        # Schema, seed and external dependencies are never silently overwritten/deleted.
        for name,change in [('seed',"update f30_probe.loads set freight_amount=1"),('privilege',"grant select on f30_probe.invoices to authenticated"),('function',"alter function public.f30_probe_action(uuid,text,text) set search_path=public")]:
            result=lab.run('operator','begin; '+change+'; '+TARGET+artifact('fixture.sql'),ok=False)
            check('reinstall refuses '+name+' drift atomically',result.returncode!=0 and fingerprint(lab)==base)
        lab.run('operator','create view public.f30_external_dependency as select * from f30_probe.invoices;')
        check('cleanup RESTRICT refuses external dependency atomically',op(lab,'cleanup.sql',ok=False).returncode!=0 and fingerprint(lab)==base)
        lab.run('operator','drop view public.f30_external_dependency;')
        # Use the unchanged real v2 freeze scripts; never synthesize a freeze exception.
        major=int(lab.scalar("select current_setting('server_version_num')::int/10000"))
        freeze=fz.fill2(fz.sql('02_enable_freeze.sql'),**fz.good(major,scope="'public','f30_probe'",reviewed="'f30_test_control'"))
        acl=fz.catalog_fp(lab)
        lab.run('operator',freeze)
        frozen=fingerprint(lab)
        check('freeze leaves seed and receipt data unchanged',frozen['seed']==base['seed'] and frozen['receipts']==base['receipts'])
        check('cleanup refuses active freeze',op(lab,'cleanup.sql',ok=False).returncode!=0)
        new=Session(lab,'authenticator');live.append(new)
        check('new backend established after activation',new.pid not in (direct.pid,pool.pid))
        evidence['backends']={'direct':direct.pid,'pooled':pool.pid,'new_after_freeze':new.pid}
        for s,label in [(direct,'direct'),(pool,'pooled'),(new,'new')]:
            for org in orgs:
                for role in ('owner','admin','granted_dispatcher'):
                    actions=('prepare','ready','discard') if role=='granted_dispatcher' else ('prepare','ready','discard','issue','reissue','submit')
                    for action in actions:
                        result,state,out=s.call(org['identities'][role],org['invoices']['issued'],action,commit=True)
                        check(f'frozen {label} {role} {action}',state=='25006' and 'TDP_MAINTENANCE_FREEZE' in out,out)
                        evidence['results'].append({'phase':'frozen','transport':label,'role':role,'action':action,'expected':'25006 + TDP_MAINTENANCE_FREEZE','actual':state,'marker': 'TDP_MAINTENANCE_FREEZE' in out})
                    check(f'frozen {label} {role} preview readable',s.call(org['identities'][role],org['invoices']['issued'],'preview')[0]['code']=='OK')
            for role in ('ungranted_dispatcher','accountant','driver','viewer'):
                check('freeze preserves authorization refusal '+label+role,s.call(a['identities'][role],inv,'submit')[0]=={'code':'FORBIDDEN'})
            for role in ('granted_dispatcher','ungranted_dispatcher','accountant','driver','viewer','null','anon','service_role'):
                uid=a['identities'].get(role)
                sqlrole=role if role in ('anon','service_role') else 'authenticated'
                result,state,out=s.call(uid,inv,'submit',role=sqlrole)
                check('frozen denial '+label+' '+role,state=='42501' if sqlrole!='authenticated' else result=={'code':'FORBIDDEN'},out)
                if uid: check('frozen tenant isolation '+label+' '+role,s.call(uid,b['invoices']['issued'],'submit')[0]=={'code':'NOT_FOUND'})
        check('all frozen attempts leave data fingerprints unchanged',fingerprint(lab)==frozen)
        lab.run('operator',fz.sql('05_disable_freeze.sql'))
        restoration=lab.run('operator',fz.sql('06_verify_disable.sql'))
        check('exact v2 restoration verifier passes','SQL_LAYER_RESTORED__EXTERNAL_WRITE_PROBE_REQUIRED' in restoration.stdout)
        check('exact prior role attributes, settings and ACL restored',fz.catalog_fp(lab)==acl and fingerprint(lab)==base)
        check('no orphan trigger remains',fz.trig_count(lab)==0)
        for s,label in [(direct,'direct'),(pool,'pooled'),(new,'new')]:
            check('restored write '+label,s.call(owner,inv,'prepare',key='restore-'+label,commit=True)[0]['code']=='OK')
        op(lab,'reset.sql');check('post-restoration fingerprint restored',fingerprint(lab)==base)
        # Deliberately fail after activation; cleanup must unfreeze via the real script.
        try:
            lab.run('operator',freeze)
            raise RuntimeError('synthetic probe failure')
        except RuntimeError:
            lab.run('operator',fz.sql('05_disable_freeze.sql'))
        check('failure path restores exact state and no active run',fz.catalog_fp(lab)==acl and fingerprint(lab)==base and lab.scalar("select count(*) from ops_freeze_v2.freeze_run where status='frozen'")=='0')
        # A changed privilege is reported as drift, never accepted as an exact restoration.
        lab.run('operator',freeze)
        lab.run('operator','grant select on table f30_probe.invoices to service_role;')
        lab.run('operator',fz.sql('05_disable_freeze.sql'))
        drift=lab.run('operator',fz.sql('06_verify_disable.sql'))
        check('restoration verifier refuses privilege drift','SQL_LAYER_RESTORED_BUT_FINGERPRINT_DIFFERS' in drift.stdout)
        check('fixture reset refuses changed ACL',op(lab,'reset.sql',ok=False).returncode!=0)
        lab.run('operator','revoke select on table f30_probe.invoices from service_role;')
        check('only the injected privilege is revoked; exact prior ACL restored',fz.catalog_fp(lab)==acl and fingerprint(lab)==base)
        evidence['restored']=fingerprint(lab)
        op(lab,'cleanup.sql');op(lab,'cleanup.sql')
        check('cleanup idempotent; no fixture schema or RPC',lab.scalar("select (to_regnamespace('f30_probe') is null and to_regprocedure('public.f30_probe_action(uuid,text,text)') is null and to_regprocedure('public.f30_probe_context()') is null)::text")=='true')
        # Clean reinstall has identical row/catalog fingerprints, including owner and ACL.
        op(lab,'fixture.sql');check('deterministic reinstall fingerprint',fingerprint(lab)==base);op(lab,'cleanup.sql')
        lab.run('operator','drop table f30_test_control.marker; drop schema f30_test_control;')
        check('fixture cleanup leaves prior public role/settings/ACL fingerprint exact',fz.catalog_fp(lab)==initial)
        evidence['final']={'fixture_tables':0,'fixture_rpcs':0,'fixture_rows':0,'active_freezes':0,'freeze_triggers':0,'seed_fingerprint_before_cleanup':base['seed'],'catalog_fingerprint_before_cleanup':base['catalog'],'prior_catalog_restored':True}
        good=True
    finally:
        for s in live: s.close()
        # Cluster cleanup stops and deletes only this harness-created local cluster.
        lab.c.cleanup(good)
    evidence['checks']=len(checks)
    path=Path('/private/tmp/f30-role-fixture-evidence.json');path.write_text(json.dumps(evidence,indent=2)+'\n')
    print(f'ALL {len(checks)} ROLE FIXTURE CHECKS PASSED; evidence {path}')

if __name__=='__main__':
    if len(sys.argv)!=1: raise SystemExit('LOCAL ONLY: no target/connection arguments accepted')
    main()
