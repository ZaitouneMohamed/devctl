"""End-to-end tests: a real server on a free port, a fake CLI, plain urllib requests."""

import http.client
import json
import socket
import subprocess
import time
import tempfile
import threading
import unittest
from pathlib import Path

from devctl_dash.cli import CliResult
from devctl_dash.server import App, Settings, make_server


class FakeCli:
    def __init__(self):
        self.calls = []

    def run(self, args, *, confirm=None, yes=False, input_text=None):
        self.calls.append((args, confirm))
        self.last_input = input_text
        if args[:2] == ["github", "login"] or args[:2] == ["github", "identity"] or args[:2] == ["github", "logout"]:
            return CliResult(0, "", "")
        if args == ["history", "clear"]:
            if confirm != "history":
                return CliResult(6, "", "error: confirmation text does not match 'history'\n")
            return CliResult(0, '{"cleared": true}\n', "")
        if args[:2] == ["github", "repos"]:
            return CliResult(0, '[{"repo": "me/blog", "private": false, "language": "PHP"}]', "")
        if args == ["version"]:
            return CliResult(0, '{"version": "9.9"}', "")
        if args[:1] == ["logs"]:
            return CliResult(0, "\n".join(f"line {i}" for i in range(1, 301)) + "\n", "")
        if args == ["config", "show"]:
            return CliResult(0, '[{"key": "a", "value": "<script>", "from": "default"}]', "")
        return CliResult(2, "", "error: unknown\n")

    def run_json(self, args, *, confirm=None):
        if args == ["site", "list"]:
            return [{"name": "shop", "category": "personal", "kind": "laravel", "url": "https://shop.test",
                     "db_engine": "mysql", "state": "stopped", "path": "/x"}]
        return json.loads(self.run(args, confirm=confirm).stdout)

    def start(self, args, *, confirm=None, yes=False, cwd=None):
        self.calls.append((args, confirm, yes))
        self.last_cwd = cwd
        return subprocess.Popen(["sh", "-c", "echo step one; echo step two; exit 0"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.port = free_port()
        settings = Settings(
            port=self.port, devctl_bin="/nonexistent", history_file=base / "history.jsonl",
            state_dir=base / "state", run_dir=base / "run",
            static_dir=Path(__file__).resolve().parents[1] / "static",
        )
        settings.login_dir.mkdir(parents=True, mode=0o700)
        self.settings = settings
        self.cli = FakeCli()
        self.app = App(settings, cli=self.cli)
        self.server = make_server(self.app)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.app.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def request(self, method, path, *, host=None, cookie=None, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Host": host or f"127.0.0.1:{self.port}", **(headers or {})}
        if cookie:
            h["Cookie"] = cookie
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        conn.request(method, path, body=data, headers=h)
        res = conn.getresponse()
        payload = res.read()
        conn.close()
        return res, payload

    def login(self):
        code = "C" * 43
        (self.settings.login_dir / code).touch(mode=0o600)
        res, _ = self.request("GET", f"/login?code={code}")
        self.assertEqual(res.status, 303)
        cookie = res.getheader("Set-Cookie").split(";")[0]
        _, body = self.request("GET", "/api/session", cookie=cookie)
        return cookie, json.loads(body)["csrf"]

    def test_wrong_host_rejected(self):
        res, _ = self.request("GET", "/", host="evil.example")
        self.assertEqual(res.status, 421)

    def test_requires_login(self):
        res, body = self.request("GET", "/")
        self.assertEqual(res.status, 401)
        self.assertIn(b"devctl dashboard", body)
        res, _ = self.request("GET", "/api/overview")
        self.assertEqual(res.status, 401)

    def test_security_headers(self):
        res, _ = self.request("GET", "/")
        self.assertIn("default-src 'none'", res.getheader("Content-Security-Policy"))
        self.assertEqual(res.getheader("X-Content-Type-Options"), "nosniff")

    def test_login_then_pages(self):
        cookie, _ = self.login()
        res, body = self.request("GET", "/", cookie=cookie)
        self.assertEqual(res.status, 200)
        self.assertIn(b"<title>devctl</title>", body)
        res, _ = self.request("GET", "/static/app.js", cookie=cookie)
        self.assertEqual(res.status, 200)
        res, _ = self.request("GET", "/static/../server.py", cookie=cookie)
        self.assertEqual(res.status, 404)
        _, body = self.request("GET", "/api/overview", cookie=cookie)
        self.assertEqual(json.loads(body)["version"], {"version": "9.9"})

    def test_post_needs_csrf_and_json(self):
        cookie, csrf = self.login()
        res, _ = self.request("POST", "/api/history/clear", cookie=cookie, body={"confirm": "history"})
        self.assertEqual(res.status, 403)
        res, _ = self.request("POST", "/api/history/clear", cookie=cookie, body={},
                              headers={"X-Devctl-CSRF": csrf, "Content-Type": "text/plain"})
        self.assertEqual(res.status, 415)
        self.assertEqual(self.cli.calls, [])

    def test_clear_passes_typed_text_to_cli(self):
        cookie, csrf = self.login()
        h = {"X-Devctl-CSRF": csrf}
        res, body = self.request("POST", "/api/history/clear", cookie=cookie, body={"confirm": "nope"}, headers=h)
        self.assertEqual(res.status, 409)
        self.assertIn("does not match", json.loads(body)["error"])
        res, body = self.request("POST", "/api/history/clear", cookie=cookie, body={"confirm": "history"}, headers=h)
        self.assertEqual(res.status, 200)
        self.assertEqual(self.cli.calls[-1], (["history", "clear"], "history"))

    def test_history_api_and_validation(self):
        self.settings.history_file.write_text(json.dumps(
            {"type": "action", "ts": "t", "source": "cli", "action": "x.y", "args": [], "result": "ok"}) + "\n")
        cookie, _ = self.login()
        _, body = self.request("GET", "/api/history", cookie=cookie)
        self.assertEqual(json.loads(body)["events"][0]["action"], "x.y")
        res, _ = self.request("GET", "/api/history?type=bogus", cookie=cookie)
        self.assertEqual(res.status, 400)

    def test_events_stream_starts(self):
        cookie, _ = self.login()
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/api/events", headers={"Host": f"127.0.0.1:{self.port}", "Cookie": cookie})
        res = conn.getresponse()
        self.assertEqual(res.getheader("Content-Type"), "text/event-stream")
        self.assertEqual(res.readline(), b"event: hello\n")
        conn.close()


if __name__ == "__main__":
    unittest.main()


class SitesTest(ServerTest):
    def post(self, path, body):
        cookie, csrf = self.login()
        return self.request("POST", path, cookie=cookie, body=body, headers={"X-Devctl-CSRF": csrf}), cookie

    def test_site_list(self):
        cookie, _ = self.login()
        res, body = self.request("GET", "/api/sites", cookie=cookie)
        self.assertEqual(json.loads(body)[0]["url"], "https://shop.test")

    def test_create_runs_devctl_with_fixed_arguments_and_streams_output(self):
        (res, body), cookie = self.post("/api/sites/create", {"name": "shop", "category": "personal", "engine": "mysql"})
        self.assertEqual(res.status, 202)
        job = json.loads(body)["job"]
        self.assertEqual(self.cli.calls[-1], (["site", "create", "shop", "--template", "laravel-inertia-react",
                                               "--category", "personal", "--db", "mysql"], None, True))
        for _ in range(50):
            _, raw = self.request("GET", f"/api/jobs/{job}", cookie=cookie)
            snap = json.loads(raw)
            if snap["done"]:
                break
            time.sleep(0.05)
        self.assertEqual(snap["lines"], ["step one", "step two"])
        self.assertEqual(snap["exit"], 0)
        _, raw = self.request("GET", f"/api/jobs/{job}?from=1", cookie=cookie)
        self.assertEqual(json.loads(raw)["lines"], ["step two"])

    def test_bad_input_never_reaches_devctl(self):
        for body in ({"name": "Shop", "category": "personal", "engine": "mysql"},
                     {"name": "shop; rm -rf ~", "category": "personal", "engine": "mysql"},
                     {"name": "shop", "category": "--yes", "engine": "mysql"},
                     {"name": "shop", "category": "personal"}):
            (res, _), _ = self.post("/api/sites/create", body)
            self.assertEqual(res.status, 400, body)
        (res, _), _ = self.post("/api/sites/action", {"name": "shop", "action": "rm"})
        self.assertEqual(res.status, 400)
        self.assertEqual(self.cli.calls, [])

    def test_delete_passes_the_typed_name_to_devctl(self):
        (res, _), _ = self.post("/api/sites/action", {"name": "shop", "action": "delete", "confirm": "shop"})
        self.assertEqual(res.status, 202)
        # The database is kept unless the box was ticked (with_db exactly true).
        self.assertEqual(self.cli.calls[-1], (["site", "delete", "shop", "--keep-db"], "shop", False))
        for value in ("yes", 1, "true", None):
            self.post("/api/sites/action", {"name": "shop", "action": "delete", "confirm": "shop", "with_db": value})
            self.assertEqual(self.cli.calls[-1][0][-1], "--keep-db")
        self.post("/api/sites/action", {"name": "shop", "action": "delete", "confirm": "shop", "with_db": True})
        self.assertEqual(self.cli.calls[-1], (["site", "delete", "shop", "--with-db"], "shop", False))

    def test_unknown_job(self):
        cookie, _ = self.login()
        res, _ = self.request("GET", "/api/jobs/999", cookie=cookie)
        self.assertEqual(res.status, 404)
        res, _ = self.request("GET", "/api/jobs/abc", cookie=cookie)
        self.assertEqual(res.status, 404)

    def test_create_passes_the_chosen_template(self):
        (res, _), _ = self.post("/api/sites/create", {"name": "api", "category": "personal", "engine": "none", "template": "spring-boot"})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["site", "create", "api", "--template", "spring-boot", "--category", "personal", "--db", "none"])

    def test_clone_from_github(self):
        (res, _), _ = self.post("/api/sites/clone", {"repo": "elden-co/crm", "category": "elden"})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["site", "clone", "elden-co/crm", "--category", "elden"])
        (res, _), _ = self.post("/api/sites/clone", {"repo": "me/blog", "name": "my-blog", "category": "personal"})
        self.assertEqual(self.cli.calls[-1][0], ["site", "clone", "me/blog", "--category", "personal", "--name", "my-blog"])

    def test_clone_rejects_unsafe_repositories(self):
        for repo in ("me/blog; rm -rf ~", "--upload-pack=x/y", "https://evil/x", "me"):
            (res, _), _ = self.post("/api/sites/clone", {"repo": repo, "category": "elden"})
            self.assertEqual(res.status, 400, repo)


class SetupTest(SitesTest):
    def test_token_goes_to_stdin_never_into_arguments(self):
        token = "ghp_" + "A" * 36
        (res, _), _ = self.post("/api/setup/github/token", {"token": token})
        self.assertEqual(res.status, 200)
        args, _ = self.cli.calls[-1]
        self.assertEqual(args, ["github", "login", "--with-token"])
        self.assertNotIn(token, " ".join(args))
        self.assertEqual(self.cli.last_input, token + "\n")

    def test_bad_tokens_rejected_before_devctl(self):
        for token in ("password123", "ghp_short", "ghp_" + "A" * 36 + "\nrm", "", None):
            (res, _), _ = self.post("/api/setup/github/token", {"token": token})
            self.assertEqual(res.status, 400, token)
        self.assertEqual(self.cli.calls, [])

    def test_device_login_runs_as_a_job(self):
        (res, body), _ = self.post("/api/setup/github/login", {})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["github", "login"])

    def test_git_identity(self):
        (res, _), _ = self.post("/api/setup/git-identity", {"name": "Zaitoune M", "email": "me@example.com"})
        self.assertEqual(res.status, 200)
        self.assertEqual(self.cli.calls[-1][0], ["github", "identity", "--name", "Zaitoune M", "--email", "me@example.com"])
        for body in ({"name": "", "email": "me@example.com"}, {"name": "x", "email": "not-an-email"}, {"name": "a\nb", "email": "me@example.com"}):
            (res, _), _ = self.post("/api/setup/git-identity", body)
            self.assertEqual(res.status, 400, body)

    def test_unknown_setup_action(self):
        (res, _), _ = self.post("/api/setup/github/rm", {})
        self.assertEqual(res.status, 404)


class UploadTest(SitesTest):
    def upload(self, name, data):
        if not hasattr(self, "_auth"):
            self._auth = self.login()  # login codes work once: log in once per test
        cookie, csrf = self._auth
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/api/upload", body=data, headers={
            "Host": f"127.0.0.1:{self.port}", "Cookie": cookie, "X-Devctl-CSRF": csrf,
            "X-Filename": name, "Content-Type": "application/octet-stream"})
        res = conn.getresponse()
        body = json.loads(res.read() or b"{}")
        conn.close()
        return res.status, body

    def test_upload_stored_privately_and_used_by_id(self):
        status, body = self.upload("crm.sql.gz", b"\x1f\x8bdump")
        self.assertEqual(status, 200)
        upload = body["upload"]
        path = self.settings.upload_dir / upload
        self.assertEqual(path.read_bytes(), b"\x1f\x8bdump")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        (res, _), _ = self.post("/api/sites/db", {"name": "crm", "engine": "mysql", "fill": "import", "upload": upload})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["site", "db", "crm", "--engine", "mysql", "--fill", "import", "--file", str(path)])

    def test_upload_rejects_other_files(self):
        self.assertEqual(self.upload("evil.sh", b"rm -rf ~")[0], 400)

    def test_upload_name_never_becomes_a_path(self):
        # Regression: the extension used to be split from the client's name ("./../x.sql").
        for evil in ("../../x.sql", "a/../../b.sql.gz", "..\\..\\c.dump", "x.sql/../../y.sql"):
            self.assertEqual(self.upload(evil, b"x")[0], 400, evil)
        status, body = self.upload("my.backup.sql.gz", b"x")
        self.assertEqual(status, 200)
        self.assertRegex(body["upload"], r"^[0-9a-f]{24}\.sql\.gz$")
        self.assertEqual([p.name for p in self.settings.upload_dir.iterdir()], [body["upload"]])
        self.assertFalse(any(self.settings.run_dir.parent.glob("**/x.sql")))

    def test_browser_cannot_choose_a_path(self):
        for upload in ("/etc/shadow", "../../.ssh/id_rsa", "deadbeef.sql", None):
            (res, _), _ = self.post("/api/sites/db", {"name": "crm", "engine": "mysql", "fill": "import", "upload": upload})
            self.assertEqual(res.status, 400, upload)
        self.assertEqual(self.cli.calls, [])

    def test_clone_with_database_options(self):
        (res, _), _ = self.post("/api/sites/clone", {"repo": "me/crm", "category": "elden", "engine": "auto", "fill": "migrate"})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["site", "clone", "me/crm", "--category", "elden", "--db", "auto", "--fill", "migrate"])
        (res, _), _ = self.post("/api/sites/clone", {"repo": "me/crm", "category": "elden", "engine": "oracle"})
        self.assertEqual(res.status, 400)


class PagesTest(SitesTest):
    def get(self, path):
        if not hasattr(self, "_auth"):
            self._auth = self.login()
        return self.request("GET", path, cookie=self._auth[0])

    def test_logs_part_and_size_checked(self):
        res, body = self.get("/api/logs?site=shop&part=web&lines=100")
        self.assertEqual(res.status, 200)
        self.assertEqual(len(json.loads(body)["lines"]), 100)
        self.assertEqual(self.cli.calls[-1][0], ["logs", "shop", "--web", "-n", "100"])
        for bad in ("site=shop&part=all", "site=../x&part=web", "site=shop;rm&part=app"):
            self.assertEqual(self.get("/api/logs?" + bad)[0].status, 400, bad)

    def test_database_actions_are_fixed_commands(self):
        (res, _), _ = self.post("/api/db/create", {"name": "shop_v2", "engine": "postgres"})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["db", "create", "shop_v2", "--engine", "postgres"])
        (res, _), _ = self.post("/api/db/server", {"server": "mysql-8-4", "action": "stop"})
        self.assertEqual(self.cli.calls[-1][0], ["db", "stop", "mysql-8-4"])
        (res, _), _ = self.post("/api/db/export", {"name": "shop"})
        self.assertEqual(self.cli.calls[-1][0], ["db", "export", "shop"])
        self.assertEqual(self.cli.last_cwd, str(self.settings.export_dir))
        for body in ({"name": "Shop", "engine": "mysql"}, {"name": "shop", "engine": "oracle"}, {"name": "x;y", "engine": "mysql"}):
            (res, _), _ = self.post("/api/db/create", body)
            self.assertEqual(res.status, 400, body)

    def test_import_needs_an_upload_and_passes_the_typed_name(self):
        (res, _), _ = self.post("/api/db/import", {"name": "shop", "upload": "/etc/passwd"})
        self.assertEqual(res.status, 400)

    def test_export_download_only_from_the_exports_folder(self):
        folder = self.settings.export_dir
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "shop-mysql-20261111-101500.sql.gz").write_bytes(b"\x1f\x8bok")
        res, body = self.get("/api/exports/shop-mysql-20261111-101500.sql.gz")
        self.assertEqual(res.status, 200)
        self.assertEqual(body, b"\x1f\x8bok")
        self.assertIn("attachment", res.getheader("Content-Disposition"))
        for bad in ("../dashboard.json", "..%2fdashboard.json", "shop-mysql-1-2.sql.gz", "x.gz"):
            self.assertEqual(self.get("/api/exports/" + bad)[0].status, 404, bad)

    def test_service_actions(self):
        (res, _), _ = self.post("/api/svc/action", {"name": "mailpit", "action": "start"})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["svc", "start", "mailpit"])
        (res, _), _ = self.post("/api/svc/action", {"name": "mailpit", "action": "rm"})
        self.assertEqual(res.status, 400)


class SharedDbTest(SitesTest):
    def test_existing_database_choices(self):
        (res, _), _ = self.post("/api/sites/clone", {"repo": "me/panel", "category": "elden", "engine": "use:domi_api", "fill": "none"})
        self.assertEqual(res.status, 202)
        self.assertEqual(self.cli.calls[-1][0], ["site", "clone", "me/panel", "--category", "elden", "--use-db", "domi_api", "--fill", "none"])
        (res, _), _ = self.post("/api/sites/db", {"name": "panel", "engine": "use:domi_api", "fill": "none"})
        self.assertEqual(self.cli.calls[-1][0], ["site", "db", "panel", "--use", "domi_api", "--fill", "none"])
        (res, _), _ = self.post("/api/sites/create", {"name": "panel", "category": "elden", "template": "laravel-blade", "engine": "use:domi_api"})
        self.assertEqual(self.cli.calls[-1][0], ["site", "create", "panel", "--template", "laravel-blade", "--category", "elden", "--use-db", "domi_api"])
        for bad in ("use:../x", "use:", "use:a;b", "use:Domi"):
            (res, _), _ = self.post("/api/sites/create", {"name": "p2", "category": "elden", "template": "laravel-blade", "engine": bad})
            self.assertEqual(res.status, 400, bad)


class RepoListTest(SitesTest):
    def test_cached_and_refresh_flags(self):
        cookie, _ = self.login()
        for path, args in (("/api/github/repos", ["github", "repos"]),
                           ("/api/github/repos?cached=1", ["github", "repos", "--cached"]),
                           ("/api/github/repos?refresh=1", ["github", "repos", "--refresh"])):
            self.request("GET", path, cookie=cookie)
            self.assertEqual(self.cli.calls[-1][0], args, path)
