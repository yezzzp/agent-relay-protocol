"""agent-core command line and shared helpers.

Every module named ``cmd_<name>.py`` in this package is a subcommand of ``arp``.
It must define ``HELP: str`` and ``def register(parser) -> None``, and set
``parser.set_defaults(func=run)`` where ``run(args) -> int``.
"""
