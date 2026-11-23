import time
from datetime import datetime, timezone
from pathlib import Path

from agentcore import config, gitwt

HELP = "Show one line per worktree with its state; 'set <state>' records the current one."
STATES = ("working", "waiting-owner", "ready", "idle", "integrated")


def register(parser) -> None:
    parser.add_argument("--count", action="store_true", help="print only N/limit")
    parser.add_argument("rest", nargs="*", metavar="set <state>")
    parser.set_defaults(func=run)


def age(seconds: float) -> str:
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return f"{int(seconds // size)}{unit}"
    return "now"


def read_state(wt: Path, last_commit: float, idle_hours: float) -> str:
    try:
        first = (wt / ".arp" / "session-state").read_text().splitlines()[0].strip()
        if first in STATES:
            return first
    except (OSError, IndexError):
        pass
    return "idle" if time.time() - last_commit > idle_hours * 3600 else "working"


def run(args) -> int:
    if args.rest:
        if len(args.rest) != 2 or args.rest[0] != "set" or args.rest[1] not in STATES:
            print(f"usage: arp sessions set <{'|'.join(STATES)}>")
            return 2
        root = config.git_root(".")
        if root is None:
            print("not inside a git repository")
            return 1
        (root / ".arp").mkdir(exist_ok=True)
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        (root / ".arp" / "session-state").write_text(f"{args.rest[1]}\n{stamp}\n")
        print(f"{root.name}: {args.rest[1]}")
        return 0
    project = config.load_project(".")
    if project is None:
        print("not inside a git repository")
        return 1
    soft = int(project.get("sessions", "soft_limit"))
    trees = gitwt.worktrees(".")
    count = gitwt.claude_count([w["path"] for w in trees])
    if args.count:
        print(f"{count}/{soft}")
        return 0
    idle_hours = float(project.get("sessions", "idle_hours"))
    now = time.time()
    rows = []
    for w in trees:
        stamp = gitwt.git(w["path"], "log", "-1", "--format=%ct").stdout.strip()
        last = float(stamp) if stamp else now
        ram = gitwt.rss_mb(gitwt.server_pids(w["path"]))
        rows.append(
            (
                w["branch"] or "(detached)",
                read_state(w["path"], last, idle_hours),
                age(now - last),
                "dirty" if gitwt.dirty_files(w["path"]) else "clean",
                f"{ram:.0f} MB" if ram else "-",
            )
        )
    width = max((len(r[0]) for r in rows), default=0)
    for r in rows:
        print(f"{r[0]:<{width}}  {r[1]:<13}  {r[2]:>4}  {r[3]:<5}  {r[4]}")
    print(f"talking sessions: {count}/{soft}")
    if count > soft:
        print(f"warning: {count} sessions are open, above the soft limit of {soft}. Consider pausing one.")
    return 0
