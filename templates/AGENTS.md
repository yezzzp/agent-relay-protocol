# {{PROJECT_NAME}}

> Source of truth for coding agents. Read on every turn: keep it under ~150 lines.
> If a linter can enforce it, it does not go here.

## 1. What it is
{{PURPOSE}}

<!-- 2-3 lines: what problem it solves and for whom. No marketing. -->

## 2. Stack
- **Language:** {{LANGUAGE}}
- **Framework:** {{FRAMEWORK}}
- **Package manager:** {{PACKAGE_MANAGER}}
- **Data / services:** {{SERVICES}}

<!-- The package manager matters: pnpm and npm are not interchangeable. -->

## 3. Commands

| To | Command |
|---|---|
| Install dependencies | `{{CMD_INSTALL}}` |
| Run in development | `{{CMD_DEV}}` |
| **Verify (mandatory)** | `{{CMD_CHECK}}` |
| One single test | `{{CMD_TEST_ONE}}` |

`{{CMD_CHECK}}` is the only source of truth: format + lint + types + tests.
If it fails, the work is not finished. The same commands live in `.arp/config.toml`.

## 4. Structure

```
{{STRUCTURE}}
```

<!-- Only the directories that matter and what goes in each. 5-8 lines. -->

## 5. Conventions
{{CONVENTIONS}}

<!-- ONLY what no linter can enforce: naming, error handling, how a test is
     structured. If the formatter fixes it by itself, it does not go here. -->

## 6. Business rules
{{BUSINESS_RULES}}

<!-- Domain constraints the code does not explain by itself.
     E.g. "amounts are Decimal, never float: the tax authority requires exactly 2 decimals". -->

## 7. Do not touch
{{DO_NOT_TOUCH}}

<!-- Generated files, applied migrations, infrastructure configs. -->

## Working charter
{{CHARTER}}

<!-- How this project works, set before any feature:
     - verify commands: see `.arp/config.toml` ([verify])
     - main user flows: see `.arp/flows.toml`
     - rules that compute or decide something, each one gets TDD (test first, seen failing):
       - <rule> — <where it lives>
-->

{{ARP_BLOCK}}
