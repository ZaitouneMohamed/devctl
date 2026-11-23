"""Background jobs: long devctl commands (creating a site runs Composer and npm) whose
output the page shows while they run. Only the server decides what runs (fixed argv)."""

from __future__ import annotations

import itertools
import threading
import time
from dataclasses import dataclass, field

MAX_LINES = 4000
MAX_JOBS = 50


@dataclass
class Job:
    id: int
    title: str
    lines: list[str] = field(default_factory=list)
    exit: int | None = None
    started: float = field(default_factory=time.time)

    def snapshot(self, start: int) -> dict:
        return {"id": self.id, "title": self.title, "lines": self.lines[start:], "next": len(self.lines),
                "done": self.exit is not None, "exit": self.exit}


class Jobs:
    def __init__(self, cli):
        self.cli = cli
        self._jobs: dict[int, Job] = {}
        self._ids = itertools.count(1)
        self._lock = threading.Lock()

    def start(self, title: str, args: list[str], **kwargs) -> Job:
        job = Job(next(self._ids), title)
        proc = self.cli.start(args, **kwargs)
        with self._lock:
            self._jobs[job.id] = job
            for old in sorted(self._jobs)[:-MAX_JOBS]:
                del self._jobs[old]
        threading.Thread(target=self._pump, args=(job, proc), daemon=True).start()
        return job

    @staticmethod
    def _pump(job: Job, proc) -> None:
        for line in proc.stdout:
            job.lines.append(line.rstrip("\n"))
            if len(job.lines) > MAX_LINES:
                del job.lines[: len(job.lines) - MAX_LINES]
        job.exit = proc.wait()

    def get(self, job_id: int) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)
