"""Fast, deterministic audit of a repo: what agent-core finds and what is missing.

No model is involved. Results are cached per repo HEAD in
``$XDG_CACHE_HOME/agent-core/audit`` so the session-start hook stays fast.
"""

import hashlib
import json
import os
from pathlib import Path

from agentcore.config import git

SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "dist", "build", ".next", "target", "__pycache__"}
WORKFLOW_WORDS = ("worktree", "integrat", "tdd", "task file", "docs/ai/tasks", "handoff", "relay")


def cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "agent-core" / "audit"


def shallow_files(root: Path, depth: int = 2) -> list[Path]:
    found: list[Path] = []
    stack = [(root, 0)]
    while stack:
        folder, level = stack.pop()
        try:
            entries = list(folder.iterdir())
        except OSError:
            continue
        for entry in entries:
            if entry.is_dir():
                if level < depth and entry.name not in SKIP_DIRS:
                    stack.append((entry, level + 1))
            else:
                found.append(entry)
    return found


def detect_stack(names: set[str]) -> list[str]:
    stack = []
    if "pyproject.toml" in names or "requirements.txt" in names:
        tool = "uv" if "uv.lock" in names else "poetry" if "poetry.lock" in names else "pip"
        stack.append(f"python ({tool})")
    if "package.json" in names:
        tool = (
            "pnpm" if "pnpm-lock.yaml" in names
            else "yarn" if "yarn.lock" in names
            else "bun" if "bun.lockb" in names or "bun.lock" in names
            else "npm"
        )
        stack.append(f"node ({tool})")
    if "go.mod" in names:
        stack.append("go")
    if "Cargo.toml" in names:
        stack.append("rust")
    return stack


def run_audit(root: Path) -> dict:
    files = shallow_files(root)
    names = {f.name for f in files}
    rel = {str(f.relative_to(root)) for f in files}

    docs = [root / n for n in ("CLAUDE.md", "AGENTS.md") if (root / n).is_file()]
    doc_text = " ".join(d.read_text(errors="ignore").lower() for d in docs)

    unit = any(
        n.startswith("test_") and n.endswith(".py") or n.endswith("_test.py") or n.endswith("_test.go")
        or ".test." in n
        for n in names
    ) or (root / "tests").is_dir()
    e2e = sorted({n for n in names if n.startswith(("playwright.config", "cypress.config"))})
    ci = (root / ".github" / "workflows").is_dir() or ".gitlab-ci.yml" in names

    branches = set(git(root, "branch", "--format=%(refname:short)").split())
    worktrees = git(root, "worktree", "list", "--porcelain").count("worktree ")

    memory_dirs = [
        d for d in ("docs/ai/memoria", "docs/ai/memory", "docs/memory", ".memory")
        if (root / d).is_dir()
    ]

    facts = {
        "claude_md": (root / "CLAUDE.md").is_file(),
        "agents_md": (root / "AGENTS.md").is_file(),
        "docs_describe_workflow": any(w in doc_text for w in WORKFLOW_WORDS),
        "stack": detect_stack(names),
        "unit_tests": unit,
        "e2e_runner": [n.split(".")[0] for n in e2e],
        "ci": ci,
        "branches": sorted(b for b in branches if b in {"main", "master", "develop", "dev"}),
        "worktrees": max(worktrees - 1, 0),
        "task_folder": (root / "docs" / "ai" / "tasks").is_dir(),
        "memory_folder": memory_dirs[0] if memory_dirs else "",
        "arp_config": (root / ".arp" / "config.toml").is_file(),
        "arp_flows": (root / ".arp" / "flows.toml").is_file(),
        "tracked_files": len(rel),
    }
    facts["missing"] = missing(facts)
    return facts


def missing(f: dict) -> list[str]:
    out = []
    if not f["agents_md"] and not f["claude_md"]:
        out.append("AGENTS.md")
    if not f["arp_config"]:
        out.append(".arp/config.toml (verify commands, ports, branches)")
    if not f["arp_flows"]:
        out.append(".arp/flows.toml (main user flows)")
    if not f["unit_tests"]:
        out.append("unit tests")
    if "develop" not in f["branches"]:
        out.append("integration branch `develop`")
    if not f["task_folder"]:
        out.append("docs/ai/tasks/")
    if not f["memory_folder"]:
        out.append("a memory folder")
    return out


def significant(facts: dict) -> str:
    """Hash of the facts whose change is worth telling an adopted project."""
    keys = ("claude_md", "agents_md", "stack", "unit_tests", "e2e_runner", "ci", "arp_config", "arp_flows")
    blob = json.dumps({k: facts.get(k) for k in keys}, sort_keys=True)
    return hashlib.sha1(blob.encode()).hexdigest()[:12]


def audit(root: Path, use_cache: bool = True) -> dict:
    head = git(root, "rev-parse", "HEAD") or "no-head"
    status = git(root, "status", "--porcelain", "--untracked-files=no")
    stamp = hashlib.sha1(f"{root}|{head}|{status}".encode()).hexdigest()
    path = cache_dir() / f"{stamp}.json"
    if use_cache and path.is_file():
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            pass
    facts = run_audit(root)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(facts))
    except OSError:
        pass
    return facts


def summary(f: dict) -> list[str]:
    has = []
    if f["claude_md"] or f["agents_md"]:
        docs = " and ".join(n for n, k in (("CLAUDE.md", "claude_md"), ("AGENTS.md", "agents_md")) if f[k])
        has.append(docs + (" (already describes a workflow)" if f["docs_describe_workflow"] else ""))
    if f["stack"]:
        has.append(", ".join(f["stack"]))
    if f["unit_tests"]:
        has.append("unit tests")
    if f["e2e_runner"]:
        has.append("e2e: " + ", ".join(f["e2e_runner"]))
    if f["ci"]:
        has.append("CI")
    if f["branches"]:
        has.append("branches: " + ", ".join(f["branches"]))
    if f["worktrees"]:
        has.append(f"{f['worktrees']} worktree(s)")
    if f["task_folder"]:
        has.append("docs/ai/tasks/")
    if f["memory_folder"]:
        has.append(f["memory_folder"])
    return [
        "Has: " + ("; ".join(has) if has else "nothing agent-core recognizes yet") + ".",
        "Missing: " + ("; ".join(f["missing"]) if f["missing"] else "nothing") + ".",
    ]
