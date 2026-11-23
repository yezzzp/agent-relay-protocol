"""The scripted integrator (``arp integrate``) and the release (``arp release``)."""

import fcntl
import importlib.util
import sys
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

from agentcore import config, gitwt

RUN_PY = Path(__file__).resolve().parent.parent / "run.py"


@contextmanager
def lock(main: Path):
    (main / ".arp").mkdir(exist_ok=True)
    handle = open(main / ".arp" / "integrate.lock", "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        yield False
        return
    try:
        yield True
    finally:
        fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()


def has_test_run() -> bool:
    return importlib.util.find_spec("agentcore.cmd_test_run") is not None


def wrap(command: str, tier: str, record: bool) -> str:
    if record and has_test_run():
        import shlex

        return (
            f"{shlex.quote(sys.executable)} -I {shlex.quote(str(RUN_PY))} test-run "
            f"--tier {tier} --runner integrator -- sh -c {shlex.quote(command)}"
        )
    return command


class Report:
    def __init__(self, main: Path, branch: str, title: str):
        self.main, self.branch, self.title = main, branch, title
        self.steps: list[tuple[str, bool, float]] = []
        self.tail = ""
        self.sha = ""
        self.outcome = "refused"
        self.fix = ""
        self.when = datetime.now()
        self.batch: list[str] = []

    def step(self, name, ok, secs, output=""):
        self.steps.append((name, ok, secs))
        if not ok:
            self.tail = "\n".join(output.rstrip().splitlines()[-40:])

    def write(self) -> Path:
        folder = self.main / ".arp" / "integration"
        folder.mkdir(parents=True, exist_ok=True)
        slug = self.branch.replace("/", "-")
        path = folder / f"{self.when:%Y-%m-%d-%H%M%S}-{slug}.md"
        lines = [
            f"# {self.title}: {self.branch}",
            "",
            f"- Result: {self.outcome}",
            f"- Branch: {self.branch}",
            f"- Commit: {self.sha or 'n/a'}",
            *([f"- Verified together with: {', '.join(b for b in self.batch if b != self.branch)}"]
              if len(self.batch) > 1 else []),
            "",
            "## Steps",
        ]
        for name, ok, secs in self.steps:
            lines.append(f"- {'pass' if ok else 'FAIL'} {name} ({secs:.1f}s)")
        if not self.steps:
            lines.append("- none ran")
        if self.tail:
            lines += ["", "## Output of the failing step (last 40 lines)", "", "```", self.tail, "```"]
        if self.fix:
            lines += ["", "## Who must fix what", "", self.fix]
        path.write_text("\n".join(lines) + "\n")
        return path


def finish(report: Report, code: int) -> int:
    path = report.write()
    print(f"{report.title.lower()} {report.branch}: {report.outcome}")
    for name, ok, secs in report.steps:
        print(f"  {'ok  ' if ok else 'FAIL'} {name} ({secs:.1f}s)")
    if report.fix:
        print(report.fix)
    print(f"report: {path}")
    return code


def ensure_worktree(main: Path, path: Path, branch: str) -> tuple[Path, str | None]:
    """Find or create the worktree holding the branch. Returns (path, error)."""
    existing = {w["path"].resolve(): w for w in gitwt.worktrees(main)}
    holder = next((w["path"] for w in existing.values() if w["branch"] == branch), None)
    if holder is not None:
        path = holder
    if path.resolve() in existing and not path.is_dir():
        gitwt.git(main, "worktree", "prune")
        existing.pop(path.resolve())
    if path.resolve() in existing:
        w = existing[path.resolve()]
        if w["branch"] != branch:
            return path, f"{path} is on '{w['branch']}', expected '{branch}'"
        if gitwt.dirty_files(path):
            return path, f"{path} has uncommitted changes"
        return path, None
    path.parent.mkdir(parents=True, exist_ok=True)
    out = gitwt.git(main, "worktree", "add", str(path), branch)
    return path, (None if out.returncode == 0 else out.stderr.strip())


def conflict_files(wt: Path) -> list[str]:
    out = gitwt.git(wt, "diff", "--name-only", "--diff-filter=U").stdout
    return out.split()


def run_steps(report, project, wt, commands, tier_record) -> bool:
    for name, command, tier in commands:
        if not command:
            continue
        rc, out, secs = gitwt.sh(wrap(command, tier, tier_record) if tier else command, wt)
        report.step(name, rc == 0, secs, out)
        if rc != 0:
            return False
    return True


def undo(wt: Path, sha: str):
    gitwt.git(wt, "reset", "--hard", sha)


def _slug(branch: str) -> str:
    return branch.replace("/", "-")


def _queue_dir(main: Path) -> Path:
    return main / ".arp" / "integration" / "queue"


def _result_path(main: Path, branch: str) -> Path:
    return main / ".arp" / "integration" / "results" / f"{_slug(branch)}.json"


def _queued(main: Path) -> list[str]:
    folder = _queue_dir(main)
    entries = sorted(folder.glob("*"), key=lambda f: f.stat().st_mtime) if folder.is_dir() else []
    return [f.read_text().strip() for f in entries if f.read_text().strip()]


def _enqueue(main: Path, branch: str) -> None:
    folder = _queue_dir(main)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / _slug(branch)).write_text(branch + "\n")


def _dequeue(main: Path, branch: str) -> None:
    (_queue_dir(main) / _slug(branch)).unlink(missing_ok=True)


def _set_result(main: Path, branch: str, outcome: str, code: int, report: Path | None) -> None:
    import json

    path = _result_path(main, branch)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"outcome": outcome, "code": code, "report": str(report or "")}))
    _dequeue(main, branch)


def _settings(cfg: dict, main: Path) -> tuple[str, Path, list]:
    integ = cfg["branches"]["integration"]
    wt = Path(cfg["branches"]["integration_worktree"].format(root=str(main), integration=integ))
    db = cfg["env"]["db_rebuild"]
    plan = [
        ("db_rebuild", db.replace("{name}", gitwt.test_db(cfg, wt)) if db else "", None),
        ("verify.full", cfg["verify"]["full"], "unit"),
        ("verify.e2e", cfg["verify"]["e2e"], "e2e"),
    ]
    return integ, wt, plan


def _batch(project, main: Path, branches: list[str], keep_servers: bool) -> None:
    """Merge every branch, verify once, land all. On a failure with more than one branch, each
    is tried alone, so the good ones land and only the guilty one is refused."""
    cfg = project.config
    integ, wt_path, plan = _settings(cfg, main)
    title = " + ".join(branches)
    report = Report(main, title, "Integration")
    wt, err = ensure_worktree(main, wt_path, integ)
    if err:
        report.fix = f"Integration worktree problem: {err}"
        path = report.write()
        for b in branches:
            _set_result(main, b, "refused", 1, path)
        return
    pre = gitwt.git(wt, "rev-parse", "HEAD").stdout.strip()
    sources = {w["branch"]: w for w in gitwt.worktrees(main)}
    merged: list[str] = []
    for b in branches:
        if gitwt.git(main, "merge-base", "--is-ancestor", b, integ).returncode == 0:
            _set_result(main, b, "nothing to integrate", 0, None)
            continue
        merge = gitwt.git(wt, "merge", "--no-ff", "--no-edit", b)
        if merge.returncode == 0:
            merged.append(b)
            continue
        files = conflict_files(wt)
        gitwt.git(wt, "merge", "--abort")
        if merged:  # it may only clash with a branch of this batch: next round, against the new tip
            _enqueue(main, b)
            continue
        one = Report(main, b, "Integration")
        one.step("merge", False, 0, merge.stdout + merge.stderr)
        one.fix = (f"Session on {b} must merge {integ} into its branch and resolve conflicts in: "
                   + (", ".join(files) or "see output"))
        _set_result(main, b, "refused", 1, one.write())
    if not merged:
        return
    report = Report(main, " + ".join(merged), "Integration")
    report.step("merge" + (f" ({len(merged)} branches)" if len(merged) > 1 else ""), True, 0)
    if not run_steps(report, project, wt, plan, bool(cfg["tests"]["record"])):
        undo(wt, pre)
        if len(merged) > 1:
            report.fix = "The batch failed; each branch is tried alone next."
            report.write()
            for b in merged:
                _batch(project, main, [b], keep_servers)
            return
        failed = report.steps[-1][0]
        report.fix = (f"Session on {merged[0]} must fix '{failed}' (output above), then ask again. "
                      f"{integ} was left unchanged.")
        report.sha = gitwt.git(main, "rev-parse", "--short=12", merged[0]).stdout.strip()
        _set_result(main, merged[0], "refused", 1, report.write())
        return
    report.outcome = "landed"
    report.sha = gitwt.git(wt, "rev-parse", "--short=12", "HEAD").stdout.strip()
    for command in cfg.get("integrate", {}).get("after", []) or []:
        rc, out, secs = gitwt.sh(command, wt)
        report.step(f"after: {command}", rc == 0, secs, "" if rc == 0 else out)
    import time as _time

    for b in merged:
        source = sources.get(b)
        if source:
            state = source["path"] / ".arp" / "session-state"
            state.parent.mkdir(exist_ok=True)
            state.write_text(f"integrated\n{int(_time.time())}\n")
            if not keep_servers and (n := gitwt.stop_servers(source["path"])):
                report.step(f"stopped {n} dev server process(es) of {b}", True, 0)
    report.batch = merged
    for b in merged:  # one report per branch, so each session finds its own
        report.branch = b
        _set_result(main, b, "landed", 0, report.write())


def _drain(project, main: Path, keep_servers: bool) -> None:
    while waiting := _queued(main):
        _batch(project, main, waiting, keep_servers)


def _print_result(main: Path, branch: str) -> int:
    import json

    data = json.loads(_result_path(main, branch).read_text())
    print(f"integration {branch}: {data['outcome']}")
    if data["report"]:
        text = Path(data["report"]).read_text()
        for line in text.splitlines():
            if line.startswith("- pass ") or line.startswith("- FAIL "):
                print("  " + line[2:])
        if "## Who must fix what" in text:
            print(text.split("## Who must fix what", 1)[1].strip())
        print(f"report: {data['report']}")
    return int(data["code"])


def integrate(branch: str, dry_run=False, keep_servers=False) -> int:
    project = config.load_project(".")
    main = config.main_root(".")
    if project is None or main is None:
        print("not inside a git repository", file=sys.stderr)
        return 1
    cfg = project.config
    integ = cfg["branches"]["integration"]
    if gitwt.git(main, "rev-parse", "--verify", "-q", f"refs/heads/{branch}").returncode != 0:
        print(f"no such branch: {branch}", file=sys.stderr)
        return 1
    if branch in (integ, cfg["branches"]["production"]):
        print(f"{branch} is the integration or production branch; integrate a task branch", file=sys.stderr)
        return 1
    if not (cfg["verify"]["full"] or "").strip():
        print("verify.full is empty in .arp/config.toml: nothing would be checked, so nothing is merged. "
              "Set it (agent-init proposes one), then integrate again.", file=sys.stderr)
        return 1
    if gitwt.git(main, "merge-base", "--is-ancestor", branch, integ).returncode == 0:
        print(f"nothing to integrate: every commit of {branch} is already in {integ}")
        return 0
    source = next((w for w in gitwt.worktrees(main) if w["branch"] == branch), None)
    if source and (dirty := gitwt.dirty_files(source["path"])):
        report = Report(main, branch, "Integration")
        report.fix = (f"Session on {branch} must commit or stash {len(dirty)} uncommitted file(s) "
                      f"in {source['path']}, then ask again.")
        return finish(report, 1)
    if dry_run:
        return _dry_run(cfg, main, branch)

    _result_path(main, branch).unlink(missing_ok=True)
    _enqueue(main, branch)
    told = False
    import time as _time

    while not _result_path(main, branch).exists():
        with lock(main) as got:
            if got:
                _drain(project, main, keep_servers)
                continue
        if not told:
            print(f"queued: another integration is running; {branch} goes in the next batch")
            told = True
        _time.sleep(1)
    return _print_result(main, branch)


def _dry_run(cfg: dict, main: Path, branch: str) -> int:
    integ, wt_path, plan = _settings(cfg, main)
    with lock(main) as got:
        if not got:
            print("another integration is running; try the dry run when it finishes", file=sys.stderr)
            return 1
        wt, err = ensure_worktree(main, wt_path, integ)
        if err:
            print(f"Integration worktree problem: {err}", file=sys.stderr)
            return 1
        pre = gitwt.git(wt, "rev-parse", "HEAD").stdout.strip()
        merge = gitwt.git(wt, "merge", "--no-ff", "--no-commit", branch)
        files = conflict_files(wt) if merge.returncode != 0 else []
        gitwt.git(wt, "merge", "--abort")
        undo(wt, pre)
        if merge.returncode != 0:
            print(f"dry run: {branch} conflicts with {integ} in: " + (", ".join(files) or "see git output"))
            return 1
        print(f"dry run: {branch} merges cleanly into {integ}. Steps that would run:")
        for n, c, _ in plan:
            print(f"  {n}: {c or '(skipped, empty)'}")
        return 0


def release(tag: str) -> int:
    project = config.load_project(".")
    main = config.main_root(".")
    if project is None or main is None:
        print("not inside a git repository", file=sys.stderr)
        return 1
    cfg = project.config
    integ, prod = cfg["branches"]["integration"], cfg["branches"]["production"]
    report = Report(main, tag, "Release")
    if not (cfg["verify"]["full"] or "").strip() or not (cfg["verify"]["e2e_full"] or "").strip():
        print("verify.full and verify.e2e_full must be set in .arp/config.toml before a release.", file=sys.stderr)
        return 1
    with lock(main) as got:
        if not got:
            print("another integration is running; try again when it finishes", file=sys.stderr)
            return 1
        if gitwt.git(main, "rev-parse", "-q", "--verify", f"refs/tags/{tag}").returncode == 0:
            report.fix = f"Tag {tag} already exists."
            return finish(report, 1)
        wt = Path(
            cfg["branches"]["production_worktree"].format(root=str(main), production=prod)
        )
        wt, err = ensure_worktree(main, wt, prod)
        if err:
            report.fix = f"Production worktree problem: {err}"
            return finish(report, 1)
        pre = gitwt.git(wt, "rev-parse", "HEAD").stdout.strip()
        merge = gitwt.git(wt, "merge", "--no-ff", "--no-edit", integ)
        if merge.returncode != 0:
            gitwt.git(wt, "merge", "--abort")
            undo(wt, pre)
            report.step("merge", False, 0, merge.stdout + merge.stderr)
            report.fix = f"{integ} does not merge cleanly into {prod}; resolve it before releasing."
            return finish(report, 1)
        report.step("merge", True, 0)
        plan = [
            ("verify.full", cfg["verify"]["full"], "unit"),
            ("verify.e2e_full", cfg["verify"]["e2e_full"], "e2e_full"),
        ]
        if not run_steps(report, project, wt, plan, bool(cfg["tests"]["record"])):
            undo(wt, pre)
            report.fix = f"Fix '{report.steps[-1][0]}' on {integ}, then release again. {prod} was left unchanged."
            return finish(report, 1)
        tagged = gitwt.git(wt, "tag", "-a", tag, "-m", f"Release {tag}")
        if tagged.returncode != 0:
            undo(wt, pre)
            report.fix = f"Could not tag: {tagged.stderr.strip()}"
            return finish(report, 1)
        report.outcome = "released"
        report.sha = gitwt.git(wt, "rev-parse", "--short=12", "HEAD").stdout.strip()
        code = finish(report, 0)
        print(f"not pushed. To publish: git push origin {prod} {tag}")
        return code
