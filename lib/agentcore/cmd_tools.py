"""arp tools: what this machine is missing for agent-core and this project."""

import json
from pathlib import Path

from agentcore import tools
from agentcore.config import load_project

HELP = "List what this machine is missing, with the install command (--fix runs the ones without sudo)."


def register(parser) -> None:
    parser.add_argument("--fix", action="store_true", help="run the installs that need no sudo")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--path", default=".")
    parser.set_defaults(func=run)


def run(args) -> int:
    project = load_project(args.path)
    root = project.root if project else None
    cfg = project.config if project else None
    missing = tools.check(root, cfg)
    if args.json:
        print(json.dumps([vars(n) for n in missing], indent=2))
        return 1 if missing else 0
    if not missing:
        print("✓ nothing missing" + (f" for {Path(root).name}" if root else ""))
        return 0
    for n in missing:
        how = n.install or "no known installer: install it by hand"
        print(f"✗ {n.tool} ({n.why})\n    {how}")
    if not args.fix:
        print("\n`arp tools --fix` runs the commands without sudo. The sudo ones are yours to run.")
        return 1
    for need, ok in tools.run_fix(missing):
        print(f"{'✓' if ok else '✗'} {need.tool}")
    left = tools.check(root, cfg)
    for n in left:
        print(f"still missing: {n.tool} → {n.install}")
    return 1 if left else 0
