---
name: tests
description: Decide the kind of test before writing any, using a six-step decision guide with generic patterns and the project's own rules; TDD for business rules; e2e only for listed user flows; and the tools that keep the suite honest (test-guard, test-run, test-health). Use before writing or changing a test, when fixing a bug found while testing, when tests are slow or flaky, or when asked whether a test is worth keeping.
---

# tests

## Before any test, write one line
```
tier: unit (rule 2) · covers S3 · file: tests/test_discounts.py
```
If you cannot fill it in, do not write the test.

## Decision order: stop at the first yes
| # | Question | Then |
|---|---|---|
| 1 | Can the code make the mistake **impossible**? (shared component, type, database constraint) | Do that. No test. |
| 2 | Does it **compute or decide** something? (money, stock, permissions, state changes, dates) | **Unit test, TDD.** |
| 3 | Does it depend on **two actors, time or retries**? (concurrency, idempotency, queues) | **Unit test against the real database, TDD.** Never e2e. |
| 4 | Is it about **how it looks**? | **`ui-check`.** No test. |
| 5 | Does it break a **whole user flow** listed in `.arp/flows.toml`? | **e2e tagged `@flow <id>`**, plus `@critical` when that flow has `critical = true` (the integrator runs only `@critical`). Extend that flow's test before adding one. |
| 6 | None of the above. | **No test.** A break shows on the first click. |

## TDD
1. **Red:** write the test and run it. It must fail, for the reason you expect.
2. **Green:** write the least code that makes it pass.
3. **Refactor:** clean up while it stays green.

A test that passes the moment it is written proves nothing. Fix the test.

## Patterns
First look for this project's own cases: the business rules listed under `## Working charter` in `AGENTS.md`, and the flows in `.arp/flows.toml`. Use the patterns below for anything they do not cover. They are generic on purpose and fit any product.

| Pattern | For example | Decision |
|---|---|---|
| A calculation | a discount, a tax, a commission, a due date, a balance | Unit, TDD (2) |
| A permission | a role must not see or change something | Unit on the API (2). Hiding it in the UI is not the protection |
| A state change | an item cannot go from cancelled back to active | Unit, TDD (2) |
| Two actors at once | two requests for the last unit, two people editing one record | Unit against the real database, TDD (3) |
| A retry or a duplicate | an offline client resends, a webhook arrives twice | Unit with an idempotency key (3) |
| An external service fails | the provider times out or returns garbage | Unit with a fake at the boundary (3), plus one manual sandbox run |
| A data transformation | an import or an export, parsing a file | Unit on the function (2) |
| A double submit | a second click creates a second record | Structural (1): the shared button disables while pending, plus the idempotency unit test |
| An empty, long or loading state | a blank page, cut-off text | Structural (1) in the shared component, then `ui-check` |
| How it looks | a repeated title, uneven spacing, dark mode | `ui-check` (4) |
| A flow wired wrong | each part works alone, but the screen calls the wrong endpoint | e2e `@flow <id>` (5): extend that flow's test |
| Simple create, read, update or delete | a screen that edits one field | No test (6). `ui-check` for the look |
| A migration | a new column or index | No test. The integrator rebuilds the database from migrations |
| Copy | a label or a typo | No test |
| A flaky test | fails one run in ten | Fix the cause or delete it. Never add retries |

## Fix rule for bugs found while testing
| Kind | Fix |
|---|---|
| A business rule | a unit test first, then the fix |
| A UI detail | a structural fix in the shared component, no test |
| A broken flow | an e2e test for that flow |

## Tools
| Command | What it does |
|---|---|
| `arp test-guard` | Runs inside the quick verify and the integrator. Fails on an e2e test with no `@flow`, an unknown flow, a flow over `tests.e2e_per_flow`, or configured retries. `--baseline` accepts today's offenders in an existing project, so only new ones fail. |
| `arp test-run --tier <t> --runner session -- <cmd>` | Wraps a test command and records its results in the shared local database. |
| `arp test-health` | Report: cost, flaky tests, value, suspects, duplicates, trend. `--all` compares projects. |
| `arp test-health --mutate <test>` | Checks a suspect with mutation testing. A test that no mutant breaks is a delete candidate, and the owner approves each deletion. |
| `arp test-report` | The periodic report. Every `tests.report_every_days` (default 7), the session-start hook writes it in the background to `~/.local/share/agent-core/reports/<project>-<id>/` and the next session tells the owner what changed: new suspects, flaky tests. Publish the page as a private artifact when the owner wants to see it. |

## Adding a user flow
A flow is one sentence in `.arp/flows.toml`. Add one only for a new end-to-end path the owner cares about. The integration report shows it to them.
