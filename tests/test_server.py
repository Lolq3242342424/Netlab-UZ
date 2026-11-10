"""Тесты HTTP-сервера NetLab UZ (старая версия server.py).

Запуск: uv run python -m unittest tests.test_server -v
Сервер поднимается в фоновом потоке на случайном порту, БД — во временной папке.
Не отправляет запросы в интернет, не требует ручного запуска.
"""
import json
import os
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from pathlib import Path

os.environ["NETLAB_QUIET"] = "1"  # чтобы не засорять вывод логами BaseHTTPRequestHandler

from netlab import tasks  # noqa: E402
from netlab.server import MAX_BODY, create_server  # noqa: E402

STATIC_INDEX = Path(__file__).resolve().parent.parent / "static" / "index.html"


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.db = os.path.join(cls.tmp.name, "test.db")
        cls.server = create_server("127.0.0.1", 0, cls.db)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.tmp.cleanup()

    # ----- вспомогательные
    def req(self, method, path, body=None, headers=None, raw=None):
        conn = HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        if raw is not None:
            data = raw
        elif body is not None:
            data = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        else:
            data = None
        conn.request(method, path, body=data, headers=h)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        return resp.status, resp, payload

    def jreq(self, *a, **kw):
        status, resp, payload = self.req(*a, **kw)
        return status, (json.loads(payload) if payload else None)

    # ----- протокол и заголовки
    def test_security_headers_on_api(self):
        status, resp, _ = self.req("GET", "/api/tasks")
        self.assertEqual(status, 200)
        self.assertEqual(resp.getheader("X-Content-Type-Options"), "nosniff")
        self.assertEqual(resp.getheader("Referrer-Policy"), "no-referrer")
        self.assertEqual(resp.getheader("X-Frame-Options"), "DENY")
        self.assertEqual(resp.getheader("Cache-Control"), "no-store")
        self.assertIn("default-src 'self'", resp.getheader("Content-Security-Policy"))

    @unittest.skipUnless(STATIC_INDEX.exists(),
                         "static/index.html отсутствует — будет проверено на этапе C.7")
    def test_index_served(self):
        status, resp, body = self.req("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"NetLab", body)
        self.assertEqual(resp.getheader("X-Content-Type-Options"), "nosniff")

    def test_path_traversal_blocked(self):
        for p in ("/../netlab/engine.py", "/..%2fnetlab%2fengine.py",
                  "/static/../../README.md"):
            status, _, _ = self.req("GET", p)
            self.assertEqual(status, 404, p)

    def test_bad_host_rejected(self):
        status, res = self.jreq("GET", "/api/tasks",
                                headers={"Host": "evil.example"})
        self.assertEqual(status, 403)
        self.assertEqual(res["error"]["code"], "FORBIDDEN_HOST")

    def test_method_not_allowed(self):
        status, _, _ = self.req("POST", "/", raw=b"",
                                headers={"Content-Type": "application/json"})
        self.assertEqual(status, 405)

    # ----- валидация тела
    def test_post_requires_json(self):
        status, res = self.jreq("POST", "/api/ping", raw=b"a=b",
                                headers={"Content-Type":
                                         "application/x-www-form-urlencoded"})
        self.assertEqual(status, 415)
        self.assertEqual(res["error"]["code"], "UNSUPPORTED_MEDIA_TYPE")

    def test_bad_json(self):
        status, res = self.jreq("POST", "/api/ping", raw=b"{broken",
                                headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400)
        self.assertEqual(res["error"]["code"], "BAD_REQUEST")

    def test_too_large_body(self):
        # Отправляем только заголовки: сервер обязан ответить 413 по Content-Length,
        # не дожидаясь тела (проверка в _read_json идёт до чтения).
        conn = HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.putrequest("POST", "/api/ping")
        conn.putheader("Host", f"127.0.0.1:{self.port}")
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(MAX_BODY + 1))
        conn.endheaders()
        resp = conn.getresponse()
        status = resp.status
        body = resp.read()
        conn.close()
        self.assertEqual(status, 413)
        self.assertEqual(json.loads(body)["error"]["code"], "TOO_LARGE")

    # ----- задания
    def test_tasks_list(self):
        status, res = self.jreq("GET", "/api/tasks")
        self.assertEqual(status, 200)
        self.assertEqual(res["tasks"], tasks.list_tasks())

    def test_tasks_check_and_unknown(self):
        status, res = self.jreq("GET", "/api/tasks/fix_mask")
        self.assertEqual(status, 200)
        self.assertEqual(res["id"], "fix_mask")
        topo = res["topology"]

        status, res = self.jreq("POST", "/api/tasks/fix_mask/check",
                                {"topology": topo})
        self.assertEqual(status, 200)
        self.assertFalse(res["passed"])

        status, _ = self.jreq("GET", "/api/tasks/unknown")
        self.assertEqual(status, 404)

    # ----- ping
    def test_ping_api(self):
        topo = tasks.get_task_topology("fix_mask")
        status, res = self.jreq(
            "POST", "/api/ping",
            {"topology": topo, "source": "pc1", "target": "pc2"})
        self.assertEqual(status, 200)
        self.assertEqual(res["code"], "REPLY_DIFFERENT_SUBNET")

    def test_ping_bad_topology(self):
        status, res = self.jreq(
            "POST", "/api/ping",
            {"topology": {"devices": 1}, "source": "a", "target": "b"})
        self.assertEqual(status, 400)
        self.assertEqual(res["error"]["code"], "TOPOLOGY_INVALID")

    # ----- проекты
    def test_project_lifecycle(self):
        topo = tasks.get_task_topology("fix_subnet")

        status, res = self.jreq("POST", "/api/projects",
                                {"name": "A", "topology": topo})
        self.assertEqual(status, 200)
        pid = res["project"]["id"]
        self.assertEqual(res["project"]["name"], "A")

        status, res = self.jreq("GET", f"/api/projects/{pid}")
        self.assertEqual(status, 200)
        self.assertEqual(res["project"]["topology"], topo)

        status, res = self.jreq("PUT", f"/api/projects/{pid}",
                                {"name": "B", "topology": topo})
        self.assertEqual(status, 200)
        self.assertEqual(res["project"]["name"], "B")

        status, res = self.jreq("DELETE", f"/api/projects/{pid}")
        self.assertEqual(status, 200)
        self.assertTrue(res["deleted"])

        status, _ = self.jreq("GET", f"/api/projects/{pid}")
        self.assertEqual(status, 404)

    def test_invalid_project_name(self):
        status, res = self.jreq(
            "POST", "/api/projects",
            {"name": "", "topology": tasks.get_task_topology("fix_mask")})
        self.assertEqual(status, 400)
        self.assertEqual(res["error"]["code"], "INVALID_NAME")

    def test_unknown_api(self):
        status, _ = self.jreq("GET", "/api/nonexistent")
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()