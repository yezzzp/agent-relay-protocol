"""SessionStart hook: inject the workflow, or ask once, or stay silent.

Called by hooks/hooks.json with the hook payload on stdin. It must be fast and it
must never fail the session: any error prints nothing and exits 0.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

from agentcore import audit, db
from agentcore.config import git_root, load_project, load_user

HELP = "Session-start hook (used by the plugin; prints context for the agent)."
SKILL_DIR = Path(__file__).resolve().parents[2] / "skills" / "work"
PIECE_RE = re.compile(r"<!-- piece:(?P<name>[\w-]+) -->\n(?P<body>.*?)<!-- /piece -->\n?", re.S)


def register(parser) -> None:
    parser.add_argument("--event", default="startup", help="startup | clear | compact | resume")
    parser.add_argument("--cwd", default=None, help="override the payload's cwd")
    parser.set_defaults(func=run)


def workflow(pieces: list[str] | None) -> str:
    text = (SKILL_DIR / "WORKFLOW.md").read_text()
    head = text.split("<!-- piece:", 1)[0].rstrip() + "\n"
    parts = [
        m.group("body").strip() for m in PIECE_RE.finditer(text)
        if pieces is None or m.group("name") in pieces
    ]
    return head + "\n" + "\n\n".join(parts) + "\n"


def frontmatter(text: str) -> dict:
    if not text.startswith("---"):
        return {}
    block = text.split("---", 2)[1]
    return dict(
        (k.strip(), v.strip()) for k, _, v in (line.partition(":") for line in block.splitlines()) if k.strip()
    )


def active_tasks(root: Path) -> list[tuple[Path, dict, str]]:
    folder = root / "docs" / "ai" / "tasks"
    found = []
    for path in sorted(folder.glob("*.md")) if folder.is_dir() else []:
        text = path.read_text(errors="ignore")
        meta = frontmatter(text)
        if meta.get("status") in {"IN_PROGRESS", "HANDOFF"}:
            found.append((path, meta, text))
    return found


def section(text: str, title: str) -> str:
    match = re.search(rf"^## {re.escape(title)}\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return match.group(1).strip() if match else ""


def next_step(text: str) -> str:
    match = re.search(r"^\s*- \[ \] (.+)$", text, re.M)
    return match.group(1).strip() if match else "no open task"


def sessions_count(root: Path) -> str:
    run_py = Path(__file__).resolve().parents[1] / "run.py"
    try:
        out = subprocess.run(
            [sys.executable, "-I", str(run_py), "sessions", "--count"],
            cwd=root, capture_output=True, text=True, timeout=1.5,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def project_lines(root: Path) -> list[str]:
    project = load_project(root)
    if project is None or not project.has_config:
        return ["No `.arp/config.toml` yet: use the commands in AGENTS.md or README."]
    c = project.config
    lines = [f"- {k}: `{v}`" for k, v in c["verify"].items() if v]
    lines.append(f"- branches: integration `{c['branches']['integration']}`, production `{c['branches']['production']}`")
    env = c["env"]
    if env.get("db_prefix"):
        lines.append(f"- test database prefix `{env['db_prefix']}`; first ports web {env['web_port']}, api {env['api_port']}")
    flows = ", ".join(project.flows) if project.flows else "none listed"
    lines.append(f"- user flows: {flows}")
    if count := sessions_count(root):
        lines.append(f"- sessions: {count}")
    return ["## This project", *lines]


def task_lines(root: Path, event: str) -> list[str]:
    lines = []
    for path, meta, text in active_tasks(root):
        rel = path.relative_to(root)
        lines.append(f"## Active task: `{rel}` ({meta.get('status')}, owner {meta.get('owner', '?')})")
        lines.append(f"Next: {next_step(section(text, 'Tasks') or text)}")
        if event == "compact" and (specs := section(text, "Specs")):
            lines += ["The owner's words (verbatim, they still apply):", specs]
    return lines


def test_report_lines(conn, project, root: Path) -> list[str]:
    from agentcore import cmd_test_report as report

    cfg = load_project(root)
    every = int(cfg.config["tests"].get("report_every_days", 7)) if cfg else 7
    if report.has_runs(conn, project["id"]) and report.is_due(project["name"], every):
        report.start_in_background(root)
    return report.session_lines(project["name"])


def ask_lines(facts: dict) -> list[str]:
    return [
        "# agent-core: first visit to this project",
        *audit.summary(facts),
        "",
        "Before the first task, ask the owner ONCE with AskUserQuestion whether this project uses",
        "agent-core's way of working (worktrees, tests chosen before code, scripted integration, memory):",
        "1. Adopt everything: run `arp adopt`, then offer `agent-init` to fill only what is missing.",
        "   Existing files win; nothing in the repo is written without the owner's yes.",
        "2. Choose pieces (multi-select: workflow, worktrees, integrator, tests, ui-check, style, memory,",
        "   relay): run `arp adopt --state partial --pieces <list>`.",
        "3. Not in this project: run `arp decline`. Say it can be undone with `arp audit`.",
        "Record the answer with the command before doing anything else. Then go on with the request.",
    ]


def render(cwd: Path, event: str) -> str:
    user = load_user()
    root = git_root(cwd)
    if root is None:
        if user.get("default") == "off":
            return ""
        return workflow(None) + (
            "\nThis folder is not a git repo. If it is a new project, offer `git init` and then "
            "`agent-init` to set how it works before any feature.\n"
        )

    conn = db.connect()
    project = db.ensure_project(conn, root)
    reg = db.registry(conn, project["id"])
    state = reg["state"] if reg else "unknown"
    facts = audit.audit(root)

    if state == "unknown":
        default = user.get("default", "ask")
        if default == "off":
            return ""
        if default == "on":
            db.set_registry(conn, project["id"], "adopted", audit_hash=audit.significant(facts))
            state = "adopted"
        else:
            return "\n".join(ask_lines(facts)) + "\n"

    if state == "declined":
        return ""

    pieces = None if state == "adopted" else [p for p in reg["pieces"].split(",") if p]
    out = [workflow(pieces).rstrip(), ""]
    out += project_lines(root)
    out += task_lines(root, event)
    if pieces is None or "tests" in pieces:
        out += test_report_lines(conn, project, root)

    new_hash = audit.significant(facts)
    if reg and reg["audit_hash"] and reg["audit_hash"] != new_hash:
        out += ["", "Note: the project changed since it was adopted:", *audit.summary(facts),
                "Mention it once to the owner if it affects the workflow."]
    if not reg or reg["audit_hash"] != new_hash:
        db.set_registry(conn, project["id"], state, pieces=pieces or [], audit_hash=new_hash)
    return "\n".join(out).rstrip() + "\n"


def run(args) -> int:
    try:
        payload = {}
        if not sys.stdin.isatty():
            raw = sys.stdin.read()
            payload = json.loads(raw) if raw.strip() else {}
        cwd = Path(args.cwd or payload.get("cwd") or ".").resolve()
        event = payload.get("source") or args.event
        sys.stdout.write(render(cwd, event))
    except Exception as exc:  # the hook must never break a session
        print(f"[agent-core] session-start skipped: {exc}", file=sys.stderr)
    return 0
