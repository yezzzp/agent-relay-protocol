"""Keep the e2e suite from growing back: every e2e test names a user flow."""

import json
import os
import re
import sys
from pathlib import Path

from agentcore import config

HELP = "Fail when an e2e test names no flow, a flow is over its cap, or retries are configured."

SKIP_DIRS = {"node_modules", ".git", ".venv", "venv", "__pycache__", "dist", "build", ".next", ".arp"}
BASELINE = Path(".arp") / "test-guard-baseline.json"

TEST_RE = re.compile(r"\b(test|it)(?:\.(?:only|skip|fixme|slow|fail))?\s*\(\s*(['\"`])((?:\\.|(?!\2).)*)\2", re.S)
DESCRIBE_RE = re.compile(r"\b(?:test|it)\.describe(?:\.(?:serial|parallel|only|skip|fixme))?\s*\(\s*(['\"`])((?:\\.|(?!\1).)*)\1", re.S)
FLOW_RE = re.compile(r"@flow(?:[\s:=]+)([A-Za-z0-9_-]+)")
ANNOT_RE = re.compile(r"type\s*:\s*['\"]flow['\"]\s*,\s*description\s*:\s*['\"]([A-Za-z0-9_-]+)['\"]")


def register(parser) -> None:
    parser.add_argument(
        "--baseline",
        action="store_true",
        help="write .arp/test-guard-baseline.json with the current offenders; only new ones fail afterwards",
    )
    parser.set_defaults(func=run)


def glob_regex(pattern: str) -> re.Pattern:
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out + r"\Z")


def walk(root: Path):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            full = Path(base) / name
            yield full, full.relative_to(root).as_posix()


def match_close(text: str, start: int) -> int:
    """Index of the brace closing the one at ``start``; skips strings and comments."""
    depth, i, n = 0, start, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                return n
        elif text.startswith("/*", i):
            i = text.find("*/", i)
            if i < 0:
                return n
            i += 1
        elif c in "'\"`":
            i += 1
            while i < n and text[i] != c:
                i += 2 if text[i] == "\\" else 1
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def _head(text: str, end: int) -> str:
    """Options between the title and the callback: ``{ tag: ... }``."""
    rest = text[end : end + 400]
    cut = min([x for x in (rest.find("=>"), rest.find("function")) if x >= 0] or [len(rest)])
    return rest[:cut]


def parse_spec(text: str) -> list[dict]:
    scopes = []
    for m in DESCRIBE_RE.finditer(text):
        head = _head(text, m.end())
        arrow = text.find("=>", m.end())
        body = text.find("{", arrow if arrow >= 0 else m.end())
        end = match_close(text, body) if body >= 0 else m.end()
        scopes.append((m.start(), end, m.group(2) + " " + head))
    tests = []
    for m in TEST_RE.finditer(text):
        head = _head(text, m.end())
        context = " ".join(t for (s, e, t) in scopes if s < m.start() < e)
        blob = f"{m.group(3)} {head} {context}"
        flow = FLOW_RE.search(blob) or ANNOT_RE.search(blob)
        tests.append({"title": m.group(3), "flow": flow.group(1) if flow else None, "pos": m.start()})
    return tests


def find_retries(root: Path) -> list[tuple[str, str]]:
    found = []
    pw_cfg = re.compile(r"^playwright\.config\.[cm]?[jt]s$")
    for full, rel in walk(root):
        name = full.name
        if pw_cfg.match(name):
            text = full.read_text(errors="ignore")
            for m in re.finditer(r"\bretries\s*:\s*([^,\n}]+)", text):
                if re.search(r"[1-9]", m.group(1)):
                    found.append((rel, f"retries: {m.group(1).strip()} in Playwright config"))
        elif name.endswith((".spec.ts", ".spec.js", ".test.ts")):
            text = full.read_text(errors="ignore")
            for m in re.finditer(r"describe\.configure\(\s*\{[^}]*\bretries\s*:\s*(\d+)", text):
                if int(m.group(1)) > 0:
                    found.append((rel, f"describe.configure retries: {m.group(1)}"))
        elif name.endswith(".py") or name in ("pytest.ini", "tox.ini", "setup.cfg", "pyproject.toml"):
            text = full.read_text(errors="ignore")
            if name.endswith(".py"):
                if re.search(r"@pytest\.mark\.(flaky|rerun)\w*|^\s*@flaky\b", text, re.M):
                    found.append((rel, "flaky/rerun marker"))
            elif re.search(r"--reruns\b|\breruns\s*=", text):
                found.append((rel, "pytest reruns configured"))
    return found


def collect(root: Path, project) -> tuple[dict[str, str], dict[str, int]]:
    """Return (offenders key -> message, tests per flow)."""
    flows = set(project.flows)
    known = ", ".join(sorted(flows)) or "none defined"
    matcher = glob_regex(project.get("tests", "e2e_glob") or "**/*.spec.ts")
    offenders: dict[str, str] = {}
    per_flow: dict[str, int] = {}
    for full, rel in walk(root):
        if not matcher.match(rel):
            continue
        for t in parse_spec(full.read_text(errors="ignore")):
            title = " ".join(t["title"].split())
            if t["flow"] is None:
                offenders[f"no-flow:{rel}:{title}"] = (
                    f'{rel}: e2e test "{title}" names no flow. '
                    f"Fix: add '@flow <id>' to its title or tag (flows in .arp/flows.toml: {known})."
                )
            elif t["flow"] not in flows:
                offenders[f"unknown-flow:{rel}:{title}:{t['flow']}"] = (
                    f'{rel}: e2e test "{title}" names flow "{t["flow"]}", which is not in .arp/flows.toml. '
                    f"Fix: use an existing flow ({known}) or add the flow to flows.toml for the owner to review."
                )
            else:
                per_flow[t["flow"]] = per_flow.get(t["flow"], 0) + 1
    cap = int(project.get("tests", "e2e_per_flow"))
    for flow, count in sorted(per_flow.items()):
        if count > cap:
            offenders[f"cap:{flow}"] = (
                f'flow "{flow}" has {count} e2e tests, over the cap of {cap}. '
                "Fix: merge them into the existing flow test or delete the ones that add nothing."
            )
    for rel, what in find_retries(root):
        offenders[f"retries:{rel}:{what}"] = (
            f"{rel}: {what}. Fix: remove the retries; fix the cause of the flake or delete the test."
        )
    return offenders, per_flow


def run(args) -> int:
    project = config.load_project(".")
    if project is None:
        print("arp test-guard: not inside a git repository.", file=sys.stderr)
        return 1
    root = project.root
    offenders, per_flow = collect(root, project)
    path = root / BASELINE
    if args.baseline:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"offenders": sorted(offenders), "flow_counts": per_flow}, indent=2) + "\n")
        print(f"Baseline written: {len(offenders)} offender(s) grandfathered in {BASELINE}.")
        return 0
    base = {"offenders": [], "flow_counts": {}}
    if path.is_file():
        try:
            base = json.loads(path.read_text())
        except ValueError:
            print(f"arp test-guard: {BASELINE} is not valid JSON; ignoring it.", file=sys.stderr)
    old = set(base.get("offenders", []))
    counts = base.get("flow_counts", {})
    problems = []
    for key, message in offenders.items():
        if key in old:
            if key.startswith("cap:") and per_flow.get(key[4:], 0) > counts.get(key[4:], 0):
                problems.append(message + " (it grew since the baseline)")
            continue
        problems.append(message)
    for line in problems:
        print(line)
    if problems:
        print(f"test-guard: {len(problems)} problem(s).", file=sys.stderr)
        return 1
    print("test-guard: ok")
    return 0
