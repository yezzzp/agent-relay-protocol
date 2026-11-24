---
name: explore
description: One LLM exploration pass over a screen or flow, only for business rules, after ui-check is clean. Use when a screen is opened or finished and the project has rules a script cannot measure (permissions, totals, states, who can do what). Not for layout, spacing or text; ui-check owns those.
---

# explore

The only model-driven step of the UI flow. Layout, copy duplication and console errors belong to `ui-check`; run that first and do not start here until it has no errors.

## Rules

1. **Read first**: the project's `AGENTS.md` and its memory folder (search by topic). The rules written there beat intuition.
2. **Own QA database.** Create or copy one for this session. Never a shared, staging or production database. Say which one you used in the findings.
3. **No screenshots of your own.** Read `ui-check`'s `ui-check.json` and its images. For a state `ui-check` did not reach (after saving, after a role change), run `ui-check --url ...` again on that state rather than capturing by hand.
4. **Try to break it as a user would**: empty and invalid input, back button, each role, long lists, and every documented rule from `AGENTS.md`. Save for real, in the QA database. Double clicks are `ui-check --probe`'s job, and the known failures of `style` §5 are already covered: do not spend the pass on them.
5. **Only business rules.** A finding is a rule broken, or a flow that cannot be completed. A visual defect goes back to `ui-check` or a shared component.

## Findings file

Write `explore.json` next to `ui-check.json`, in the same shape so `report.mjs` can read it:

```json
{"version":1,"views":[],"checks":["business-rule"],"themes":[],"viewports":[],
 "findings":[{"severity":"error","check":"business-rule","view":"/orders","theme":"light",
   "selector":"","text":"What was done, what the rule says, what happened","screenshot":"light-1440x900-orders.jpg"}]}
```

Anything only the owner can decide goes to `questions.json` (`[{"question","context","screenshot"}]`), one line each, and nowhere else. Do not ask what a rule in memory already answers.

## Fix, then recheck

Fix without waiting for the owner, then repeat the same steps and re-run `ui-check`. The fix rule (plan D12 and section 6) decides what stays behind:

| what was wrong | what stays |
|---|---|
| a business rule | a **unit test** of the rule |
| a UI detail | a **structural fix** in the shared component; no test. If it could happen on any screen, a row in `style` §5 |
| a broken user flow | an **e2e test tagged `@flow`**, for a flow the project lists |

A fix never adds an e2e test by default.

## Report

```
node ${CLAUDE_PLUGIN_ROOT}/scripts/report.mjs after/ui-check.json explore.json --before before/ui-check.json --after after/ui-check.json --questions questions.json --out ui-report.html
```

Publish the HTML as an artifact. The page is built from a template; do not write HTML yourself.
