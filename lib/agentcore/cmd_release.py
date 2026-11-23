from agentcore import integrate

HELP = "Merge the integration branch into production, verify fully, and tag. Never pushes."


def register(parser) -> None:
    parser.add_argument("tag", help="for example v1.0.0")
    parser.set_defaults(func=run)


def run(args) -> int:
    return integrate.release(args.tag)
