import subprocess
from pathlib import Path

from agentcore import audit, db
from agentcore.config import git_root

HELP = "Adopt agent-core in this project, fully or by pieces (stored on this machine, not in the repo)."


def register(parser) -> None:
    parser.add_argument("--state", choices=("adopted", "partial"), default="adopted")
    parser.add_argument("--pieces", default="", help=f"comma list of: {', '.join(db.PIECES)}")
    parser.set_defaults(func=run)


def run(args) -> int:
    root = git_root(Path.cwd())
    if root is None:
        print("Not a git repo.")
        return 1
    pieces = [p.strip() for p in args.pieces.split(",") if p.strip()]
    unknown = [p for p in pieces if p not in db.PIECES]
    if unknown:
        print(f"Unknown piece(s): {', '.join(unknown)}. Choose from: {', '.join(db.PIECES)}")
        return 1
    if args.state == "partial" and not pieces:
        print("A partial adoption needs --pieces.")
        return 1
    if args.state == "adopted":
        pieces = []
    conn = db.connect()
    project = db.ensure_project(conn, root)
    db.set_registry(conn, project["id"], args.state, pieces, audit.significant(audit.audit(root)))
    print(f"{project['name']}: {args.state}" + (f" ({', '.join(pieces)})" if pieces else ""))
    if args.state == "partial":
        print("Next session gets those pieces. To set up the project files, run: agent-init")
        return 0
    init = Path(__file__).resolve().parents[2] / "bin" / "agent-init"
    done = subprocess.run([str(init), "--no-agent"], cwd=root, check=False)
    if done.returncode != 0:
        print("agent-init failed; run it by hand: agent-init --no-agent")
        return done.returncode
    print("Fill every TODO in .arp/config.toml and .arp/flows.toml, or run agent-init for the interview.")
    return 0
