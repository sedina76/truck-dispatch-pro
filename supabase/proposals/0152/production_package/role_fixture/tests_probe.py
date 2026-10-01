#!/usr/bin/env python3
"""Offline transport/contract tests. Fake in-memory tokens, no network or credentials."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

probe=load('f30_role',HERE/'probe.py')
parent=load('f30_parent',HERE.parent/'api_freeze_probe_production.py')
REF='abcdefghijklmnopqrst'

def token(sub):
    payload={'sub':sub,'role':'authenticated','iss':f'https://{REF}.supabase.co/auth/v1'}
    enc=base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip('=')
    return 'synthetic.'+enc+'.not-a-signature'

def environment():
    e={'TDP_F30_TEST_PROJECT_REF':REF,'TDP_F30_ENVIRONMENT':'nonproduction-f30','TDP_PROD_ANON_KEY':'synthetic-anon','TDP_PROD_SERVICE_KEY':'synthetic-service'}
    for n,org in enumerate(probe.topology()['organizations'],1):
        for role,uid in org['identities'].items(): e[f'TDP_F30_ORG{n}_{role.upper()}_JWT']=token(uid)
    e['TDP_F30_NULL_JWT']=token(None)
    return e

def context():
    return {'code':'OK','project_ref':REF,'environment':'nonproduction-f30','fixture_id':probe.topology()['fixture_id'],'source_hash':probe.topology()['source_hash'],'seed_matches':True,'catalog_matches':True,'postgres_version':'17.6 (synthetic contract response)'}

class ProbeTests(unittest.TestCase):
    def test_guard_absent_and_production(self):
        for ref,env in [(REF,{}),('zteixenjpcygjvznueuo',environment()),('fjmrvvyjvqdyopnyetez',environment()),(REF,{**environment(),'TDP_F30_ENVIRONMENT':'production'}),(REF,{**environment(),'TDP_F30_TEST_PROJECT_REF':'different'})]:
            calls=[]
            with self.assertRaises(ValueError): probe.run(lambda *args:calls.append(args),'unused','baseline',env,ref)
            self.assertEqual(calls,[])
    def test_token_subject_and_issuer_binding(self):
        for value in ('invalid',token('f3000000-0000-0000-0000-000000001005')):
            with self.assertRaises(ValueError): probe.validate_target(REF,{**environment(),'TDP_F30_ORG1_OWNER_JWT':value})
        probe.validate_target(REF,environment())
    def test_null_jwt_is_optional_but_never_weakened_when_supplied(self):
        env_without_null={k:v for k,v in environment().items() if k!='TDP_F30_NULL_JWT'}
        probe.validate_target(REF,env_without_null)  # must NOT raise: absence alone is fine
        self.assertFalse(probe.null_identity_available(env_without_null))
        self.assertTrue(probe.null_identity_available(environment()))
        for garbage in ('not-a-jwt',token('11111111-1111-1111-1111-111111111111')):  # present but malformed/wrong-subject
            with self.assertRaises(ValueError): probe.validate_target(REF,{**environment(),'TDP_F30_NULL_JWT':garbage})
    def test_parent_guard_enforces_additional_allowlist_before_requests(self):
        from argparse import Namespace
        a=Namespace(confirm='PROBE PRODUCTION '+REF,ref=REF,phase='baseline',role_model=True)
        env={'TDP_PROD_PROJECT_REF':REF,'TDP_PROD_PROJECT_URL':'https://'+REF+'.supabase.co'}
        with patch.dict(os.environ,env,clear=True), self.assertRaises(SystemExit) as c: parent.guard(a)
        self.assertEqual(c.exception.code,4)
    def test_parent_guard_does_NOT_refuse_when_ONLY_the_null_jwt_is_missing(self):
        from argparse import Namespace
        a=Namespace(confirm='PROBE PRODUCTION '+REF,ref=REF,phase='baseline',role_model=True)
        env={'TDP_PROD_PROJECT_REF':REF,'TDP_PROD_PROJECT_URL':'https://'+REF+'.supabase.co',**{k:v for k,v in environment().items() if k!='TDP_F30_NULL_JWT'}}
        with patch.dict(os.environ,env,clear=True): parent.guard(a)  # must NOT raise -- this is the fix under test
    def test_removing_any_of_the_14_named_identities_still_refuses_only_the_null_jwt_is_optional(self):
        for name in probe.required_token_names():
            env={k:v for k,v in environment().items() if k!=name}
            with self.assertRaises(ValueError): probe.run(lambda *a:None,'unused','baseline',env,REF)
    def test_marker_version_and_fingerprint_failures_stop_before_writes(self):
        for key,value in [('code','FORBIDDEN'),('environment','production'),('project_ref','other'),('source_hash','changed'),('seed_matches',False),('catalog_matches',False),('postgres_version','18.0')]:
            calls=[]
            def request(*args):
                calls.append(args[2]);return 200,json.dumps({**context(),key:value})
            result=probe.run(request,'unused','baseline',environment(),REF)
            self.assertEqual(result['verdict'],'BLOCKED');self.assertEqual(calls,['/rest/v1/rpc/f30_probe_context'])
    def test_complete_case_matrix_and_parameter_allowlist(self):
        for phase in ('baseline','frozen','restored'):
            cases=probe.cases(phase)
            self.assertEqual(len(cases),170)
            self.assertEqual({c['role'] for c in cases},{'owner','admin','granted_dispatcher','ungranted_dispatcher','accountant','driver','viewer','null','anon','service_role'})
            self.assertTrue(all(set(c['params'])=={'p_invoice_id','p_action','p_request_key'} for c in cases))
            self.assertTrue(all(c['expected']=='FORBIDDEN' for c in cases if c['role']=='granted_dispatcher' and c['test'] in ('issue','reissue','submit','factoring_replay')))
    def test_cases_without_null_omit_only_the_null_role_and_change_nothing_else(self):
        for phase in ('baseline','frozen','restored'):
            with_null=probe.cases(phase,True); without_null=probe.cases(phase,False)
            self.assertEqual(with_null,probe.cases(phase))  # True is the default -- byte-for-byte the same as calling with no second argument at all
            null_rows=[c for c in with_null if c['role']=='null']
            self.assertTrue(null_rows)
            self.assertEqual(len(with_null)-len(null_rows),len(without_null))
            self.assertNotIn('null',{c['role'] for c in without_null})
            self.assertEqual([c for c in with_null if c['role']!='null'],without_null)  # every remaining case is IDENTICAL, same order, nothing else touched
    def test_all_three_phases(self):
        for phase in ('baseline','frozen','restored'):
            cases=iter(probe.cases(phase))
            def request(base,method,path,key,bearer,body):
                if path.endswith('context'): return 200,json.dumps(context())
                c=next(cases);self.assertEqual(body,c['params'])
                expected=c['expected']
                if expected=='FROZEN': return 405,json.dumps({'code':'25006','message':'TDP_MAINTENANCE_FREEZE synthetic'})
                if expected=='42501': return 403,json.dumps({'code':'42501'})
                return 200,json.dumps({'code':'OK','synthetic':True} if expected=='OK' else {'code':expected})
            r=probe.run(request,'unused',phase,environment(),REF)
            self.assertEqual(r['verdict'],'PASS');self.assertEqual(len(r['results']),170)
            self.assertEqual(r['null_identity_status'],'included');self.assertNotIn('null_identity_reason',r)
    def test_the_14_named_identities_run_and_can_still_fully_pass_when_null_jwt_is_absent(self):
        env_without_null={k:v for k,v in environment().items() if k!='TDP_F30_NULL_JWT'}
        for phase in ('baseline','frozen','restored'):
            cases=iter(probe.cases(phase,False))
            def request(base,method,path,key,bearer,body):
                if path.endswith('context'): return 200,json.dumps(context())
                c=next(cases);self.assertEqual(body,c['params'])
                expected=c['expected']
                if expected=='FROZEN': return 405,json.dumps({'code':'25006','message':'TDP_MAINTENANCE_FREEZE synthetic'})
                if expected=='42501': return 403,json.dumps({'code':'42501'})
                return 200,json.dumps({'code':'OK','synthetic':True} if expected=='OK' else {'code':expected})
            r=probe.run(request,'unused',phase,env_without_null,REF)
            self.assertEqual(r['verdict'],'PASS')
            self.assertEqual(len(r['results']),len(probe.cases(phase,False)))
            self.assertNotIn('null',{c['identity'].split('_',1)[1] for c in r['results']})
            self.assertEqual(r['null_identity_status'],'not_proven')
            self.assertIn('F30_NULL_IDENTITY_JWT_NOT_SUPPLIED',r['null_identity_reason'])
            self.assertIn('role_fixture/tests.py',r['null_identity_reason'])
    def test_summary_verdict_fully_proven_when_pass_and_null_included(self):
        self.assertEqual(probe.summary_verdict({'verdict':'PASS','null_identity_status':'included'}),'F30_ROLE_MODEL_FULLY_PROVEN')
    def test_summary_verdict_14_proven_when_pass_and_null_not_proven(self):
        self.assertEqual(probe.summary_verdict({'verdict':'PASS','null_identity_status':'not_proven'}),'F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN')
    def test_summary_verdict_passes_non_pass_verdicts_through_unchanged(self):
        for verdict in ('BLOCKED','BREACH','FAIL','ANYTHING_ELSE'):
            self.assertEqual(probe.summary_verdict({'verdict':verdict,'null_identity_status':'included'}),verdict)
            self.assertEqual(probe.summary_verdict({'verdict':verdict}),verdict)  # missing null_identity_status never affects a non-PASS pass-through
    def test_summary_verdict_over_actual_run_results(self):
        for phase in ('baseline','frozen','restored'):
            cases=iter(probe.cases(phase))
            def request(base,method,path,key,bearer,body):
                if path.endswith('context'): return 200,json.dumps(context())
                c=next(cases);expected=c['expected']
                if expected=='FROZEN': return 405,json.dumps({'code':'25006','message':'TDP_MAINTENANCE_FREEZE synthetic'})
                if expected=='42501': return 403,json.dumps({'code':'42501'})
                return 200,json.dumps({'code':'OK','synthetic':True} if expected=='OK' else {'code':expected})
            r=probe.run(request,'unused',phase,environment(),REF)
            self.assertEqual(probe.summary_verdict(r),'F30_ROLE_MODEL_FULLY_PROVEN')
        env_without_null={k:v for k,v in environment().items() if k!='TDP_F30_NULL_JWT'}
        cases=iter(probe.cases('baseline',False))
        def request2(base,method,path,key,bearer,body):
            if path.endswith('context'): return 200,json.dumps(context())
            c=next(cases);expected=c['expected']
            if expected=='FROZEN': return 405,json.dumps({'code':'25006','message':'TDP_MAINTENANCE_FREEZE synthetic'})
            if expected=='42501': return 403,json.dumps({'code':'42501'})
            return 200,json.dumps({'code':'OK','synthetic':True} if expected=='OK' else {'code':expected})
        r=probe.run(request2,'unused','baseline',env_without_null,REF)
        self.assertEqual(probe.summary_verdict(r),'F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN')
    def test_blocked_before_any_case_reports_null_identity_as_not_attempted(self):
        def request(*args): return 500,'{}'
        r=probe.run(request,'unused','baseline',environment(),REF)
        self.assertEqual(r['verdict'],'BLOCKED');self.assertEqual(r['null_identity_status'],'not_attempted')
    def test_breach_stops_immediately(self):
        calls=[]
        def request(base,method,path,*args):
            calls.append(path)
            return 200,json.dumps(context() if path.endswith('context') else {'code':'OK','synthetic':True})
        r=probe.run(request,'unused','frozen',environment(),REF)
        self.assertEqual(r['verdict'],'BREACH');self.assertEqual(len(calls),3) # context, preview, first write
    def test_wrong_freeze_error_is_never_a_pass(self):
        case=next(c for c in probe.cases('frozen') if c['expected']=='FROZEN')
        for status,body in [(403,{'code':'42501'}),(405,{'code':'25006','message':'different'}),(500,{'code':'25006','message':'TDP_MAINTENANCE_FREEZE'}),(0,{})]:
            self.assertEqual(probe.evaluate(case,status,json.dumps(body))['verdict'],'FAIL')
    def test_denials_must_not_expose_identifiers(self):
        case=next(c for c in probe.cases('baseline') if c['expected']=='NOT_FOUND')
        self.assertEqual(probe.evaluate(case,200,json.dumps({'code':'NOT_FOUND','organization':'leak'}))['verdict'],'FAIL')
        self.assertEqual(probe.evaluate(case,200,json.dumps({'code':'NOT_FOUND'}))['verdict'],'PASS')
    def test_anon_and_service_permission_denied(self):
        for c in probe.cases('baseline'):
            if c['role'] in ('anon','service_role'):
                self.assertEqual(probe.evaluate(c,403,json.dumps({'code':'42501'}))['verdict'],'PASS')
                self.assertEqual(probe.evaluate(c,200,json.dumps({'code':'OK'}))['verdict'],'FAIL')
    def test_sanitized_evidence_and_token_scrubbing(self):
        c=probe.cases('baseline')[0]
        secret=environment()['TDP_F30_ORG1_OWNER_JWT']
        r=probe.evaluate(c,500,json.dumps({'code':secret,'message':secret,'details':secret}))
        self.assertNotIn(secret,json.dumps(r))
        with patch.dict(os.environ,environment(),clear=True): self.assertNotIn(secret,parent.scrub(secret))
    def test_parent_evidence_explicitly_marks_the_null_identity_case(self):
        src=(HERE.parent/'api_freeze_probe_production.py').read_text()
        self.assertIn('ev["null_identity_status"] = result.get("null_identity_status"',src)
        self.assertIn('F30_NULL_IDENTITY_NOT_PROVEN',src)
        self.assertIn('ev["role_model"] = result',src)  # the full role_model dict (incl. null_identity_reason when applicable) still reaches the evidence file too
    def test_parent_evidence_gives_pass_an_explicit_summary_verdict(self):
        src=(HERE.parent/'api_freeze_probe_production.py').read_text()
        self.assertIn('ev["role_model_summary"] = role_module.summary_verdict(result)',src)
        self.assertIn('F30_ROLE_MODEL_FULLY_PROVEN',src)
        self.assertIn("ev['role_model_summary']",src)  # printed, not just written silently to the evidence file
    def test_real_pilot_contract_unchanged(self):
        sql=(HERE.parents[2]/'0157/proposed_0157.sql').read_text()
        for name in ('submit_carrier_invoice_to_factor','issue_prepared_carrier_invoice','reissue_carrier_invoice'):
            body=sql.split('create function public.'+name+'(',1)[1].split('$fn$;',1)[0]
            self.assertIn("p.role::text in ('owner', 'admin')",body)
            self.assertNotIn("p.role::text in ('owner', 'admin', 'dispatcher')",body)
        self.assertIn("v_role = 'dispatcher' and exists",sql)

if __name__=='__main__': unittest.main()
