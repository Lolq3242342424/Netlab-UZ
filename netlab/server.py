"""HTTP-сервер NetLab UZ: статические файлы + JSON API (только стандартная библиотека).

Безопасность этапа 1 (локальный запуск, без аккаунтов):
  * по умолчанию слушает только 127.0.0.1;
  * проверка заголовка Host (защита от DNS-rebinding);
  * изменяющие запросы принимаются только как application/json
    (кросс-сайтовая форма так отправить не может, CORS мы не разрешаем);
  * лимит размера тела запроса, строгая проверка схемы на сервере;
  * защита от выхода за пределы папки static;
  * заголовки CSP, nosniff, no-referrer, X-Frame-Options.
Аккаунтов нет, поэтому НЕ выставляйте сервер в интернет (см. README).
"""
import json
import mimetypes
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import engine, tasks
from .storage import ProjectError, ProjectStore

ROOT = Path(__file__).resolve().parent.parent
STATIC_DIR = ROOT / "static"
MAX_BODY = 1_000_000  # 1 МБ — с большим запом для схемы из 50 устройств

SECURITY_HEADERS = {
    "Content-Security-Policy": ("default-src 'self'; img-src 'self' data:; "
                                "object-src 'none'; frame-ancestors 'none'; base-uri 'none'"),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
}

ROUTE_PROJECT = re.compile(r"^/api/projects/(\d{1,12})$")
ROUTE_TASK = re.compile(r"^/api/tasks/([a-z_]{1,40})$")
ROUTE_TASK_CHECK = re.compile(r"^/api/tasks/([a-z_]{1,40})/check$")


class ApiError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status, self.code = status, code


def make_handler(store, allowed_hosts):
    class Handler(BaseHTTPRequestHandler):
        server_version = "NetLabUZ/0.1"

        # ----- вспомогательные методы
        def _send(self, status, body, content_type):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in SECURITY_HEADERS.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self._send(status, body, "application/json; charset=utf-8")

        def _read_json(self):
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                raise ApiError(415, "UNSUPPORTED_MEDIA_TYPE")
            try:
                length = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                raise ApiError(400, "BAD_REQUEST")
            if length <= 0:
                raise ApiError(400, "BAD_REQUEST")
            if length > MAX_BODY:
                raise ApiError(413, "TOO_LARGE")
            try:
                return json.loads(self.rfile.read(length).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                raise ApiError(400, "BAD_REQUEST")

        def _check_host(self):
            host = (self.headers.get("Host") or "").lower()
            if host not in allowed_hosts:
                raise ApiError(403, "FORBIDDEN_HOST")

        # ----- обработка запроса
        def _dispatch(self):
            try:
                self._check_host()
                path = self.path.split("?", 1)[0]
                if path.startswith("/api/"):
                    self._json(200, self._api(path))
                elif self.command in ("GET", "HEAD"):
                    self._static(path)
                else:
                    raise ApiError(405, "METHOD_NOT_ALLOWED")
            except ApiError as e:
                self._json(e.status, {"error": {"code": e.code}})
            except engine.TopologyError as e:
                self._json(400, {"error": {"code": e.code}})
            except ProjectError as e:
                status = 404 if e.code == "NOT_FOUND" else 400
                self._json(status, {"error": {"code": e.code}})
            except Exception as e:  # подробности — только в лог, не пользователю
                print(f"internal error: {type(e).__name__}: {e}", file=sys.stderr)
                self._json(500, {"error": {"code": "INTERNAL"}})

        def _api(self, path):
            m, method = None, self.command
            if path == "/api/tasks" and method == "GET":
                return {"tasks": tasks.list_tasks()}
            if path == "/api/projects" and method == "GET":
                return {"projects": store.list()}
            if path == "/api/projects" and method == "POST":
                body = self._read_json()
                self._need_dict(body)
                return {"project": store.create(body.get("name"), body.get("topology"))}
            if path == "/api/ping" and method == "POST":
                body = self._read_json()
                self._need_dict(body)
                return engine.ping(body.get("topology"), body.get("source"), body.get("target"))
            m = ROUTE_TASK.match(path)
            if m and method == "GET":
                topo = tasks.get_task_topology(m.group(1))
                if topo is None:
                    raise ApiError(404, "NOT_FOUND")
                return {"id": m.group(1), "topology": topo}
            m = ROUTE_TASK_CHECK.match(path)
            if m and method == "POST":
                body = self._read_json()
                self._need_dict(body)
                result = tasks.check_task(m.group(1), body.get("topology"))
                if result is None:
                    raise ApiError(404, "NOT_FOUND")
                return result
            m = ROUTE_PROJECT.match(path)
            if m:
                pid = int(m.group(1))
                if method == "GET":
                    return {"project": store.get(pid)}
                if method == "PUT":
                    body = self._read_json()
                    self._need_dict(body)
                    return {"project": store.update(pid, body.get("name"), body.get("topology"))}
                if method == "DELETE":
                    store.delete(pid)
                    return {"deleted": True}
            raise ApiError(404, "NOT_FOUND")

        @staticmethod
        def _need_dict(body):
            if not isinstance(body, dict):
                raise ApiError(400, "BAD_REQUEST")

        def _static(self, path):
            rel = "index.html" if path in ("", "/") else path.lstrip("/")
            target = (STATIC_DIR / rel).resolve()
            if STATIC_DIR not in target.parents or not target.is_file():
                raise ApiError(404, "NOT_FOUND")  # в т.ч. попытки ../
            ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype in ("application/json", "application/javascript"):
                ctype += "; charset=utf-8"
            self._send(200, target.read_bytes(), ctype)

        do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _dispatch

        def log_message(self, fmt, *args):  # короткий лог без тела запросов
            if os.environ.get("NETLAB_QUIET") != "1":
                sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    return Handler


def create_server(host="127.0.0.1", port=8000, db_path=None):
    """Создаёт (но не запускает) HTTP-сервер."""
    db_path = db_path or os.environ.get("NETLAB_DB") or str(ROOT / "data" / "netlab.db")
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    store = ProjectStore(db_path)
    server = ThreadingHTTPServer((host, port), make_handler(store, set()))
    real_port = server.server_address[1]  # важно при port=0 (тесты)
    allowed = {f"{h}:{real_port}" for h in ("127.0.0.1", "localhost", host)}
    server.RequestHandlerClass = make_handler(store, allowed)
    return server
