import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen


MODULE_PATH = pathlib.Path(__file__).parents[1] / "lib" / "dashboard-server.py"
SPEC = importlib.util.spec_from_file_location("dashboard_server", MODULE_PATH)
assert SPEC and SPEC.loader
dashboard_server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dashboard_server)


class Upstream(BaseHTTPRequestHandler):
    budgets = [
        {
            "budget_id": "account",
            "name": "Account",
            "parent_budget_id": None,
            "org_ids": ["org-a"],
            "status": "active",
            "cycle_acu_limit": 100,
            "temporary_cycle_acu_limit": None,
        },
        {
            "budget_id": "child",
            "name": "Child",
            "parent_budget_id": "account",
            "org_ids": ["org-a"],
            "status": "active",
            "cycle_acu_limit": 50,
            "temporary_cycle_acu_limit": None,
        },
    ]
    patches = []
    auth_headers = []
    verification_mismatch = False
    verification_failure = False
    pagination_mode = "normal"
    details_unavailable = False
    tier_verification_failure = False
    duplicate_budgets = False
    tiers = [{"tier_id": "tier-1", "budget_id": "child", "name": "Starter", "is_default": False, "cycle_acu_limit": 50, "policy": "manual", "max_limit": None, "priority": 1, "member_count": 2, "created_at": "2026-01-01"}]
    requests = [{"request_id": 7, "budget_id": "child", "name": "Alice", "email": "alice@example.com", "tier_id": "tier-1", "tier_name": "Starter", "requested_cycle_acu_limit": 60, "current_cycle_acu_limit": 50, "message": "Need more room", "status": "pending", "created_at": "2026-01-01"}]

    def log_message(self, *_args):
        return

    def send_json(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.auth_headers.append(self.headers.get("Authorization"))
        path = self.path.split("?", 1)[0]
        if path.endswith("/budgets"):
            if self.verification_failure and self.patches:
                self.send_json(500, {"detail": "verification unavailable"})
            elif "after=p2" in self.path:
                second = self.budgets[0] if self.duplicate_budgets else self.budgets[1]
                page = {"items": [second], "has_next_page": False, "end_cursor": None}
                if self.pagination_mode == "repeat":
                    page["has_next_page"] = True
                    page["end_cursor"] = "p2"
                self.send_json(200, page)
            else:
                page = {"items": [self.budgets[0]], "has_next_page": True, "end_cursor": "p2"}
                if self.pagination_mode == "missing":
                    page["end_cursor"] = None
                self.send_json(200, page)
        elif "/tiers/" in path:
            if self.tier_verification_failure:
                self.send_json(500, {"detail": "verification unavailable"})
                return
            if self.details_unavailable:
                self.send_json(404, {"detail": "unsupported"})
                return
            tier = next((item for item in self.tiers if path.endswith(str(item["tier_id"]))), None)
            self.send_json(200 if tier else 404, tier or {})
        elif path.endswith("/tiers"):
            if self.details_unavailable:
                self.send_json(404, {"detail": "unsupported"})
                return
            self.send_json(200, {"items": self.tiers, "has_next_page": False, "end_cursor": None})
        elif "/requests/" in path:
            if self.details_unavailable:
                self.send_json(404, {"detail": "unsupported"})
                return
            request = next((item for item in self.requests if path.endswith(str(item["request_id"]))), None)
            self.send_json(200 if request else 404, request or {})
        elif path.endswith("/requests"):
            if self.details_unavailable:
                self.send_json(404, {"detail": "unsupported"})
                return
            self.send_json(200, {"items": self.requests, "has_next_page": False, "end_cursor": None})
        else:
            self.send_json(404, {})

    def do_PATCH(self):
        self.auth_headers.append(self.headers.get("Authorization"))
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        self.patches.append(body)
        if "/tiers/" in self.path:
            tier_id = self.path.rsplit("/", 1)[-1]
            for tier in self.tiers:
                if tier["tier_id"] == tier_id:
                    tier.update(body)
            self.send_json(200, next(item for item in self.tiers if item["tier_id"] == tier_id))
            return
        for budget in self.budgets:
            if budget["budget_id"] == self.path.rsplit("/", 1)[-1]:
                budget.update(body)
        self.send_json(200, {} if not self.verification_mismatch else {"cycle_acu_limit": 999})

    def do_POST(self):
        self.auth_headers.append(self.headers.get("Authorization"))
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length)) if length else None
        if self.path.endswith("/tiers"):
            tier = {"tier_id": "tier-new", "budget_id": "child", **body}
            self.tiers.append(tier)
            self.send_json(201, tier)
            return
        if self.path.endswith("/approve"):
            self.requests[0]["status"] = "approved"
            self.requests[0]["cycle_acu_limit"] = body["cycle_acu_limit"]
            self.send_json(200, self.requests[0])
            return
        if self.path.endswith("/deny"):
            self.requests[0]["status"] = "denied"
            self.send_json(200, self.requests[0])
            return
        self.send_json(404, {})


class DashboardServerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temp.name)
        served = root / "served"
        served.mkdir()
        self.served = served
        (served / "index.html").write_text("dashboard")
        (served / "secret.txt").write_text("should not be served")
        (served / ".hidden").write_text("hidden")
        outside = root / "outside.txt"
        outside.write_text("outside")
        (served / "link").symlink_to(outside)
        self.header = root / "auth"
        self.header.write_text("Authorization: Bearer test-secret\n")
        self.header.chmod(0o600)
        self.request_file = root / "refresh"
        Upstream.budgets = [
            {
                "budget_id": "account",
                "name": "Account",
                "parent_budget_id": None,
                "org_ids": ["org-a"],
                "status": "active",
                "cycle_acu_limit": 100,
                "temporary_cycle_acu_limit": None,
            },
            {
                "budget_id": "child",
                "name": "Child",
                "parent_budget_id": "account",
                "org_ids": ["org-a"],
                "status": "active",
                "cycle_acu_limit": 50,
                "temporary_cycle_acu_limit": None,
            },
        ]
        Upstream.patches = []
        Upstream.auth_headers = []
        Upstream.verification_mismatch = False
        Upstream.verification_failure = False
        Upstream.pagination_mode = "normal"
        Upstream.details_unavailable = False
        Upstream.tier_verification_failure = False
        Upstream.duplicate_budgets = False
        Upstream.tiers = [{"tier_id": "tier-1", "budget_id": "child", "name": "Starter", "is_default": False, "cycle_acu_limit": 50, "policy": "manual", "max_limit": None, "priority": 1, "member_count": 2, "created_at": "2026-01-01"}]
        Upstream.requests = [{"request_id": 7, "budget_id": "child", "name": "Alice", "email": "alice@example.com", "tier_id": "tier-1", "tier_name": "Starter", "requested_cycle_acu_limit": 60, "current_cycle_acu_limit": 50, "message": "Need more room", "status": "pending", "created_at": "2026-01-01"}]
        self.upstream = HTTPServer(("127.0.0.1", 0), Upstream)
        self.upstream_thread = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.upstream_thread.start()
        api_base = f"http://127.0.0.1:{self.upstream.server_port}"
        handler = lambda *args, **kwargs: dashboard_server.DashboardHandler(
            *args,
            directory=str(served),
            request_file=str(self.request_file),
            header_file=str(self.header),
            api_base=api_base,
            **kwargs,
        )
        self.local = dashboard_server.DashboardServer(("127.0.0.1", 0), handler)
        self.local_thread = threading.Thread(target=self.local.serve_forever, daemon=True)
        self.local_thread.start()
        self.base = f"http://127.0.0.1:{self.local.server_address[1]}"

    def tearDown(self):
        self.local.shutdown()
        self.local.server_close()
        self.upstream.shutdown()
        self.upstream.server_close()
        self.temp.cleanup()

    def request(self, method, path, body=None, headers=None):
        payload = None if body is None else json.dumps(body).encode()
        request = Request(self.base + path, data=payload, method=method, headers=headers or {})
        try:
            with urlopen(request) as response:
                raw = response.read()
                try:
                    return response.status, json.loads(raw)
                except json.JSONDecodeError:
                    return response.status, raw.decode()
        except HTTPError as error:
            raw = error.read()
            error.close()
            return error.code, json.loads(raw)

    def valid_update(self, **overrides):
        value = {
            "budget_id": "child",
            "cycle_acu_limit": 70,
            "temporary_cycle_acu_limit": None,
            "expected_cycle_acu_limit": 50,
            "expected_temporary_cycle_acu_limit": None,
            "expected_parent_effective": 100,
            "expected_parent_allocated": 50,
            "expected_root_effective": 100,
            "confirm": "UPDATE BUDGET",
        }
        value.update(overrides)
        return value

    def test_live_pagination_and_detail_degrade_without_leaking_auth(self):
        status, body = self.request("GET", "/__dag_budgets")
        self.assertEqual(status, 200)
        self.assertEqual([item["budget_id"] for item in body["items"]], ["account", "child"])
        status, body = self.request("GET", "/__dag_budget_detail?budget_id=child")
        self.assertEqual(status, 200)
        self.assertEqual(body["requests"][0]["request_id"], 7)
        self.assertTrue(body["availability"]["tiers"])
        self.assertNotIn("test-secret", json.dumps(body))
        self.assertTrue(all(header == "Bearer test-secret" for header in Upstream.auth_headers))
        self.assertFalse(str(self.header).startswith(str(self.served)))
        self.assertEqual(self.header.stat().st_mode & 0o777, 0o600)

    def test_unreadable_detail_endpoints_degrade_explicitly(self):
        Upstream.details_unavailable = True
        status, body = self.request("GET", "/__dag_budget_detail?budget_id=child")
        self.assertEqual(status, 200)
        self.assertFalse(body["availability"]["tiers"])
        self.assertFalse(body["availability"]["requests"])

    def test_duplicate_budget_ids_fail_closed(self):
        Upstream.duplicate_budgets = True
        status, body = self.request("GET", "/__dag_budgets")
        self.assertEqual(status, 502)
        self.assertIn("duplicate", body["error"])

    def test_zero_cap_account_and_uncapped_child_remain_readable(self):
        Upstream.budgets[0]["cycle_acu_limit"] = 0
        Upstream.budgets[1]["cycle_acu_limit"] = None
        status, _ = self.request("GET", "/__dag_budgets")
        self.assertEqual(status, 200)

    def test_write_requires_origin_header_and_exact_schema(self):
        status, _ = self.request("POST", "/__dag_budget_update", self.valid_update())
        self.assertEqual(status, 403)
        status, _ = self.request(
            "POST",
            "/__dag_budget_update",
            {"unexpected": True},
            {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"},
        )
        self.assertEqual(status, 400)
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        for invalid_id in ("bad/id", "bad?", "bad#", "bad\nid"):
            status, _ = self.request("POST", "/__dag_budget_update", self.valid_update(budget_id=invalid_id), headers)
            self.assertEqual(status, 400)

    def test_all_mutation_routes_require_json_content_type(self):
        bodies = [
            ("/__dag_tier_create", {"budget_id": "child", "name": "Tier", "cycle_acu_limit": 1, "confirm": "CREATE TIER"}),
            ("/__dag_tier_update", {"budget_id": "child", "tier_id": "tier-1", "name": "Tier", "cycle_acu_limit": 1, "expected_name": "Starter", "expected_cycle_acu_limit": 50, "confirm": "UPDATE TIER"}),
            ("/__dag_request_decide", {"budget_id": "child", "request_id": 7, "action": "deny", "cycle_acu_limit": None, "expected_requested_cycle_acu_limit": 60, "confirm": "DENY REQUEST"}),
        ]
        for path, body in bodies:
            status, _ = self.request("POST", path, body, {"Origin": self.base, "X-DAG-Write": "1"})
            self.assertEqual(status, 415)
            status, _ = self.request("POST", path, body, {"Content-Type": "application/json", "X-DAG-Write": "1"})
            self.assertEqual(status, 403)

    def test_stale_update_refused_and_success_patches_only_changed_key(self):
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        status, body = self.request(
            "POST",
            "/__dag_budget_update",
            self.valid_update(expected_cycle_acu_limit=49),
            headers,
        )
        self.assertEqual(status, 409)
        self.assertIn("changed", body["error"])
        status, body = self.request("POST", "/__dag_budget_update", self.valid_update(), headers)
        self.assertEqual(status, 200)
        self.assertEqual(body["budget"]["cycle_acu_limit"], 70)
        self.assertEqual(Upstream.patches[-1], {"cycle_acu_limit": 70})
        self.assertTrue(self.request_file.exists())
        self.assertNotIn("test-secret", json.dumps(body))

    def test_budget_update_refuses_changed_parent_or_sibling_allocation_before_patch(self):
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        Upstream.budgets[0]["cycle_acu_limit"] = 90
        status, _ = self.request("POST", "/__dag_budget_update", self.valid_update(), headers)
        self.assertEqual(status, 409)
        self.assertEqual(Upstream.patches, [])
        Upstream.budgets[0]["cycle_acu_limit"] = 100
        Upstream.budgets[1]["cycle_acu_limit"] = 55
        status, _ = self.request("POST", "/__dag_budget_update", self.valid_update(), headers)
        self.assertEqual(status, 409)
        self.assertEqual(Upstream.patches, [])

    def test_tier_create_and_update_require_explicit_write_and_live_expectations(self):
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        status, body = self.request("POST", "/__dag_tier_create", {
            "budget_id": "child", "name": "Burst", "cycle_acu_limit": None, "confirm": "CREATE TIER",
        }, headers)
        self.assertEqual(status, 201)
        self.assertEqual(body["tier"]["policy"], "manual")
        status, body = self.request("POST", "/__dag_tier_update", {
            "budget_id": "child", "tier_id": "tier-1", "name": "Starter Plus", "cycle_acu_limit": 75,
            "expected_name": "Starter", "expected_cycle_acu_limit": 50, "confirm": "UPDATE TIER",
        }, headers)
        self.assertEqual(status, 200)
        self.assertEqual(body["tier"]["cycle_acu_limit"], 75)
        status, _ = self.request("POST", "/__dag_tier_update", {
            "budget_id": "child", "tier_id": "tier-1", "name": "Changed", "cycle_acu_limit": 80,
            "expected_name": "Starter", "expected_cycle_acu_limit": 50, "confirm": "UPDATE TIER",
        }, headers)
        self.assertEqual(status, 409)

    def test_tier_create_verification_failure_is_partial_success(self):
        Upstream.tier_verification_failure = True
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        status, body = self.request("POST", "/__dag_tier_create", {
            "budget_id": "child", "name": "Burst", "cycle_acu_limit": 75, "confirm": "CREATE TIER",
        }, headers)
        self.assertEqual(status, 502)
        self.assertTrue(body["partial_success"])
        self.assertTrue(self.request_file.exists())

    def test_request_approve_and_deny_use_numeric_pending_ids(self):
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        status, body = self.request("POST", "/__dag_request_decide", {
            "budget_id": "child", "request_id": 7, "action": "approve", "cycle_acu_limit": 70,
            "expected_requested_cycle_acu_limit": 60, "confirm": "APPROVE REQUEST",
        }, headers)
        self.assertEqual(status, 200)
        self.assertEqual(body["request"]["status"], "approved")
        self.assertEqual(body["request"]["cycle_acu_limit"], 70)
        Upstream.requests = [{"request_id": 7, "budget_id": "child", "requested_cycle_acu_limit": 60, "current_cycle_acu_limit": 50, "status": "pending"}]
        status, body = self.request("POST", "/__dag_request_decide", {
            "budget_id": "child", "request_id": 7, "action": "deny", "cycle_acu_limit": None,
            "expected_requested_cycle_acu_limit": 60, "confirm": "DENY REQUEST",
        }, headers)
        self.assertEqual(status, 200)
        self.assertEqual(body["request"]["status"], "denied")

    def test_tier_and_request_writes_reject_missing_auth_and_invalid_request(self):
        status, _ = self.request("POST", "/__dag_tier_create", {
            "budget_id": "child", "name": "Tier", "cycle_acu_limit": 1, "confirm": "CREATE TIER",
        })
        self.assertEqual(status, 403)
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        status, _ = self.request("POST", "/__dag_request_decide", {
            "budget_id": "child", "request_id": 7, "action": "deny", "cycle_acu_limit": 1,
            "expected_requested_cycle_acu_limit": 60, "confirm": "DENY REQUEST",
        }, headers)
        self.assertEqual(status, 400)

    def test_archived_budget_is_not_writable(self):
        Upstream.budgets[1]["status"] = "archived"
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        status, _ = self.request("POST", "/__dag_budget_update", self.valid_update(), headers)
        self.assertEqual(status, 409)

    def test_malformed_or_repeated_pagination_cursor_is_rejected(self):
        Upstream.pagination_mode = "missing"
        status, body = self.request("GET", "/__dag_budgets")
        self.assertEqual(status, 502)
        self.assertIn("end_cursor", body["error"])
        Upstream.pagination_mode = "repeat"
        status, body = self.request("GET", "/__dag_budgets")
        self.assertEqual(status, 502)
        self.assertIn("end_cursor", body["error"])

    def test_verification_failure_is_partial_and_queues_refresh(self):
        Upstream.verification_failure = True
        headers = {"Origin": self.base, "X-DAG-Write": "1", "Content-Type": "application/json"}
        status, body = self.request("POST", "/__dag_budget_update", self.valid_update(), headers)
        self.assertEqual(status, 502)
        self.assertTrue(body["partial_success"])
        self.assertTrue(self.request_file.exists())

    def test_static_dotfiles_traversal_and_symlinks_are_rejected(self):
        self.assertEqual(self.request("GET", "/.hidden")[0], 404)
        self.assertEqual(self.request("GET", "/link")[0], 404)
        self.assertEqual(self.request("GET", "/%2e%2e/outside.txt")[0], 404)
        self.assertEqual(self.request("GET", "/index.html")[0], 200)


if __name__ == "__main__":
    unittest.main()
