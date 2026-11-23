---
name: resume
description: Picks up a task another agent left half done. Use when the user asks to continue, resume or follow up on a task started by another agent, when they mention that Claude or Codex ran out of tokens, or when opening a project that has pending tasks in docs/ai/tasks/.
---

# Resume — pick up a handed-off task

## 1. Find the task

Read `docs/ai/tasks/*.md`. Look for `status: HANDOFF`.

- None → say so and stop. Do not invent work.
- Several → list them with their goal and ask which one.
- One with `status: IN_PROGRESS` and an `owner` other than you → **do not touch it**.
  Another agent may be working right now. Tell the user and wait.

## 2. Rebuild the real state

In this order, before writing a single line of code:

1. Read the whole task file. `## Specs` are the owner's exact words; `## Log` starts
   with the next step; `## Decisions` are closed.
2. `git log --oneline -15` and `git diff` — what really happened.
3. Run the verify command from section 3 of AGENTS.md (or `verify.quick` in
   `.arp/config.toml`).

Step 3 is not optional: the task file says what the predecessor **believed**; the
command says what **is**. If they differ, the command wins.

## 3. Take ownership

Update the frontmatter before working:

```yaml
owner: <your name: claude | codex>
status: IN_PROGRESS
updated: <ISO-8601 date>
```

## 4. Continue

From the **first `[ ]`** in `## Tasks`, not from the beginning.

If the task file says it was generated automatically by ARP, it has no checkboxes or
decisions: it is the approved plan plus the tree state, promoted by a hook when the
quota ran out. Step 2 is then not optional — compare the plan against `git log` and
`git diff` to deduce how far the predecessor got, and turn the plan into a checklist
when you pick it up.

- Do not redo work already marked `[x]` and confirmed by the tree.
- **Do not reopen recorded decisions.** If one looks wrong to you, tell the user in one
  line and keep going with it until they decide otherwise.
- Respect the risks noted in the log.

## 5. Close every step

When a step is finished: verify with the command, tick `[x]`, update the task file and
commit. You may be the next one to run out of quota.

When everything is `[x]`: `status: DONE`.
