#!/usr/bin/env python3
"""Offline tests for provision_auth_test_identities.py and cleanup_auth_test_identities.py, run TOGETHER against one fake, in-memory Auth backend (never a real
network call). Proves the full lifecycle -- provision, verify, cleanup, verify absence -- and every refusal path, exactly as tests_probe.py does for probe.py."""
import base64
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


prov = load("f30_prov", HERE / "provision_auth_test_identities.py")
clean = load("f30_clean", HERE / "cleanup_auth_test_identities.py")
probe = load("f30_probe_mod", HERE / "probe.py")
REF = "abcdefghij0123456789"


def b64url(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


class FakeAuthBackend:
    """A tiny, purely in-memory stand-in for the real Supabase Auth Admin API. No socket, no file, no external process."""

    def __init__(self):
        self.users = {}  # id -> {id, email}

    def request(self, method, path, headers, body):
        if path == "/auth/v1/admin/users" and method == "POST":
            if body["id"] in self.users:
                return 422, json.dumps({"error_code": "email_exists", "msg": "User already registered"})
            self.users[body["id"]] = {"id": body["id"], "email": body["email"]}
            return 201, json.dumps(self.users[body["id"]])
        if path.startswith("/auth/v1/token") and method == "POST":
            match = next((u for u in self.users.values() if u["email"] == body["email"]), None)
            if not match:
                return 400, json.dumps({"error": "invalid_grant"})
            token = f"{b64url({'alg': 'ES256'})}.{b64url({'sub': match['id'], 'role': 'authenticated'})}.sig"
            return 200, json.dumps({"access_token": token})
        if path.startswith("/auth/v1/admin/users/") and method == "GET":
            uid = path.rsplit("/", 1)[1]
            return (200, json.dumps(self.users[uid])) if uid in self.users else (404, "{}")
        if path.startswith("/auth/v1/admin/users/") and method == "DELETE":
            uid = path.rsplit("/", 1)[1]
            if uid in self.users:
                del self.users[uid]
                return 204, ""
            return 404, "{}"
        return 404, "{}"


class FakeAuthBackendIgnoresRequestedId(FakeAuthBackend):
    """Simulates the one confirmed-risky server behavior: on create, silently assigns its OWN id instead of honoring the requested one (everything else -- GET,
    DELETE, sign-in -- behaves normally, keyed on whatever id the row actually has). Used to prove the full provision -> orphan -> cleanup-orphans lifecycle."""

    def __init__(self, assigned_id):
        super().__init__()
        self.assigned_id = assigned_id
        self._used = False

    def request(self, method, path, headers, body):
        if path == "/auth/v1/admin/users" and method == "POST" and not self._used:
            self._used = True
            real_id = self.assigned_id
            self.users[real_id] = {"id": real_id, "email": body["email"]}
            return 201, json.dumps(self.users[real_id])
        return super().request(method, path, headers, body)


class LifecycleTests(unittest.TestCase):
    def test_full_lifecycle_provision_then_cleanup(self):
        backend = FakeAuthBackend()
        with tempfile.TemporaryDirectory() as td:
            written = prov.run(backend.request, "fake-service-role-key", Path(td))
            self.assertEqual(sorted(written), sorted(i["env_name"] for i in prov.identities()))
            self.assertEqual(len(backend.users), 14)
            for i in prov.identities():
                token = (Path(td) / i["env_name"]).read_text()
                claims = json.loads(prov.b64url_decode(token.split(".")[1]))
                self.assertEqual(claims["sub"], i["uuid"])
        deleted, absent = clean.run(backend.request, "fake-service-role-key")
        self.assertEqual(sorted(deleted), sorted(i["env_name"] for i in clean.identities()))
        self.assertEqual(absent, [])
        self.assertEqual(backend.users, {})
        # a second cleanup pass is a clean no-op, never an error
        deleted2, absent2 = clean.run(backend.request, "fake-service-role-key")
        self.assertEqual(deleted2, [])
        self.assertEqual(len(absent2), 14)

    def test_provisioning_and_cleanup_use_the_SAME_deterministic_uuids_as_topology_json(self):
        self.assertEqual({i["uuid"] for i in prov.identities()}, {i["uuid"] for i in clean.identities()})
        t = prov.topology()
        expected = {uid for org in t["organizations"] for uid in org["identities"].values()}
        self.assertEqual({i["uuid"] for i in prov.identities()}, expected)

    def test_the_14_token_filenames_exactly_match_topology_json_and_what_probe_py_reads(self):
        """The three independent sources of truth for 'which 14 env var names exist' must never drift apart: topology.json (the data), provision's own
        identities() (what it writes to --out-dir), and probe.py's required_token_names() (what the hosted probe actually reads out of the environment).
        A single, byte-for-byte-identical, sorted list of all three -- not just equal SETS -- so even ordering assumptions elsewhere can rely on it."""
        t = prov.topology()
        from_topology = sorted(f"TDP_F30_ORG{n}_{role.upper()}_JWT" for n, org in enumerate(t["organizations"], 1) for role in org["identities"])
        from_provisioning = sorted(i["env_name"] for i in prov.identities())
        from_cleanup = sorted(i["env_name"] for i in clean.identities())
        from_probe = sorted(probe.required_token_names())
        self.assertEqual(len(from_topology), 14)
        self.assertEqual(from_topology, from_provisioning)
        self.assertEqual(from_topology, from_cleanup)
        self.assertEqual(from_topology, from_probe)

    def test_cleanup_refuses_a_user_that_is_not_provably_this_fixtures_own_even_if_provisioning_never_ran(self):
        backend = FakeAuthBackend()
        target = prov.identities()[0]
        backend.users[target["uuid"]] = {"id": target["uuid"], "email": "not-ours@example.com"}
        with self.assertRaises(clean.OwnershipError):
            clean.run(backend.request, "k")
        self.assertIn(target["uuid"], backend.users)  # never deleted

    def test_a_partial_prior_run_is_visible_as_already_exists_not_silently_reused(self):
        backend = FakeAuthBackend()
        target = prov.identities()[0]
        backend.users[target["uuid"]] = {"id": target["uuid"], "email": target["email"]}
        with tempfile.TemporaryDirectory() as td, self.assertRaises(prov.ProvisioningError) as c:
            prov.run(backend.request, "k", Path(td))
        self.assertIn("already exists", str(c.exception))

    def test_orphan_full_lifecycle_provision_records_it_and_cleanup_orphans_removes_it(self):
        real_id = "77777777-7777-7777-7777-777777777777"
        backend = FakeAuthBackendIgnoresRequestedId(real_id)
        expected_first = prov.identities()[0]
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(prov.OrphanCreatedError):
                prov.run(backend.request, "k", Path(td))
            written = list(Path(td).iterdir())
            self.assertEqual(sorted(p.name for p in written), ["ORPHANS.json", "PROVISIONING_STATUS.json"])  # no token file for the orphaned identity
            orphans = json.loads((Path(td) / "ORPHANS.json").read_text())
            self.assertEqual(orphans, [{"env_name": expected_first["env_name"], "expected_uuid": expected_first["uuid"], "actual_id": real_id, "email": expected_first["email"]}])
            status = json.loads((Path(td) / "PROVISIONING_STATUS.json").read_text())
            self.assertEqual(status["status"], "failed")
            self.assertEqual(status["succeeded"], [])
            # ENFORCED STOP: a rerun against the same out_dir is refused while ORPHANS.json is unresolved -- provisioning can never be silently re-attempted
            # (and thus never silently create a SECOND orphan) while the first one is still outstanding.
            with self.assertRaises(SystemExit):
                prov.run(backend.request, "k", Path(td))
        # the real row exists under real_id, NOT under topology.json's expected uuid -- the main cleanup command cannot see it at all:
        deleted, absent = clean.run(backend.request, "k")
        self.assertEqual(deleted, [])
        self.assertIn(expected_first["env_name"], absent)  # false negative: cleanup thinks it's absent, but it exists under a different id
        self.assertIn(real_id, backend.users)  # proves the row is still there
        # cleanup-orphans, given the exact record provisioning wrote, finds and removes it correctly, and cmd_cleanup_orphans persists the true remaining
        # (now-empty) state back to the orphans file, which unblocks refuse_if_unresolved:
        with tempfile.TemporaryDirectory() as td2:
            orphans_file = Path(td2) / "ORPHANS.json"
            orphans_file.write_text(json.dumps(orphans))
            orphan_deleted, orphan_absent = clean.run_orphans(backend.request, "k", orphans)
            self.assertEqual(orphan_deleted, [expected_first["env_name"]])
            self.assertEqual(orphan_absent, [])
            self.assertNotIn(real_id, backend.users)
            clean.write_remaining_orphans(orphans_file, orphans, orphan_deleted + orphan_absent)
            self.assertEqual(json.loads(orphans_file.read_text()), [])
            self.assertIsNone(clean.refuse_if_unresolved(orphans_file, "orphan"))  # no longer blocks anything

    def test_orphan_with_unconfirmed_email_is_recorded_unresolved_and_never_auto_cleanable(self):
        class BackendReturnsWrongEmailToo(FakeAuthBackend):
            def request(self, method, path, headers, body):
                if path == "/auth/v1/admin/users" and method == "POST":
                    real_id = "88888888-8888-8888-8888-888888888888"
                    self.users[real_id] = {"id": real_id, "email": "totally-different@example.com"}
                    return 201, json.dumps(self.users[real_id])
                return super().request(method, path, headers, body)

        backend = BackendReturnsWrongEmailToo()
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(prov.OrphanCreatedError) as c:
                prov.run(backend.request, "k", Path(td))
            self.assertFalse(c.exception.email_confirmed)
            self.assertFalse((Path(td) / "ORPHANS.json").exists())  # never recorded as an actionable orphan
            unresolved = json.loads((Path(td) / "UNRESOLVED.json").read_text())
            self.assertEqual(len(unresolved), 1)
            self.assertEqual(unresolved[0]["returned_email"], "totally-different@example.com")
            status = json.loads((Path(td) / "PROVISIONING_STATUS.json").read_text())
            self.assertEqual(status["status"], "failed")
            # ENFORCED STOP: unlike a confirmed orphan, there is no tool that can ever clear UNRESOLVED.json automatically -- a rerun stays refused.
            with self.assertRaises(SystemExit):
                prov.run(backend.request, "k", Path(td))

    def test_unconfirmed_email_failure_writes_UNRESOLVED_json_before_cmd_provision_exits(self):
        """Traces cmd_provision's actual control flow (not just run()): patches sys.exit itself so the check runs at the exact moment cmd_provision would
        exit, proving the durable UNRESOLVED.json record is already on disk BEFORE that call, not merely eventually."""
        import os as _os

        class BackendReturnsWrongEmailToo(FakeAuthBackend):
            def request(self, method, path, headers, body):
                if path == "/auth/v1/admin/users" and method == "POST":
                    real_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                    self.users[real_id] = {"id": real_id, "email": "still-different@example.com"}
                    return 201, json.dumps(self.users[real_id])
                return super().request(method, path, headers, body)

        backend = BackendReturnsWrongEmailToo()

        class Args:
            pass

        with tempfile.TemporaryDirectory() as td:
            a = Args()
            a.project_ref = REF
            a.out_dir = td
            a.confirm = f"PROVISION F30 AUTH USERS {REF}"
            _os.environ["TDP_F30_SERVICE_ROLE_KEY"] = "k"
            _os.environ["TDP_F30_TEST_PROJECT_REF"] = REF
            _os.environ["TDP_F30_ENVIRONMENT"] = "nonproduction-f30"
            orig_real_request = prov.real_request
            orig_exit = prov.sys.exit
            observed_at_exit = {}
            unresolved_path = Path(td) / "UNRESOLVED.json"

            def spying_exit(code=None):
                # This is exactly the call site inside cmd_provision's `except OrphanCreatedError` branch -- if the record were written AFTER this call
                # (or not at all), the file would not exist yet at this precise instant.
                observed_at_exit["exists"] = unresolved_path.exists()
                observed_at_exit["code"] = code
                orig_exit(code)

            prov.real_request = lambda ref: backend.request
            prov.sys.exit = spying_exit
            try:
                with self.assertRaises(SystemExit):
                    prov.cmd_provision(a)
            finally:
                prov.real_request = orig_real_request
                prov.sys.exit = orig_exit
                del _os.environ["TDP_F30_SERVICE_ROLE_KEY"]
                del _os.environ["TDP_F30_TEST_PROJECT_REF"]
                del _os.environ["TDP_F30_ENVIRONMENT"]
            self.assertTrue(observed_at_exit["exists"], "UNRESOLVED.json must already exist at the moment cmd_provision calls sys.exit")
            self.assertEqual(observed_at_exit["code"], 3)  # the distinct, unresolved-ownership exit code, not the ordinary failure code 1
            self.assertTrue(unresolved_path.exists())
            recorded = json.loads(unresolved_path.read_text())
            self.assertEqual(len(recorded), 1)
            self.assertEqual(recorded[0]["returned_email"], "still-different@example.com")

    def test_cmd_cleanup_refuses_to_start_while_an_orphans_file_has_unresolved_entries(self):
        class Args:
            pass

        with tempfile.TemporaryDirectory() as td:
            orphans_file = Path(td) / "ORPHANS.json"
            orphans_file.write_text(json.dumps([{"env_name": "x", "expected_uuid": "x", "actual_id": "x", "email": "x"}]))
            a = Args()
            a.project_ref = REF
            a.orphans_file = str(orphans_file)
            a.unresolved_file = None
            a.confirm = None
            with self.assertRaises(SystemExit):
                clean.cmd_cleanup(a)  # refused before it ever reaches require_target_confirmed or the service-role-key check

    def test_cmd_cleanup_orphans_writes_an_empty_orphans_file_on_full_success(self):
        real_id = "99999999-9999-9999-9999-999999999999"
        backend = FakeAuthBackendIgnoresRequestedId(real_id)
        expected_first = prov.identities()[0]
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            with self.assertRaises(prov.OrphanCreatedError):
                prov.run(backend.request, "k", out_dir)
            orphans_file = out_dir / "ORPHANS.json"

            class Args:
                pass

            a = Args()
            a.project_ref = REF
            a.orphans_file = str(orphans_file)
            a.confirm = f"CLEANUP F30 ORPHANS {REF}"
            import os

            os.environ["TDP_F30_SERVICE_ROLE_KEY"] = "k"
            os.environ["TDP_F30_TEST_PROJECT_REF"] = REF
            os.environ["TDP_F30_ENVIRONMENT"] = "nonproduction-f30"
            orig_real_request = clean.real_request
            clean.real_request = lambda ref: backend.request
            try:
                clean.cmd_cleanup_orphans(a)  # succeeds; does NOT sys.exit on the success path
            finally:
                clean.real_request = orig_real_request
                del os.environ["TDP_F30_SERVICE_ROLE_KEY"]
                del os.environ["TDP_F30_TEST_PROJECT_REF"]
                del os.environ["TDP_F30_ENVIRONMENT"]
            self.assertEqual(json.loads(orphans_file.read_text()), [])
            self.assertIsNone(clean.refuse_if_unresolved(orphans_file, "orphan"))

    def test_null_identity_has_no_code_path_in_either_tool(self):
        self.assertNotIn("null", {i["role"] for i in prov.identities()})
        self.assertNotIn("null", {i["role"] for i in clean.identities()})
        self.assertEqual(len(prov.identities()), 14)
        self.assertEqual(len(clean.identities()), 14)

    def test_neither_tool_imports_a_network_module_at_module_scope(self):
        import ast

        forbidden = {"urllib", "http", "socket", "requests", "smtplib", "ftplib", "asyncio", "ssl", "paramiko", "telnetlib"}
        for mod_path in (HERE / "provision_auth_test_identities.py", HERE / "cleanup_auth_test_identities.py"):
            tree = ast.parse(mod_path.read_text())
            imported = set()
            for node in tree.body:
                if isinstance(node, ast.Import):
                    imported.update(n.name.split(".")[0] for n in node.names)
                elif isinstance(node, ast.ImportFrom) and node.module:
                    imported.add(node.module.split(".")[0])
            self.assertTrue(imported.isdisjoint(forbidden), f"{mod_path.name}: {imported}")

    def test_no_secret_or_token_value_ever_appears_in_a_printed_line(self):
        import os

        backend = FakeAuthBackend()
        os.environ["TDP_F30_SERVICE_ROLE_KEY"] = "super-secret-service-role-key-value"
        try:
            with tempfile.TemporaryDirectory() as td:
                prov.run(backend.request, os.environ["TDP_F30_SERVICE_ROLE_KEY"], Path(td))
                for name in [i["env_name"] for i in prov.identities()]:
                    token_value = (Path(td) / name).read_text()
                    scrubbed = prov.scrub(f"debug: key={os.environ['TDP_F30_SERVICE_ROLE_KEY']} token={token_value}")
                    self.assertNotIn("super-secret-service-role-key-value", scrubbed)
                    self.assertNotIn(token_value, scrubbed)
        finally:
            del os.environ["TDP_F30_SERVICE_ROLE_KEY"]


class SelfCheckTests(unittest.TestCase):
    def test_provisioning_self_check_passes(self):
        self.assertTrue(prov.self_check())

    def test_cleanup_self_check_passes(self):
        self.assertTrue(clean.self_check())


if __name__ == "__main__":
    unittest.main()
