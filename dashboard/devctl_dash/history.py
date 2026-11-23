"""SQLite index of devctl's history file (history.jsonl).

The JSON Lines file written by the CLI is the source of truth; this index only makes it
searchable and lets the live view ask "what is new since id N". When the file is
cleared or replaced, the index is rebuilt and its generation number goes up.
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

_SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    ts     TEXT NOT NULL,
    type   TEXT NOT NULL,
    source TEXT NOT NULL,
    name   TEXT NOT NULL,   -- action name or alert code
    status TEXT NOT NULL,   -- action result or alert level
    raw    TEXT NOT NULL    -- the original JSON object
);
CREATE INDEX IF NOT EXISTS events_type ON events(type);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


class HistoryIndex:
    def __init__(self, jsonl_path: Path, db_path: Path):
        self.jsonl_path = jsonl_path
        self.db_path = db_path
        self._lock = threading.Lock()
        db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self._connect() as db:
            db.executescript(_SCHEMA)

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        """One connection per use: commit on success, roll back on error, always close.

        (`with sqlite3.connect(...)` alone only commits; it never closes the connection.)
        """
        db = sqlite3.connect(self.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def _meta(db: sqlite3.Connection, key: str, default: int = 0) -> int:
        row = db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return int(row["value"]) if row else default

    @staticmethod
    def _set_meta(db: sqlite3.Connection, key: str, value: int) -> None:
        db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", (key, str(value)))

    def sync(self) -> int:
        """Import new complete lines from the file. Returns the number imported."""
        with self._lock, self._connect() as db:
            offset = self._meta(db, "offset")
            inode = self._meta(db, "inode")
            try:
                st = os.stat(self.jsonl_path)
            except FileNotFoundError:
                if offset:
                    self._reset(db)
                return 0
            if st.st_ino != inode or st.st_size < offset:
                self._reset(db)
                offset = 0
            if st.st_size == offset:
                return 0
            with open(self.jsonl_path, "rb") as f:
                f.seek(offset)
                data = f.read()
            end = data.rfind(b"\n") + 1  # leave a partial last line for the next sync
            imported = 0
            for line in data[:end].splitlines():
                event = _parse(line)
                if event is not None:
                    db.execute(
                        "INSERT INTO events(ts, type, source, name, status, raw) VALUES (?,?,?,?,?,?)",
                        event,
                    )
                    imported += 1
            self._set_meta(db, "offset", offset + end)
            self._set_meta(db, "inode", st.st_ino)
            return imported

    def _reset(self, db: sqlite3.Connection) -> None:
        db.execute("DELETE FROM events")
        self._set_meta(db, "offset", 0)
        self._set_meta(db, "generation", self._meta(db, "generation") + 1)

    def generation(self) -> int:
        with self._connect() as db:
            return self._meta(db, "generation")

    def query(
        self,
        *,
        after_id: int = 0,
        limit: int = 200,
        type_: str | None = None,
        source: str | None = None,
        text: str | None = None,
        newest_first: bool = True,
    ) -> list[dict]:
        sql = "SELECT id, raw FROM events WHERE id > ?"
        params: list = [after_id]
        if type_:
            sql += " AND type = ?"
            params.append(type_)
        if source:
            sql += " AND source = ?"
            params.append(source)
        if text:
            sql += " AND raw LIKE ? ESCAPE '\\'"
            params.append("%" + text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%")
        sql += " ORDER BY id " + ("DESC" if newest_first else "ASC") + " LIMIT ?"
        params.append(max(1, min(limit, 1000)))
        with self._connect() as db:
            return [{"id": row["id"], **json.loads(row["raw"])} for row in db.execute(sql, params)]

    def counts(self) -> dict[str, int]:
        with self._connect() as db:
            rows = db.execute("SELECT type, COUNT(*) AS n FROM events GROUP BY type").fetchall()
        return {row["type"]: row["n"] for row in rows}


def _parse(line: bytes) -> tuple | None:
    """Turn one JSON line into a row, or None if it is not a valid history record."""
    try:
        obj = json.loads(line)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(obj, dict) or obj.get("type") not in ("action", "alert"):
        return None
    if obj["type"] == "action":
        name, status = obj.get("action"), obj.get("result")
    else:
        name, status = obj.get("code"), obj.get("level")
    fields = (obj.get("ts"), obj["type"], obj.get("source"), name, status)
    if not all(isinstance(v, str) for v in fields):
        return None
    return (*fields, json.dumps(obj, separators=(",", ":")))
