import os
import tempfile
import time
import unittest
from pathlib import Path

from devctl_dash.auth import Auth, COOKIE_NAME, LOGIN_CODE_TTL_SECONDS

CODE = "A" * 43


class AuthTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.auth = Auth(self.dir, {"127.0.0.1:7780"})

    def tearDown(self):
        self.tmp.cleanup()

    def make_code(self, name=CODE, mode=0o600, age=0):
        path = self.dir / name
        path.touch(mode=mode)
        os.chmod(path, mode)
        if age:
            t = time.time() - age
            os.utime(path, (t, t))
        return name

    def test_code_works_once(self):
        code = self.make_code()
        session = self.auth.redeem_login_code(code)
        self.assertIsNotNone(session)
        self.assertIsNone(self.auth.redeem_login_code(code))

    def test_expired_code_rejected(self):
        self.assertIsNone(self.auth.redeem_login_code(self.make_code(age=LOGIN_CODE_TTL_SECONDS + 5)))

    def test_code_readable_by_others_rejected(self):
        self.assertIsNone(self.auth.redeem_login_code(self.make_code(mode=0o644)))

    def test_malformed_codes_rejected(self):
        for bad in ["", "short", "../" + CODE, CODE + "/x", "A" * 200, "A" * 30 + " "]:
            self.assertIsNone(self.auth.redeem_login_code(bad), bad)

    def test_cookie_round_trip(self):
        session = self.auth.redeem_login_code(self.make_code())
        header = self.auth.cookie_header(session)
        self.assertIn("HttpOnly", header)
        self.assertIn("SameSite=Strict", header)
        found = self.auth.session_from_cookie(f"other=1; {COOKIE_NAME}={session.id}")
        self.assertEqual(found, session)
        self.assertIsNone(self.auth.session_from_cookie(f"{COOKIE_NAME}=nope"))
        self.assertIsNone(self.auth.session_from_cookie(None))

    def test_host_check(self):
        self.assertTrue(self.auth.host_allowed("127.0.0.1:7780"))
        for bad in [None, "", "evil.example:7780", "127.0.0.1", "127.0.0.1:7781", "localhost:7780"]:
            self.assertFalse(self.auth.host_allowed(bad), bad)

    def test_csrf(self):
        session = self.auth.redeem_login_code(self.make_code())
        self.assertTrue(Auth.csrf_ok(session, session.csrf))
        self.assertFalse(Auth.csrf_ok(session, None))
        self.assertFalse(Auth.csrf_ok(session, "wrong"))


if __name__ == "__main__":
    unittest.main()
