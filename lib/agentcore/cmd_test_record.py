import sys
from pathlib import Path

from agentcore import config, db, testdata

HELP = "Record an existing test report (pytest JUnit XML or Playwright JSON) in the test database."


def register(parser) -> None:
    parser.add_argument("--tier", required=True, choices=["unit", "e2e", "e2e_full"])
    parser.add_argument("--runner", default="session", choices=["session", "integrator"])
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--junit", metavar="FILE", help="pytest JUnit XML report")
    src.add_argument("--playwright-json", metavar="FILE", help="Playwright JSON reporter output")
    parser.set_defaults(func=run)


def run(args) -> int:
    project = config.load_project(".")
    if project is None:
        print("arp test-record: not inside a git repository.", file=sys.stderr)
        return 1
    if not project.get("tests", "record"):
        print("arp test-record: tests.record is false; nothing recorded.", file=sys.stderr)
        return 0
    path = Path(args.junit or args.playwright_json)
    if not path.is_file():
        print(f"arp test-record: {path} does not exist.", file=sys.stderr)
        return 1
    try:
        if args.junit:
            results, duration = testdata.parse_junit(path, project.root)
        else:
            results, duration = testdata.parse_playwright(path)
    except Exception as exc:  # malformed report
        print(f"arp test-record: cannot read {path}: {exc}", file=sys.stderr)
        return 1
    conn = db.connect()
    row = db.ensure_project(conn, ".")
    run_id = testdata.record(
        conn, row, args.tier, args.runner, f"record {path.name}", results, duration, project.root
    )
    print(f"Recorded run {run_id}: {len(results)} tests ({args.tier}, {args.runner}).")
    return 0
