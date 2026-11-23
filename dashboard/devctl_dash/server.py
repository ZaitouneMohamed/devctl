"""HTTP server for the devctl dashboard (standard library only).

Every request must carry the right Host header. Everything except /login needs a session
cookie; every POST also needs the X-Devctl-CSRF header. All state changes go through the
devctl CLI (cli.py).
"""

from __future__ import annotations

import argparse
import re
import secrets
import json
import os
import signal
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from .auth import Auth, Session
from .cli import Cli, CliError
from .history import HistoryIndex
from .jobs import Jobs

MAX_BODY_BYTES = 16 * 1024
MAX_UPLOAD_BYTES = 4 * 1024 * 1024 * 1024  # database dumps
UPLOAD_KEEP_SECONDS = 24 * 3600
# A plain file name (no folders) ending in an allowed extension; group 1 is that extension.
_UPLOAD_EXT = re.compile(r"[^/\\\x00]{1,200}?\.(sql|sql\.gz|dump|dump\.gz|archive|archive\.gz|gz)", re.IGNORECASE)
SSE_POLL_SECONDS = 1.0
SSE_HEARTBEAT_SECONDS = 15.0

SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
}

STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
}

# Cards for features whose CLI module is not built yet (roadmap module numbers).
COMING = [
    {"title": "Databases", "module": 7, "text": "Shared servers, users, import/export"},
    {"title": "Services", "module": 13, "text": "Mailpit, Meilisearch, Elasticsearch, RabbitMQ, Kafka"},
    {"title": "AI models", "module": 16, "text": "Ollama server and models"},
    {"title": "Cloud tools", "module": 17, "text": "kind, Terraform, LocalStack"},
]


@dataclass(frozen=True)
class Settings:
    port: int
    devctl_bin: str
    history_file: Path
    state_dir: Path
    run_dir: Path
    static_dir: Path
    domain: str = ""

    @property
    def login_dir(self) -> Path:
        return self.run_dir / "dashboard-login"

    @property
    def export_dir(self) -> Path:
        return self.run_dir / "exports"

    @property
    def upload_dir(self) -> Path:
        return self.run_dir / "uploads"

    @property
    def state_file(self) -> Path:
        return self.run_dir / "dashboard.json"


class App:
    def __init__(self, settings: Settings, cli: Cli | None = None):
        self.settings = settings
        hosts = {f"127.0.0.1:{settings.port}", f"localhost:{settings.port}"}
        if settings.domain:
            hosts.add(settings.domain)  # served by Caddy over HTTPS (https://devctl.test)
        self.auth = Auth(settings.login_dir, hosts)
        self.history = HistoryIndex(settings.history_file, settings.state_dir / "history.sqlite")
        self.cli = cli or Cli(settings.devctl_bin)
        self.static = {
            p.name: p for p in settings.static_dir.iterdir() if p.is_file() and p.suffix in STATIC_TYPES
        }
        self.stopping = threading.Event()
        self.jobs = Jobs(self.cli)


class Handler(BaseHTTPRequestHandler):
    server_version = "devctl-dashboard"
    sys_version = ""
    app: App  # set on the subclass created by make_server

    # ---- plumbing -------------------------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:
        # Never log query strings: /login carries a (one-time) code.
        path = urlsplit(self.path).path
        sys.stderr.write(f"{self.command} {path} {args[1] if len(args) > 1 else ''}\n")

    def _send(self, status: int, body: bytes, content_type: str, extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in {**SECURITY_HEADERS, **(extra or {})}.items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, data) -> None:
        self._send(status, json.dumps(data).encode(), "application/json")

    def _error(self, status: int, message: str) -> None:
        self._json(status, {"error": message})

    def _session(self) -> Session | None:
        return self.app.auth.session_from_cookie(self.headers.get("Cookie"))

    def _guard(self) -> tuple[bool, Session | None]:
        """Common checks. Returns (handled, session); handled=True means a response was sent."""
        if not self.app.auth.host_allowed(self.headers.get("Host")):
            self._send(HTTPStatus.MISDIRECTED_REQUEST, b"wrong host\n", "text/plain")
            return True, None
        return False, self._session()

    # ---- GET ------------------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        handled, session = self._guard()
        if handled:
            return
        url = urlsplit(self.path)
        path, query = url.path, parse_qs(url.query)

        if path == "/login":
            return self._login(query.get("code", [""])[0])
        if session is None:
            if path.startswith("/api/"):
                return self._error(HTTPStatus.UNAUTHORIZED, "not logged in")
            return self._send(HTTPStatus.UNAUTHORIZED, _LOGGED_OUT_PAGE, "text/html; charset=utf-8")

        if path in ("/", "/index.html"):
            return self._static("index.html")
        if path.startswith("/static/"):
            return self._static(path.removeprefix("/static/"))
        if path == "/api/session":
            return self._json(HTTPStatus.OK, {"csrf": session.csrf})
        if path == "/api/overview":
            return self._overview()
        if path == "/api/history":
            return self._history(query)
        if path == "/api/settings":
            return self._cli_json(["config", "show"])
        if path == "/api/events":
            return self._events(query)
        if path == "/api/status":
            return self._cli_json(["status"])
        if path == "/api/sites":
            return self._cli_json(["site", "list"])
        if path == "/api/db":
            return self._cli_json(["db", "list"])
        if path == "/api/db/databases":
            return self._cli_json(["db", "list", "--databases"])
        if path == "/api/db/creds":
            name = query.get("name", [""])[0]
            if not _DBNAME.fullmatch(name):
                return self._error(HTTPStatus.BAD_REQUEST, "invalid database name")
            return self._cli_json(["db", "creds", name])
        if path == "/api/engine":
            return self._cli_json(["engine", "status"])
        if path == "/api/svc":
            return self._cli_json(["svc", "list"])
        if path == "/api/svc/info":
            name = query.get("name", [""])[0]
            if not _WORD.fullmatch(name):
                return self._error(HTTPStatus.BAD_REQUEST, "invalid service")
            args = ["svc", "info", name] + (["--show-secrets"] if query.get("show") == ["1"] else [])
            return self._cli_json(args)
        if path == "/api/logs":
            return self._logs(query)
        if path.startswith("/api/exports/"):
            return self._download(path.removeprefix("/api/exports/"))
        if path == "/api/github":
            return self._cli_json(["github", "status"])
        if path == "/api/github/repos":
            # cached=1: instant answer from devctl's cache (404 if none yet);
            # refresh=1: ask GitHub now; default: cache if under 15 minutes old.
            args = ["github", "repos"]
            if query.get("cached") == ["1"]:
                args.append("--cached")
            elif query.get("refresh") == ["1"]:
                args.append("--refresh")
            return self._cli_json(args)
        if path.startswith("/api/jobs/"):
            return self._job(path.removeprefix("/api/jobs/"), query)
        self._error(HTTPStatus.NOT_FOUND, "not found")

    def _login(self, code: str) -> None:
        session = self.app.auth.redeem_login_code(code)
        if session is None:
            return self._send(HTTPStatus.UNAUTHORIZED, _LOGGED_OUT_PAGE, "text/html; charset=utf-8")
        self._send(
            HTTPStatus.SEE_OTHER,
            b"",
            "text/plain",
            {"Location": "/", "Set-Cookie": self.app.auth.cookie_header(session)},
        )

    def _static(self, name: str) -> None:
        file = self.app.static.get(name)  # whitelist: only files present at startup
        if file is None:
            return self._error(HTTPStatus.NOT_FOUND, "not found")
        self._send(HTTPStatus.OK, file.read_bytes(), STATIC_TYPES[file.suffix])

    def _overview(self) -> None:
        self.app.history.sync()
        try:
            version = self.app.cli.run_json(["version"])
        except CliError as exc:
            version = {"error": str(exc)}
        self._json(
            HTTPStatus.OK,
            {"version": version, "history": self.app.history.counts(), "coming": COMING},
        )

    def _history(self, query: dict[str, list[str]]) -> None:
        self.app.history.sync()

        def one(key: str) -> str | None:
            value = query.get(key, [""])[0].strip()
            return value or None

        type_ = one("type")
        if type_ not in (None, "action", "alert"):
            return self._error(HTTPStatus.BAD_REQUEST, "type must be action or alert")
        try:
            limit = int(one("limit") or 200)
        except ValueError:
            return self._error(HTTPStatus.BAD_REQUEST, "limit must be a number")
        rows = self.app.history.query(type_=type_, source=one("source"), text=one("q"), limit=limit)
        self._json(HTTPStatus.OK, {"generation": self.app.history.generation(), "events": rows})

    def _cli_json(self, args: list[str]) -> None:
        try:
            self._json(HTTPStatus.OK, self.app.cli.run_json(args))
        except CliError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, str(exc))

    def _events(self, query: dict[str, list[str]]) -> None:
        """Server-Sent Events: push new history rows and a 'reset' when history is cleared."""
        try:
            last_id = int(query.get("after", ["0"])[0])
        except ValueError:
            last_id = 0
        history = self.app.history
        history.sync()
        generation = history.generation()

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream")
        for key, value in SECURITY_HEADERS.items():
            self.send_header(key, value)
        self.end_headers()
        self.close_connection = True

        last_beat = time.monotonic()
        try:
            self._sse("hello", {"generation": generation})
            while not self.app.stopping.is_set():
                history.sync()
                current = history.generation()
                if current != generation:
                    generation, last_id = current, 0
                    self._sse("reset", {"generation": generation})
                rows = history.query(after_id=last_id, limit=500, newest_first=False)
                for row in rows:
                    self._sse("history", row)
                    last_id = row["id"]
                if time.monotonic() - last_beat > SSE_HEARTBEAT_SECONDS:
                    self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
                    last_beat = time.monotonic()
                self.app.stopping.wait(SSE_POLL_SECONDS)
        except (BrokenPipeError, ConnectionResetError):
            pass  # browser tab closed

    def _sse(self, event: str, data) -> None:
        self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()

    # ---- POST -----------------------------------------------------------------------

    def do_POST(self) -> None:  # noqa: N802
        handled, session = self._guard()
        if handled:
            return
        if session is None:
            return self._error(HTTPStatus.UNAUTHORIZED, "not logged in")
        if not self.app.auth.csrf_ok(session, self.headers.get("X-Devctl-CSRF")):
            return self._error(HTTPStatus.FORBIDDEN, "missing or wrong CSRF token")
        if urlsplit(self.path).path == "/api/upload":
            return self._upload()
        body = self._read_json()
        if body is None:
            return

        path = urlsplit(self.path).path
        if path == "/api/history/clear":
            return self._run_action(["history", "clear"], confirm=_str(body.get("confirm")))
        if path == "/api/sites/create":
            return self._site_create(body)
        if path == "/api/sites/action":
            return self._site_action(body)
        if path == "/api/sites/clone":
            return self._site_clone(body)
        if path == "/api/sites/db":
            return self._site_db(body)
        if path.startswith("/api/db/"):
            return self._db(path.removeprefix("/api/db/"), body)
        if path == "/api/svc/action":
            name, action = _str(body.get("name")), _str(body.get("action"))
            if not (name and _WORD.fullmatch(name)) or action not in ("start", "stop"):
                return self._error(HTTPStatus.BAD_REQUEST, "unknown service or action")
            return self._start_job(f"{action.title()} {name}", ["svc", action, name], yes=True)
        if path.startswith("/api/setup/"):
            return self._setup(path.removeprefix("/api/setup/"), body)
        self._error(HTTPStatus.NOT_FOUND, "not found")

    # ---- sites (every action is a devctl command; devctl validates again) -----------------

    def _start_job(self, title: str, args: list[str], **kwargs) -> None:
        job = self.app.jobs.start(title, args, **kwargs)
        self._json(HTTPStatus.ACCEPTED, {"job": job.id})

    def _site_create(self, body: dict) -> None:
        name, category, engine, template = (_str(body.get(k)) for k in ("name", "category", "engine", "template"))
        template = template or "laravel-inertia-react"
        if not (name and _NAME.fullmatch(name) and category and _WORD.fullmatch(category)
                and engine and _WORD.fullmatch(template)):
            return self._error(HTTPStatus.BAD_REQUEST, "name, category, template and database are required")
        if engine.startswith("use:") and _DBNAME.fullmatch(engine.removeprefix("use:")):
            db_args = ["--use-db", engine.removeprefix("use:")]
        elif _WORD.fullmatch(engine):
            db_args = ["--db", engine]
        else:
            return self._error(HTTPStatus.BAD_REQUEST, "invalid database choice")
        # Pressing "Create" in the form is the confirmation (the form shows what will happen).
        self._start_job(f"Create {name}", ["site", "create", name, "--template", template,
                                           "--category", category, *db_args], yes=True)

    # ---- uploads (database dumps) ------------------------------------------------------

    def _upload(self) -> None:
        """Stream a dump file into run/uploads (0600) and return its id; old ones are removed."""
        name = self.headers.get("X-Filename", "")
        match = _UPLOAD_EXT.fullmatch(name)
        if not match:
            return self._error(HTTPStatus.BAD_REQUEST, "upload a .sql, .sql.gz, .dump or .archive file")
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if not 0 < length <= MAX_UPLOAD_BYTES:
            return self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "file missing or larger than 4 GiB")
        folder = self.app.settings.upload_dir
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        now = time.time()
        for old in folder.iterdir():
            if old.is_file() and now - old.stat().st_mtime > UPLOAD_KEEP_SECONDS:
                old.unlink(missing_ok=True)
        # The stored name is ours: random hex + the allow-listed extension (never the client's name).
        upload_id = f"{secrets.token_hex(12)}.{match.group(1).lower()}"
        target = folder / upload_id
        if target.resolve().parent != folder.resolve():
            return self._error(HTTPStatus.BAD_REQUEST, "invalid file name")
        remaining = length
        with open(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as out:
            while remaining:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    break
                out.write(chunk)
                remaining -= len(chunk)
        if remaining:
            target.unlink(missing_ok=True)
            return self._error(HTTPStatus.BAD_REQUEST, "upload interrupted")
        self._json(HTTPStatus.OK, {"upload": upload_id})

    def _upload_path(self, upload_id) -> str | None:
        """Only ids this server created map to a file: the browser never chooses a path."""
        if not (isinstance(upload_id, str) and _UPLOAD_ID.fullmatch(upload_id)):
            return None
        path = self.app.settings.upload_dir / upload_id
        return str(path) if path.is_file() else None

    def _db_args(self, body: dict) -> list[str] | None:
        """--db/--fill/--file options from a form, or None if invalid."""
        engine, fill = _str(body.get("engine")), _str(body.get("fill"))
        args: list[str] = []
        if engine and engine.startswith("use:"):
            # An existing database another site uses ("use:NAME").
            existing = engine.removeprefix("use:")
            if not _DBNAME.fullmatch(existing):
                return None
            args += ["--use-db" if body.get("_clone") else "--use", existing]
        elif engine:
            if engine not in ("auto", "mysql", "postgres", "mariadb", "sqlite", "none"):
                return None
            args += ["--db" if body.get("_clone") else "--engine", engine]
        if fill:
            if fill not in ("migrate", "import", "none"):
                return None
            args += ["--fill", fill]
            if fill == "import":
                path = self._upload_path(body.get("upload"))
                if path is None:
                    return None
                args += ["--file", path]
        return args

    def _site_db(self, body: dict) -> None:
        name = _str(body.get("name"))
        extra = self._db_args({**body, "_clone": False})
        if not (name and _NAME.fullmatch(name)) or extra is None:
            return self._error(HTTPStatus.BAD_REQUEST, "site, database and how to fill it are required (import: upload the file first)")
        self._start_job(f"Database for {name}", ["site", "db", name, *extra], yes=True)

    def _site_clone(self, body: dict) -> None:
        repo, name, category = (_str(body.get(k)) for k in ("repo", "name", "category"))
        if not (repo and _REPO.fullmatch(repo) and category and _WORD.fullmatch(category)):
            return self._error(HTTPStatus.BAD_REQUEST, "repository (OWNER/REPO) and category are required")
        args = ["site", "clone", repo, "--category", category]
        if name:
            if not _NAME.fullmatch(name):
                return self._error(HTTPStatus.BAD_REQUEST, "invalid site name")
            args += ["--name", name]
        extra = self._db_args({**body, "_clone": True})
        if extra is None:
            return self._error(HTTPStatus.BAD_REQUEST, "invalid database choice (import: upload the file first)")
        args += extra
        # Pressing "Clone" is the confirmation; devctl answers its own questions with the
        # defaults (use devctl's shared services; install dependencies once).
        self._start_job(f"Clone {repo}", args, yes=True)

    # ---- databases page ------------------------------------------------------------------

    def _db(self, what: str, body: dict) -> None:
        if what == "server":
            server, action = _str(body.get("server")), _str(body.get("action"))
            if not (server and _SERVER.fullmatch(server)) or action not in ("start", "stop"):
                return self._error(HTTPStatus.BAD_REQUEST, "unknown server or action")
            return self._start_job(f"{action.title()} {server}", ["db", action, server], yes=True)
        name = _str(body.get("name"))
        if not (name and _DBNAME.fullmatch(name)):
            return self._error(HTTPStatus.BAD_REQUEST, "invalid database name (lowercase letters, digits, _)")
        if what == "create":
            engine = _str(body.get("engine"))
            if engine not in ("mysql", "postgres", "mariadb", "mongodb"):
                return self._error(HTTPStatus.BAD_REQUEST, "choose an engine")
            return self._start_job(f"Create database {name}", ["db", "create", name, "--engine", engine], yes=True)
        if what == "export":
            folder = self.app.settings.export_dir
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._clean(folder)
            return self._start_job(f"Export {name}", ["db", "export", name], cwd=str(folder))
        if what == "import":
            path = self._upload_path(body.get("upload"))
            if path is None:
                return self._error(HTTPStatus.BAD_REQUEST, "upload the dump file first")
            # A non-empty database needs its typed name, checked again by devctl.
            return self._start_job(f"Import into {name}", ["db", "import", name, path], confirm=_str(body.get("confirm")) or "")
        self._error(HTTPStatus.NOT_FOUND, "not found")

    @staticmethod
    def _clean(folder: Path) -> None:
        now = time.time()
        for old in folder.iterdir():
            if old.is_file() and now - old.stat().st_mtime > UPLOAD_KEEP_SECONDS:
                old.unlink(missing_ok=True)

    def _download(self, name: str) -> None:
        """Send an export devctl made in run/exports (name checked; no other file is reachable)."""
        if not _EXPORT.fullmatch(name):
            return self._error(HTTPStatus.NOT_FOUND, "not found")
        file = self.app.settings.export_dir / name
        if not file.is_file() or file.resolve().parent != self.app.settings.export_dir.resolve():
            return self._error(HTTPStatus.NOT_FOUND, "not found")
        size = file.stat().st_size
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        for key, value in SECURITY_HEADERS.items():
            self.send_header(key, value)
        self.end_headers()
        with open(file, "rb") as f:
            while chunk := f.read(1 << 20):
                self.wfile.write(chunk)

    # ---- logs page -----------------------------------------------------------------------

    def _logs(self, query: dict[str, list[str]]) -> None:
        site, part = query.get("site", [""])[0], query.get("part", ["web"])[0]
        try:
            lines = max(10, min(int(query.get("lines", ["200"])[0]), 2000))
        except ValueError:
            lines = 200
        if not _NAME.fullmatch(site) or part not in ("app", "php", "web", "db"):
            return self._error(HTTPStatus.BAD_REQUEST, "choose a site and a part (app, php, web, db)")
        result = self.app.cli.run(["logs", site, f"--{part}", "-n", str(lines)])
        if not result.ok:
            return self._error(HTTPStatus.BAD_GATEWAY, result.error_message())
        self._json(HTTPStatus.OK, {"lines": result.stdout.splitlines()[-lines:]})

    # ---- setup page (GitHub, git identity) --------------------------------------------

    def _setup(self, what: str, body: dict) -> None:
        if what == "github/install":
            return self._start_job("Install the GitHub CLI", ["github", "install"])
        if what == "github/login":
            # Device flow: the job's output contains the one-time code; the page shows it.
            return self._start_job("Sign in to GitHub", ["github", "login"])
        if what == "github/token":
            token = body.get("token")
            if not (isinstance(token, str) and _TOKEN.fullmatch(token)):
                return self._error(HTTPStatus.BAD_REQUEST, "that does not look like a GitHub token (ghp_… or github_pat_…)")
            return self._run_action(["github", "login", "--with-token"], input_text=token + "\n")
        if what == "github/logout":
            return self._run_action(["github", "logout"], yes=True)
        if what == "git-identity":
            name, email = body.get("name"), body.get("email")
            if not (isinstance(name, str) and 0 < len(name) <= 100 and "\n" not in name
                    and isinstance(email, str) and _EMAIL.fullmatch(email)):
                return self._error(HTTPStatus.BAD_REQUEST, "a name and a valid email are required")
            return self._run_action(["github", "identity", "--name", name, "--email", email])
        self._error(HTTPStatus.NOT_FOUND, "not found")

    def _site_action(self, body: dict) -> None:
        name, action = _str(body.get("name")), _str(body.get("action"))
        if not (name and _NAME.fullmatch(name)) or action not in ("start", "stop", "delete"):
            return self._error(HTTPStatus.BAD_REQUEST, "unknown site or action")
        if action == "delete":
            # Same rule as the terminal: the typed name is checked again by devctl.
            # The database goes only when the box was ticked (default: kept).
            db_flag = "--with-db" if body.get("with_db") is True else "--keep-db"
            return self._start_job(f"Delete {name}", ["site", "delete", name, db_flag],
                                   confirm=_str(body.get("confirm")) or "")
        self._start_job(f"{action.title()} {name}", ["site", action, name])

    def _job(self, raw_id: str, query: dict[str, list[str]]) -> None:
        try:
            job = self.app.jobs.get(int(raw_id))
            start = max(0, int(query.get("from", ["0"])[0]))
        except ValueError:
            job = None
        if job is None:
            return self._error(HTTPStatus.NOT_FOUND, "no such job")
        self._json(HTTPStatus.OK, job.snapshot(start))

    def _read_json(self) -> dict | None:
        if self.headers.get_content_type() != "application/json":
            self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "expected application/json")
            return None
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_BODY_BYTES:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "body too large")
            return None
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._error(HTTPStatus.BAD_REQUEST, "invalid JSON")
            return None
        if not isinstance(data, dict):
            self._error(HTTPStatus.BAD_REQUEST, "expected a JSON object")
            return None
        return data

    def _run_action(self, args: list[str], *, confirm: str | None = None, yes: bool = False,
                    input_text: str | None = None) -> None:
        kwargs = {"confirm": confirm}
        if yes:
            kwargs["yes"] = True
        if input_text is not None:
            kwargs["input_text"] = input_text
        result = self.app.cli.run(args, **kwargs)
        if result.ok:
            try:
                data = json.loads(result.stdout) if result.stdout.strip() else {}
            except ValueError:
                data = {}
            return self._json(HTTPStatus.OK, {"ok": True, "result": data})
        status = {6: HTTPStatus.CONFLICT, 2: HTTPStatus.BAD_REQUEST, 3: HTTPStatus.BAD_REQUEST}.get(
            result.exit, HTTPStatus.BAD_GATEWAY
        )
        self._json(status, {"ok": False, "exit": result.exit, "error": result.error_message()})


_NAME = re.compile(r"[a-z][a-z0-9-]{0,40}[a-z0-9]")
_WORD = re.compile(r"[a-z][a-z0-9-]{0,30}")
_DBNAME = re.compile(r"[a-z][a-z0-9_]{0,31}")
_SERVER = re.compile(r"[a-z][a-z0-9]*-[a-z0-9-]{1,20}")
_EXPORT = re.compile(r"[a-z][a-z0-9_]{0,31}-[a-z]+-[0-9]{8}-[0-9]{6}\.[a-z]+\.gz")
_UPLOAD_ID = re.compile(r"[0-9a-f]{24}\.[a-z.]{2,12}")
_TOKEN = re.compile(r"ghp_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{40,255}")
_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}")


def _str(value) -> str | None:
    return value if isinstance(value, str) and "\n" not in value and len(value) <= 200 else None


_LOGGED_OUT_PAGE = b"""<!doctype html><meta charset="utf-8"><title>devctl</title>
<body style="font:16px system-ui,sans-serif;max-width:36rem;margin:15vh auto;padding:0 1rem;color:#222">
<h1 style="font-size:1.4rem">devctl dashboard</h1>
<p>You are not logged in, or your login link has expired (links work once, for 2 minutes).</p>
<p>Open the dashboard with the <b>devctl Dashboard</b> icon, or run <code>devctl dashboard</code>.</p>
</body>
"""


def make_server(app: App, host: str = "127.0.0.1") -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"app": app})
    server = ThreadingHTTPServer((host, app.settings.port), handler)
    server.daemon_threads = True
    return server


def _write_state(settings: Settings, port: int) -> None:
    settings.run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = json.dumps({"pid": os.getpid(), "port": port, "started": int(time.time())})
    fd, tmp = tempfile.mkstemp(dir=settings.run_dir, prefix=".dashboard.")
    with os.fdopen(fd, "w") as f:
        f.write(data + "\n")
    os.replace(tmp, settings.state_file)


def parse_args(argv: list[str]) -> Settings:
    parser = argparse.ArgumentParser(prog="devctl-dashboard")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--devctl-bin", required=True)
    parser.add_argument("--history-file", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--domain", default="")
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("--port must be 1-65535")
    return Settings(
        port=args.port,
        devctl_bin=args.devctl_bin,
        history_file=args.history_file,
        state_dir=args.state_dir,
        run_dir=args.run_dir,
        domain=args.domain,
        static_dir=Path(__file__).resolve().parent.parent / "static",
    )


def main(argv: list[str]) -> int:
    os.umask(0o077)
    settings = parse_args(argv)
    app = App(settings)
    try:
        server = make_server(app)
    except OSError as exc:
        print(f"devctl-dashboard: cannot listen on 127.0.0.1:{settings.port}: {exc}", file=sys.stderr)
        return 1

    def stop(_signum, _frame) -> None:
        app.stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    app.history.sync()
    _write_state(settings, settings.port)
    print(f"devctl-dashboard listening on http://127.0.0.1:{settings.port}", file=sys.stderr)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        settings.state_file.unlink(missing_ok=True)
    return 0
