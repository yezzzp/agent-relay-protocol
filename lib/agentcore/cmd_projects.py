from agentcore import db

HELP = "List every project agent-core knows, with its adoption state."


def register(parser) -> None:
    parser.set_defaults(func=run)


def run(args) -> int:
    conn = db.connect()
    rows = conn.execute(
        "SELECT p.name, p.path, COALESCE(r.state, 'unknown') AS state, COALESCE(r.pieces, '') AS pieces "
        "FROM projects p LEFT JOIN registry r ON r.project_id = p.id ORDER BY p.name"
    ).fetchall()
    if not rows:
        print("No projects yet.")
        return 0
    width = max(len(r["name"]) for r in rows)
    for r in rows:
        extra = f"  ({r['pieces']})" if r["pieces"] else ""
        print(f"{r['name']:<{width}}  {r['state']:<8}{extra}  {r['path']}")
    return 0
