---
name: work
description: Entry point for any task in a project that uses agent-core. Classifies the task as small or big, opens the task file for big work, and routes to the tests, integrate, sessions, style, ui-check and memory skills as the steps need them. Use at the start of a task, when the owner describes a feature, or when unsure which agent-core skill applies.
---

# work

The rules are in [WORKFLOW.md](WORKFLOW.md). The plugin injects them at every session start and after every compaction. This skill adds the procedure.

## Steps
1. **Restate** the goal in one line and the smallest change that meets it.
2. **Memory:** search for the topic (skill `memory`).
3. **Classify:** could another agent finish this from the request and `git diff` alone?
   - **Small:** skip to step 5.
   - **Big:** step 4.
4. **Task file:** create `docs/ai/tasks/<slug>.md` from the template below **before the first edit**. Copy the owner's words exactly into `## Specs`, with no paraphrase. Number them S1, S2… Add later owner messages as new S#.
5. **Isolate:** own worktree and branch (skill `integrate`, "Start").
6. **Per task:**
   - decide the test (skill `tests`) and write the `tier:` line;
   - build;
   - for UI, use the `style` skill, then `ui-check`;
   - run the quick verify command;
   - commit.
7. **Integrate:** `arp integrate <branch>` (skill `integrate`).
8. **Close:**
   - record new owner decisions (skill `memory`);
   - set the task file to `status: DONE`;
   - `arp sessions set ready`, or close the session.

## Task file template
```markdown
---
task: <slug>
owner: claude
status: IN_PROGRESS
branch: <branch>
updated: <ISO-8601>
---
## Specs
S1. «<owner's words, verbatim>»
## Tasks
- [ ] <task> (S1)
## Decisions
- <chosen> — rejected: <alternative>, because <reason>
## Log
L1. <date> request received
```

## Rounds with builders
For big work with several tasks:
1. **Plan with the owner.** Before planning a new feature, list what the industry expects of it (for a chatbot: streaming, files, voice, errors, limits, history) and sort it into *now*, *later* and *out on purpose*. Ask only the decisions that are the owner's. Each task in the plan names its files, the interfaces it shares and its test.
2. **Build.** Once the owner approves, launch one `agent-core:builder` per task, in one message, with `isolation: "worktree"`. Tasks that touch the same files go to the same builder, or run one after another.
3. **Review.** Read each diff against its S#, run the verify command yourself, and send fixes back to the same builder with SendMessage.
4. **Integrate.** Merge the builders' branches into the task branch, verify once more, then `arp integrate`.

## Subagents
- Use one when the owner will only read the result. Brief it with:
  - the goal;
  - the task file path and the S# it covers;
  - the files to read;
  - what is already ruled out;
  - the verify command.
- Ask for a report of at most 20 lines, with details in a file.
- You own its work: review the diff and run the checks yourself before integrating.
- Collect its questions for the owner. Ask them together at the end of the round.
