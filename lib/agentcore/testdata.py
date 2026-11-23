"""Parse test reports and store them in the shared database.

Sources: pytest JUnit XML and the Playwright JSON reporter. Nothing is added
inside the project's own tests.
"""

import re
import sqlite3
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

from agentcore import db
from agentcore.config import git

FLOW_RE = re.compile(r"@flow(?:[\s:=]+)([A-Za-z0-9_-]+)")
OUTCOMES = ("pass", "fail", "skip", "flaky")


@dataclass
class Result:
    file: str
    name: str
    outcome: str
    duration: float = 0.0
    flow: str | None = None


def flow_of(*texts: str) -> str | None:
    for text in texts:
        if text and (m := FLOW_RE.search(text)):
            return m.group(1)
    return None


def tier_family(tier: str) -> str:
    return "e2e" if tier.startswith("e2e") else "unit"


def _merge(items: list[Result], rerun_is_flaky: bool) -> list[Result]:
    """Collapse repeated entries of one test (reruns, or one per browser project)."""
    order: dict[tuple[str, str], list[Result]] = {}
    for item in items:
        order.setdefault((item.file, item.name), []).append(item)
    merged = []
    for group in order.values():
        seen = {g.outcome for g in group}
        if rerun_is_flaky and "fail" in seen and "pass" in seen:
            outcome = "flaky"
        else:
            outcome = next(o for o in ("fail", "flaky", "pass", "skip") if o in seen)
        merged.append(
            Result(
                group[0].file,
                group[0].name,
                outcome,
                sum(g.duration for g in group),
                next((g.flow for g in group if g.flow), None),
            )
        )
    return merged


def _junit_location(classname: str, name: str, root: Path) -> tuple[str, str]:
    parts = classname.split(".") if classname else []
    for i in range(len(parts), 0, -1):
        candidate = "/".join(parts[:i]) + ".py"
        if (root / candidate).is_file():
            rest = parts[i:]
            return candidate, "::".join([*rest, name])
    if parts:
        return "/".join(parts) + ".py", name
    return "(unknown)", name


def parse_junit(path: Path, root: Path) -> tuple[list[Result], float | None]:
    tree = ET.parse(path)
    items: list[Result] = []
    total = 0.0
    suites = [tree.getroot()] if tree.getroot().tag == "testsuite" else list(tree.getroot())
    for suite in suites:
        total += float(suite.get("time") or 0)
        for case in suite.iter("testcase"):
            name = case.get("name") or ""
            file = case.get("file") or None
            if file:
                file = file.replace("\\", "/")
                cls = [p for p in (case.get("classname") or "").split(".") if p[:1].isupper()]
                full = "::".join([*cls, name])
            else:
                file, full = _junit_location(case.get("classname") or "", name, root)
            if case.find("failure") is not None or case.find("error") is not None:
                outcome = "fail"
            elif case.find("skipped") is not None:
                outcome = "skip"
            else:
                outcome = "pass"
            items.append(Result(file, full, outcome, float(case.get("time") or 0), flow_of(full)))
    return _merge(items, rerun_is_flaky=True), total or None


def _pw_flow(spec_title: str, test: dict, titles: list[str]) -> str | None:
    texts = [spec_title, *titles]
    tags = test.get("tags") or []
    texts += [t if isinstance(t, str) else str(t) for t in tags]
    if found := flow_of(*texts):
        return found
    for ann in test.get("annotations") or []:
        if ann.get("type") == "flow" and ann.get("description"):
            return str(ann["description"]).strip()
        if found := flow_of(str(ann.get("type", "")), str(ann.get("description", ""))):
            return found
    return None


def parse_playwright(path: Path) -> tuple[list[Result], float | None]:
    import json

    data = json.loads(path.read_text())
    items: list[Result] = []

    def walk(suite: dict, titles: list[str], file: str) -> None:
        file = suite.get("file") or file
        own = suite.get("title") or ""
        titles = titles if (not own or own == file or own.endswith((".ts", ".js"))) else [*titles, own]
        for spec in suite.get("specs", []):
            for test in spec.get("tests", []):
                status = test.get("status") or test.get("expectedStatus")
                outcome = {
                    "expected": "pass",
                    "unexpected": "fail",
                    "flaky": "flaky",
                    "skipped": "skip",
                }.get(status, "pass")
                dur = sum(r.get("duration", 0) for r in test.get("results", [])) / 1000
                name = " › ".join([*titles, spec.get("title", "")])
                flow = _pw_flow(spec.get("title", ""), test, titles)
                items.append(Result(spec.get("file") or file, name, outcome, dur, flow))
        for child in suite.get("suites", []):
            walk(child, titles, file)

    for suite in data.get("suites", []):
        walk(suite, [], suite.get("file") or "")
    stats = data.get("stats") or {}
    total = stats.get("duration")
    return _merge(items, rerun_is_flaky=False), (total / 1000 if total else None)


def record(
    conn: sqlite3.Connection,
    project: sqlite3.Row,
    tier: str,
    runner: str,
    command: str,
    results: list[Result],
    duration: float | None,
    cwd: Path | str = ".",
) -> int:
    stamp = db.now()
    branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD") or None
    sha = git(cwd, "rev-parse", "HEAD") or None
    if duration is None:
        duration = sum(r.duration for r in results)
    cur = conn.execute(
        "INSERT INTO runs (project_id, started_at, branch, commit_sha, command, tier, runner, duration_s) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (project["id"], stamp, branch, sha, command, tier, runner, duration),
    )
    run_id = cur.lastrowid
    family = tier_family(tier)
    for r in results:
        conn.execute(
            "INSERT INTO tests (project_id, file, name, tier, flow, first_seen, last_seen) "
            "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(project_id, file, name) DO UPDATE SET "
            "last_seen = excluded.last_seen, deleted_at = NULL, "
            "flow = COALESCE(excluded.flow, tests.flow), "
            "tier = CASE WHEN excluded.tier = 'e2e' THEN 'e2e' ELSE tests.tier END",
            (project["id"], r.file, r.name, family, r.flow, stamp, stamp),
        )
        test_id = conn.execute(
            "SELECT id FROM tests WHERE project_id = ? AND file = ? AND name = ?",
            (project["id"], r.file, r.name),
        ).fetchone()["id"]
        conn.execute(
            "INSERT OR REPLACE INTO results (run_id, test_id, outcome, duration_s) VALUES (?, ?, ?, ?)",
            (run_id, test_id, r.outcome, r.duration),
        )
    conn.execute(
        "INSERT INTO run_stats (run_id, tests, fails, flakies) VALUES (?, ?, ?, ?)",
        (
            run_id,
            len(results),
            sum(r.outcome == "fail" for r in results),
            sum(r.outcome == "flaky" for r in results),
        ),
    )
    conn.commit()
    return int(run_id)
