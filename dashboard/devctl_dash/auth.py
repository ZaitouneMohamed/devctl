"""Authentication for a dashboard that is only reachable from this laptop.

Threats handled: other web pages in the browser (CSRF, DNS rebinding) and other local
users. Login uses one-time codes that `devctl dashboard` writes as 0600 files; a code
is exchanged for an HttpOnly, SameSite=Strict session cookie.
"""

from __future__ import annotations

import hmac
import os
import re
import secrets
import threading
import time
from dataclasses import dataclass, field
from http.cookies import CookieError, SimpleCookie
from pathlib import Path

COOKIE_NAME = "devctl_session"
LOGIN_CODE_TTL_SECONDS = 120
SESSION_TTL_SECONDS = 12 * 3600
_CODE_RE = re.compile(r"[A-Za-z0-9_-]{20,128}")


@dataclass
class Session:
    id: str
    csrf: str
    created: float = field(default_factory=time.time)

    def expired(self, now: float | None = None) -> bool:
        return (now or time.time()) - self.created > SESSION_TTL_SECONDS


class Auth:
    def __init__(self, login_dir: Path, allowed_hosts: set[str]):
        self.login_dir = login_dir
        self.allowed_hosts = allowed_hosts
        self._sessions: dict[str, Session] = {}
        self._lock = threading.Lock()

    def host_allowed(self, host: str | None) -> bool:
        """Reject requests whose Host is not ours (blocks DNS-rebinding attacks)."""
        return host is not None and host in self.allowed_hosts

    def redeem_login_code(self, code: str) -> Session | None:
        """Exchange a one-time login code for a new session. Each code works once."""
        if not _CODE_RE.fullmatch(code or ""):
            return None
        path = self.login_dir / code
        try:
            st = path.stat()
            path.unlink()  # one-time: whoever unlinks first wins
        except (FileNotFoundError, NotADirectoryError):
            return None
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            return None
        if time.time() - st.st_mtime > LOGIN_CODE_TTL_SECONDS:
            return None
        session = Session(id=secrets.token_urlsafe(32), csrf=secrets.token_urlsafe(32))
        with self._lock:
            self._sessions[session.id] = session
        return session

    def session_from_cookie(self, cookie_header: str | None) -> Session | None:
        if not cookie_header:
            return None
        try:
            cookie = SimpleCookie(cookie_header)
        except CookieError:
            return None
        morsel = cookie.get(COOKIE_NAME)
        if morsel is None:
            return None
        with self._lock:
            session = self._sessions.get(morsel.value)
            if session and session.expired():
                del self._sessions[session.id]
                return None
        return session

    @staticmethod
    def csrf_ok(session: Session, header_value: str | None) -> bool:
        return header_value is not None and hmac.compare_digest(session.csrf, header_value)

    @staticmethod
    def cookie_header(session: Session) -> str:
        return f"{COOKIE_NAME}={session.id}; HttpOnly; SameSite=Strict; Path=/"
