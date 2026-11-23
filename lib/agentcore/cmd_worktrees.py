import re
import shutil
import subprocess
from pathlib import Path

from agentcore import config, gitwt

HELP = "Worktrees. 'new <name>' makes one from the integration branch; 'prune' removes merged, clean ones (--yes)."


def register(parser) -> None:
    parser.add_argument("action", choices=["new", "prune"])
    parser.add_argument("name", nargs="?", help="new: branch name, such as web/orders-filter")
    parser.add_argument("--yes", action="store_true", help="actually remove (default is a dry run)")
    parser.set_defaults(func=run)


def session_state(path: Path, cfg: dict) -> str:
    """The same state `arp sessions` shows: the recorded one, else working after a recent commit."""
    from agentcore.cmd_sessions import read_state

    last = gitwt.git(path, "log", "-1", "--format=%ct").stdout.strip()
    return read_state(path, float(last or 0), float(cfg["sessions"]["idle_hours"]))


def free_port(start: int, used: set[int]) -> int:
    port = start
    while port in used:
        port += 1
    return port


def new(project, main: Path, name: str) -> int:
    cfg = project.config
    integ = cfg["branches"]["integration"]
    source = Path(cfg["branches"]["integration_worktree"].format(root=str(main), integration=integ))
    if not source.is_dir():
        source = main
    if cfg["env"]["db_prefix"]:
        wanted = gitwt.test_db(cfg, Path(name.replace("/", "-")))
        taken = {gitwt.test_db(cfg, w["path"]): w["path"] for w in gitwt.worktrees(main)}
        taken[gitwt.test_db(cfg, source)] = source
        taken.setdefault(gitwt.test_db(cfg, Path(cfg["branches"]["production_worktree"].format(
            root=str(main), production=cfg["branches"]["production"]))), "production")
        taken.setdefault(gitwt.test_db(cfg, Path(integ)), "integration")
        if wanted in taken:
            print(f"the test database {wanted} already belongs to {taken[wanted]}; pick another branch name")
            return 1
    path = Path(cfg["env"]["worktree"].format(root=str(main), name=re.sub(r"[^A-Za-z0-9._-]+", "-", name.replace("/", "-"))))
    if path.exists():
        print(f"already exists: {path}")
        return 1
    gitwt.git(main, "fetch", "--quiet")
    base = integ if gitwt.git(main, "rev-parse", "--verify", "--quiet", integ).returncode == 0 else "HEAD"
    made = gitwt.git(main, "worktree", "add", "-b", name, str(path), base)
    if made.returncode != 0:
        print(made.stderr.strip())
        return 1
    (path / ".arp").mkdir(exist_ok=True)
    (path / ".arp" / "base").write_text(gitwt.git(path, "rev-parse", "HEAD").stdout.strip() + "\n")
    copied = []
    for rel in cfg["env"].get("copy", []):
        src = source / rel
        if src.is_file():
            shutil.copy2(src, path / rel)
            copied.append(rel)
    print(f"worktree: {path}  (branch {name} from {base})")
    if copied:
        print(f"copied from {source.name}: {', '.join(copied)}")
    if ".testmondata" in cfg["env"].get("copy", []) and ".testmondata" not in copied:
        print("no test map yet: the first quick run is a full run, the next ones only run what changed")
    used_web, used_api = set(), set()
    for w in gitwt.worktrees(main):
        env = w["path"] / ".arp" / "ports"
        if env.is_file():
            for line in env.read_text().splitlines():
                key, _, value = line.partition("=")
                if value.isdigit():
                    (used_web if key == "web" else used_api).add(int(value))
    web = free_port(int(cfg["env"]["web_port"]), used_web)
    api = free_port(int(cfg["env"]["api_port"]), used_api)
    (path / ".arp").mkdir(exist_ok=True)
    (path / ".arp" / "ports").write_text(f"web={web}\napi={api}\n")
    print(f"ports: web {web}, api {api}")
    if cfg["env"]["db_prefix"]:
        db_name = gitwt.test_db(cfg, path)
        print(f"test database: {db_name}")
        if cfg["env"]["db_rebuild"]:
            subprocess.run(cfg["env"]["db_rebuild"].replace("{name}", db_name), shell=True, cwd=str(path))
    return 0


def run(args) -> int:
    project = config.load_project(".")
    main = config.main_root(".")
    if project is None or main is None:
        print("not inside a git repository")
        return 1
    if args.action == "new":
        if not args.name:
            print("usage: arp worktrees new <branch>")
            return 2
        return new(project, main, args.name)
    cfg = project.config
    integ, prod = cfg["branches"]["integration"], cfg["branches"]["production"]
    protected = {
        main.resolve(),
        Path(cfg["branches"]["integration_worktree"].format(root=str(main), integration=integ)).resolve(),
        Path(cfg["branches"]["production_worktree"].format(root=str(main), production=prod)).resolve(),
    }
    tip = gitwt.git(main, "rev-parse", integ).stdout.strip()
    victims, kept = [], []
    for w in gitwt.worktrees(main):
        branch = w["branch"]
        if w["path"].resolve() in protected or not branch or branch in (integ, prod):
            continue
        merged = gitwt.git(main, "merge-base", "--is-ancestor", branch, integ).returncode == 0
        if not merged:
            continue
        why = ""
        if gitwt.git(main, "rev-parse", branch).stdout.strip() == tip:
            why = "same commit as the integration branch"
        elif gitwt.own_commits(w["path"], branch) == 0:
            why = "no commits of its own yet"
        elif session_state(w["path"], cfg) == "working":
            why = "session marked working"
        elif gitwt.dirty_files(w["path"]):
            why = "uncommitted changes"
        elif gitwt.pids_inside(w["path"]):
            why = "a process is running inside it"
        if why:
            kept.append((w, why))
        else:
            victims.append(w)
    for w, why in kept:
        print(f"keep: {w['branch']}  ({why})")
    if not victims:
        print("nothing to prune")
        return 0
    for w in victims:
        print(f"{'remove' if args.yes else 'would remove'}: {w['branch']}  {w['path']}")
        if not args.yes:
            continue
        done = gitwt.git(main, "worktree", "remove", "--force", str(w["path"]))
        if done.returncode != 0:
            print(f"  failed: {done.stderr.strip()}")
            continue
        gitwt.git(main, "branch", "-D", w["branch"])
        drop = cfg["env"]["db_drop"]
        if drop:
            name = gitwt.test_db(cfg, w["path"])
            if any(gitwt.test_db(cfg, o["path"]) == name for o in gitwt.worktrees(main)):
                print(f"  kept database {name}: another worktree uses it")
                continue
            subprocess.run(drop.replace("{name}", name), shell=True, cwd=str(main))
    if not args.yes:
        print("dry run; pass --yes to remove")
    return 0
