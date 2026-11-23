---
name: memory
description: The project's shared memory of owner decisions, rules and gotchas that the code does not show. Search it before acting on a topic; add to it when the owner decides something new. Use at the start of any task, when the owner states a preference or corrects you, and when a lesson repeats.
---

# memory

## Where
The project's memory folder, as found by the audit (`arp status`). Typical names are `docs/ai/memory/` and `docs/ai/memoria/`. Every session and every subagent reads and writes the same folder. Without one, propose `docs/ai/memory/` to the owner.

## Search before acting
```bash
grep -ril "<topic words>" <memory folder>
```
A recorded owner decision beats your intuition. If it looks outdated, ask. Do not silently ignore it.

## Add
- **One fact per file:** `<kind>_<slug>.md`, where kind is one of `decision`, `rule`, `gotcha`, `feedback`, `reference`.
- Body: the fact, then `**Why:**` and `**How to apply:**`, plus the owner's date (`owner, YYYY-MM-DD`).
- One line in the index (`MEMORY.md`): `- [Title](file.md) — hook`, under 200 characters.
- Update an existing file rather than duplicating it. Delete a memory that turned out wrong.
- Not memory: what the code, the git history or `AGENTS.md` already say.

## Keep it loadable
- The index must stay under 200 lines, each line under 200 characters. Older entries move to `## Archive` with one line per topic.
- When a rule shows up in the memory twice, it should become a check (lint, test, script), not more text.
- `arp lessons` lists:
  - problems in the index;
  - files missing from the index;
  - lessons learned more than once;
  - rules a check could enforce, each with the kind of check;
  - likely duplicates.
- Propose each check to the owner. Once it exists, the memory file only links to it.
- Add `arp lessons --check` to the quick verify command, so the index never grows past its limits again.
