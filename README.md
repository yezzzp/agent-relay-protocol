# agent-core

A Claude Code plugin for working with several coding agents on one project without losing context, stepping on each other, or shipping unverified work.

## What it gives you

- **One way of working, everywhere.** Open Claude in any folder and it already knows the workflow: worktree, test first, verify, integrate, record decisions. A session-start hook loads it, and loads it again after every compaction. See `skills/work/WORKFLOW.md`.

- **Isolated sessions.** Each task runs in its own git worktree, with its own test database and ports.
- **One integrator.** A script merges finished work into `develop`, rebuilds the database and runs the tests. `main` moves only when you say so.
- **A session limit.** A warning when more than three sessions talk to you at once. It never blocks. Idle sessions offer to hand off and close.
- **Work that survives.** Big tasks keep your exact words in a task file, so compaction and handoffs lose nothing.
- **Real verification.** Unit tests for business rules, critical end-to-end tests on every integration, the full suite before production.
- **Cheap UI checks.** Deterministic browser checks first, one LLM pass last, and a report built from a template.
- **One style.** A minimal base style for every product, plus a brand layer per project.
- **Shared memory.** Owner decisions are stored one fact per file and searched before acting.

## Install

```
/plugin install agent-core --marketplace yezzzp/agent-relay-protocol
```

On Claude Code older than 2.1.275:

```
/plugin marketplace add yezzzp/agent-relay-protocol
/plugin install agent-core@agent-core
```

For Codex CLI and the statusline:

```
git clone https://github.com/yezzzp/agent-relay-protocol ~/Projects/agent-core
~/Projects/agent-core/install.sh
```

## Adopt a project

The first time you open Claude in a project, agent-core audits it: docs, stack, tests, branches, task and memory folders. Then it asks once:

- **Adopt everything:** fills in only what is missing. Existing files win.
- **Choose pieces:** for example only `tests` and `ui-check`.
- **Not in this project:** nothing is injected, and it never asks again.

The answer is stored on your machine, not in the repo. Change it with `arp adopt`, `arp decline` or `arp audit`. To try agent-core on a few projects only, set `default = "off"` in `~/.config/agent-core/config.toml` and enable them one by one.

Adopting everything runs:

```
agent-init
```

It sets **how the project works** before any feature: verify commands, main user flows (`.arp/flows.toml`), the business rules that get TDD, ports and branches. It writes `AGENTS.md`, `CLAUDE.md`, `.arp/config.toml` and `.arp/flows.toml`. The config keys:

| Key | Meaning |
|---|---|
| `verify.quick` | Lint, types and the tests touched by your change. Every session runs it. |
| `verify.full` | Every unit test. Run by the integrator. |
| `verify.e2e` | Critical end-to-end tests. Run by the integrator. |
| `verify.e2e_full` | Every end-to-end test. Run before a release. |
| `env.*` | Test database prefix and rebuild command, first free ports. |
| `branches.*` | Integration and production branch names. |
| `sessions.*` | Session limit, and the idle time before handoff. |

Project knowledge (domain rules, brand, screens) goes in the project's `.claude/skills/`, never in the plugin.

## Daily flow

1. **Start.** `/agent-core:work <task>`. The agent classifies it:
   - **Small:** could another agent finish it from the request and `git diff`? It just does it.
   - **Big:** it opens `docs/ai/tasks/<slug>.md` with your words verbatim (S1, S2…), the tasks and the decisions.
2. **Work.** In its own worktree. Subagents take the jobs that need no conversation with you.
3. **Verify.** `verify.quick` must pass. UI changes also pass `ui-check`.
4. **Integrate.** `arp integrate <branch>`. If it fails, nothing is merged and the report says what to fix.
5. **Release.** `arp release vN.x.y` runs the full suite and tags `main`. Only when you decide.

## Sessions or subagents

| Use | When |
|---|---|
| A **session** | You will talk to it: answer its questions, review it, iterate. |
| A **subagent** | You will only read its result. |

One session per round of work, closed once that round is integrated.

## Tests

| Tier | Runs | Contains |
|---|---|---|
| Unit | every change | business rules, written test-first (red, green, refactor) |
| Critical e2e | every integration | one test per main user flow, tagged `@critical` |
| Full e2e | before a release | everything |

Before writing a test, the agent picks the tier with a six-step decision guide, with generic patterns, after the project's own rules. It writes its choice down first (`tier: unit (rule 2) · covers S3`). A guard fails `verify.quick` when an e2e test names no flow from `.arp/flows.toml`, or when a flow goes over its cap.

When testing finds a bug:

| Kind of bug | Fix |
|---|---|
| A business rule | a unit test first, then the fix |
| A UI detail | a structural fix, such as a component that cannot fail that way |
| A broken flow | an e2e test |

Every test run, from every project, is recorded in one local database, `~/.local/share/agent-core/agent-core.db`, where each row points to its project. `arp test-health` turns that history into a report covering cost, flaky tests, value, suspects, duplicates and the weekly trend. A suspect is a test that never fails while the code it covers keeps changing. Mutation testing decides whether to delete it, and you approve each deletion. Every 7 days (`tests.report_every_days`) a report page is written to `~/.local/share/agent-core/reports/<project>/`, and the next session tells you what changed. Nothing runs in the background between sessions.

## Commands

| Command | Does |
|---|---|
| `agent-init` | Set up a project's charter and files |
| `arp status` | This project's adoption state and audit |
| `arp adopt [--state partial --pieces …]`, `arp decline` | Decide whether this project uses agent-core |
| `arp audit` | Audit again; the next session asks again |
| `arp projects` | Every project and its state |
| `arp config check` | Validate `.arp/config.toml`, ports and flows |
| `arp doctor` | What is installed and where, and what this machine is missing |
| `arp tools [--fix]` | Missing tools for this project, with the install command; `--fix` runs the ones without sudo |
| `arp update` | Update the repo, the links and the hooks |
| `arp sessions [set <state>]` | List sessions and their state, or set yours |
| `arp integrate <branch>` | Merge into `develop` after the checks pass |
| `arp release <tag>` | Full suite, then tag `main` |
| `arp test-health` | Report on test value and cost |
| `arp test-report` | The periodic report (every 7 days, started by the session hook) |
| `arp lessons [--check]` | Memory index limits, and rules that should become checks |
| `arp worktrees new <branch>` | Worktree from `develop`, with `.env`, the test map, its own ports and database |
| `arp worktrees prune` | Remove merged worktrees and their databases |

## Skills

| Skill | Use |
|---|---|
| `work` | Entry point for any task |
| `integrate` | Branch model, and how to request an integration |
| `sessions` | Session limit, pausing and closing |
| `relay`, `resume` | Hand a task to another agent, and pick it up |
| `commit` | Conventional Commits |
| `memory` | Search and record owner decisions |
| `tests` | Test tiers and the fix rule |
| `ui-check` | Deterministic browser checks with Playwright |
| `explore` | One LLM pass for business rules |
| `style` | Base visual style |
| `no-comments` | Remove comments that restate the code |

## License

MIT
