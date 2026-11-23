"""Run a test command, pass its exit code through and record the results.

Capture never edits the project's tests or config:

* pytest: ``PYTEST_ADDOPTS`` gets ``-p arp_junit`` (lib/pytest_plugin, on
  ``PYTHONPATH``), so every pytest process writes its own JUnit file in
  ``$ARP_JUNIT_DIR``. It works through ``uv run``, ``make``, scripts and xdist,
  and two pytest calls in one command are both recorded. A command that sets
  its own ``--junitxml`` keeps it.
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
    if any(c.startswith("--reporter") for c in cmd):
        return cmd
    if "playwright" in " ".join(cmd) and "test" in cmd:
        i = cmd.index("test")
        return [*cmd[: i + 1], "--reporter=list,json", *cmd[i + 1 :]]
    # a whole shell line in one argument, as in `sh -c "cd web && playwright test"`
    return [_inject_playwright(c) if PW_RE.search(c) else c for c in cmd]


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
        plugin_dir = str(Path(__file__).resolve().parents[1] / "pytest_plugin")
        env["PYTHONPATH"] = os.pathsep.join(p for p in (plugin_dir, env.get("PYTHONPATH", "")) if p)
        env["ARP_JUNIT_DIR"] = str(tmp)
        env["PYTEST_ADDOPTS"] = f"{env.get('PYTEST_ADDOPTS', '')} -p arp_junit".strip()
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
        try:
            _record(project, args, command, junit, pw, elapsed)
        except Exception as exc:  # recording is a side effect: it never changes the test result
            print(f"arp test-run: results not recorded ({exc}); the tests' exit code stands.", file=sys.stderr)
    for f in tmp.glob("*"):
        f.unlink()
    tmp.rmdir()
    return code


def _record(project, args, command, junit: Path, pw: Path, elapsed: float) -> None:
    results: list[testdata.Result] = []
    reports = [(p, lambda f: testdata.parse_junit(f, project.root)) for p in sorted(junit.parent.glob("junit*.xml"))]
    for path, parse in [*reports, (pw, testdata.parse_playwright)]:
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
