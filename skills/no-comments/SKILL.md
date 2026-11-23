---
name: no-comments
description: Remove code comments that restate what the code does, and turn comments that claim a constraint into a check. Use before committing or review, when touching a file with many comments, or when asked to clean up comments.
---

# no-comments

Agents read comments as truth, so a stale one misleads them. Keep only what the code cannot say.

## For each comment in the diff (or the named files)
| Comment | Action |
|---|---|
| Says *what* the code does ("loop over orders") | Delete it. Rename instead if the code is unclear. |
| Commented-out code | Delete it. Git has it. |
| Claims a constraint ("never call this twice", "amount must be positive") | Encode it as a type, an assertion at the boundary, a database constraint, or a test. Then delete the comment. |
| A *why* that cannot be encoded (an owner decision, an external quirk) | Keep one line pointing to where it is recorded: `# why: see docs/ai/memory/decision_x.md`. |
| A license header, or a docstring that is public API | Keep it. |

## Enforce
- Python: enable ruff `ERA` (commented-out code).
- Report what was deleted, what was encoded and with what, and what was kept and why.
