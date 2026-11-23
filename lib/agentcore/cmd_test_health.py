"""Which tests earn their cost: cost, flakes, value, suspects, duplicates, trend."""

import html
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from agentcore import config, db, gitwt

HELP = "Report which tests earn their cost (--html for a page, --mutate to check one test)."

RETENTION_DAYS = 90
TEMPLATE = Path(__file__).resolve().parents[2] / "templates" / "report" / "test-health.html"
TEST_PATH = re.compile(r"(^|/)(tests?|__tests__|e2e)/|(^|/)test_[^/]*\.py$|_test\.py$|(^|/)conftest\.py$|\.spec\.[jt]s$")


def register(parser) -> None:
    parser.add_argument("--project", help="project name (default: the current repo)")
    parser.add_argument("--all", action="store_true", help="every project, compared")
    parser.add_argument("--html", metavar="OUT", help="write the HTML report here")
    parser.add_argument("--prune", action="store_true", help=f"fold results older than {RETENTION_DAYS} days into totals")
    parser.add_argument("--refresh-coverage", action="store_true", help="read .testmondata and count commits on covered code")
    parser.add_argument("--mutate", metavar="TEST", help="mutation-test the code a test covers (needs mutmut)")
    parser.set_defaults(func=run)


# ---------------------------------------------------------------- selection

def select_projects(conn, args) -> list[sqlite3.Row] | None:
    if args.all:
        return conn.execute("SELECT * FROM projects ORDER BY name").fetchall()
    if args.project:
        rows = conn.execute("SELECT * FROM projects WHERE name = ? OR key = ?", (args.project, args.project)).fetchall()
        if not rows:
            print(f"arp test-health: no project named {args.project!r}. See: arp projects", file=sys.stderr)
            return None
        return rows
    row = db.ensure_project(conn, ".")
    if row is None:
        print("arp test-health: not inside a git repository (use --project or --all).", file=sys.stderr)
        return None
    return [row]


# ---------------------------------------------------------------- coverage

def read_testmon(root: Path) -> tuple[dict[str, set[str]] | None, str]:
    """Map test node id -> source files, from pytest-testmon's database."""
    path = root / ".testmondata"
    if not path.is_file():
        return None, f"no .testmondata in {root}"
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        need = {"test_execution", "test_execution_file_fp", "file_fp"}
        if not need <= tables:
            return None, ".testmondata has an unknown layout (different testmon version)"
        cols = {r[1] for r in conn.execute("PRAGMA table_info(test_execution)")}
        if "test_name" not in cols:
            return None, ".testmondata has an unknown layout (different testmon version)"
        out: dict[str, set[str]] = {}
        for name, filename in conn.execute(
            "SELECT te.test_name, fp.filename FROM test_execution te "
            "JOIN test_execution_file_fp l ON l.test_execution_id = te.id "
            "JOIN file_fp fp ON fp.id = l.fingerprint_id"
        ):
            if filename:
                out.setdefault(name, set()).add(filename)
        conn.close()
        return out, ""
    except sqlite3.Error as exc:
        return None, f".testmondata unreadable: {exc}"


def source_files(files: set[str], root: Path) -> set[str]:
    out = set()
    for f in files:
        p = Path(f)
        if p.is_absolute():
            try:
                f = p.relative_to(root).as_posix()
            except ValueError:
                continue
        if not TEST_PATH.search(f):
            out.add(f)
    return out


def refresh_coverage(conn, project: sqlite3.Row) -> str:
    root = Path(project["path"])
    here = config.git_root(".")
    cover, why = read_testmon(here if here and (here / ".testmondata").is_file() else root)
    if cover is None and here and here != root:
        cover, why = read_testmon(root)
    if cover is None:
        return f"{project['name']}: coverage skipped, {why}."
    tests = conn.execute(
        "SELECT id, file, name, first_seen FROM tests WHERE project_id = ? AND deleted_at IS NULL", (project["id"],)
    ).fetchall()
    if not tests:
        return f"{project['name']}: no recorded tests to attach coverage to."
    oldest = min(t["first_seen"] for t in tests)
    log = config.git(root, "log", f"--since={oldest}", "--name-only", "--format=%x00%H %ct")
    by_file: dict[str, list[int]] = {}
    commits: dict[str, int] = {}
    for chunk in log.split("\x00")[1:]:
        head, *names = chunk.split("\n")
        sha, ct = head.split()
        commits[sha] = int(ct)
        for n in names:
            if n.strip():
                by_file.setdefault(n.strip(), []).append(sha)  # type: ignore[arg-type]
    stamp = db.now()
    done = 0
    for t in tests:
        files = cover.get(f"{t['file']}::{t['name']}")
        if not files:
            continue
        since = datetime.fromisoformat(t["first_seen"]).timestamp()
        shas = {s for f in source_files(files, root) for s in by_file.get(f, []) if commits[s] >= since}  # type: ignore[index]
        conn.execute(
            "INSERT INTO coverage_changes (test_id, commits, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(test_id) DO UPDATE SET commits = excluded.commits, updated_at = excluded.updated_at",
            (t["id"], len(shas), stamp),
        )
        done += 1
    conn.commit()
    return f"{project['name']}: coverage updated for {done} of {len(tests)} tests."


# ---------------------------------------------------------------- prune

def prune(conn, projects) -> str:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)).isoformat(timespec="seconds")
    folded = 0
    for p in projects:
        rows = conn.execute(
            "SELECT r.test_id, COUNT(*) n, SUM(r.outcome='pass') ps, SUM(r.outcome='fail') fs, "
            "SUM(r.outcome='flaky') fl, SUM(r.outcome='skip') sk, COALESCE(SUM(r.duration_s),0) d "
            "FROM results r JOIN runs u ON u.id = r.run_id WHERE u.project_id = ? AND u.started_at < ? "
            "GROUP BY r.test_id",
            (p["id"], cutoff),
        ).fetchall()
        for r in rows:
            conn.execute(
                "INSERT INTO test_totals (test_id, runs, passes, fails, flakies, skips, duration_s) "
                "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(test_id) DO UPDATE SET "
                "runs = runs + excluded.runs, passes = passes + excluded.passes, fails = fails + excluded.fails, "
                "flakies = flakies + excluded.flakies, skips = skips + excluded.skips, "
                "duration_s = duration_s + excluded.duration_s",
                (r["test_id"], r["n"], r["ps"], r["fs"], r["fl"], r["sk"], r["d"]),
            )
        cur = conn.execute(
            "DELETE FROM results WHERE run_id IN (SELECT id FROM runs WHERE project_id = ? AND started_at < ?)",
            (p["id"], cutoff),
        )
        folded += cur.rowcount
        root = Path(p["path"])
        if root.is_dir():
            trees = [w["path"] for w in gitwt.worktrees(root)] or [root]
            refs = [r for r in (config.load_project(root).config["branches"].values() if config.load_project(root) else [])
                    if isinstance(r, str) and "{" not in r]
            for t in conn.execute("SELECT id, file FROM tests WHERE project_id = ? AND deleted_at IS NULL", (p["id"],)):
                if not t["file"].endswith(".py") or any((w / t["file"]).exists() for w in trees):
                    continue
                if any(gitwt.git(root, "cat-file", "-e", f"{ref}:{t['file']}").returncode == 0 for ref in refs):
                    continue
                conn.execute("UPDATE tests SET deleted_at = ? WHERE id = ?", (db.now(), t["id"]))
    conn.commit()
    return f"Pruned: {folded} result rows older than {RETENTION_DAYS} days folded into per-test totals."


# ---------------------------------------------------------------- collection

def collect(conn, project: sqlite3.Row, suspect_runs: int) -> dict:
    pid = project["id"]
    tests = {
        r["id"]: dict(r, runs=0, fails=0, flakies=0, dur=0.0, mixed=0, tiers=set())
        for r in conn.execute(
            "SELECT t.*, c.commits FROM tests t LEFT JOIN coverage_changes c ON c.test_id = t.id "
            "WHERE t.project_id = ? AND t.deleted_at IS NULL",
            (pid,),
        )
    }
    for r in conn.execute(
        "SELECT r.test_id, COUNT(*) n, SUM(r.outcome='fail') f, SUM(r.outcome='flaky') fl, "
        "COALESCE(SUM(r.duration_s),0) d FROM results r JOIN runs u ON u.id = r.run_id "
        "WHERE u.project_id = ? GROUP BY r.test_id",
        (pid,),
    ):
        if r["test_id"] in tests:
            t = tests[r["test_id"]]
            t["runs"] += r["n"]; t["fails"] += r["f"]; t["flakies"] += r["fl"]; t["dur"] += r["d"]
    for r in conn.execute(
        "SELECT x.* FROM test_totals x JOIN tests t ON t.id = x.test_id WHERE t.project_id = ?", (pid,)
    ):
        if r["test_id"] in tests:
            t = tests[r["test_id"]]
            t["runs"] += r["runs"]; t["fails"] += r["fails"]; t["flakies"] += r["flakies"]; t["dur"] += r["duration_s"]
    for r in conn.execute(
        "SELECT r.test_id, u.commit_sha FROM results r JOIN runs u ON u.id = r.run_id "
        "WHERE u.project_id = ? AND u.commit_sha IS NOT NULL GROUP BY r.test_id, u.commit_sha "
        "HAVING SUM(r.outcome='fail') > 0 AND SUM(r.outcome='pass') > 0",
        (pid,),
    ):
        if r["test_id"] in tests:
            tests[r["test_id"]]["mixed"] += 1
    for r in conn.execute(
        "SELECT DISTINCT r.test_id, u.tier FROM results r JOIN runs u ON u.id = r.run_id WHERE u.project_id = ?", (pid,)
    ):
        if r["test_id"] in tests:
            tests[r["test_id"]]["tiers"].add("e2e" if r["tier"].startswith("e2e") else "unit")
    for t in tests.values():
        t["avg"] = t["dur"] / t["runs"] if t["runs"] else 0.0
    live = list(tests.values())

    files: dict[str, dict] = {}
    for t in live:
        f = files.setdefault(t["file"], {"file": t["file"], "tests": 0, "avg": 0.0})
        f["tests"] += 1
        f["avg"] += t["avg"]

    tiers = [dict(r) for r in conn.execute(
        "SELECT tier, COUNT(*) runs, COALESCE(SUM(duration_s),0) total, COALESCE(AVG(duration_s),0) avg "
        "FROM runs WHERE project_id = ? GROUP BY tier ORDER BY tier", (pid,))]
    trend = [dict(r) for r in conn.execute(
        "SELECT strftime('%Y-W%W', u.started_at) week, COUNT(*) runs, AVG(u.duration_s) avg_s, MAX(s.tests) tests "
        "FROM runs u LEFT JOIN run_stats s ON s.run_id = u.id WHERE u.project_id = ? "
        "GROUP BY week ORDER BY week", (pid,))]

    by_name: dict[str, list[dict]] = {}
    for t in live:
        by_name.setdefault(t["name"], []).append(t)
    duplicates = [
        {"kind": "same name", "name": n, "where": ", ".join(sorted(x["file"] for x in g))}
        for n, g in by_name.items() if len(g) > 1
    ]
    duplicates += [
        {"kind": "unit and e2e", "name": t["name"], "where": t["file"]} for t in live if len(t["tiers"]) > 1
    ]

    has_cov = any(t["commits"] is not None for t in live)
    suspects = sorted(
        (t for t in live if t["runs"] and not t["fails"] and not t["flakies"]
         and t["commits"] is not None and t["commits"] >= suspect_runs),
        key=lambda t: -t["commits"],
    )
    per_flow: dict[str, int] = {}
    for t in live:
        if t["flow"]:
            per_flow[t["flow"]] = per_flow.get(t["flow"], 0) + 1
    last = conn.execute(
        "SELECT AVG(duration_s) FROM (SELECT duration_s FROM runs WHERE project_id = ? ORDER BY started_at DESC LIMIT 5)",
        (pid,),
    ).fetchone()[0]
    return {
        "project": project["name"],
        "tests": len(live),
        "runs": sum(t["runs"] for t in tiers),
        "slow_tests": sorted(live, key=lambda t: -t["avg"])[:10],
        "slow_files": sorted(files.values(), key=lambda f: -f["avg"])[:10],
        "tiers": tiers,
        "flaky": sorted((t for t in live if t["flakies"] or t["mixed"]), key=lambda t: -(t["flakies"] + t["mixed"])),
        "value": sorted((t for t in live if t["fails"]), key=lambda t: -t["fails"])[:15],
        "suspects": suspects,
        "has_coverage": has_cov,
        "duplicates": duplicates,
        "trend": trend,
        "per_flow": per_flow,
        "suite_s": last or 0.0,
    }


# ---------------------------------------------------------------- output

def secs(v: float | None) -> str:
    return "-" if v is None else f"{v:.2f}s" if v < 60 else f"{v / 60:.1f}min"


def summary(d: dict, suspect_runs: int) -> str:
    lines = [f"{d['project']}: {d['tests']} tests, {d['runs']} runs, recent suite time {secs(d['suite_s'])}"]
    for t in d["tiers"]:
        lines.append(f"  tier {t['tier']}: {t['runs']} runs, {secs(t['total'])} total, {secs(t['avg'])} per run")
    lines.append(f"  flaky: {len(d['flaky'])}   caught a failure: {len(d['value'])}   duplicates: {len(d['duplicates'])}")
    if d["has_coverage"]:
        lines.append(f"  suspects (never failed, covered code changed >= {suspect_runs} commits): {len(d['suspects'])}")
    else:
        lines.append("  suspects: no coverage data yet (arp test-health --refresh-coverage)")
    for t in d["slow_tests"][:3]:
        lines.append(f"  slow: {secs(t['avg'])}  {t['file']}::{t['name']}")
    for t in d["flaky"][:3]:
        lines.append(f"  flaky: {t['file']}::{t['name']}")
    for t in d["suspects"][:3]:
        lines.append(f"  suspect: {t['commits']} commits  {t['file']}::{t['name']}")
    return "\n".join(lines)


def table(headers: list[str], rows: list[list], numeric: set[int] = frozenset()) -> str:
    if not rows:
        return '<p class="note">Nothing to report.</p>'
    head = "".join(f'<th class="n">{html.escape(h)}</th>' if i in numeric else f"<th>{html.escape(h)}</th>" for i, h in enumerate(headers))
    body = "".join(
        "<tr>" + "".join(
            f'<td class="n">{html.escape(str(c))}</td>' if i in numeric else f"<td>{c}</td>" for i, c in enumerate(r)
        ) + "</tr>" for r in rows
    )
    return f'<div class="scroll"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>'


def code(t: dict) -> str:
    return f"<code>{html.escape(t['file'])}::{html.escape(t['name'])}</code>"


def project_sections(d: dict, suspect_runs: int, heading: str = "h2") -> str:
    h = lambda s: f"<{heading}>{html.escape(s)}</{heading}>"
    out = [h(f"{d['project']} cost")]
    out.append(table(["Tier", "Runs", "Total", "Per run"],
                     [[html.escape(t["tier"]), t["runs"], secs(t["total"]), secs(t["avg"])] for t in d["tiers"]], {1, 2, 3}))
    out.append("<h3>Slowest tests (average)</h3>")
    out.append(table(["Test", "Avg", "Runs"], [[code(t), secs(t["avg"]), t["runs"]] for t in d["slow_tests"]], {1, 2}))
    out.append("<h3>Slowest files (sum of test averages)</h3>")
    out.append(table(["File", "Tests", "Time"],
                     [[f"<code>{html.escape(f['file'])}</code>", f["tests"], secs(f["avg"])] for f in d["slow_files"]], {1, 2}))
    out.append(h(f"{d['project']} flaky"))
    out.append('<p class="note">Marked flaky by the runner, or failed and passed on the same commit.</p>')
    out.append(table(["Test", "Flaky runs", "Commits with both"],
                     [[code(t), t["flakies"], t["mixed"]] for t in d["flaky"]], {1, 2}))
    out.append(h(f"{d['project']} value"))
    out.append('<p class="note">Times each test failed. Tests that never failed are judged under suspects.</p>')
    out.append(table(["Test", "Failures", "Runs"], [[code(t), t["fails"], t["runs"]] for t in d["value"]], {1, 2}))
    out.append(h(f"{d['project']} suspects"))
    if d["has_coverage"]:
        out.append(f'<p class="note">Never failed while the code they cover changed in at least {suspect_runs} commits. '
                   "Check with <code>arp test-health --mutate</code>; the owner decides.</p>")
        out.append(table(["Test", "Commits on covered code", "Runs", "Avg"],
                         [[code(t), t["commits"], t["runs"], secs(t["avg"])] for t in d["suspects"]], {1, 2, 3}))
    else:
        out.append('<p class="note">No coverage data. Run <code>arp test-health --refresh-coverage</code>.</p>')
    out.append(h(f"{d['project']} duplicates"))
    out.append(table(["Kind", "Name", "Where"],
                     [[html.escape(x["kind"]), f"<code>{html.escape(x['name'])}</code>", f"<code>{html.escape(x['where'])}</code>"]
                      for x in d["duplicates"]]))
    out.append(h(f"{d['project']} trend"))
    out.append(table(["Week", "Runs", "Avg run time", "Tests in a run"],
                     [[html.escape(w["week"]), w["runs"], secs(w["avg_s"]), w["tests"] or "-"] for w in d["trend"]], {1, 2, 3}))
    return "\n".join(out)


def render_html(data: list[dict], suspect_runs: int) -> str:
    sections = []
    if len(data) > 1:
        sections.append("<h2>Projects compared</h2>")
        sections.append(table(
            ["Project", "Tests", "Runs", "Recent suite", "Max tests per flow", "Flaky", "Suspects"],
            [[html.escape(d["project"]), d["tests"], d["runs"], secs(d["suite_s"]),
              max(d["per_flow"].values(), default=0), len(d["flaky"]), len(d["suspects"])] for d in data],
            {1, 2, 3, 4, 5, 6}))
    for d in data:
        sections.append(project_sections(d, suspect_runs))
    title = "Test health: " + (data[0]["project"] if len(data) == 1 else "all projects")
    page = TEMPLATE.read_text()
    return (page.replace("{{TITLE}}", html.escape(title))
            .replace("{{GENERATED}}", datetime.now().strftime("%Y-%m-%d %H:%M"))
            .replace("{{SECTIONS}}", "\n".join(sections)))


# ---------------------------------------------------------------- mutation

def mutate(conn, project: sqlite3.Row, target: str) -> int:
    exe = shutil.which("mutmut")
    if exe is None:
        print("arp test-health --mutate needs mutmut. Install it with: pip install mutmut  (or: uv tool install mutmut)", file=sys.stderr)
        return 2
    if target.isdigit():
        row = conn.execute("SELECT * FROM tests WHERE id = ? AND project_id = ?", (int(target), project["id"])).fetchone()
    else:
        row = conn.execute(
            "SELECT * FROM tests WHERE project_id = ? AND (file || '::' || name = ? OR name = ?)",
            (project["id"], target, target)).fetchone()
    if row is None:
        print(f"arp test-health: no recorded test matches {target!r}.", file=sys.stderr)
        return 1
    root = Path(project["path"])
    here = config.git_root(".") or root
    cover, why = read_testmon(here if (here / ".testmondata").is_file() else root)
    if cover is None:
        print(f"arp test-health: cannot find what the test covers: {why}.", file=sys.stderr)
        return 1
    files = sorted(f for f in source_files(cover.get(f"{row['file']}::{row['name']}", set()), here) if f.endswith(".py"))
    if not files:
        print("arp test-health: testmon lists no source files for that test.", file=sys.stderr)
        return 1
    version = subprocess.run([exe, "--version"], capture_output=True, text=True).stdout
    if re.search(r"version\s+[3-9]\.", version):
        print("arp test-health --mutate supports mutmut 2.x flags only. Install: pip install 'mutmut<3'", file=sys.stderr)
        return 2
    nodeid = f"{row['file']}::{row['name']}"
    print(f"Mutating {len(files)} file(s) covered by {nodeid}")
    proc = subprocess.run(
        [exe, "run", "--paths-to-mutate", ",".join(files), "--runner", f"python -m pytest -x -q {nodeid}"],
        cwd=here, capture_output=True, text=True)
    text = proc.stdout + proc.stderr
    killed = re.findall(r"🎉\s*(\d+)", text)
    survived = re.findall(r"🙁\s*(\d+)", text)
    if not killed and not survived:
        print("arp test-health: could not read mutmut's result:\n" + text[-600:], file=sys.stderr)
        return 1
    k, s = int(killed[-1]) if killed else 0, int(survived[-1]) if survived else 0
    print(f"Mutants killed: {k}, survived: {s}")
    if k == 0:
        print(f"Delete candidate: {nodeid} killed no mutant. The owner decides.")
    else:
        print("The test earns its place: at least one mutant made it fail.")
    return 0


# ---------------------------------------------------------------- command

def run(args) -> int:
    conn = db.connect()
    if args.mutate:
        project = config.load_project(".")
        row = db.ensure_project(conn, ".")
        if row is None or project is None:
            print("arp test-health: not inside a git repository.", file=sys.stderr)
            return 1
        return mutate(conn, row, args.mutate)
    projects = select_projects(conn, args)
    if projects is None:
        return 1
    if args.refresh_coverage:
        for p in projects:
            print(refresh_coverage(conn, p))
    if args.prune:
        print(prune(conn, projects))
    suspect_runs = 10
    cur = config.load_project(".")
    if cur is not None:
        suspect_runs = int(cur.get("tests", "suspect_runs"))
    data = [collect(conn, p, suspect_runs) for p in projects]
    if not data:
        print("No projects recorded yet.")
        return 0
    for d in data:
        print(summary(d, suspect_runs))
    if args.html:
        out = Path(args.html)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render_html(data, suspect_runs))
        print(f"HTML report: {out}")
    return 0
