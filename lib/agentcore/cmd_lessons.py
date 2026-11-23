"""arp lessons: keep the project's memory loadable, and turn repeated rules into checks.

Text rules fail silently when an agent skips them. A rule that has to be
written twice, or that names a file, a column or a command, usually belongs in
a lint, a test or a validator instead. This command finds those candidates. The
agent then proposes each check to the owner. It never deletes or rewrites
memory by itself.
"""

import json
import re
from itertools import combinations
from pathlib import Path

from agentcore import audit
from agentcore.config import git_root

HELP = "Check the memory index and list rules that repeat or that a check could enforce."

INDEX_MAX_LINES = 200
INDEX_MAX_CHARS = 200
STOP = set(
    "a an and are as at be by de del el en es for from has in is it la las lo los no of on or "
    "para por que se sin the to un una y con su sus al this that with not never always solo "
    "nunca siempre mas más ya va".split()
)
HARD = re.compile(
    r"\b(never|always|must|must not|do not|don't|nunca|siempre|jam[aá]s|no se|debe|solo se|prohibid)\b", re.I
)
REPEATED = re.compile(
    r"(again|second time|twice|same mistake|already happened|otra vez|de nuevo|dos veces|"
    r"ya pas[oó]|ya se cometi|se repiti|volvi[oó] a)", re.I
)
ENFORCED = re.compile(
    r"(validator|validador|lint|test_|\.spec\.|check|ci\b|constraint|unique|assert)"
    r"[^.\n]{0,60}(detects|catches|blocks|fails|detecta|bloquea|falla|rechaza)", re.I
)
ANCHOR = re.compile(r"`[^`]{2,60}`|\b[\w./-]+\.(py|ts|tsx|js|csv|sql|toml|json|md)\b|\b[a-z]+_[a-z_]+\b")


def register(parser) -> None:
    parser.add_argument("--memory", help="memory folder (default: the one the audit finds)")
    parser.add_argument("--check", action="store_true", help="exit 1 when the index is over its limits")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--top", type=int, default=15, help="items per section")
    parser.set_defaults(func=run)


def split_front(text: str) -> tuple[dict, str]:
    if not text.startswith("---"):
        return {}, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}, text
    meta = {}
    for line in parts[1].splitlines():
        key, sep, value = line.partition(":")
        if sep and not line.startswith(" "):
            meta[key.strip()] = value.strip().strip('"')
    return meta, parts[2]


def words(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-záéíóúñü0-9]{3,}", text.lower()) if w not in STOP}


def suggest(body: str) -> str:
    low = body.lower()
    if re.search(r"\.csv|dataset|validar|validator|validador", low):
        return "a validator rule"
    if re.search(r"\.tsx?\b|screen|pantalla|component|\bui\b|css", low):
        return "a lint rule or a ui-check check"
    if re.search(r"migration|migraci|unique|foreign key|constraint|column|columna", low):
        return "a database constraint or a migration test"
    if re.search(r"\.py\b|service|servicio|model|modelo|\bapi\b|endpoint", low):
        return "a unit test or a type"
    if re.search(r"commit|branch|rama|worktree|git\b", low):
        return "a git hook or an arp check"
    return "a test or a script"


def load(folder: Path) -> list[dict]:
    items = []
    for path in sorted(folder.glob("*.md")):
        if path.name.upper() == "MEMORY.MD":
            continue
        text = path.read_text(errors="ignore")
        meta, body = split_front(text)
        kind = path.stem.split("_", 1)[0]
        items.append({
            "file": path.name,
            "kind": kind,
            "title": meta.get("name", path.stem),
            "description": meta.get("description", ""),
            "body": body,
            "words": words(f"{path.stem.replace('_', ' ')} {meta.get('description', '')}"),
        })
    return items


def index_problems(folder: Path, items: list[dict]) -> dict:
    index = folder / "MEMORY.md"
    if not index.is_file():
        return {"missing_index": True, "lines": 0, "long_lines": [], "orphans": [], "broken": []}
    lines = index.read_text(errors="ignore").splitlines()
    linked = set(re.findall(r"\]\(([^)]+\.md)\)", "\n".join(lines)))
    files = {i["file"] for i in items}
    return {
        "missing_index": False,
        "lines": len(lines),
        "long_lines": [n + 1 for n, line in enumerate(lines) if len(line) > INDEX_MAX_CHARS],
        "orphans": sorted(files - linked),
        "broken": sorted(link for link in linked if link not in files and "/" not in link),
    }


def duplicates(items: list[dict], top: int) -> list[dict]:
    pairs = []
    for a, b in combinations(items, 2):
        if not a["words"] or not b["words"]:
            continue
        score = len(a["words"] & b["words"]) / len(a["words"] | b["words"])
        if score >= 0.45:
            pairs.append({"a": a["file"], "b": b["file"], "overlap": round(score, 2)})
    return sorted(pairs, key=lambda p: -p["overlap"])[:top]


def candidates(items: list[dict], top: int) -> tuple[list[dict], list[dict]]:
    repeated, enforceable = [], []
    for item in items:
        body = item["body"]
        if ENFORCED.search(body):
            continue
        anchors = len(ANCHOR.findall(body))
        hard = len(HARD.findall(body))
        entry = {"file": item["file"], "title": item["description"] or item["title"], "suggest": suggest(body)}
        if REPEATED.search(body):
            repeated.append(entry | {"score": hard + anchors})
        elif item["kind"] in {"rule", "regla", "gotcha", "feedback", "convention", "convencion", "incidente"} \
                and hard and anchors >= 2:
            enforceable.append(entry | {"score": hard * 2 + anchors})
    key = lambda e: -e["score"]  # noqa: E731
    return sorted(repeated, key=key)[:top], sorted(enforceable, key=key)[:top]


def find_folder(args) -> Path | None:
    if args.memory:
        return Path(args.memory)
    root = git_root(Path.cwd())
    if root is None:
        return None
    found = audit.run_audit(root).get("memory_folder")
    return root / found if found else None


def run(args) -> int:
    folder = find_folder(args)
    if folder is None or not folder.is_dir():
        print("No memory folder found. Pass --memory <dir>.")
        return 1
    items = load(folder)
    idx = index_problems(folder, items)
    repeated, enforceable = candidates(items, args.top)
    report = {
        "folder": str(folder),
        "files": len(items),
        "index": idx,
        "repeated": repeated,
        "enforceable": enforceable,
        "duplicates": duplicates(items, args.top),
    }
    over = idx["missing_index"] or idx["lines"] > INDEX_MAX_LINES or bool(idx["long_lines"])

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 1 if args.check and over else 0

    print(f"Memory: {folder} · {len(items)} files")
    if idx["missing_index"]:
        print("✗ no MEMORY.md index")
    else:
        mark = "✗" if idx["lines"] > INDEX_MAX_LINES else "✓"
        print(f"{mark} index: {idx['lines']} lines (limit {INDEX_MAX_LINES}; past it, sessions load it cut)")
        if idx["long_lines"]:
            print(f"✗ {len(idx['long_lines'])} index lines over {INDEX_MAX_CHARS} characters")
        if idx["orphans"]:
            print(f"! {len(idx['orphans'])} files not in the index: {', '.join(idx['orphans'][:5])}…")
        if idx["broken"]:
            print(f"! {len(idx['broken'])} index links to missing files: {', '.join(idx['broken'][:5])}")

    def section(title: str, rows: list[dict]) -> None:
        if not rows:
            return
        print(f"\n{title}")
        for r in rows:
            print(f"- {r['file']}: {r['title'][:110]}\n    → {r['suggest']}")

    section("Lessons learned more than once: make each a check", repeated)
    section("Rules a check could enforce", enforceable)
    if report["duplicates"]:
        print("\nPossible duplicates: merge into one file")
        for d in report["duplicates"]:
            print(f"- {d['a']} ≈ {d['b']} ({int(d['overlap'] * 100)} %)")
    print("\nPropose each check to the owner; once it exists, the memory file only links to it.")
    return 1 if args.check and over else 0
