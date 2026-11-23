---
name: commit
description: Writes and creates commits following Conventional Commits, splitting the work into atomic commits and verifying first. Use when the user asks to commit, save the work, or leave the tree clean. Also when closing a step of a plan.
---

# Commit — readable, English, atomic history

A commit answers one question: **why does this change exist**. The diff already says
what changed; the message does not repeat it.

## 1. Look before you write

```
git status --short
git diff --staged
git diff
git log --oneline -20
```

The `git log` is not optional: it gives you the scopes the project already uses. Reuse
them instead of inventing synonyms (`installer` today, `install` tomorrow).

## 2. Split the work

If the tree mixes unrelated changes, **do not put them in one commit**. Group by
logical unit and commit one at a time, `git add <file>` file by file.

When two unrelated changes live in the same file, you need to go down to hunks
(`git apply --cached` with a patch). There, **show the commit plan and wait for the
user's approval** before touching the index. It is the operation where it is easiest
to break something.

If the whole tree is a single logical unit, one commit is enough. Do not invent splits.

## 3. Verify once, before the batch

Run the verify command from section 3 of AGENTS.md (or `verify.quick` in
`.arp/config.toml`) on the whole tree, **before** the first commit.

If it fails: commit nothing. Report the error and stop.

Relay commits (`wip`) are outside this skill: they are save points, not history
entries. Their rules are in section 8 of AGENTS.md.

## 4. Message format

The whole message is in **English**, even if the conversation is in another language.

```
type(scope): subject in the imperative

Body wrapped at 72 columns when it applies.

BREAKING CHANGE: what breaks and what to do about it.
```

**Types:** `feat` `fix` `refactor` `docs` `test` `chore` `perf` `build` `ci`.

`refactor` does not change behavior. If it does, it is `feat` or `fix`.

A tenth type, `wip`, exists but you **do not write it with this skill**: it belongs to
the relay protocol and is defined in section 8 of AGENTS.md.

**Scope:** the top-level directory or module of the touched file, checked against the
ones in `git log`. If the change is cross-cutting, omit it: `chore: bump ruff`.

**Subject:** imperative (`add`, never `added` or `adds`), lowercase first letter, no
trailing period, ≤50 characters.

**Breaking change:** `!` before the colon (`feat(api)!: ...`) and a `BREAKING CHANGE:`
footer describing what breaks.

## 5. When it gets a body

No body if it touches ≤2 files **and** the change is obvious from the subject.

A body is mandatory if any of these holds:

- it touches ≥3 files,
- it changes behavior observable from outside (API, CLI, output format),
- there was a design decision with alternatives.

The body says **why**, and **what was rejected and why**. It never lists files or
lines: that is the diff.

```
refactor(installer): extract TUI selection into a function

The interactive block was tangled with argument parsing, which made
--agents impossible to test without a TTY.

Dropped `dialog`: an external dependency for what amounts to 30 lines
of ANSI escapes.
```

## 6. Limits

- **Never push.** The user decides that.
- Do not use `git commit -a`: it breaks the split of step 2.
- Do not amend or rebase already published commits unless asked.

## 7. Close

One line per commit created: short hash and subject. If you stopped because
verification was red or you were waiting for hunk approval, say so and do not go on.
