---
name: integrate
description: Branch model and integration for agent-core projects. Start every code task in its own worktree; finish it with `arp integrate`; move production only with `arp release` when the owner says so. Use when starting a code task, when it is done, when asked to merge, integrate, release or ship, or to clean up worktrees.
---

# integrate

## Branches
| Branch | Role | Who moves it |
|---|---|---|
| `develop` (config `branches.integration`) | everything finished, verified together | `arp integrate`, never by hand |
| `main` (config `branches.production`) | production | `arp release vN.x.y`, only when the owner says so |
| one branch per task | the work | its session |

## Start
```bash
root=$(git rev-parse --show-toplevel)
git -C "$root" worktree add "$root-wt/<task>" -b <task> develop
cd "$root-wt/<task>"
```
- Use the test database `arp worktrees new` printed (`<db_prefix><worktree folder>`). Rebuild it with the `env.db_rebuild` command from `.arp/config.toml`.
- Use the first free ports from `env.web_port` and `env.api_port`.
- Never use another session's database or ports.
- Run `arp sessions` first. Above the soft limit, warn the owner once and continue if they want.

## Finish
1. The quick verify command passes, and the worktree is clean (everything committed).
2. `arp integrate <task>`. It locks, merges in the integration worktree, rebuilds the database, runs the full suite and the critical e2e tests, and writes `.arp/integration/<date>-<task>.md`.
3. If it fails, nothing was merged. Read the report, fix it in your branch, and run it again.
4. When it lands, `arp sessions set ready`. The dev server of that worktree is stopped.

## Release
`arp release vN.x.y` runs everything (full suite and every e2e test) and tags production. It never pushes: show the owner the push command it prints.

## Clean up
`arp worktrees prune` lists merged, clean worktrees. With `--yes` it removes them and their test databases. Confirm with the owner first.
