from pathlib import Path

from agentcore import audit, db
from agentcore.config import git_root, load_project

HELP = "Show this project's adoption state, pieces and audit."


def register(parser) -> None:
    parser.set_defaults(func=run)


def run(args) -> int:
    root = git_root(Path.cwd())
    if root is None:
        print("Not a git repo.")
        return 1
    conn = db.connect()
    project = db.ensure_project(conn, root)
    reg = db.registry(conn, project["id"])
    state = reg["state"] if reg else "unknown"
    print(f"{project['name']}: {state}" + (f" ({reg['pieces']})" if reg and reg["pieces"] else ""))
    if reg and reg["decided_at"]:
        print(f"decided {reg['decided_at']}")
    cfg = load_project(root)
    print(f"config: {'.arp/config.toml' if cfg and cfg.has_config else 'none'}")
    for line in audit.summary(audit.audit(root)):
        print(line)
    return 0
