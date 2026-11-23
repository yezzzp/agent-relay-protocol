# agent-core v2 — plan

**Goal.** One Claude Code plugin that gives every project the same way of working: isolated sessions, one integrator, real verification, a shared memory, and one visual style. Install it on any machine with two commands. Project-specific knowledge stays in each project.

**Status (2026-11-23).** Phases 0–10 are built on branch `v2`. Every suite passes (`bash tests/run.sh`), `claude plugin validate .` passes, and a real session in an adopted repo followed the workflow unprompted. Still open:
- Phase 11 (first real project): waiting for its owner. The project is marked `declined` until then, so its live sessions are not disturbed.
- Mutation testing has not run against a real mutmut. Only a fake one was used.
- `ui-check` was measured on a real app, 2026-11-23. A Sonnet session ran it on three screens in two themes and reported the findings. It took 4 turns, 32 s and about 113k tokens (79k cache read, 33k cache write, 0.5k output), about US$ 0.15. The LLM-driven explorer it replaces had a median of 170 turns and about 24M tokens per run, across 40 runs. Those runs also saved data and tried to break the screen, which is still `explore`'s job, so the ratio is only for the checks.
- That run found two bugs in `ui-check`, both fixed:
  - `requestfailed` crashed;
  - aborted requests counted as errors.
- `ui.login` accepts `label:<text>` and `button:<name>`, and refills the fields until submit is enabled (hydration).
- `arp lessons` is built. `arp test-report` writes the periodic test-health report, every `tests.report_every_days`.

- Changed-only tests: each stack template has `check_changed` (pytest-testmon, `vitest --changed`; Go caches per package; Rust has no selection). `agent-init` puts it in `verify.quick` and the full command in `verify.full`. `arp worktrees new` copies the test map (`.testmondata`) from the integration worktree, so the first run in a new worktree is already selective.
- New machine: `arp tools` lists what the project's commands need (uv, pnpm, docker…, Playwright and Chromium for `ui-check`, missing `.venv` or `node_modules`), with the install command for this system. `--fix` runs the ones without sudo. The session-start hook tells the agent what is missing, so it offers the install before the first command fails.

**This repo is public.** No project names, client data or business rules go here. Each project keeps its own adoption plan.

---

## 1. Decisions

These are closed. Do not reopen them during implementation.

| # | Decision | Why |
|---|---|---|
| D1 | agent-core becomes a Claude Code **plugin** with its own marketplace. `install.sh` stays only for Codex and the statusline. | It installs and updates the same way on every machine. No hand-made symlinks. |
| D2 | Everything in this repo is in **English**: skills, README, templates, commit messages. Projects keep their own language. | Anyone can read it. |
| D3 | Generic method goes in the plugin. Ports, database names, domain rules and brand go in the project. | Today project skills are linked globally and load in every repo. |
| D4 | Branches: `main` is production and only moves when the owner says so. `develop` is integration. A release is a tag `vN.x.y` on `main`. | Already proven in practice. |
| D5 | **Integration is a script**, run **locally** first, with CI later. The model steps in only on a conflict or a failure. | Merging, rebuilding the database and running the suite are mechanical. A session doing them costs memory and attention. |
| D6 | **Session = a conversation with the owner. Subagent = a job with no conversation.** If you will answer its questions, it is a session. If you will only read its result, it is a subagent. | Clear rule for when to use which. |
| D7 | **3 talking sessions is a soft limit.** Over it, the agent warns and proposes pausing one, but the owner can go on. The integrator script and subagents do not count. | The bottleneck is the owner's attention, not the machine. The owner decides. |
| D8 | **One session per round**, not per topic. When the round is integrated, the session closes. | Long sessions compact many times and lose the owner's exact words. |
| D9 | Big work gets a **task file from the first edit**, holding the owner's **literal words** (borrowed from ODD). Small work gets no file. | The owner's rules must survive compaction and handoffs. |
| D10 | TDD only for **business rules** (unit tests). No TDD for UI. | Cheap where it matters, and it gives the agent a clear target. |
| D11 | Three test tiers: unit tests always, **critical e2e** on every integration, **full e2e** only before `main`. | Full e2e suites are slow and often serial. |
| D12 | A fix found while testing does not automatically add an e2e test. | Otherwise every QA fix leaves a browser test forever, and the suite only grows. |
| D13 | **Test runs are recorded in one global SQLite database** for all projects, like engram: `~/.local/share/agent-core/agent-core.db`. Every row points to its project with a foreign key. A report decides which tests earn their cost. | One database instead of one per project. It allows comparing projects, and it stays out of every repo. |
| D18 | **How we work comes first.** `agent-init` starts every project by setting the working charter: verify commands, main user flows, business rules, test tiers. The project's features come after. | The structure is the same in every project, and it is set before the first line of code. |
| D20 | **The workflow is global and always loaded.** A plugin `SessionStart` hook injects `WORKFLOW.md` (`skills/work/WORKFLOW.md`) plus the project's own settings in every session, in every project, and again after every compaction. `agent-init` sets up the project, but the way of working does not depend on it. | Opening Claude in any folder is enough: it already knows worktrees, tests first, the integrator and the memory. Re-injecting after a compaction fixes the loss of rules seen in long sessions. |
| D21 | **Opt-in per project, asked once.** The first time Claude opens a project, a script **audits** it and the agent asks once: adopt everything, choose pieces, or no. The answer is stored on the machine, outside the repo, and is never asked again. A project that says no gets nothing injected. A user-wide default (`ask`, `on` or `off`) covers people who want to try the plugin on a few projects only. | Advanced projects stay untouched if the owner wants. The owner decides per project, and others working on the same repo are not affected. |
| D19 | **The model decides the kind of test before writing one**, using the decision guide in §6. A **guard** enforces it: an e2e test must name a listed user flow, and each flow has a cap. | Without a rule and a guard, the e2e suite grows back no matter how often it is trimmed. |
| D14 | UI checks run **deterministic scripts first**. The LLM explorer runs once, at the end, for business rules. The report is built from a **template**, not written by the model. | LLM-driven checks are slow and expensive. |
| D15 | One **base style** (minimal, sober, Apple-like) for every product, plus a **brand layer** per project. | Same look everywhere, and no restating rules each time. |
| D16 | **No comments** that say *what* the code does. Only a *why* that cannot be encoded, and it should point to a memory file. | Stale comments mislead agents. |
| D17 | Not adopted: pstack and gentle-ai as whole packages. Ideas taken from them are listed in §5. | They fit other workflows: GitHub PRs, cloud agents, Cursor. |

---

## 2. Target layout

```
agent-core/
  .claude-plugin/
    plugin.json            name: agent-core
    marketplace.json       lets anyone run: /plugin marketplace add yezzzp/agent-relay-protocol
  skills/
    work/                  entry point: classify the task (small | big), pick the steps
    integrate/             branch model, request integration, read the integrator's report
    sessions/              session limit, board, pause and close
    relay/  resume/        handoff between agents (kept, simplified)
    commit/                Conventional Commits (kept)
    memory/                shared decision memory: how to search it, how to add to it
    tests/                 test tiers, the fix rule, test health
    ui-check/              Playwright + Chromium: deterministic checks and screenshots
    explore/               LLM explorer: one pass, business rules only
    style/                 base visual style
    no-comments/           remove "what" comments, turn constraints into checks
  bin/
    agent-init             adopt a project (kept)
    arp                    CLI: status | update | integrate | release | sessions | test-health
  scripts/
    integrate.sh           the integrator (D5)
    ui-check.mjs           deterministic browser checks, driven by the project config
    report.mjs             HTML report from JSON + screenshots (D14)
    test-health.py         test run recorder and report (D13)
  hooks/                   hooks.json: SessionStart injects the workflow; quota notice, plan capture (kept), test run recorder
  templates/               AGENTS.md, arp-block.md, task.md, project config
  statusline/              kept, plus the session count
  docs/
  tests/
```

Each project adds:

```
.arp/config.toml           commands, ports, database, branches, limits
.arp/flows.toml            the main user flows; each e2e test names one
.claude/skills/            domain skills and the brand layer
```

Shared by every project on the machine, outside any repo:

```
~/.local/share/agent-core/agent-core.db     test history of all projects
```

Example `.arp/config.toml`:

```toml
[verify]
quick    = "uv run ruff check . && uv run mypy app && uv run pytest -q -n auto --testmon"
full     = "uv run pytest -q -n 8 --testmon-noselect"
e2e      = "cd web && pnpm e2e --grep @critical"
e2e_full = "cd web && pnpm e2e"

[env]
db_prefix  = "app_test_"
db_rebuild = "scripts/test-db.sh {name}"
web_port   = 3011     # first free port; each worktree takes the next
api_port   = 8011

[branches]
integration = "develop"
production  = "main"

[sessions]
soft_limit = 3        # warn above this; never block
idle_hours = 6        # waiting on the owner longer than this: offer relay and close

[tests]
record          = true
suspect_runs    = 10  # covered code changed this many times and the test never failed
e2e_per_flow    = 3   # the guard fails above this
```

Example `.arp/flows.toml`:

```toml
[checkout]
says     = "A customer fills a cart, pays and gets a receipt."
critical = true

[refund]
says     = "Staff refunds a paid order and the stock comes back."
critical = true
```

---

## 3. Global skills cleanup

What happens to each kind of entry in `~/.claude/skills`:

| Entry | Today | Target |
|---|---|---|
| `commit`, `relay`, `resume` | symlinks to this repo | come from the plugin; delete the symlinks |
| Project skills (integrate, test, review UI, orchestrate, memory, style, per-app flows) | linked globally, so they load in every repo | generic method goes to the plugin skills; the rest moves to that project's `.claude/skills/` |
| Unrelated global tools | global | unchanged |

**Result:** no project skill is global. Opening another repo loads only the plugin.

---

## 4. Phases

### Phase 0: Package, translate, make public-ready
- [ ] Add `.claude-plugin/plugin.json` and `marketplace.json`. Move `templates/skills/*` to `skills/`.
- [ ] Translate the skills, the templates and `arp-block.md` to English.
- [ ] Replace `README.md` with `docs/README.next.md`.
- [ ] Keep `install.sh` for Codex and the statusline only.
- [ ] Public-ready:
  - Replace the one project-specific example in `templates/AGENTS.md`.
  - Add a CI check (`tests/no-private.sh`) that fails on a denylist of project names.
  - Check the git history before making the repo public. Today it has 1 match.
- **Check:** on a clean machine, `/plugin marketplace add yezzzp/agent-relay-protocol` and `/plugin install agent-core` give working `commit`, `relay` and `resume`. `tests/run.sh` and `tests/no-private.sh` pass.

### Phase 0b: The workflow in every session
- [ ] Write `skills/work/WORKFLOW.md`. Keep it under 80 lines, because it is loaded in every session.
- [ ] `hooks/hooks.json`, the same mechanism engram uses:
  - `SessionStart`, matcher `startup|clear`: runs `scripts/session-start.sh`.
  - `SessionStart`, matcher `compact`: runs the same script, which also reprints the active task file's `## Specs`.
- [ ] `session-start.sh` looks up the project in the registry (phase 0c) and prints, by state:

  | State | What it injects |
  |---|---|
  | `adopted` | `WORKFLOW.md`, the project's commands, ports, branch and test database, `sessions N/3`, and the active task file (path, status, next step) |
  | `partial` | Only the sections of `WORKFLOW.md` for the chosen pieces |
  | `declined` | Nothing |
  | `unknown` | The audit result, and the instruction to ask the owner once (phase 0c) |
- [ ] `agent-init` stops explaining the workflow. It only writes the project's charter (§4, phase 2) and its scaffolding.
- [ ] Remove the copy of the workflow from the ARP block in `AGENTS.md`. The block keeps only what is project-specific.
- **Check:**
  - Open Claude in an empty folder: the first reply to "add a feature" mentions a worktree, the test tier and `arp integrate`, with no other prompt.
  - Force a compaction in a big task: the next reply quotes the task file's S# verbatim.

### Phase 0c: Audit and opt-in per project
- [ ] **Registry**, a table in the global database (`~/.local/share/agent-core/agent-core.db`), keyed by the repo's git remote, or by its path when there is no remote:

  | Column | Meaning |
  |---|---|
  | `project_id` | the same `projects` row the test history uses |
  | `state` | `unknown`, `adopted`, `partial` or `declined` |
  | `pieces` | for `partial`: a subset of `workflow`, `worktrees`, `integrator`, `tests`, `ui-check`, `style`, `memory`, `relay` |
  | `decided_at`, `audit_hash` | when it was decided, and what the audit saw |

- [ ] **User default**, in `~/.config/agent-core/config.toml`: `default = "ask"` (the default), `"on"` (adopt every new project) or `"off"` (only projects enabled by hand).
- [ ] **Audit**, `scripts/audit.sh`. It is deterministic, takes under a second, and is cached by the repo's HEAD. It reports what exists and what is missing:
  - `CLAUDE.md` and `AGENTS.md`, and whether they already describe a workflow;
  - stack and package manager (the detection `agent-init` already does);
  - unit tests and their command; e2e tests and their runner; CI;
  - branches (`develop`, `main`), and worktrees in use;
  - `docs/ai/tasks/`, a memory folder, `.arp/config.toml`, `.arp/flows.toml`.
- [ ] **First visit** (state `unknown`): the agent shows the audit in a few lines and asks once, with `AskUserQuestion`:
  - **Adopt everything:** runs `agent-init`, which fills only what is missing.
  - **Choose pieces:** multi-select of the pieces above.
  - **Not in this project:** stores `declined` and says how to undo it.
  It stores the answer with `arp adopt --state … [--pieces …]` before doing anything else.
- [ ] **Respect what exists:**
  - Existing `CLAUDE.md`, `AGENTS.md`, test layout and branch names win.
  - `agent-init` adds blocks and does not rewrite.
  - When a project's rule contradicts `WORKFLOW.md`, the project wins, and the agent says so once.
- [ ] **Files in the repo are optional.** Adopting writes to the repo (the `AGENTS.md` block, `.arp/`) only after the owner agrees, because the repo may be shared. Without that, the registry alone drives the injection.
- [ ] **Commands:**
  - `arp status`: state and pieces for this project;
  - `arp adopt`, `arp decline`;
  - `arp audit`: run the audit again and ask again;
  - `arp projects`: every project and its state.
- [ ] A big change in the audit (a new test runner, a new `AGENTS.md`) is reported once to an `adopted` project. A `declined` project never hears from it again unless `arp audit` is run.
- **Check:**
  1. A fresh, advanced repo with its own `CLAUDE.md`: the first session shows the audit and asks once.
  2. Answer "no": the second session injects nothing and asks nothing.
  3. `arp adopt --state partial --pieces tests,ui-check`: the next session gets only those sections.
  4. With `default = "off"`, a new repo is never asked.

### Phase 1: Global cleanup
- [ ] Delete the `commit`, `relay` and `resume` symlinks.
- [ ] Move project skills from `~/.claude/skills` into each project's `.claude/skills/`.
- **Check:** a session opened in an unrelated repo lists no project skill. A session in the project still lists them.

### Phase 2: Working charter and project config
- [ ] `agent-init` asks, before anything about features:
  1. **Verify commands:** quick, full, e2e, e2e full.
  2. **Main user flows**, 5 to 20 of them, each in one sentence. They go to `.arp/flows.toml`.
  3. **Business rules** that compute or decide something (money, stock, permissions, states). They become the TDD list in `AGENTS.md`.
  4. **Ports, test database, branches.**
- [ ] It writes `AGENTS.md` with the charter, `.arp/config.toml` and `.arp/flows.toml`.
- [ ] `arp config check` fails on a missing key, a taken port or an empty flow list.
- **Check:** `agent-init` on a fresh repo produces the three files, and `arp config check` passes. A new session in that repo, asked to add a feature, names its test tier before writing code.

### Phase 3: Integrator script
- [ ] `arp integrate <branch>`:
  1. Refuse if the worktree is dirty.
  2. Merge into `develop` in a dedicated worktree.
  3. Rebuild the database from migrations.
  4. Run `verify.full` and `verify.e2e`.
  5. Write `.arp/integration/<date>-<branch>.md` with the result and the failing tests.
- [ ] On a conflict or a failure, stop and print one line telling which session must fix what. Nothing is merged.
- [ ] Queue: one integration at a time, with a lock file.
- [ ] `arp release vN.x.y` runs `verify.e2e_full` and tags `main`. Only when the owner asks.
- [ ] Sessions call `arp integrate`. There is no integrator session any more.
- [ ] Later: the same script in GitHub Actions on push to `develop`.
- **Check:** integrate two branches, one clean and one with a broken test. The first lands, the second is refused with a report, and `develop` stays green.

### Phase 4: Sessions
- [ ] `arp sessions`: one line per worktree, with branch, state (`working | waiting-owner | ready | idle`), last activity, and RAM if a dev server is up.
- [ ] Show the count in the statusline: `sessions 2/3`.
- [ ] `sessions` skill: when a talking session starts over `soft_limit`, warn once and list which sessions could pause. Never block.
- [ ] A session idle longer than `idle_hours` offers to write its relay and close.
- [ ] After `arp integrate` succeeds, stop that worktree's dev server.
- [ ] Resources:
  - Optional `MemoryMax` per session via `systemd-run --user --scope`.
  - Set the test workers from the number of active sessions.
- [ ] `arp worktrees prune` removes merged worktrees and their test databases.
- **Check:** with 3 sessions open, a fourth starts with one warning. `arp sessions` matches reality. Pruning leaves no merged worktree behind.

### Phase 5: Work protocol (ODD-style)
- [ ] `work` skill, the entry point:
  - **Classify** with the resumability test: could another agent continue from the request and `git diff` alone?
    - Yes: **small**. Do it, verify, commit. No file.
    - No: **big**.
  - **Big** work opens `docs/ai/tasks/<slug>.md` **before the first edit**, with:
    - `## Specs`: the owner's words verbatim, numbered S1, S2…
    - `## Tasks`: one line per task, with its S# and its commit.
    - `## Decisions`: what was chosen, and what was rejected and why.
    - `## Log`
  - A session or subagent working on big work reads that file first, and rereads it after a compaction.
- [ ] Simplify `relay`: when the file exists, relay only sets `status: HANDOFF` and the next step.
- [ ] Update `arp-block.md`: replace "task files only for relay" with the small/big rule.
- [ ] Subagent rules:
  - A brief points to the task file and the S# it covers. It never pastes the spec.
  - A subagent returns a summary of at most 20 lines. Details go to a file.
  - Questions for the owner are collected and asked once, at the end of the round.
- **Check:** run one big task across a compaction. After it, the agent quotes S# verbatim and has lost no rule.

### Phase 6: Testing policy and test health
- [ ] `tests` skill:
  - **Tiers:** unit (TDD for business rules), critical e2e tagged `@critical` (one per main flow), full e2e.
  - **Fix rule:**
    - A business rule → a unit test, written first and seen failing.
    - A UI detail (double click, empty state, overflow) → a structural fix, such as a shared component that cannot fail that way. No test.
    - A broken end-to-end flow → an e2e test.
  - **TDD:** red, green, refactor. A test that passes the moment it is written is wrong.
- [ ] The `tests` skill carries the **decision guide** in §6: the decision order and the generic patterns. The agent writes its choice ("tier: unit, rule S3") before it writes a test.
- [ ] **Guard.** `arp test-guard` runs inside `verify.quick` and in the integrator, and fails when:
  - a new e2e test has no `@flow <id>`, or names a flow missing from `.arp/flows.toml`;
  - a flow has more than `e2e_per_flow` tests;
  - a test is marked to retry until it passes.

  Adding a flow to `flows.toml` is allowed, but the integration report lists it for the owner.
- [ ] **Recorder.** Every test run, in a session or in the integrator, appends to the global `~/.local/share/agent-core/agent-core.db`:

  | Table | Columns |
  |---|---|
  | `projects` | id, name, path, git remote |
  | `tests` | id, **project_id → projects**, file, name, tier, flow, first seen, last seen, deleted at |
  | `runs` | id, **project_id → projects**, date, branch, commit, command, tier, runner (session or integrator), duration |
  | `results` | **run_id → runs**, **test_id → tests**, outcome (pass, fail, skip, flaky), duration |
  | `coverage_changes` | **test_id → tests**, commits that touched the covered code (from testmon and `git log`) |

  - Sources: pytest's JUnit XML and Playwright's JSON reporter. Nothing is added inside the project's tests.
  - Size: about 2 000 rows per full run. Keep raw results for 90 days, then keep only per-test totals.
  - The database lives outside every repo, so the public plugin never ships anyone's data.
- [ ] **Report.** `arp test-health [--project <name> | --all]` writes one HTML page (template, `report.mjs`) and a short terminal summary. `--all` compares projects: suite time, tests per flow, suspects.
  - **Cost:** the slowest tests and files, and the total time per tier.
  - **Flaky:** tests that failed and then passed with no code change.
  - **Value:** how often each test caught a real failure.
  - **Suspects:** never failed, while the code they cover changed `suspect_runs` times or more.
  - **Duplicates:** tests with the same name or the same assertions.
  - **Trend:** suite time and test count per week.
- [ ] **Suspect check.** `arp test-health --mutate <test>` runs mutation testing (`mutmut` for Python) on the code the test covers. If no mutant makes it fail, it is listed as a delete candidate. The owner approves each deletion.
- [ ] The integrator adds one line to its report: suite time, and new suspects since the last run.
- [ ] Later, if still slow: run e2e in parallel with one database per worker.
- **Check:**
  - An e2e test with no `@flow` makes `verify.quick` fail.
  - Given "a flow wired wrong", a fresh session writes an e2e test. Given a calculation, a permission or a double submit, it does not.
  - After a week of runs in two projects, `arp test-health --all` shows real numbers for both, and at least one suspect has been checked by mutation.

### Phase 7: UI checks
- [ ] `ui-check`: Playwright + Chromium, driven by the config (URL, login, viewports, themes). Deterministic checks:
  - cut-off text, unequal spacing, borders, scrollbars, layers outside the viewport, console and API errors;
  - **repeated text**: the same string twice in one view (a title repeated as a subtitle, a name shown twice);
  - **chat vs panel**: an assistant's reply repeats what a side panel already shows;
  - consistency with screens marked as approved: table footer, tabs, search.
- [ ] `explore`: one LLM pass after `ui-check` is clean, only for business rules. It reads the `ui-check` JSON and does not take its own screenshots.
- [ ] `report.mjs`: one HTML page from the JSON and the screenshots, with a before and after and only the owner's real questions. Published as an artifact.
- **Check:** on a screen with a known repeated title, `ui-check` flags it without the LLM. A full check uses fewer tokens than the LLM-driven flow it replaces. Measure both on the same screen.

### Phase 8: Style
- [ ] `style` skill, the base:
  - Minimal, sober, Apple-like. Neutral greys, one accent color, generous inner margins.
  - Nothing repeated in a view. Names, not codes (codes in a tooltip). The least text that is still clear.
  - No KPI cards. Counters go in tabs or chips.
  - A restyle never loses information: compare field by field.
  - Use real component-library parts (e.g. shadcn) instead of imitations.
  - Tokens: type scale, spacing scale, radius, motion. Light and dark.
- [ ] Brand layer template: logo color, action color, domain formats.
- **Check:** a new screen in a second project follows the base with no extra instructions.

### Phase 9: No comments
- [ ] `no-comments` skill:
  - Delete comments that restate the code.
  - For a comment that claims a constraint, propose a check (test, type, lint) or a link to a memory file.
- [ ] Python projects: enable ruff `ERA` (commented-out code).
- **Check:** run it on one module. The remaining comments are only links or real whys.

### Phase 10: Memory
- [ ] `memory` skill: one fact per file, an index with one line each, search before acting, add on every owner decision.
- [ ] Keep the index under 200 lines: an archive section, and a check that fails when it is over.
- [ ] `arp lessons`: list memory rules that repeat or that a check could enforce, and propose the check (the "encode lessons in structure" idea).
- **Check:** a 300-plus-line index is reduced, and loads whole in a new session.

### Phase 11: First real project
- [ ] Follow that project's own adoption plan, kept in the project.
- [ ] Run one real round end to end with the new flow, and write down what broke.
- **Check:** one feature goes from session to `develop` with `arp integrate`, and the owner reviews a template report.

---

## 5. Borrowed ideas

| From | Idea | Where |
|---|---|---|
| pstack | One entry skill that picks the steps | `work` |
| pstack | Principles as small files loaded on demand | `work` references, if it grows |
| pstack | `/correct`: fix a repeated mistake with structure, not text | `arp lessons` |
| pstack | `no-comments` | `no-comments` |
| pstack | Blind eval before changing a shared skill | later, not in v2 |
| gentle-ai (ODD) | Small/big by the resumability test, a task file with literal specs | phase 5 |
| own | Isolated worktree, database and ports per session | `integrate`, config |

## 6. Test decision guide

This section becomes the core of the `tests` skill. The agent reads it **before** writing any test.

### Decision order

Ask in this order, and stop at the first yes.

| # | Question | Then |
|---|---|---|
| 1 | Can the code make the mistake **impossible**? (a shared component, a type, a database constraint) | Do that. No test. |
| 2 | Does it **compute or decide** something? (money, stock, permissions, state changes, dates) | **Unit test, TDD.** Write it, see it fail, then write the code. |
| 3 | Does it depend on **two actors, time or retries**? (concurrency, idempotency, queues) | **Unit test against the real database, TDD.** Never e2e: a browser cannot reproduce it reliably. |
| 4 | Is it about **how it looks**? (spacing, repeated text, cut-off labels, dark mode) | **`ui-check`.** No test. |
| 5 | Does it break a **whole user flow** listed in `flows.toml`? (screen → API → database → screen) | **e2e, tagged `@flow <id>`.** Extend that flow's test before adding a new one. |
| 6 | None of the above. | **No test.** If it breaks, you will see it on the first click. |

### Patterns

The generic patterns (a calculation, a permission, two actors at once, a double submit, a flow wired wrong…) live in `skills/tests/SKILL.md`, so they exist in one place. Each project's own cases come first: its business rules in `AGENTS.md` and its flows in `.arp/flows.toml`.

### What the agent writes before a test

One line in its reply or in the task file:

```
tier: unit (rule 2) · covers S3 · file: tests/test_discounts.py
```

If it cannot fill in that line, it does not write the test.

## 7. Answered

| Question | Answer (2026-11-23) |
|---|---|
| Public repo? | Yes. Phase 0 makes it public-ready. |
| Session limit? | 3, as a soft limit: warn, never block. |
| Integrator local or CI? | Local first, CI later. |
| First project's critical e2e list? | Confirmed. It lives in that project's adoption plan. |
