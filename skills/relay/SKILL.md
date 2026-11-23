---
name: relay
description: Writes the handoff of the task in progress so another agent can pick it up. Use when the user asks to relay, hand over or pass the task to another agent, when they say their plan quota or tokens are running out, or when a quota notice says the session will not finish. Do not use it if the task is already done.
---

# Relay — hand the task to another agent

Your only output is leaving on disk what a **cold** agent needs to continue. Do not keep
working on the task after invoking this.

## 1. Identify the task

Look for `docs/ai/tasks/<slug>.md` for the task in progress (match by branch or topic).

- **It exists** (big work, opened before the first edit): this is the short path. Do
  only this, then go to step 4:
  - set `status: HANDOFF`, `owner: none`, update `updated`;
  - add the **next step** at the top of `## Log` (what to do first, and where it stopped);
  - tick `[x]` on what is finished in `## Tasks`; add to `## Decisions` anything decided
    since the last update, with what was rejected and why.
  Never touch `## Specs`: those are the owner's words.
- **It does not exist:** the work was small, or nobody opened a file. Go to step 2.

If `.arp/current-plan.md` exists, **read it first**: it is the plan approved in plan
mode, saved to disk by a hook. Its frontmatter already carries the `slug` — use it as is.
Without it, the slug is kebab-case, derived from the current branch or the goal
(`auth-refactor`, `fix-pdf-export`).

## 2. Write the file (only when it did not exist)

The draft is raw material, not the product: do not copy it as is. Add what **only you
know** and it cannot contain — what you already ran, the decisions you made on the fly,
the alternatives you dropped and why, where you deviated from the plan.

Use the template in `docs/ai/tasks/_TEMPLATE.md` if it exists. Frontmatter:

```yaml
---
task: <slug>
owner: none
status: HANDOFF
branch: <current branch>
updated: <ISO-8601 date>
---
```

Required content:

- **Specs** — the owner's words from this conversation, verbatim, numbered S1, S2…
  The successor needs the intent and the exact wording, not your paraphrase.
- **Tasks** — the checklist, with `[x]` on what is closed and `[ ]` on what is pending.
- **Decisions** — and **rejected alternatives with their reason**. This is the most
  valuable part of the file: it stops the successor from rehashing what is settled.
- **Log** — the next step first; the real result of the verify command from section 3
  of AGENTS.md (run it before writing this; do not assume it); risks / do not break.

When the task file is written, delete `.arp/current-plan.md`. It did its job: the task
file replaces it. If you leave it, a later quota cut would promote it as if it were
another task and you would have two files for the same thing.

## 3. Do not write what git already says

No listing of diffs, changed lines or history. The successor has `git diff` and
`git log`. The file keeps **intent**, not changes.

## 4. Leave the tree clean

Commit everything, including the task file and whatever is half done:

```
git add -A && git commit -m "wip(<slug>): handoff — <step where it stopped>"
```

It is a relay commit, with the rules of section 8 of AGENTS.md: everything goes in and
you do not wait for verification to pass. Do not split it into atomic commits or invoke
the `commit` skill — here time is running against you.

A commit is much harder to cut in half than a half-written file.

## 5. Close

Report in one line: file path, step where it stopped, and that the successor must use
`resume`. Do not start new work.
