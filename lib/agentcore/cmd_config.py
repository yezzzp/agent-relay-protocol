import socket
from pathlib import Path

from agentcore import config

HELP = "Project config tools. 'check' validates .arp/config.toml and flows.toml."


def register(parser) -> None:
    parser.add_argument("action", choices=["check"])
    parser.set_defaults(func=run)


def port_taken(port) -> bool:
    with socket.socket() as s:
        try:
            s.bind(("127.0.0.1", int(port)))
        except OSError:
            return True
    return False


def run(args) -> int:
    project = config.load_project(".")
    if project is None:
        print("not inside a git repository")
        return 1
    problems = []
    if not project.has_config:
        problems.append("missing .arp/config.toml")
    if not project.get("verify", "quick"):
        problems.append("missing verify.quick")
    for key in ("integration", "production", "integration_worktree", "production_worktree"):
        if not project.get("branches", key):
            problems.append(f"missing branches.{key}")
    for key in ("web_port", "api_port"):
        port = project.get("env", key)
        if port and port_taken(port):
            problems.append(f"env.{key} {port} is already taken on 127.0.0.1")
    flows = project.flows
    if not flows and (main := config.main_root(".")):
        flows = config.read_toml(Path(main) / ".arp" / "flows.toml")
    if not flows:
        problems.append("empty or missing .arp/flows.toml")
    for p in problems:
        print(f"problem: {p}")
    if problems:
        return 1
    print("ok")
    return 0
