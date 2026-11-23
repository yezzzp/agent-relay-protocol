"""Worktree, process and shell helpers shared by integrate, release, sessions and worktrees."""

import os
import re
import signal
import subprocess
import time
from pathlib import Path

SERVER_RE = re.compile(r"next|vite|uvicorn|npm run dev|pnpm dev")


def git(path, *args, check=False):
    out = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True)
    if check and out.returncode != 0:
        raise RuntimeError((out.stderr or out.stdout).strip())
    return out


def sh(command, cwd):
    """Run a shell string. Returns (returncode, combined output, seconds)."""
    start = time.monotonic()
    out = subprocess.run(
        command, shell=True, cwd=str(cwd), capture_output=True, text=True, errors="replace"
    )
    return out.returncode, (out.stdout or "") + (out.stderr or ""), time.monotonic() - start


def worktrees(path=".") -> list[dict]:
    out = git(path, "worktree", "list", "--porcelain").stdout
    result, cur = [], {}
    for line in out.splitlines() + [""]:
        if not line:
            if cur:
                result.append(cur)
            cur = {}
            continue
        key, _, value = line.partition(" ")
        cur[key] = value
        if key == "branch":
            cur["branch"] = value.removeprefix("refs/heads/")
    return [
        {"path": Path(w["worktree"]), "branch": w.get("branch", ""), "head": w.get("HEAD", "")}
        for w in result
    ]


def dirty_files(path) -> list[str]:
    """Uncommitted paths, ignoring agent-core's own .arp/ state files."""
    out = git(path, "status", "--porcelain").stdout.splitlines()
    return [line for line in out if not line[3:].strip('"').startswith(".arp/")]


def expand(template: str, root: Path, **names) -> Path:
    return Path(template.format(root=str(root), **names))


def sanitize(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def _pids():
    try:
        return [int(n) for n in os.listdir("/proc") if n.isdigit()]
    except OSError:
        return []


def _cwd(pid):
    try:
        return Path(os.readlink(f"/proc/{pid}/cwd"))
    except OSError:
        return None


def _cmdline(pid) -> list[str]:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return []
    return [a.decode(errors="replace") for a in raw.split(b"\0") if a]


def _inside(path: Path | None, base: Path) -> bool:
    if path is None:
        return False
    try:
        path.relative_to(base.resolve())
        return True
    except ValueError:
        return False


def server_pids(base: Path) -> list[int]:
    found = []
    for pid in _pids():
        if pid == os.getpid() or not _inside(_cwd(pid), base):
            continue
        if SERVER_RE.search(" ".join(_cmdline(pid))):
            found.append(pid)
    return found


def rss_mb(pids) -> float:
    total = 0
    for pid in pids:
        try:
            for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1])
        except (OSError, ValueError):
            pass
    return total / 1024


def stop_servers(base: Path) -> int:
    pids = server_pids(base)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    return len(pids)


def claude_count(bases: list[Path]) -> int:
    count = 0
    for pid in _pids():
        cmd = _cmdline(pid)
        if not cmd or os.path.basename(cmd[0]) != "claude":
            try:
                comm = Path(f"/proc/{pid}/comm").read_text().strip()
            except OSError:
                continue
            if comm != "claude":
                continue
        cwd = _cwd(pid)
        if any(_inside(cwd, b) for b in bases):
            count += 1
    return count
