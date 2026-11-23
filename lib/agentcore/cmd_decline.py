from pathlib import Path

from agentcore import db
from agentcore.config import git_root

HELP = "Do not use agent-core in this project. Nothing is injected and it never asks again."


def register(parser) -> None:
    parser.set_defaults(func=run)


def run(args) -> int:
    root = git_root(Path.cwd())
    if root is None:
        print("Not a git repo.")
        return 1
    conn = db.connect()
    project = db.ensure_project(conn, root)
    db.set_registry(conn, project["id"], "declined")
    print(f"{project['name']}: declined. Undo with `arp audit` (asks again) or `arp adopt`.")
    return 0
