<!-- ARP:BEGIN v2 -->
## 8. Agent protocol (ARP)

Managed by `agent-init`. Do not edit by hand: it is regenerated on every run.
The way of working (worktrees, test tiers, integration) is injected every session by the
agent-core plugin. This block keeps only what is specific to this project.

### Verification
No step is marked `[x]` unless the verify command from section 3 passes.
The agent's opinion does not replace the command.

When writing tests for a business rule: write the test first and **see it fail** before
implementing. A test that passes the moment it is written is wrong.

### Small and big work
Ask: could another agent finish this from the request plus `git diff` alone?

- **Small:** yes. Do it, verify, commit. No file.
- **Big:** no. Create `docs/ai/tasks/<slug>.md` **before the first edit**, with:
  - `## Specs`: the owner's words verbatim, numbered S1, S2…
  - `## Tasks`: one line each, with its S# and its commit.
  - `## Decisions`: what was chosen, and what was rejected and why.
  - `## Log`

Frontmatter:

```yaml
---
task: <slug>
owner: claude | codex | none
status: IN_PROGRESS | HANDOFF | DONE
branch: <branch>
updated: <ISO-8601>
---
```

Relay on a big task only sets `status: HANDOFF` and the next step in the file.
`.arp/current-plan.md` is a disposable draft written by a hook when a plan is approved. It is
not a task file and is not committed. Its existence does not mean a task is in progress.

### Task ownership
- Take a task only if `owner` is `none`, your own name, or `status` is `HANDOFF`.
- If `owner` is another agent and `status` is `IN_PROGRESS`: touch nothing, tell the user.
- When you take it: write your name in `owner`, set `status: IN_PROGRESS`, update `updated`.

### Relay commits (`wip`)
A save point, not a history entry. One format only:

```
git add -A && git commit -m "wip(<slug>): <step where it stopped>"
```

`git add -A` on purpose: everything goes in, including half-done work. It is **not** split
into atomic commits and verification is **not** required to pass. Saving the work is all
that matters here. Any other commit follows the `commit` skill.

### When resuming (`/resume`, `$resume`)
1. Read the task file, then `git log` and `git diff` for the real state.
2. Run the verify command before writing code.
3. Continue from the first `[ ]`. Do not redo finished work or reopen decisions.
<!-- ARP:END -->
