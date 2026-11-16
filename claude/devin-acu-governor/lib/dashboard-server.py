#!/usr/bin/env python3
"""Local dashboard server and the narrowly scoped live budget API."""

from __future__ import annotations

import http.server
import json
import os
import pathlib
import socketserver
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


MAX_BODY = 4096
BUDGET_FIELDS = (
    "budget_id",
    "cycle_acu_limit",
    "temporary_cycle_acu_limit",
    "expected_cycle_acu_limit",
    "expected_temporary_cycle_acu_limit",
    "expected_parent_effective",
    "expected_parent_allocated",
    "expected_root_effective",
    "confirm",
)
ENDPOINT = "/__dag_refresh_now"


class UpstreamError(Exception):
    def __init__(self, message: str, status: int = 502, unsupported: bool = False):
        super().__init__(message)
        self.status = status
        self.unsupported = unsupported


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, separators=(",", ":")) + "\n").encode("utf-8")


def _limit(value: Any) -> bool:
    return value is None or (isinstance(value, int) and not isinstance(value, bool) and value >= 0)


def _valid_budget_id(value: Any) -> bool:
    return isinstance(value, str) and bool(value) and not any(ord(char) < 32 or ord(char) == 127 for char in value) and not any(
        char in value for char in ("/", "?", "#")
    )


def _valid_name(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip()) and len(value) <= 120 and not any(
        ord(char) < 32 or ord(char) == 127 for char in value
    )


def _valid_identifier(value: Any) -> bool:
    if isinstance(value, int) and not isinstance(value, bool):
        return value > 0
    return isinstance(value, str) and bool(value) and not any(ord(char) < 32 or ord(char) == 127 for char in value) and not any(
        char in value for char in ("/", "?", "#")
    )


def _nonnegative_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 2**53 - 1


def _safe_limit(value: Any) -> bool:
    return value is None or _nonnegative_integer(value)


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    server_version = "DAGDashboard/1"

    def __init__(self, *args: Any, directory: str, request_file: str, header_file: str, api_base: str, **kwargs: Any):
        self.request_file = request_file
        self.header_file = header_file
        self.api_base = api_base.rstrip("/")
        super().__init__(*args, directory=directory, **kwargs)

    @property
    def dashboard_server(self) -> "DashboardServer":
        return self.server  # type: ignore[return-value]

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _send_json(self, code: int, body: Any) -> None:
        payload = _json_bytes(body)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _error(self, code: int, message: str) -> None:
        self._send_json(code, {"ok": False, "error": message})

    def _read_auth_header(self) -> str:
        try:
            header = pathlib.Path(self.header_file).read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise UpstreamError("dashboard auth header unavailable") from exc
        if not header.startswith("Authorization: ") or "\n" in header or "\r" in header:
            raise UpstreamError("dashboard auth header invalid")
        return header

    def _upstream(self, method: str, path: str, body: Any = None) -> tuple[int, Any]:
        try:
            auth = self._read_auth_header()
            headers = {"Accept": "application/json", auth.split(":", 1)[0]: auth.split(":", 1)[1].strip()}
            payload = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
            if payload is not None:
                headers["Content-Type"] = "application/json"
            request = urllib.request.Request(
                f"{self.api_base}{path}", data=payload, headers=headers, method=method
            )
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            exc.close()
            if exc.code in (404, 405):
                raise UpstreamError("endpoint is not supported by this Devin deployment", 502, True) from exc
            raise UpstreamError(f"Devin API returned HTTP {exc.code}", 502) from exc
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
            raise UpstreamError("Devin API request failed", 502) from exc

    def _pages(self, path: str) -> list[dict[str, Any]]:
        pages: list[dict[str, Any]] = []
        cursor = ""
        seen: set[str] = set()
        while True:
            parsed = urllib.parse.urlsplit(path)
            query = [(key, value) for key, value in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
                     if key not in ("first", "after")]
            query.append(("first", "200"))
            if cursor:
                query.append(("after", cursor))
            url = parsed.path + "?" + urllib.parse.urlencode(query)
            _status, page = self._upstream("GET", url)
            if not isinstance(page, dict) or not isinstance(page.get("items"), list):
                raise UpstreamError("Devin API returned an invalid page: items must be an array")
            pages.append(page)
            has_next_page = page.get("has_next_page")
            if has_next_page is False:
                return pages
            if has_next_page is not True:
                raise UpstreamError("Devin API returned an invalid page: has_next_page must be boolean")
            cursor = page.get("end_cursor")
            if not isinstance(cursor, str) or not cursor or cursor in seen:
                raise UpstreamError("Devin API returned an invalid or repeated end_cursor")
            seen.add(cursor)

    def _static_allowed(self) -> bool:
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        parts = [part for part in path.split("/") if part]
        if any(part in (".", "..") or part.startswith(".") for part in parts):
            return False
        root = pathlib.Path(self.directory).resolve()
        candidate = root.joinpath(*parts)
        try:
            if os.path.commonpath((str(root), str(candidate.resolve()))) != str(root):
                return False
        except (OSError, ValueError):
            return False
        current = root
        for part in parts:
            current /= part
            if current.is_symlink():
                return False
        return True

    def _budgets(self) -> list[dict[str, Any]]:
        budgets = [item for page in self._pages("/v3beta1/enterprise/usage-policies/budgets") for item in page["items"]]
        ids = [item.get("budget_id") for item in budgets]
        if any(not isinstance(budget_id, str) or not budget_id for budget_id in ids) or len(ids) != len(set(ids)):
            raise UpstreamError("Devin API returned duplicate or invalid budget IDs", 502)
        return budgets

    def _queue_refresh(self) -> None:
        try:
            request_path = pathlib.Path(self.request_file)
            tmp_path = request_path.with_name(f"{request_path.name}.tmp.{os.getpid()}")
            tmp_path.write_text(f"{time.time_ns()}\n", encoding="utf-8")
            os.replace(tmp_path, request_path)
        except OSError as exc:
            raise UpstreamError("failed to queue dashboard refresh", 500) from exc

    def _queue_refresh_best_effort(self) -> None:
        try:
            self._queue_refresh()
        except UpstreamError:
            return

    def _read_body(self) -> Any:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise UpstreamError("request body length is invalid", 400)
        if length <= 0 or length > MAX_BODY:
            raise UpstreamError("request body must be between 1 and 4096 bytes", 413)
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise UpstreamError("request body must be JSON", 400) from exc

    def _require_write(self) -> None:
        if not self._write_origin_ok():
            raise UpstreamError("write requires same-origin request and X-DAG-Write: 1", 403)

    def _budget(self, budgets: list[dict[str, Any]], budget_id: str) -> dict[str, Any]:
        budget = next((item for item in budgets if item.get("budget_id") == budget_id), None)
        if budget is None or budget.get("status") != "active":
            raise UpstreamError("budget is missing or not active", 409)
        return budget

    def _allocation_state(self, budgets: list[dict[str, Any]], budget_id: str) -> tuple[int | None, int | None, int | None]:
        target = self._budget(budgets, budget_id)
        parent_id = target.get("parent_budget_id") or budget_id
        parent = next((item for item in budgets if item.get("budget_id") == parent_id), None)
        if parent is None:
            raise UpstreamError("budget parent is missing", 409)
        children = [item for item in budgets if item.get("status") == "active" and item.get("parent_budget_id") == parent_id]
        effective = [item.get("temporary_cycle_acu_limit") if item.get("temporary_cycle_acu_limit") is not None else item.get("cycle_acu_limit") for item in children]
        allocated = None if any(value is None for value in effective) else sum(effective)
        root = target
        visited: set[str] = set()
        while root.get("parent_budget_id"):
            if root.get("budget_id") in visited:
                raise UpstreamError("budget hierarchy contains a cycle", 409)
            visited.add(root.get("budget_id"))
            root = next((item for item in budgets if item.get("budget_id") == root.get("parent_budget_id")), None)
            if root is None:
                raise UpstreamError("budget root is missing", 409)
        root_effective = root.get("temporary_cycle_acu_limit") if root.get("temporary_cycle_acu_limit") is not None else root.get("cycle_acu_limit")
        parent_effective = parent.get("temporary_cycle_acu_limit") if parent.get("temporary_cycle_acu_limit") is not None else parent.get("cycle_acu_limit")
        return parent_effective, allocated, root_effective

    def _tier(self, budget_id: str, tier_id: str) -> dict[str, Any]:
        for tier in [item for page in self._pages(
            f"/v3beta1/enterprise/usage-policies/budgets/{urllib.parse.quote(budget_id, safe='')}/tiers"
        ) for item in page["items"]]:
            if str(tier.get("tier_id", tier.get("id", ""))) == tier_id:
                return tier
        raise UpstreamError("tier is not part of the selected budget", 409)

    def _pending_request(self, budget_id: str, request_id: int) -> dict[str, Any]:
        path = f"/v3beta1/enterprise/usage-policies/budgets/{urllib.parse.quote(budget_id, safe='')}/requests?status=pending"
        for request in [item for page in self._pages(path) for item in page["items"]]:
            if request.get("request_id") == request_id or request.get("id") == request_id:
                return request
        raise UpstreamError("request is not pending for the selected budget", 409)

    def _write_origin_ok(self) -> bool:
        expected = f"http://127.0.0.1:{self.dashboard_server.server_address[1]}"
        return self.headers.get("Origin") == expected and self.headers.get("X-DAG-Write") == "1"

    def do_GET(self) -> None:
        split = urllib.parse.urlsplit(self.path)
        if split.path == "/__dag_budgets":
            try:
                self._send_json(200, {"items": self._budgets()})
            except UpstreamError as exc:
                self._error(exc.status, str(exc))
            return
        if split.path == "/__dag_budget_detail":
            budget_id = urllib.parse.parse_qs(split.query).get("budget_id", [""])[0]
            if not _valid_budget_id(budget_id):
                self._error(400, "budget_id is required")
                return
            result: dict[str, Any] = {"tiers": [], "requests": [], "availability": {}}
            for key, endpoint in (
                ("tiers", f"/v3beta1/enterprise/usage-policies/budgets/{urllib.parse.quote(budget_id, safe='')}/tiers"),
                (
                    "requests",
                    f"/v3beta1/enterprise/usage-policies/budgets/{urllib.parse.quote(budget_id, safe='')}/requests",
                ),
            ):
                try:
                    suffix = "?status=pending" if key == "requests" else ""
                    pages = self._pages(endpoint + suffix)
                    result[key] = [item for page in pages for item in page.get("items", [])]
                    result["availability"][key] = True
                except UpstreamError as exc:
                    if not exc.unsupported:
                        self._error(exc.status, f"{key}: {exc}")
                        return
                    result["availability"][key] = False
                    result[f"{key}_error"] = str(exc)
            self._send_json(200, result)
            return
        if split.path == ENDPOINT:
            self._error(405, "method not allowed")
            return
        if not self._static_allowed():
            self._error(404, "not found")
            return
        super().do_GET()

    def do_HEAD(self) -> None:
        if not self._static_allowed():
            self._error(404, "not found")
            return
        super().do_HEAD()

    def do_POST(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path == ENDPOINT:
            if self.headers.get("X-DAG-Refresh") != "1":
                self._error(403, "missing refresh header")
                return
            try:
                self._queue_refresh()
                self._send_json(202, {"ok": True})
            except UpstreamError as exc:
                self._error(exc.status, str(exc))
            return
        try:
            self._require_write()
            if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                raise UpstreamError("mutation requests require Content-Type: application/json", 415)
            payload = self._read_body()
            if path == "/__dag_budget_update":
                self._budget_update(payload)
            elif path == "/__dag_tier_create":
                self._tier_create(payload)
            elif path == "/__dag_tier_update":
                self._tier_update(payload)
            elif path == "/__dag_request_decide":
                self._request_decide(payload)
            else:
                self._error(404, "not found")
        except UpstreamError as exc:
            self._error(exc.status, str(exc))

    def _budget_update(self, payload: Any) -> None:
        if not isinstance(payload, dict) or set(payload) != set(BUDGET_FIELDS):
            raise UpstreamError("request schema is exact and contains no unexpected fields", 400)
        if payload["confirm"] != "UPDATE BUDGET" or not _valid_budget_id(payload["budget_id"]):
            raise UpstreamError("confirm and budget_id are invalid", 400)
        if not _limit(payload["cycle_acu_limit"]) or not _limit(payload["temporary_cycle_acu_limit"]):
            raise UpstreamError("limits must be null or nonnegative integers", 400)
        if not _limit(payload["expected_cycle_acu_limit"]) or not _limit(payload["expected_temporary_cycle_acu_limit"]):
            raise UpstreamError("expected limits must be null or nonnegative integers", 400)
        for field in ("expected_parent_effective", "expected_parent_allocated", "expected_root_effective"):
            if not _safe_limit(payload[field]):
                raise UpstreamError("expected allocation values must be null or nonnegative integers", 400)
        budgets = self._budgets()
        current = self._budget(budgets, payload["budget_id"])
        parent_effective, allocated, root_effective = self._allocation_state(budgets, payload["budget_id"])
        if (
            parent_effective != payload["expected_parent_effective"]
            or allocated != payload["expected_parent_allocated"]
            or root_effective != payload["expected_root_effective"]
        ):
            raise UpstreamError("parent or root allocation changed since it was loaded", 409)
        current_monthly = current.get("cycle_acu_limit")
        current_temporary = current.get("temporary_cycle_acu_limit")
        if current_monthly != payload["expected_cycle_acu_limit"] or current_temporary != payload["expected_temporary_cycle_acu_limit"]:
            raise UpstreamError("budget changed since it was loaded", 409)
        changes = {}
        if current_monthly != payload["cycle_acu_limit"]:
            changes["cycle_acu_limit"] = payload["cycle_acu_limit"]
        if current_temporary != payload["temporary_cycle_acu_limit"]:
            changes["temporary_cycle_acu_limit"] = payload["temporary_cycle_acu_limit"]
        if not changes:
            raise UpstreamError("no budget changes requested", 400)
        encoded = urllib.parse.quote(payload["budget_id"], safe="")
        status, updated = self._upstream("PATCH", f"/v3beta1/enterprise/usage-policies/budgets/{encoded}", changes)
        if status != 200:
            raise UpstreamError(f"unexpected budget PATCH status {status}", 502)
        try:
            verified = next((item for item in self._budgets() if item.get("budget_id") == payload["budget_id"]), None)
        except UpstreamError as exc:
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": f"budget update succeeded but live verification failed: {exc}", "partial_success": True})
            return
        if not isinstance(verified, dict) or verified.get("cycle_acu_limit") != payload["cycle_acu_limit"] or verified.get("temporary_cycle_acu_limit") != payload["temporary_cycle_acu_limit"]:
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": "budget update succeeded but live verification failed", "partial_success": True})
            return
        try:
            self._queue_refresh()
        except UpstreamError as exc:
            self._send_json(502, {"ok": False, "error": str(exc), "partial_success": True})
            return
        self._send_json(200, {"ok": True, "budget": verified, "updated": updated})

    def _tier_create(self, payload: Any) -> None:
        expected = {"budget_id", "name", "cycle_acu_limit", "confirm"}
        if not isinstance(payload, dict) or set(payload) != expected or payload["confirm"] != "CREATE TIER":
            raise UpstreamError("request schema is exact and confirm must be CREATE TIER", 400)
        if not _valid_budget_id(payload["budget_id"]) or not _valid_name(payload["name"]) or not _limit(payload["cycle_acu_limit"]):
            raise UpstreamError("budget_id, name, or cycle_acu_limit is invalid", 400)
        self._budget(self._budgets(), payload["budget_id"])
        encoded = urllib.parse.quote(payload["budget_id"], safe="")
        status, tier = self._upstream("POST", f"/v3beta1/enterprise/usage-policies/budgets/{encoded}/tiers", {
            "name": payload["name"],
            "cycle_acu_limit": payload["cycle_acu_limit"],
            "policy": "manual",
        })
        if status != 201 or not isinstance(tier, dict) or not _valid_identifier(tier.get("tier_id", tier.get("id"))):
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": "tier creation returned an invalid response", "partial_success": status == 201})
            return
        tier_id = str(tier.get("tier_id", tier.get("id")))
        try:
            verify_status, verified = self._upstream("GET", f"/v3beta1/enterprise/usage-policies/tiers/{urllib.parse.quote(tier_id, safe='')}")
        except UpstreamError as exc:
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": f"tier creation succeeded but live verification failed: {exc}", "partial_success": True})
            return
        if verify_status != 200 or not isinstance(verified, dict) or verified.get("name") != payload["name"] or verified.get("cycle_acu_limit") != payload["cycle_acu_limit"] or verified.get("policy") != "manual":
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": "tier creation succeeded but live verification failed", "partial_success": True})
            return
        self._queue_refresh_best_effort()
        self._send_json(201, {"ok": True, "tier": verified})

    def _tier_update(self, payload: Any) -> None:
        expected = {"budget_id", "tier_id", "name", "cycle_acu_limit", "expected_name", "expected_cycle_acu_limit", "confirm"}
        if not isinstance(payload, dict) or set(payload) != expected or payload["confirm"] != "UPDATE TIER":
            raise UpstreamError("request schema is exact and confirm must be UPDATE TIER", 400)
        if not _valid_budget_id(payload["budget_id"]) or not _valid_identifier(payload["tier_id"]) or not _valid_name(payload["name"]) or not _valid_name(payload["expected_name"]):
            raise UpstreamError("budget_id, tier_id, or name is invalid", 400)
        if not _limit(payload["cycle_acu_limit"]) or not _limit(payload["expected_cycle_acu_limit"]):
            raise UpstreamError("cycle_acu_limit is invalid", 400)
        self._budget(self._budgets(), payload["budget_id"])
        tier_id = str(payload["tier_id"])
        tier = self._tier(payload["budget_id"], tier_id)
        encoded_tier = urllib.parse.quote(tier_id, safe="")
        status, live = self._upstream("GET", f"/v3beta1/enterprise/usage-policies/tiers/{encoded_tier}")
        if status != 200:
            raise UpstreamError(f"unexpected tier GET status {status}", 502)
        if live.get("name") != payload["expected_name"] or live.get("cycle_acu_limit") != payload["expected_cycle_acu_limit"]:
            raise UpstreamError("tier changed since it was loaded", 409)
        changes = {}
        if live.get("name") != payload["name"]:
            changes["name"] = payload["name"]
        if live.get("cycle_acu_limit") != payload["cycle_acu_limit"]:
            changes["cycle_acu_limit"] = payload["cycle_acu_limit"]
        if not changes:
            raise UpstreamError("no tier changes requested", 400)
        status, updated = self._upstream("PATCH", f"/v3beta1/enterprise/usage-policies/tiers/{encoded_tier}", changes)
        if status != 200:
            raise UpstreamError(f"unexpected tier PATCH status {status}", 502)
        try:
            verify_status, verified = self._upstream("GET", f"/v3beta1/enterprise/usage-policies/tiers/{encoded_tier}")
        except UpstreamError as exc:
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": f"tier update succeeded but live verification failed: {exc}", "partial_success": True})
            return
        if verify_status != 200 or verified.get("name") != payload["name"] or verified.get("cycle_acu_limit") != payload["cycle_acu_limit"]:
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": "tier update succeeded but live verification failed", "partial_success": True})
            return
        self._queue_refresh_best_effort()
        self._send_json(200, {"ok": True, "tier": verified, "updated": updated, "budget_id": payload["budget_id"], "listed_tier": tier})

    def _request_decide(self, payload: Any) -> None:
        expected = {"budget_id", "request_id", "action", "cycle_acu_limit", "expected_requested_cycle_acu_limit", "confirm"}
        if not isinstance(payload, dict) or set(payload) != expected:
            raise UpstreamError("request schema is exact and contains no unexpected fields", 400)
        if not _valid_budget_id(payload["budget_id"]) or not isinstance(payload["request_id"], int) or isinstance(payload["request_id"], bool) or payload["request_id"] <= 0:
            raise UpstreamError("budget_id or request_id is invalid", 400)
        action = payload["action"]
        if action not in ("approve", "deny") or payload["confirm"] != ("APPROVE REQUEST" if action == "approve" else "DENY REQUEST"):
            raise UpstreamError("action or confirmation is invalid", 400)
        if not _nonnegative_integer(payload["expected_requested_cycle_acu_limit"]):
            raise UpstreamError("expected requested limit is invalid", 400)
        if action == "approve" and not _nonnegative_integer(payload["cycle_acu_limit"]):
            raise UpstreamError("approve limit must be a nonnegative integer", 400)
        if action == "deny" and payload["cycle_acu_limit"] is not None:
            raise UpstreamError("deny requests require a null cycle_acu_limit", 400)
        self._budget(self._budgets(), payload["budget_id"])
        request = self._pending_request(payload["budget_id"], payload["request_id"])
        requested = request.get("requested_cycle_acu_limit", request.get("cycle_acu_limit"))
        if requested != payload["expected_requested_cycle_acu_limit"]:
            raise UpstreamError("request changed since it was loaded", 409)
        request_path = f"/v3beta1/enterprise/usage-policies/requests/{payload['request_id']}"
        status, live = self._upstream("GET", request_path)
        if status != 200 or live.get("status") != "pending" or live.get("requested_cycle_acu_limit", live.get("cycle_acu_limit")) != requested:
            raise UpstreamError("request changed since it was loaded", 409)
        if action == "approve":
            current = live.get("current_cycle_acu_limit")
            if current is not None and payload["cycle_acu_limit"] < current:
                raise UpstreamError("approve limit must not be below the current cycle limit", 400)
            status, result = self._upstream("POST", f"{request_path}/approve", {"cycle_acu_limit": payload["cycle_acu_limit"]})
            wanted = "approved"
        else:
            status, result = self._upstream("POST", f"{request_path}/deny", None)
            wanted = "denied"
        if status != 200:
            raise UpstreamError(f"unexpected request decision status {status}", 502)
        try:
            verify_status, verified = self._upstream("GET", request_path)
        except UpstreamError as exc:
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": f"request decision succeeded but live verification failed: {exc}", "partial_success": True})
            return
        if verify_status != 200 or verified.get("status") != wanted:
            self._queue_refresh_best_effort()
            self._send_json(502, {"ok": False, "error": "request decision succeeded but live verification failed", "partial_success": True})
            return
        self._queue_refresh_best_effort()
        self._send_json(200, {"ok": True, "request": verified, "result": result})


class DashboardServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print("usage: dashboard-server.py PORT DIRECTORY REQUEST_FILE AUTH_HEADER_FILE API_BASE", file=sys.stderr)
        return 2
    port, directory, request_file, header_file, api_base = int(argv[1]), argv[2], argv[3], argv[4], argv[5]
    handler = lambda *args, **kwargs: DashboardHandler(
        *args, directory=directory, request_file=request_file, header_file=header_file, api_base=api_base, **kwargs
    )
    with DashboardServer(("127.0.0.1", port), handler) as server:
        server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
