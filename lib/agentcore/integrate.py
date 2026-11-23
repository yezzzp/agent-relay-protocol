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


def integrate(branch: str, dry_run=False, keep_servers=False) -> int:
    project = config.load_project(".")
    main = config.main_root(".")
    if project is None or main is None:
        print("not inside a git repository", file=sys.stderr)
        return 1
    cfg = project.config
    integ = cfg["branches"]["integration"]
    report = Report(main, branch, "Integration")
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
    with lock(main) as got:
        if not got:
            print("another integration is running; try again when it finishes", file=sys.stderr)
            return 1
        source = next((w for w in gitwt.worktrees(main) if w["branch"] == branch), None)
        if source and (dirty := gitwt.dirty_files(source["path"])):
            report.fix = (
                f"Session on {branch} must commit or stash {len(dirty)} uncommitted file(s) "
                f"in {source['path']}, then ask again."
            )
            return finish(report, 1)
        wt = Path(
            cfg["branches"]["integration_worktree"].format(root=str(main), integration=integ)
        )
        wt, err = ensure_worktree(main, wt, integ)
        if err:
            report.fix = f"Integration worktree problem: {err}"
            return finish(report, 1)
        pre = gitwt.git(wt, "rev-parse", "HEAD").stdout.strip()
        report.sha = gitwt.git(main, "rev-parse", branch).stdout.strip()[:12]
        merge = gitwt.git(wt, "merge", "--no-ff", "--no-commit" if dry_run else "--no-edit", branch)
        if merge.returncode != 0:
            files = conflict_files(wt)
            gitwt.git(wt, "merge", "--abort")
            undo(wt, pre)
            report.step("merge", False, 0, merge.stdout + merge.stderr)
            report.fix = (
                f"Session on {branch} must merge {integ} into its branch and resolve conflicts in: "
                + (", ".join(files) or "see output")
            )
            return finish(report, 1)
        db = cfg["env"]["db_rebuild"]
        name = gitwt.test_db(cfg, Path(cfg["branches"]["integration_worktree"].format(root=str(main), integration=integ)))
        plan = [
            ("db_rebuild", db.replace("{name}", name) if db else "", None),
            ("verify.full", cfg["verify"]["full"], "unit"),
            ("verify.e2e", cfg["verify"]["e2e"], "e2e"),
        ]
        if dry_run:
            gitwt.git(wt, "merge", "--abort")
            undo(wt, pre)
            print(f"dry run: {branch} merges cleanly into {integ}. Steps that would run:")
            for n, c, _ in plan:
                print(f"  {n}: {c or '(skipped, empty)'}")
            return 0
        report.step("merge", True, 0)
        record = bool(cfg["tests"]["record"])
        if not run_steps(report, project, wt, plan, record):
            undo(wt, pre)
            failed = report.steps[-1][0]
            report.fix = (
                f"Session on {branch} must fix '{failed}' (output above), then ask again. "
                f"{integ} was left unchanged."
            )
            return finish(report, 1)
        report.outcome = "landed"
        if source:
            import time as _time

            state = source["path"] / ".arp" / "session-state"
            state.parent.mkdir(exist_ok=True)
            state.write_text(f"integrated\n{int(_time.time())}\n")
        report.sha = gitwt.git(wt, "rev-parse", "--short=12", "HEAD").stdout.strip()
        if source and not keep_servers:
            n = gitwt.stop_servers(source["path"])
            if n:
                report.step(f"stopped {n} dev server process(es)", True, 0)
        return finish(report, 0)


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
