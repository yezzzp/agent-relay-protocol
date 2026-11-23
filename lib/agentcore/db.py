"""The one local database shared by every project.

Location: ``$AGENT_CORE_DB`` or ``~/.local/share/agent-core/agent-core.db``.
It holds the adoption registry and the test history. Every row points to a
``projects`` row. It never lives inside a repo.
"""

import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from agentcore.config import git, main_root

SCHEMA = """
CREATE TABLE IF NOT EXISTS projects (
    id         INTEGER PRIMARY KEY,
    key        TEXT NOT NULL UNIQUE,
    name       TEXT NOT NULL,
    path       TEXT NOT NULL,
    remote     TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS registry (
    project_id INTEGER PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    state      TEXT NOT NULL CHECK (state IN ('unknown','adopted','partial','declined')),
    pieces     TEXT NOT NULL DEFAULT '',
    decided_at TEXT,
    audit_hash TEXT
);
CREATE TABLE IF NOT EXISTS tests (
    id         INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    file       TEXT NOT NULL,
    name       TEXT NOT NULL,
    tier       TEXT NOT NULL,
    flow       TEXT,
    first_seen TEXT NOT NULL,
    last_seen  TEXT NOT NULL,
    deleted_at TEXT,
    UNIQUE (project_id, file, name)
);
CREATE TABLE IF NOT EXISTS runs (
    id         INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    started_at TEXT NOT NULL,
    branch     TEXT,
    commit_sha TEXT,
    command    TEXT,
    tier       TEXT NOT NULL,
    runner     TEXT NOT NULL,
    duration_s REAL
);
CREATE TABLE IF NOT EXISTS results (
    run_id     INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    test_id    INTEGER NOT NULL REFERENCES tests(id) ON DELETE CASCADE,
    outcome    TEXT NOT NULL CHECK (outcome IN ('pass','fail','skip','flaky')),
    duration_s REAL,
    PRIMARY KEY (run_id, test_id)
);
CREATE TABLE IF NOT EXISTS coverage_changes (
    test_id    INTEGER PRIMARY KEY REFERENCES tests(id) ON DELETE CASCADE,
    commits    INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS test_totals (
    test_id    INTEGER PRIMARY KEY REFERENCES tests(id) ON DELETE CASCADE,
    runs       INTEGER NOT NULL DEFAULT 0,
    passes     INTEGER NOT NULL DEFAULT 0,
    fails      INTEGER NOT NULL DEFAULT 0,
    flakies    INTEGER NOT NULL DEFAULT 0,
    skips      INTEGER NOT NULL DEFAULT 0,
    duration_s REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS run_stats (
    run_id  INTEGER PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
    tests   INTEGER NOT NULL,
    fails   INTEGER NOT NULL,
    flakies INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS results_test ON results(test_id);
CREATE INDEX IF NOT EXISTS runs_project ON runs(project_id, started_at);
"""

PIECES = ("workflow", "worktrees", "integrator", "tests", "ui-check", "style", "memory", "relay")


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def db_path() -> Path:
    default = Path.home() / ".local" / "share" / "agent-core" / "agent-core.db"
    return Path(os.environ.get("AGENT_CORE_DB", default))


def connect() -> sqlite3.Connection:
    path = db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn


def project_key(path: Path | str) -> tuple[str, str, Path, str] | None:
    """Return (key, name, root, remote) for the repo at ``path``.

    The key is the origin remote when there is one, so every worktree and every
    clone of the same repo shares one row. Otherwise it is the main checkout path.
    """
    root = main_root(path)
    if root is None:
        return None
    remote = git(root, "remote", "get-url", "origin")
    key = remote or str(root)
    return key, root.name, root, remote


def ensure_project(conn: sqlite3.Connection, path: Path | str = ".") -> sqlite3.Row | None:
    found = project_key(path)
    if found is None:
        return None
    key, name, root, remote = found
    conn.execute(
        "INSERT INTO projects (key, name, path, remote, created_at) VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT(key) DO UPDATE SET path = excluded.path",
        (key, name, str(root), remote or None, now()),
    )
    conn.commit()
    return conn.execute("SELECT * FROM projects WHERE key = ?", (key,)).fetchone()


def registry(conn: sqlite3.Connection, project_id: int) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM registry WHERE project_id = ?", (project_id,)).fetchone()


def set_registry(
    conn: sqlite3.Connection,
    project_id: int,
    state: str,
    pieces: list[str] | None = None,
    audit_hash: str | None = None,
) -> None:
    conn.execute(
        "INSERT INTO registry (project_id, state, pieces, decided_at, audit_hash) "
        "VALUES (?, ?, ?, ?, ?) ON CONFLICT(project_id) DO UPDATE SET "
        "state = excluded.state, pieces = excluded.pieces, decided_at = excluded.decided_at, "
        "audit_hash = COALESCE(excluded.audit_hash, registry.audit_hash)",
        (project_id, state, ",".join(pieces or []), now() if state != "unknown" else None, audit_hash),
    )
    conn.commit()
