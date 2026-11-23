import json
from pathlib import Path

from agentcore import audit, db
from agentcore.config import git_root

HELP = "Audit this project again. Unless --keep, the next session asks the adoption question again."


def register(parser) -> None:
    parser.add_argument("--json", action="store_true", help="print the raw facts")
    parser.add_argument("--keep", action="store_true", help="keep the current adoption state")
    parser.set_defaults(func=run)


def run(args) -> int:
    root = git_root(Path.cwd())
    if root is None:
        print("Not a git repo.")
        return 1
    facts = audit.audit(root, use_cache=False)
    if args.json:
        print(json.dumps(facts, indent=2))
    else:
        print("\n".join(audit.summary(facts)))
    if not args.keep:
        conn = db.connect()
        project = db.ensure_project(conn, root)
        db.set_registry(conn, project["id"], "unknown", audit_hash=audit.significant(facts))
        print("The next session will ask whether to adopt agent-core here.")
    return 0
