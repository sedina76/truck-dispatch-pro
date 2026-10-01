"""Role-model companion to the existing production freeze probe.
No network code. The parent supplies its guarded transport. Never emits response bodies/tokens.
"""
import base64
import json
from pathlib import Path
import re

HERE=Path(__file__).resolve().parent
FORBIDDEN_REFS={'zteixenjpcygjvznueuo','fjmrvvyjvqdyopnyetez','localdisposablef30xx'}
ACTIONS=('preview','prepare','ready','discard','issue','reissue','submit')

def topology(): return json.loads((HERE/'topology.json').read_text())

def required_token_names():
    """The 14 named identities -- always required. TDP_F30_NULL_JWT is deliberately NOT in this list: no ordinary Supabase Auth flow can ever produce a
    subject-less session (see provision_auth_test_identities.py's own module docstring), so requiring it unconditionally would permanently block the other 14,
    provable cases for a gap that is a known, standing limitation rather than a configuration mistake. See token_names() for the full set including it."""
    return [f'TDP_F30_ORG{n}_{role.upper()}_JWT' for n in (1,2) for role in topology()['organizations'][n-1]['identities']]

def token_names():
    return required_token_names() + ['TDP_F30_NULL_JWT']

def validate_target(ref,env):
    """Additional non-production allowlist, checked BEFORE the first request. TDP_F30_NULL_JWT is OPTIONAL: if absent, the 14 named identities still run and its
    own case is recorded as NOT_PROVEN by run() below (see cases()/run()); if PRESENT, it is validated with the exact same rigor as every other identity below --
    absence is the only thing this relaxes, never a malformed or wrong-subject value once one is supplied."""
    if ref in FORBIDDEN_REFS or ref.startswith('fjmrvvyjvqd') or not re.fullmatch('[a-z0-9]{20}',ref or ''):
        raise ValueError('F30_TEST_TARGET_REFUSED')
    if env.get('TDP_F30_TEST_PROJECT_REF')!=ref or env.get('TDP_F30_ENVIRONMENT')!='nonproduction-f30':
        raise ValueError('F30_EXPLICIT_NONPRODUCTION_TARGET_REQUIRED')
    if any(not env.get(k) for k in required_token_names()): raise ValueError('F30_REQUIRED_SYNTHETIC_IDENTITIES_MISSING')
    # Payload decoding is a consistency check, NOT signature verification (the API does that).
    # Never display/store decoded claims. Validate deterministic subjects before any request.
    expected={f'TDP_F30_ORG{n}_{r.upper()}_JWT':uid for n,org in enumerate(topology()['organizations'],1) for r,uid in org['identities'].items()}
    if env.get('TDP_F30_NULL_JWT'): expected['TDP_F30_NULL_JWT']=None  # validated only if SUPPLIED; absence is not an error (see docstring above)
    for name,subject in expected.items():
        try:
            part=env[name].split('.')[1]
            claims=json.loads(base64.urlsafe_b64decode(part+'='*(-len(part)%4)))
            valid=claims.get('role')=='authenticated' and (claims.get('sub') or None)==subject and claims.get('iss')==f'https://{ref}.supabase.co/auth/v1'
        except (IndexError,ValueError,TypeError,AttributeError): valid=False
        if not valid: raise ValueError('F30_SYNTHETIC_IDENTITY_MISMATCH')

def null_identity_available(env):
    return bool(env.get('TDP_F30_NULL_JWT'))

def context_ok(data,ref):
    return isinstance(data,dict) and data.get('code')=='OK' and data.get('project_ref')==ref and data.get('environment')=='nonproduction-f30' and data.get('fixture_id')==topology()['fixture_id'] and data.get('source_hash')==topology()['source_hash'] and data.get('seed_matches') is True and data.get('catalog_matches') is True and bool(re.match(r'^17\.6(?:\s|$)',str(data.get('postgres_version',''))))

def cases(phase,null_available=True):
    """Deterministic synthetic requests. No organization/context parameters cross the API. null_available=False (TDP_F30_NULL_JWT not supplied) omits the 'null'
    role entirely -- every other role's cases, actions, expectations and ordering are BYTE-FOR-BYTE identical to null_available=True; nothing about the 14 named
    identities changes."""
    out=[]
    for n,org in enumerate(topology()['organizations'],1):
        foreign=topology()['organizations'][2-n]['invoices']['issued']
        for role in (*org['identities'],*(['null'] if null_available else []),'anon','service_role'):
            for action in ACTIONS:
                authorized=role in ('owner','admin') or (role=='granted_dispatcher' and action in ('preview','prepare','ready','discard'))
                expected='42501' if role in ('anon','service_role') else ('FORBIDDEN' if not authorized else ('FROZEN' if phase=='frozen' and action!='preview' else 'OK'))
                out.append({'identity':f'org{n}_{role}','org':n,'role':role,'test':action,'expected':expected,'params':{'p_invoice_id':org['invoices']['issued'],'p_action':action,'p_request_key':f'f30-{phase}-{n}-{role}-{action}'}})
            if role in org['identities']:
                for label,inv in [('foreign',foreign),('unknown','f3000000-0000-0000-0000-000000999999')]:
                    out.append({'identity':f'org{n}_{role}','org':n,'role':role,'test':label,'expected':'NOT_FOUND','params':{'p_invoice_id':inv,'p_action':'submit','p_request_key':f'f30-{phase}-{n}-{role}-unknown'}})
            if role=='granted_dispatcher':
                out.append({'identity':f'org{n}_{role}','org':n,'role':role,'test':'factoring_replay','expected':'FORBIDDEN','params':{'p_invoice_id':org['invoices']['issued'],'p_action':'submit','p_request_key':f'f30-baseline-{n}-owner-submit'}})
    return out

def evaluate(case,http,body):
    try: data=json.loads(body)
    except (ValueError,TypeError): data={}
    if not isinstance(data,dict): data={}
    expected=case['expected']; code=data.get('code')
    marker=isinstance(data.get('message'),str) and data['message'].startswith('TDP_MAINTENANCE_FREEZE')
    # Record only safe enumerated codes, never arbitrary response strings.
    safe_code=code if code in ('OK','FORBIDDEN','NOT_FOUND','42501','25006','INVALID_REQUEST','IDEMPOTENCY_KEY_REUSED') else None
    if expected=='FROZEN':
        passed=http==405 and code=='25006' and marker
        verdict='PASS' if passed else ('BREACH' if 200<=http<300 else 'FAIL')
    elif expected=='42501': verdict='PASS' if http in (401,403) and code=='42501' else 'FAIL'
    elif expected in ('FORBIDDEN','NOT_FOUND'):
        verdict='PASS' if http==200 and data=={'code':expected} else 'FAIL'
    else: verdict='PASS' if http==200 and code=='OK' and data.get('synthetic') is True else 'FAIL'
    return {'identity':case['identity'],'test':case['test'],'expected':expected,'http':http,'code':safe_code,'marker_present':marker,'verdict':verdict}

NULL_IDENTITY_NOT_PROVEN_REASON=('F30_NULL_IDENTITY_JWT_NOT_SUPPLIED: no ordinary Supabase Auth flow (password sign-in, magic link, OTP, OAuth, or even anonymous '
    'sign-in) ever issues a session with no sub claim, so this fixture has no supported way to mint one; the null-identity REST case is therefore NOT PROVEN this '
    'run. The local database-level refusal (role_fixture/tests.py, direct SQL, bypassing PostgREST/GoTrue entirely) is unaffected and stands on its own.')

def run(request,base,phase,env,ref):
    """Run only after parent target guard; reject an unverified marker BEFORE any write.
    Caller owns restoration on failure. Stop on the first mismatch; never relax an assertion -- for every case that DOES run.
    TDP_F30_NULL_JWT is optional (validate_target no longer requires it): when supplied, the null-identity cases run and are evaluated with EXACTLY the same
    rules as every other case, contributing to the overall verdict exactly as before. When absent, the null-identity cases are omitted from cases() entirely and
    the returned result instead carries 'null_identity_status':'not_proven' plus a fixed, quotable reason -- an explicit, evidenced gap, never a silent one, and
    never something that blocks or weakens the 14 named identities' own results.
    """
    validate_target(ref,env)
    null_available=null_identity_available(env)
    null_identity_status='included' if null_available else 'not_proven'
    anon=env.get('TDP_PROD_ANON_KEY'); service=env.get('TDP_PROD_SERVICE_KEY')
    owner=env['TDP_F30_ORG1_OWNER_JWT']
    status,body=request(base,'POST','/rest/v1/rpc/f30_probe_context',anon,owner,{})
    try: ctx=json.loads(body)
    except (ValueError,TypeError): ctx={}
    if status!=200 or not context_ok(ctx,ref):
        return {'verdict':'BLOCKED','reason':'F30_MARKER_VERSION_OR_FINGERPRINT_MISMATCH','results':[],'null_identity_status':'not_attempted'}
    rows=[]
    for case in cases(phase,null_available):
        role=case['role']; key=service if role=='service_role' else anon
        jwt=None if role in ('anon','service_role') else env['TDP_F30_NULL_JWT' if role=='null' else f'TDP_F30_ORG{case["org"]}_{role.upper()}_JWT']
        http,body=request(base,'POST','/rest/v1/rpc/f30_probe_action',key,jwt,case['params'])
        result=evaluate(case,http,body);rows.append(result)
        if result['verdict']!='PASS': return {'verdict':result['verdict'],'results':rows,'null_identity_status':null_identity_status}
    out={'verdict':'PASS','results':rows,'null_identity_status':null_identity_status}
    if not null_available: out['null_identity_reason']=NULL_IDENTITY_NOT_PROVEN_REASON
    return out

def summary_verdict(result):
    """A single, unmistakable label for humans/evidence files, derived from -- never replacing -- run()'s own 'verdict'/'null_identity_status' fields (every
    existing assertion on those two fields is unchanged by this function's existence). Only a PASS run is ever ambiguous about what was actually proven:
      - PASS + null_identity_status=='included'     -> 'F30_ROLE_MODEL_FULLY_PROVEN'        (all 14 identities AND the null-identity REST case)
      - PASS + null_identity_status!='included'      -> 'F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN' (the 14 identities only; null case NOT_PROVEN, see reason)
    Any non-PASS verdict ('BLOCKED', 'BREACH', 'FAIL', or anything else run() might ever return) passes straight through unchanged -- this function only ever
    ADDS a distinction within PASS; it never narrows, widens, or reinterprets a failure."""
    verdict = result.get('verdict')
    if verdict != 'PASS':
        return verdict
    if result.get('null_identity_status') == 'included':
        return 'F30_ROLE_MODEL_FULLY_PROVEN'
    return 'F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN'
