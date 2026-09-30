#!/usr/bin/env python3
"""Offline mocked requests only; no hosted connection or credentials."""
import importlib.util, json, os, sys, tempfile, threading, unittest, io
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('support', ROOT/'tests_f30_database_only.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p=m.parent
class SamplingTests(unittest.TestCase):
    def run_probe(self, mode='ok', compare=None):
        seen=[]; lock=threading.Lock(); workers=set()
        def request(base, method, path, key, bearer=None, body=None):
            concurrent=threading.current_thread() is not threading.main_thread()
            with lock:
                seen.append((method,path,concurrent)); workers.add(threading.get_ident()) if concurrent else None
            if path.endswith(p.RPC_DIAG):
                if concurrent and mode=='bad_http': return 401, 'SECRET RESPONSE'
                if concurrent and mode=='null': return 200,json.dumps({'pid':44,'backend_start':None})
                pid=44 if mode=='one' or not concurrent else threading.get_ident()
                return 200,json.dumps({'pid':pid,'backend_start':'synthetic'})
            if method=='GET': return 200,'[]'
            if mode=='leak': return 201,'{}'
            return 405,json.dumps({'code':'25006','message':'TDP_MAINTENANCE_FREEZE synthetic'})
        with tempfile.TemporaryDirectory() as tmp:
            argv=['probe','--role-model','--phase','frozen','--label','pooled','--ref',m.REF,'--confirm',f'PROBE F30 DATABASE ONLY {m.REF}','--i-confirm-f30-database-only-freeze','--evidence-dir',tmp]
            if compare:
                old=Path(tmp)/'old.json';old.write_text(json.dumps({'backends':[{'pid':44,'backend_start':'synthetic'}]}));argv+=['--compare-pids',str(old),'--label','new']
            out=io.StringIO()
            with patch.dict(os.environ,m.env(),clear=True),patch.object(sys,'argv',argv),patch.object(p,'role_model',return_value=m.FakeRoleModel()),patch.object(p,'request',side_effect=request),redirect_stdout(out),redirect_stderr(out):
                with self.assertRaises(SystemExit) as exc: p.main()
            ev=json.loads(next(Path(tmp).glob('evidence_*.json')).read_text())
            return exc.exception.code,ev,seen,workers,out.getvalue()
    def test_concurrent_diagnostics_only(self):
        code,ev,seen,workers,out=self.run_probe()
        self.assertEqual(code,0);self.assertGreaterEqual(len(workers),2)
        calls=[x for x in seen if x[2]];self.assertEqual(len(calls),12)
        self.assertTrue(all(method=='POST' and path.endswith(p.RPC_DIAG) for method,path,_ in calls))
        self.assertEqual(len(ev['results']),63)
    def test_breach_stops_before_batch(self):
        code,ev,seen,workers,out=self.run_probe('leak')
        self.assertEqual(code,3);self.assertFalse(workers)
        self.assertFalse(any(method in ('PATCH','DELETE') for method,_,_ in seen))
    def test_one_backend_refused(self): self.assertEqual(self.run_probe('one')[0],2)
    def test_null_backend_refused(self): self.assertEqual(self.run_probe('null')[0],2)
    def test_failed_http_not_counted_or_exposed(self):
        code,ev,seen,workers,out=self.run_probe('bad_http')
        self.assertEqual(code,2);self.assertNotIn('SECRET RESPONSE',out+json.dumps(ev))
    def test_shared_backend_still_refused(self): self.assertEqual(self.run_probe(compare=True)[0],2)
if __name__=='__main__': unittest.main()
