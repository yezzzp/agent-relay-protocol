---
name: ui-check
description: Run the deterministic browser checks (Playwright + Chromium) on a screen and read the result. Use at the end of any UI change, before showing it to the owner, and when asked to "check the screen", "review the UI" or "see if it looks right". Catches cut-off text, uneven spacing, repeated titles, native controls, console errors and more, with no model in the loop.
---

# ui-check

Mechanical part of a UI review. It does not replace looking at the screenshots: a clean run means well measured, not well designed.

## Run

```
node ${CLAUDE_PLUGIN_ROOT}/scripts/ui-check.mjs --url /orders [--url /orders/new] [--tabs] [--probe] [--only-failures]
```

Settings come from `.arp/config.toml`, flags override them. `--project`, `--node-root`, `--base-url`, `--viewports`, `--themes`, `--out`, `--no-login`.

```toml
[ui]
base_url = "http://localhost:3000"
node_root = "web"                  # where playwright is installed; default: root, web/, frontend/, app/
viewports = ["1440x900"]
themes = ["light", "dark"]
out = ".arp/ui-check"
approved = ["/orders", "/customers"]   # screens the owner accepted, used by compare.mjs
chat_selector = "#chat"            # optional: enables the chat-vs-panel check
panel_selector = "#side-panel"
theme_storage_key = "theme"        # optional: localStorage key the app reads for its theme
skip_words = ["archive"]           # extra words that stop a menu or button from being opened
allow_native = "select.legacy"     # optional: native controls that are fine
[ui.login]
url = "/login"
email_env = "QA_EMAIL"
password_env = "QA_PASSWORD"
```

`--probe` also double-clicks every action button in `main` (not menu triggers, not sign out), once per view on the first theme and viewport. Writes stay blocked: each one is held `ui.probe_hold_ms` (800) before the abort, so a button that disables itself while pending is not mistaken for one that sends twice. Use it at the end of a screen; it reloads the view after every button that wrote or navigated, so it is slower. `ui.max_probes` caps the buttons per view (25).

Playwright is not installed by agent-core. If it is missing the script prints one line and exits 2: install it in the project, or set `ui.node_root`. Run against a dev server on the QA database, never production. It opens menus, comboboxes and dialogs. It skips controls whose label, title or value says save, delete, send, pay and the like (English, Spanish, Portuguese, plus `ui.skip_words`), and buttons that would submit a form. After login it blocks every request that is not GET, HEAD or OPTIONS, so it cannot write even if a harmless-looking control does. A blocked request is a `blocked-write` warning; if it is really a read (GraphQL, a search that uses POST), add its URL pattern to `ui.allow_write`. A view that lands on the login page is a `redirected-to-login` error, and a failed login stops the run.

## Read the result

`<out>/ui-check.json`: `findings[]` with `severity` (`error` fails the run, exit 1; `warning` does not), `check`, `view`, `theme`, `selector`, `text`, `screenshot` (and `locations` for two-place findings).

| check | meaning | fix |
|---|---|---|
| `repeated-text` | a title came back as a nearby subtitle or heading | delete one; never keep both |
| `chat-repeats-panel` | the last chat message repeats what the panel shows | shorten the message to what the panel does not say |
| `cut-off-text` | text hidden by overflow with no tooltip | wrap, widen, or add `title` |
| `unequal-spacing` | band with different padding above and below | one padding token on the shared component |
| `borderless-color` | border drawn with the default (near black or white) color | use the border color token |
| `visible-scrollbar` | a menu or list shows a scrollbar | the shared scroll style |
| `native-control` | raw select, checkbox or date input | use the project's component |
| `layer-outside-viewport` | a menu or dialog leaves the window | collision handling in the shared popover |
| `unbounded-input` | a text input or textarea with no `maxlength` | default limit in the shared input (`style` §5) |
| `focus-not-restored` | Esc closed a menu or dialog and focus did not go back to its trigger | use the library's dialog or menu, not a hand-made one |
| `double-submit` (`--probe`) | a double click sent the same write twice | the shared button disables while its action runs (`style` §5) |
| `horizontal-scroll`, `console-error`, `failed-request` | page overflow, JS errors, 4xx/5xx | real bugs; fix the cause |

Consistency with approved screens: `node ${CLAUDE_PLUGIN_ROOT}/scripts/compare.mjs --url /new-screen` compares table footer, tabs, table header, search box and primary button against `ui.approved`. Every difference is a warning.

## Fix by class

A UI detail is fixed **structurally, in the shared component**, so every screen gets it. Do not add a test for a UI detail (plan D10, D12); this script is the guard. If the same finding class returns on another screen, the component is still wrong. A class no check catches yet goes to the known-failures table of `style` §5, in generic words, and becomes a check here when a script can see it.

## Finish

Run the first pass with `--out .arp/ui-check/before` and the last with `--out .arp/ui-check/after`, so the screenshots of each pass stay next to their JSON. Re-run until no errors, then build the page for the owner:

```
cd .arp/ui-check && node ${CLAUDE_PLUGIN_ROOT}/scripts/report.mjs after/ui-check.json --before before/ui-check.json --after after/ui-check.json [--questions questions.json] --out ui-report.html
```

Publish that HTML as an artifact. Then, if the screen carries business rules, use the `explore` skill.
