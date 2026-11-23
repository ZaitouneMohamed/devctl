import json
import tempfile
import unittest
from pathlib import Path

from devctl_dash.history import HistoryIndex


def action(name="site.create", result="ok", **extra):
    return {"type": "action", "ts": "2026-11-05T10:00:00+0100", "source": "cli",
            "action": name, "args": [], "result": result, "exit": 0, "duration_ms": 1, **extra}


class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.file = base / "history.jsonl"
        self.index = HistoryIndex(self.file, base / "db" / "history.sqlite")

    def tearDown(self):
        self.tmp.cleanup()

    def append(self, *objs, raw=None):
        with open(self.file, "a") as f:
            for obj in objs:
                f.write(json.dumps(obj) + "\n")
            if raw is not None:
                f.write(raw)

    def test_missing_file_is_empty(self):
        self.assertEqual(self.index.sync(), 0)
        self.assertEqual(self.index.query(), [])

    def test_incremental_import(self):
        self.append(action("a.one"))
        self.assertEqual(self.index.sync(), 1)
        self.append(action("a.two"))
        self.assertEqual(self.index.sync(), 1)
        self.assertEqual([e["action"] for e in self.index.query()], ["a.two", "a.one"])

    def test_partial_line_waits(self):
        self.append(action("a.one"), raw='{"type": "action", "ts"')
        self.assertEqual(self.index.sync(), 1)
        with open(self.file, "a") as f:
            f.write(': "x", "source": "cli", "action": "a.two", "result": "ok"}\n')
        self.assertEqual(self.index.sync(), 1)
        self.assertEqual(len(self.index.query()), 2)

    def test_bad_lines_skipped(self):
        self.append(action(), raw='not json\n{"type":"other"}\n[1,2]\n{"type":"action","ts":1}\n')
        self.assertEqual(self.index.sync(), 1)

    def test_clear_resets_and_bumps_generation(self):
        self.append(action("a.one"), action("a.two"))
        self.index.sync()
        gen = self.index.generation()
        self.file.write_text("")
        self.append(action("history.clear"))
        self.index.sync()
        self.assertEqual([e["action"] for e in self.index.query()], ["history.clear"])
        self.assertEqual(self.index.generation(), gen + 1)

    def test_replaced_file_detected_by_inode(self):
        self.append(action("a.one"), action("a.two"))
        self.index.sync()
        new = self.file.with_suffix(".new")
        new.write_text(json.dumps(action("b.one")) + "\n" + json.dumps(action("b.two")) + "\n" + json.dumps(action("b.three")) + "\n")
        new.replace(self.file)
        self.index.sync()
        self.assertEqual(len(self.index.query()), 3)

    def test_filters_and_like_escaping(self):
        alert = {"type": "alert", "ts": "t", "source": "timer", "level": "warn", "code": "disk-low", "message": "100% used"}
        self.append(action("site.create"), action("db.create", result="failed"), alert)
        self.index.sync()
        self.assertEqual(len(self.index.query(type_="alert")), 1)
        self.assertEqual(len(self.index.query(source="timer")), 1)
        self.assertEqual(len(self.index.query(text="db.create")), 1)
        self.assertEqual(len(self.index.query(text="100%")), 1)
        self.assertEqual(len(self.index.query(text="%")), 1)  # % is literal, not a wildcard
        self.assertEqual(self.index.counts(), {"action": 2, "alert": 1})

    def test_after_id_ascending(self):
        self.append(action("a"), action("b"), action("c"))
        self.index.sync()
        first = self.index.query(newest_first=False)[0]["id"]
        rows = self.index.query(after_id=first, newest_first=False)
        self.assertEqual([r["action"] for r in rows], ["b", "c"])


if __name__ == "__main__":
    unittest.main()
