"""Run a test command, pass its exit code through and record the results.

Capture never edits the project's tests or config:

* pytest: ``PYTEST_ADDOPTS`` gets ``--junitxml=<tmp>`` (works through ``uv run``,
  ``make``, scripts, xdist). A command that sets its own ``--junitxml`` wins and
  is then not captured.
* Playwright: ``PLAYWRIGHT_JSON_OUTPUT_FILE=<tmp>`` is always set, and when the
  command line contains ``playwright test`` the flag ``--reporter=list,json`` is
  inserted right after it (replacing the project's reporters for that run).
  When Playwright runs behind a package script (``pnpm e2e``) the command cannot
  be rewritten: the run is captured only if the project's config already has the
  json reporter; otherwise use ``arp test-record --playwright-json``.
"""

import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from agentcore import config, db, testdata

HELP = "Run a test command, keep its exit code and record per-test results."

PW_RE = re.compile(r"(playwright\s+test)\b")


def register(parser) -> None:
    parser.add_argument("--tier", required=True, choices=["unit", "e2e", "e2e_full"])
    parser.add_argument("--runner", default="session", choices=["session", "integrator"])
    parser.add_argument("cmd", nargs="*", help="command after --; one argument is a shell string")
    parser.set_defaults(func=run)


def _inject_playwright(cmd: list[str] | str):
    if isinstance(cmd, str):
        if "--reporter" in cmd:
            return cmd
        return PW_RE.sub(r"\1 --reporter=list,json", cmd, count=1)
    if "playwright" in " ".join(cmd) and "test" in cmd and not any(c.startswith("--reporter") for c in cmd):
        i = cmd.index("test")
        return [*cmd[: i + 1], "--reporter=list,json", *cmd[i + 1 :]]
    return cmd


def run(args) -> int:
    cmd = list(args.cmd)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("arp test-run: no command given (usage: arp test-run --tier unit -- <command>).", file=sys.stderr)
        return 2
    project = config.load_project(".")
    recording = bool(project and project.get("tests", "record"))
    shell = len(cmd) == 1
    command = cmd[0] if shell else shlex.join(cmd)
    to_run: list[str] | str = cmd[0] if shell else cmd
    env = dict(os.environ)
    tmp = Path(tempfile.mkdtemp(prefix="arp-test-run-"))
    junit, pw = tmp / "junit.xml", tmp / "playwright.json"
    if recording:
        env["PYTEST_ADDOPTS"] = f"{env.get('PYTEST_ADDOPTS', '')} --junitxml={shlex.quote(str(junit))}".strip()
        env["PLAYWRIGHT_JSON_OUTPUT_FILE"] = str(pw)
        to_run = _inject_playwright(to_run)
    start = time.monotonic()
    try:
        proc = subprocess.run(to_run, shell=shell, env=env, check=False)
        code = proc.returncode if proc.returncode >= 0 else 128 - proc.returncode
    except FileNotFoundError as exc:
        print(f"arp test-run: {exc}", file=sys.stderr)
        code = 127
    elapsed = time.monotonic() - start
    if recording:
        _record(project, args, command, junit, pw, elapsed)
    for f in tmp.glob("*"):
        f.unlink()
    tmp.rmdir()
    return code


def _record(project, args, command, junit: Path, pw: Path, elapsed: float) -> None:
    results: list[testdata.Result] = []
    for path, parse in ((junit, lambda p: testdata.parse_junit(p, project.root)), (pw, testdata.parse_playwright)):
        if path.is_file() and path.stat().st_size:
            try:
                results += parse(path)[0]
            except Exception as exc:
                print(f"arp test-run: could not read {path.name}: {exc}", file=sys.stderr)
    conn = db.connect()
    row = db.ensure_project(conn, project.root)
    run_id = testdata.record(conn, row, args.tier, args.runner, command, results, elapsed, project.root)
    if not results:
        print(
            f"arp test-run: no per-test results captured; run {run_id} recorded with no results "
            "(use arp test-record on a report file).",
            file=sys.stderr,
        )
    else:
        print(f"arp test-run: recorded run {run_id} with {len(results)} tests.", file=sys.stderr)
