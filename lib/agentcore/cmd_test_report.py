"""Periodic test-health report, one per project, every ``tests.report_every_days``.

Nothing runs in the background on its own. The session-start hook checks
whether a project's report is due, and if so starts this command detached. The
report lands in ``~/.local/share/agent-core/reports/<project>-<id>/`` as
``test-health-<date>.html``, plus ``latest.json``. The next session reads
``latest.json``, tells the owner what changed, and offers to publish the page.
"""

import json
import os
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path

from agentcore import cmd_test_health as health
from agentcore import db
from agentcore.config import load_project

HELP = "Write this project's periodic test-health report (--if-due: only when it is due)."


def register(parser) -> None:
    parser.add_argument("--if-due", action="store_true", help="do nothing unless the last report is old enough")
    parser.add_argument("--path", default=".", help="the project folder")
    parser.set_defaults(func=run)


def reports_dir(project) -> Path:
    """One folder per project row, so two repos both named `app` never share reports."""
    return db.db_path().parent / "reports" / f"{project['name']}-{project['id']}"


def latest(project) -> dict | None:
    path = reports_dir(project) / "latest.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def is_due(project, every_days: int) -> bool:
    last = latest(project)
    if not last:
        return True
    try:
        age = (date.today() - date.fromisoformat(last["date"])).days
    except (KeyError, ValueError):
        return True
    return age >= every_days


def has_runs(conn, project_id: int) -> bool:
    return conn.execute("SELECT 1 FROM runs WHERE project_id = ? LIMIT 1", (project_id,)).fetchone() is not None


def start_in_background(root: Path) -> None:
    """Start ``arp test-report --if-due`` detached. It never slows the caller."""
    run_py = Path(__file__).resolve().parents[1] / "run.py"
    try:
        subprocess.Popen(
            [sys.executable, "-I", str(run_py), "test-report", "--if-due", "--path", str(root)],
            cwd=root, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, env=os.environ.copy(),
        )
    except OSError:
        pass


def write(conn, project, suspect_runs: int) -> dict:
    health.refresh_coverage(conn, project)
    data = health.collect(conn, project, suspect_runs)
    folder = reports_dir(project)
    folder.mkdir(parents=True, exist_ok=True)
    today = date.today().isoformat()
    html = folder / f"test-health-{today}.html"
    html.write_text(health.render_html([data], suspect_runs))

    previous = latest(project) or {}
    old_suspects = set(previous.get("suspects", []))
    suspects = [f"{t['file']}::{t['name']}" for t in data["suspects"]]
    flaky = [f"{t['file']}::{t['name']}" for t in data["flaky"]]
    info = {
        "date": today,
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "html": str(html),
        "tests": data["tests"],
        "runs": data["runs"],
        "suite_s": round(data["suite_s"], 1),
        "flaky": flaky,
        "suspects": suspects,
        "new_suspects": [s for s in suspects if s not in old_suspects],
        "has_coverage": data["has_coverage"],
        "previous": previous.get("date"),
    }
    (folder / "latest.json").write_text(json.dumps(info, indent=2))
    return info


def session_lines(project) -> list[str]:
    """What the session-start hook says about the latest report."""
    last = latest(project)
    if not last:
        return []
    line = (
        f"## Test health ({last['date']})\n"
        f"{last['tests']} tests · suite {last['suite_s']} s · {len(last['flaky'])} flaky · "
        f"{len(last['suspects'])} suspects ({len(last['new_suspects'])} new)"
    )
    out = [line, f"Report: `{last['html']}`"]
    if last["new_suspects"] or last["flaky"]:
        out.append(
            "Tell the owner once, in one line. If they want to see it, publish the HTML as a private "
            "artifact. Suspects get `arp test-health --mutate <test>` before anyone deletes them."
        )
    return out


def run(args) -> int:
    project_cfg = load_project(args.path)
    if project_cfg is None:
        print("Not a git repo.")
        return 1
    conn = db.connect()
    project = db.ensure_project(conn, project_cfg.root)
    every = int(project_cfg.config["tests"].get("report_every_days", 7))
    if args.if_due and (not has_runs(conn, project["id"]) or not is_due(project, every)):
        return 0
    info = write(conn, project, int(project_cfg.config["tests"]["suspect_runs"]))
    print(f"{project['name']}: {info['html']}")
    print(f"{info['tests']} tests, {len(info['flaky'])} flaky, {len(info['suspects'])} suspects "
          f"({len(info['new_suspects'])} new since {info['previous'] or 'the first report'})")
    return 0
