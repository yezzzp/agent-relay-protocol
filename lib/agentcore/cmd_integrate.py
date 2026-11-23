from agentcore import integrate

HELP = "Merge a branch into the integration branch, verify it, and write a report."


def register(parser) -> None:
    parser.add_argument("branch")
    parser.add_argument("--dry-run", action="store_true", help="check the merge, run nothing")
    parser.add_argument("--keep-servers", action="store_true", help="do not stop dev servers")
    parser.set_defaults(func=run)


def run(args) -> int:
    return integrate.integrate(args.branch, args.dry_run, args.keep_servers)
