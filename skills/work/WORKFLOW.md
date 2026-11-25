# How we work (agent-core)

This applies to every task in this project. Where the project's `AGENTS.md` or `CLAUDE.md` says otherwise, the project wins: say so once.

<!-- piece:workflow -->
## Every task
1. **Read first.** `AGENTS.md`, then the active task file if there is one.
2. **Classify.** Could another agent finish this from the request and `git diff` alone?
   - Yes: **small**. Just do it.
   - No: **big**. Before the first edit, open `docs/ai/tasks/<slug>.md` with:
     - `## Specs`: the owner's words verbatim (S1, S2…);
     - `## Tasks`: each with its S# and commit;
     - `## Decisions`;
     - `## Log`.
   Reread it after every compaction.
3. **Build.** Name the data shape first. No comments that restate the code: only a *why* that cannot be encoded, pointing to where it is recorded.
4. **Verify.** The project's quick verify command must pass. Your opinion does not replace the command.
5. **Close.** Mark the task file. When the round is done, the session is done.
6. **Hand it over on your port.** When a change the owner can see is verified, leave the branch's dev server running on its own port (`.arp/ports`) and give the owner the URL in the same message that says it is ready. Do it before you start the integration, not after: what works on the branch's port works on the integration branch, so the owner does not wait minutes for it.

## Sessions and subagents
- **Session:** the owner will talk to it. **Subagent:** the owner will only read its result.
- A subagent brief points to the task file and its S#, never a pasted spec. Its report is at most 20 lines, with details in a file.
- The session runs on the model the owner chose. It plans, reviews and integrates; it does not hand those to a subagent.
- Lookups go to `agent-core:explorer` (Haiku). Do a lookup of two or three calls yourself: a subagent starts with no context and costs more.
- Building goes to `agent-core:builder` (Sonnet), one per task of the approved plan, with `isolation: "worktree"`. Launch them together when their files do not overlap.
- Any other subagent runs on Sonnet: pass `model: "sonnet"`. The owner can name another model for a task.
- Before integrating, review every builder's diff and run the verify command yourself, then merge their branches into the task branch and run `arp integrate`.
- Collect questions for the owner and ask them together, at the end of the round.

## Autonomy and replies
- Reversible work: do it, then report. Irreversible or outward actions (push to production, release, delete data, message people): confirm first.
- Replies are short, in the owner's language, and lead with the result. Nothing repeated. Names, not codes.
- Say what you checked and how. Never hand the owner a check you could run.
<!-- /piece -->

<!-- piece:worktrees -->
## Isolation
- Code changes go in their own worktree: `arp worktrees new <branch>`. It branches from the integration branch, copies `.env` and the test map, and gives the worktree its own test database and ports.
- Never work on the integration or production branch directly.
- Above the session soft limit (`arp sessions`), warn once and suggest which session to pause. Never block.
<!-- /piece -->

<!-- piece:tests -->
## Tests: decide before the code
Use the `tests` skill. Before any test, write one line: `tier: … (rule N) · covers S# · file: …`. If you cannot fill it in, write no test.
1. Can the code make the mistake impossible (shared component, type, constraint)? Do that. No test.
2. Does it compute or decide something (money, stock, permissions, states)? Unit test with TDD: write it, **see it fail**, then the code.
3. Does it depend on two actors, time or retries? Unit test against the real database, with TDD. Never e2e.
4. Is it how it looks? `ui-check`. No test.
5. Does it break a whole user flow from `.arp/flows.toml`? An e2e test tagged `@flow <id>`, and `@critical` too if the flow is `critical = true`. Extend that flow's test first.
6. None of the above: no test.

In a worktree, `verify.quick` runs only the tests that touch what you changed. The integrator runs every test (`verify.full`) and the critical e2e on the integration branch; a release runs every e2e. Never run the full suite in a worktree unless the owner asks.

Never add retries to a flaky test: fix it or delete it.
<!-- /piece -->

<!-- piece:ui-check -->
## UI
- After any UI change, run `ui-check` and fix by class, in the shared component.
- At the end of a screen, one `explore` pass for business rules.
- Show the owner the report page, not a list in chat.
<!-- /piece -->

<!-- piece:style -->
## Style
Before any UI work, load the `style` skill (base), then the project's brand layer if it has one.
<!-- /piece -->

<!-- piece:integrator -->
## Integration
- `arp integrate <branch>`, in the background. Never merge by hand. If another integration is running it queues and goes in with the next batch. If it fails, fix it in your branch and run it again.
- Once the branch lands, the integration stops its dev server: from then on the owner tries it on the integration branch's port. Say so in one line.
- Do not wait for the owner's approval to integrate: give the port and start the integration in the same turn. If the owner asks for changes, iterate and integrate again; the queue absorbs it. If the integration fails, fix it in the branch, tell the owner in one line what failed, and run it again.
- Production moves only when the owner says so: `arp release vN.x.y`.
<!-- /piece -->

<!-- piece:memory -->
## Memory
- Before acting, search the project's memory for the topic. A recorded owner decision beats your intuition.
- When the owner decides something new, record it in the memory: one fact per file, plus one line in the index.
<!-- /piece -->

<!-- piece:relay -->
## Handoff
- If the session may end before the task does (quota, the owner leaves), use `relay`.
- To pick up someone else's task, use `resume`.
<!-- /piece -->
