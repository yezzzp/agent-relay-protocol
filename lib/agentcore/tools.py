"""What this machine needs, and the exact command to install what is missing.

The needs come from the project's commands: the first word of each verify and
env command (uv, pnpm, docker…), plus Playwright when ``ui-check`` is
configured. agent-core itself needs only git and Python 3.11+.
"""

import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# tool -> (why, install commands per system package manager, needs sudo)
KNOWN: dict[str, dict] = {
    "git": {"pacman": "sudo pacman -S git", "apt": "sudo apt install git", "dnf": "sudo dnf install git",
            "brew": "brew install git"},
    "python3": {"pacman": "sudo pacman -S python", "apt": "sudo apt install python3", "dnf": "sudo dnf install python3",
                "brew": "brew install python"},
    "uv": {"any": "curl -LsSf https://astral.sh/uv/install.sh | sh", "brew": "brew install uv"},
    "poetry": {"any": "curl -sSL https://install.python-poetry.org | python3 -"},
    "node": {"pacman": "sudo pacman -S nodejs", "apt": "sudo apt install nodejs", "dnf": "sudo dnf install nodejs",
             "brew": "brew install node"},
    "pnpm": {"any": "corepack enable pnpm", "brew": "brew install pnpm"},
    "npm": {"pacman": "sudo pacman -S npm", "apt": "sudo apt install npm", "dnf": "sudo dnf install npm",
            "brew": "brew install node"},
    "npx": {"pacman": "sudo pacman -S npm", "apt": "sudo apt install npm", "brew": "brew install node"},
    "docker": {"pacman": "sudo pacman -S docker docker-compose", "apt": "sudo apt install docker.io docker-compose-v2",
               "dnf": "sudo dnf install docker", "brew": "brew install --cask docker"},
    "go": {"pacman": "sudo pacman -S go", "apt": "sudo apt install golang", "dnf": "sudo dnf install golang",
           "brew": "brew install go"},
    "cargo": {"any": "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"},
    "gh": {"pacman": "sudo pacman -S github-cli", "apt": "sudo apt install gh", "dnf": "sudo dnf install gh",
           "brew": "brew install gh"},
    "psql": {"pacman": "sudo pacman -S postgresql", "apt": "sudo apt install postgresql-client",
             "dnf": "sudo dnf install postgresql", "brew": "brew install libpq"},
    "make": {"pacman": "sudo pacman -S make", "apt": "sudo apt install make", "brew": "xcode-select --install"},
}
SHELL_WORDS = {"cd", "export", "env", "true", "false", "test", "echo", "if", "then", "fi", "for", "do", "done",
               "TODO", "bash", "sh", "set", "exec", "time", "timeout", "xargs", "grep", "sed", "git"}


@dataclass
class Need:
    tool: str
    why: str
    install: str = ""
    sudo: bool = False
    project_step: bool = False  # runs inside the project, no sudo (uv sync, playwright browsers)


def system_pm() -> str:
    if platform.system() == "Darwin":
        return "brew"
    for pm in ("pacman", "apt", "dnf"):
        if shutil.which(pm):
            return pm
    return ""


def install_hint(tool: str) -> str:
    recipes = KNOWN.get(tool, {})
    return recipes.get(system_pm()) or recipes.get("any") or ""


def command_words(command: str) -> list[str]:
    words = []
    for part in re.split(r"&&|\|\||;|\|", command):
        tokens = [t for t in part.strip().split() if "=" not in t.split("/")[0] or t.startswith("-")]
        if tokens and tokens[0] not in SHELL_WORDS and re.fullmatch(r"[\w.+-]+", tokens[0]):
            words.append(tokens[0])
    return words


def project_needs(root: Path, cfg: dict) -> list[Need]:
    needs: dict[str, Need] = {}
    for section in ("verify", "env"):
        for key, command in cfg.get(section, {}).items():
            if isinstance(command, str):
                for word in command_words(command):
                    needs.setdefault(word, Need(word, f"{section}.{key}"))
    ui = cfg.get("ui", {})
    if ui.get("base_url") or ui.get("node_root"):
        needs.setdefault("node", Need("node", "ui-check"))
    return list(needs.values())


def playwright_missing(root: Path, cfg: dict) -> Need | None:
    ui = cfg.get("ui", {})
    if not (ui.get("base_url") or ui.get("node_root")):
        return None
    candidates = [Path(ui["node_root"])] if ui.get("node_root") else [root, root / "web", root / "frontend", root / "app"]
    candidates = [c if c.is_absolute() else root / c for c in candidates]
    for folder in candidates:
        if (folder / "node_modules" / "playwright").exists() or (folder / "node_modules" / "@playwright" / "test").exists():
            cache = Path.home() / (".cache/ms-playwright" if platform.system() != "Darwin" else "Library/Caches/ms-playwright")
            if not any(cache.glob("chromium*")):
                runner = "pnpm exec" if (folder / "pnpm-lock.yaml").exists() else "npx"
                return Need("chromium", "ui-check", f"cd {folder} && {runner} playwright install chromium",
                            project_step=True)
            return None
    folder = candidates[0] if ui.get("node_root") else (root / "web" if (root / "web").is_dir() else root)
    runner = "pnpm add -D" if (folder / "pnpm-lock.yaml").exists() else "npm i -D"
    return Need("playwright", "ui-check", f"cd {folder} && {runner} playwright && npx playwright install chromium",
                project_step=True)


def deps_missing(root: Path) -> list[Need]:
    out = []
    if (root / "uv.lock").exists() and not (root / ".venv").is_dir():
        out.append(Need("project python deps", ".venv missing", f"cd {root} && uv sync", project_step=True))
    for folder in [root, root / "web", root / "frontend", root / "mobile"]:
        if (folder / "package.json").exists() and not (folder / "node_modules").is_dir():
            pm = "pnpm install" if (folder / "pnpm-lock.yaml").exists() else "npm ci"
            out.append(Need(f"node deps in {folder.name or '.'}", "node_modules missing", f"cd {folder} && {pm}",
                            project_step=True))
    return out


def check(root: Path | None, cfg: dict | None) -> list[Need]:
    """Everything missing on this machine for agent-core and, if given, the project."""
    missing = []
    if not shutil.which("git"):
        missing.append(Need("git", "agent-core"))
    if sys.version_info < (3, 11):
        missing.append(Need("python3", f"agent-core needs Python 3.11+, found {platform.python_version()}"))
    if root is not None and cfg is not None:
        for need in project_needs(root, cfg):
            if not shutil.which(need.tool):
                missing.append(need)
        if extra := playwright_missing(root, cfg):
            missing.append(extra)
        missing += deps_missing(root)
    for need in missing:
        if not need.install:
            need.install = install_hint(need.tool)
        need.sudo = need.install.startswith("sudo ")
    return missing


def run_fix(needs: list[Need]) -> list[tuple[Need, bool]]:
    """Run the installs that need no sudo. The rest stay for the owner."""
    done = []
    for need in needs:
        if need.sudo or not need.install:
            continue
        ok = subprocess.run(need.install, shell=True).returncode == 0
        done.append((need, ok))
    return done
