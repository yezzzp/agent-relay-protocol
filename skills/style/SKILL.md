---
name: style
description: Base visual style for every product: minimal, sober, Apple-like, with nothing repeated and the least text that is still clear. Load before creating, changing or reviewing any screen or visual component, and before briefing a subagent on UI. A project's brand layer may override colors, fonts and density.
---

# style

The project's brand layer, if it has one (a skill or doc named in `AGENTS.md`), overrides only what it says: colors, fonts, density, light or dark first. Everything else here applies.

## 1. The screen explains itself
If a screen seems to need an explanation, change the control. Remove:
- subtitles that repeat the title or narrate the step;
- help text about how the system works inside;
- warnings that sound like threats ("required", "cannot be undone"). A disabled button says it is required. Only warn about a consequence that changes something;
- errors before the user did anything. Show an error only on a real conflict;
- placeholders that list fields or codes. Use a short action: "Search customers";
- anything that erases what the user typed on blur or Enter.

## 2. Text and data
- **Nothing repeated in a view.** If a value is in the header, the chat or a panel, it is not written again.
- **Names, not codes.** Codes nobody memorizes go in a tooltip or in small text, and search still accepts them.
- **Mark only the exception.** No "OK" or "Active" on every row; use a dash when there is nothing.
- **No KPI cards or indicator rows.** Counters go in tabs, chips, or next to a group title.
- A figure appears once per view and never breaks across lines. Do not put figures that contain each other at the same level.
- Plurals agree ("1 item", "2 items"). Show the API's real error message.

## 3. Look
- Apple-like and calm:
  - system font stack (`-apple-system, "SF Pro Text", Inter, system-ui`);
  - hierarchy by size, weight and space, not by boxes;
  - 1 px hairlines instead of shadows or filled bands;
  - generous inner margins;
  - radius 8–12 px;
  - thin-stroke icons.
- **Color means something.** Use it only for state and the main action:

  | Color | Means | Never |
  |---|---|---|
  | Accent (one hue) | action, selection, focus | decoration |
  | Green | done, paid | a button other than the final "pay" or "confirm" |
  | Amber | needs attention, there is time | saturated blocks |
  | Red | overdue, error, loss, destructive | a filled button |
  | Grey | neutral, skipped | data |

- A state is a soft background with text in the same hue, never a saturated block, and never color alone: add a word, an icon or a sign. Use `−` (U+2212) for minus.
- No gradients, no per-category palettes, no colored dots in filters.
- Light **and** dark, always. Honor `prefers-reduced-motion`.

## 4. Behavior
- Never `alert()` or `confirm()`: use the app's own sheets, dialogs or panels.
- **Symmetric spacing:** a band between two lines has the same space above and below, measured in the browser, not by eye. Paddings add up, and you measure what is visible, not the box.
- **At most two buttons together:** the main action, plus one menu ("⋯") for the rest. One main accent button per view.
- What the role cannot do does not appear. The API rejects it anyway.
- The same control looks and behaves the same on every screen. Look for the existing one before building one.
- Use the real component library (for example shadcn/ui installed by its CLI), never hand-made imitations.
- **A restyle never loses information:** compare field by field with the old version.

## 5. Done means
- [ ] §1 list applied. One main action per view, at most two buttons together.
- [ ] Checked in light and dark, with the right role. Every menu, select and dialog opened. Something created and edited for real.
- [ ] `ui-check` clean: repeated text, spacing, cut-off text, console errors.

## Briefing a subagent on UI
Paste the rules that apply **as written**. Give concrete rules, never adjectives ("warm", "lively"). Name the existing screen to copy.
