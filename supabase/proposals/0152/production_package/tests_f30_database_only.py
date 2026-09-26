#!/usr/bin/env python3
"""Offline tests for the nonproduction database-only freeze confirmation."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from argparse import Namespace
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("parent_probe", HERE / "api_freeze_probe_production.py")
parent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parent)
REF = "abcdefghijklmnopqrst"


class FakeRoleModel:
    def validate_target(self, ref, env):
        if (ref != REF or env.get("TDP_F30_TEST_PROJECT_REF") != ref or
                env.get("TDP_F30_ENVIRONMENT") != "nonproduction-f30"):
            raise ValueError("F30_EXPLICIT_NONPRODUCTION_TARGET_REQUIRED")

    def run(self, request, base, phase, env, ref):
        return {"verdict": "PASS", "null_identity_status": "not_proven"}

    def summary_verdict(self, result):
        return "F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN"


def args(ref=REF, **overrides):
    values = dict(confirm=f"PROBE F30 DATABASE ONLY {ref}", ref=ref,
                  phase="frozen", role_model=True,
                  i_confirm_f30_database_only_freeze=True,
                  i_confirm_maintenance_mode_is_on=False)
    values.update(overrides)
    return Namespace(**values)


def env(ref=REF):
    return {"TDP_PROD_PROJECT_REF": ref,
            "TDP_PROD_PROJECT_URL": f"https://{ref}.supabase.co",
            "TDP_F30_TEST_PROJECT_REF": ref,
            "TDP_F30_ENVIRONMENT": "nonproduction-f30",
            "TDP_PROD_ANON_KEY": "fake-anon", "TDP_PROD_SERVICE_KEY": "fake-service",
            "TDP_PROD_USER_JWT": "fake-jwt"}


class DatabaseOnlyTests(unittest.TestCase):
    def setUp(self):
        self.block = patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden"))
        self.block2 = patch.object(socket, "create_connection", side_effect=AssertionError("network forbidden"))
        self.block.start()
        self.block2.start()
        self.addCleanup(self.block.stop)
        self.addCleanup(self.block2.stop)

    def test_refusals_make_no_request(self):
        cases = [
            (args(phase="baseline"), env()),
            (args(role_model=False), env()),
            (args(i_confirm_maintenance_mode_is_on=True), env()),
            (args(confirm=f"PROBE PRODUCTION {REF}"), env()),
            (args(confirm="PROBE F30 DATABASE ONLY wrong"), env()),
            (args(ref="zzzzzzzzzzzzzzzzzzzz"), env()),
            (args(ref="zteixenjpcygjvznueuo"), env("zteixenjpcygjvznueuo")),
            (args(), {**env(), "TDP_F30_ENVIRONMENT": "production"}),
            (args(), {**env(), "TDP_F30_TEST_PROJECT_REF": "zzzzzzzzzzzzzzzzzzzz"}),
            (args(i_confirm_f30_database_only_freeze=False,
                  confirm=f"PROBE PRODUCTION {REF}"), env()),
        ]
        for a, e in cases:
            with self.subTest(a=a, e=e), patch.dict(os.environ, e, clear=True), \
                    patch.object(parent, "role_model", return_value=FakeRoleModel()), \
                    patch.object(parent, "request", side_effect=AssertionError("request sent")):
                with self.assertRaises(SystemExit) as exc:
                    parent.guard(a)
                self.assertEqual(exc.exception.code, 4)

    def test_existing_app_confirmation_still_works_and_db_only_is_separate(self):
        with patch.dict(os.environ, env(), clear=True), patch.object(parent, "role_model", return_value=FakeRoleModel()):
            app = args(i_confirm_f30_database_only_freeze=False,
                       i_confirm_maintenance_mode_is_on=True,
                       confirm=f"PROBE PRODUCTION {REF}")
            self.assertEqual(parent.guard(app), env()["TDP_PROD_PROJECT_URL"])
            self.assertEqual(parent.guard(args()), env()["TDP_PROD_PROJECT_URL"])

    def test_frozen_result_labels_scope_without_relaxing_generic_assertions(self):
        with tempfile.TemporaryDirectory() as tmp:
            pids = iter([11, 12] * 30)

            def fake_request(base, method, path, key, bearer=None, body=None):
                if path.endswith("ops_freeze_probe_diag"):
                    return 200, json.dumps({"pid": next(pids), "backend_start": "synthetic"})
                if method == "GET":
                    return 200, "[]"
                return 405, json.dumps({"code": "25006", "message": "TDP_MAINTENANCE_FREEZE synthetic"})

            argv = ["probe", "--role-model", "--phase", "frozen", "--label", "pooled",
                    "--ref", REF, "--confirm", f"PROBE F30 DATABASE ONLY {REF}",
                    "--i-confirm-f30-database-only-freeze", "--evidence-dir", tmp]
            with patch.dict(os.environ, env(), clear=True), patch.object(sys, "argv", argv), \
                    patch.object(parent, "role_model", return_value=FakeRoleModel()), \
                    patch.object(parent, "request", side_effect=fake_request):
                with self.assertRaises(SystemExit) as exc:
                    parent.main()
            self.assertEqual(exc.exception.code, 0)
            files = list(Path(tmp).glob("evidence_frozen_pooled_*.json"))
            self.assertEqual(len(files), 1)
            result = json.loads(files[0].read_text())
            self.assertEqual(result["final"], "F30_DATABASE_FREEZE_PROVEN")
            self.assertEqual(result["app_maintenance_mode"], "NOT_TESTED")
            self.assertEqual(result["probe_scope"], "F30_NONPRODUCTION_DATABASE_ONLY")
            self.assertEqual(result["role_model_summary"], "F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN")
            self.assertEqual(result["null_identity_status"], "not_proven")
            self.assertEqual(len(result["results"]), 3 * (1 + 4 * 5))
            self.assertTrue(all(row["verdict"] in ("PASS", "BLOCKED") for row in result["results"]))

    def test_database_only_still_stops_on_first_successful_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []

            def leaky_request(base, method, path, key, bearer=None, body=None):
                calls.append((method, path))
                if path.endswith("ops_freeze_probe_diag"):
                    return 200, json.dumps({"pid": 11, "backend_start": "synthetic"})
                if method == "GET":
                    return 200, "[]"
                return 201, "{}"

            argv = ["probe", "--role-model", "--phase", "frozen", "--label", "leak",
                    "--ref", REF, "--confirm", f"PROBE F30 DATABASE ONLY {REF}",
                    "--i-confirm-f30-database-only-freeze", "--evidence-dir", tmp]
            with patch.dict(os.environ, env(), clear=True), patch.object(sys, "argv", argv), \
                    patch.object(parent, "role_model", return_value=FakeRoleModel()), \
                    patch.object(parent, "request", side_effect=leaky_request):
                with self.assertRaises(SystemExit) as exc:
                    parent.main()
            self.assertEqual(exc.exception.code, 3)
            self.assertEqual([m for m, _ in calls if m in ("POST", "PATCH", "DELETE")], ["POST", "POST"])
            result = json.loads(next(Path(tmp).glob("evidence_frozen_leak_*.json")).read_text())
            self.assertEqual(result["final"], "FREEZE_BREACH")
            self.assertEqual(result["production_approval"], "BLOCKED")
            self.assertEqual(result["app_maintenance_mode"], "NOT_TESTED")


if __name__ == "__main__":
    unittest.main()
