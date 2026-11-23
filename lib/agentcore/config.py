"""Project and user configuration.

Project: ``<git root>/.arp/config.toml`` and ``<git root>/.arp/flows.toml``.
User:    ``$AGENT_CORE_CONFIG_HOME/config.toml`` (default ``~/.config/agent-core``).
"""

import os
import subprocess
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULTS: dict = {
    "verify": {"quick": "", "full": "", "e2e": "", "e2e_full": ""},
    "env": {"db_prefix": "", "db_rebuild": "", "db_drop": "", "web_port": 3011, "api_port": 8011},
    "branches": {
        "integration": "develop",
        "production": "main",
        "integration_worktree": "{root}-wt/{integration}",
        "production_worktree": "{root}-wt/{production}",
    },
    "sessions": {"soft_limit": 3, "idle_hours": 6},
    "tests": {
        "record": True,
        "suspect_runs": 10,
        "e2e_per_flow": 3,
        "e2e_glob": "**/*.spec.ts",
        "report_every_days": 7,
    },
}

USER_DEFAULTS: dict = {"default": "ask"}


def git(path: Path | str, *args: str) -> str:
    out = subprocess.run(
        ["git", "-C", str(path), *args], capture_output=True, text=True, check=False
    )
    return out.stdout.strip() if out.returncode == 0 else ""


def git_root(path: Path | str = ".") -> Path | None:
    top = git(path, "rev-parse", "--show-toplevel")
    return Path(top) if top else None


def main_root(path: Path | str = ".") -> Path | None:
    """The main checkout of a repo, also when called from one of its worktrees."""
    common = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        return None
    common_path = Path(common)
    return common_path.parent if common_path.name == ".git" else git_root(path)


def merge(base: dict, over: dict) -> dict:
    result = {k: (dict(v) if isinstance(v, dict) else v) for k, v in base.items()}
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def read_toml(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open("rb") as handle:
        return tomllib.load(handle)


@dataclass
class Project:
    root: Path
    config: dict
    flows: dict = field(default_factory=dict)
    has_config: bool = False

    def get(self, section: str, key: str):
        return self.config.get(section, {}).get(key)


def load_project(path: Path | str = ".") -> Project | None:
    root = git_root(path)
    if root is None:
        return None
    raw = read_toml(root / ".arp" / "config.toml")
    if not raw and (main := main_root(path)) and main != root:
        raw = read_toml(main / ".arp" / "config.toml")
    flows = read_toml(root / ".arp" / "flows.toml")
    return Project(root=root, config=merge(DEFAULTS, raw), flows=flows, has_config=bool(raw))


def user_config_home() -> Path:
    return Path(os.environ.get("AGENT_CORE_CONFIG_HOME", Path.home() / ".config" / "agent-core"))


def load_user() -> dict:
    return merge(USER_DEFAULTS, read_toml(user_config_home() / "config.toml"))
