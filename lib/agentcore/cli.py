import argparse
import importlib
import pkgutil
import sys

import agentcore


def build() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="arp", description="agent-core command line")
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    for mod in sorted(pkgutil.iter_modules(agentcore.__path__), key=lambda m: m.name):
        if not mod.name.startswith("cmd_"):
            continue
        module = importlib.import_module(f"agentcore.{mod.name}")
        name = mod.name.removeprefix("cmd_").replace("_", "-")
        module.register(sub.add_parser(name, help=module.HELP, description=module.HELP))
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 0
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
