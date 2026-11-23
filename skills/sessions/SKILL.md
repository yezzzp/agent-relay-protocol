---
name: sessions
description: Keep parallel work within what the owner can follow. Soft limit of talking sessions, a board of what each worktree is doing, and pausing idle sessions with a handoff. Use before opening another session, when the owner seems overloaded, when asked what is running, or when a session has waited a long time.
---

# sessions

## The rule
- **Session:** the owner talks to it. **Subagent:** the owner only reads its result. Prefer a subagent whenever no conversation is needed.
- **One session per round of work.** When the round is integrated, close the session. The next round starts fresh from the task file.
- **Soft limit:** `sessions.soft_limit` talking sessions (default 3). Above it, warn **once** and name which sessions could pause. Never block. The owner decides.

## Board
- `arp sessions` shows one line per worktree: branch, state, last activity, uncommitted changes, dev-server RAM.
- Set your own state when it changes: `arp sessions set working | waiting-owner | ready | idle`. `arp integrate` sets `integrated` when the branch lands; `arp worktrees prune` never removes a session that shows `working`.

## Pausing
A session that has waited on the owner longer than `sessions.idle_hours`:
1. Offer to pause.
2. On yes, write the handoff (skill `relay`), commit, and set `idle`.
3. The owner closes the window. `resume` picks it up later at no extra cost.

## Saving the machine
- After a successful integration, the worktree's dev server is stopped.
- Lower test workers when several sessions run tests at once.
- Optional: start sessions under `systemd-run --user --scope -p MemoryMax=6G claude`. A runaway session then dies alone, not the whole machine.
