"""The only way the dashboard changes anything: run the devctl CLI.

Arguments are fixed lists chosen by the server code, never strings from the browser,
and nothing is run through a shell. User input (like a typed confirmation) is passed as
a single argument value that the CLI validates again.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass


@dataclass
class CliResult:
    exit: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.exit == 0

    def error_message(self) -> str:
        lines = [l for l in self.stderr.splitlines() if l.strip()]
        return lines[-1].removeprefix("error: ") if lines else f"devctl exited with code {self.exit}"


class CliError(Exception):
    def __init__(self, result: CliResult):
        super().__init__(result.error_message())
        self.result = result


class Cli:
    def __init__(self, devctl_bin: str, timeout: int = 120):
        self.devctl_bin = devctl_bin
        self.timeout = timeout

    def run(self, args: list[str], *, confirm: str | None = None, yes: bool = False,
            input_text: str | None = None) -> CliResult:
        """input_text goes to devctl's stdin (secrets such as a token: never on a command line)."""
        argv = [self.devctl_bin, "--json", "--no-color"]
        if yes:
            argv.append("--yes")
        if confirm is not None:
            argv.append(f"--confirm={confirm}")
        argv += args
        env = dict(os.environ, DEVCTL_SOURCE="dashboard", NO_COLOR="1")
        try:
            proc = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=self.timeout,
                env=env,
                input=input_text,
                stdin=None if input_text is not None else subprocess.DEVNULL,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return CliResult(124, "", f"error: devctl did not finish within {self.timeout}s")
        except OSError as exc:
            return CliResult(127, "", f"error: cannot run devctl: {exc}")
        return CliResult(proc.returncode, proc.stdout, proc.stderr)

    def start(self, args: list[str], *, confirm: str | None = None, yes: bool = False,
              cwd: str | None = None) -> subprocess.Popen:
        """Start devctl in the background; stdout and stderr merged, line-buffered text."""
        argv = [self.devctl_bin, "--no-color"]
        if yes:
            argv.append("--yes")
        if confirm is not None:
            argv.append(f"--confirm={confirm}")
        argv += args
        env = dict(os.environ, DEVCTL_SOURCE="dashboard", NO_COLOR="1")
        return subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            text=True, bufsize=1, env=env, cwd=cwd,
        )

    def run_json(self, args: list[str], *, confirm: str | None = None):
        result = self.run(args, confirm=confirm)
        if not result.ok:
            raise CliError(result)
        try:
            return json.loads(result.stdout) if result.stdout.strip() else None
        except ValueError as exc:
            raise CliError(CliResult(1, result.stdout, f"error: devctl returned invalid JSON: {exc}")) from exc
