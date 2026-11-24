#!/usr/bin/env node
// Deterministic browser checks for one or more views. Settings: .arp/config.toml [ui], flags override.
// Output: <out>/ui-check.json plus screenshots. Exit 1 on errors, 0 on warnings only, 2 on usage.
import { mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { list, loadPlaywright, loadUi, login, parseArgs, parseSize, resolveUrl } from "./lib/common.mjs";
import { domChecks } from "./lib/page-checks.mjs";

const args = parseArgs(process.argv.slice(2), ["tabs", "only-failures", "help", "no-login", "probe"]);
if (args.help || (!args.url && !args._.length)) {
  console.error(`usage: ui-check.mjs --url <url|path> [--url ...] [--tabs] [--probe] [--only-failures]
  [--project dir] [--node-root dir] [--base-url u] [--viewports 1440x900,390x844] [--themes light,dark]
  [--out dir] [--no-login]
Settings come from <project>/.arp/config.toml [ui]; flags win.`);
  process.exit(2);
}
const project = path.resolve(args.project ?? process.cwd());
const cfg = loadUi(project);
const pick = (flag, key, dflt) => (list(args[flag]).length ? list(args[flag]) : cfg[key] !== undefined ? [].concat(cfg[key]).map(String) : dflt);
const base = args["base-url"] ?? cfg.base_url;
const viewports = pick("viewports", "viewports", ["1440x900"]);
const themes = pick("themes", "themes", ["light", "dark"]);
const urls = list(args.url ?? args._).map((u) => resolveUrl(u, base));
const out = path.resolve(project, String(args.out ?? cfg.out ?? ".arp/ui-check"));
mkdirSync(out, { recursive: true });
const maxLayers = Number(cfg.max_layers ?? 40);
// Words that stop a control from being opened, matched as whole words in English, Spanish and Portuguese.
// The real guarantee is below: after login every request that is not GET, HEAD or OPTIONS is blocked.
const SKIP_WORDS = [
  "delete", "remove", "void", "archive", "deactivate", "sign out", "log out", "logout", "confirm", "save", "pay",
  "charge", "send", "submit", "publish", "approve", "sign", "cancel order", "refund",
  "eliminar", "borrar", "quitar", "anular", "archivar", "desactivar", "cerrar sesión", "salir", "confirmar",
  "guardar", "pagar", "cobrar", "enviar", "publicar", "aprobar", "firmar", "emitir", "registrar", "devolver",
  "excluir", "apagar", "remover", "sair", "salvar", "enviar", "assinar",
  ...[].concat(cfg.skip_words ?? []),
];
const escape = (w) => String(w).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const skip = new RegExp(`(?<![\\p{L}\\p{N}])(?:${SKIP_WORDS.map(escape).join("|")})(?![\\p{L}\\p{N}])`, "iu");
const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);
const allowWrite = [].concat(cfg.allow_write ?? []).map((p) => new RegExp(p));
const LAYERS = '[role="menu"], [role="listbox"], [role="dialog"], [role="alertdialog"], [data-radix-popper-content-wrapper], [popover]:popover-open';
const TRIGGERS = '[aria-haspopup]:not([aria-haspopup="false"]), [aria-expanded], [role="combobox"]';
const TABS = cfg.tab_selector ?? '[role="tab"]';
// --probe double-clicks every action button. Writes stay blocked, but each is held before the abort:
// aborted at once, the button would come back enabled and the second click would look like a double submit.
const HOLD_MS = Number(cfg.probe_hold_ms ?? 800);
const maxProbes = Number(cfg.max_probes ?? 25);
const NEVER_PROBE = /(?<![\p{L}\p{N}])(?:sign out|log out|logout|cerrar sesión|salir|sair)(?![\p{L}\p{N}])/iu;
const PROBE_SEL = 'button, [role="button"], input[type="submit"]';

const chromium = loadPlaywright(project, args["node-root"] ?? cfg.node_root);
const browser = await chromium.launch();
const findings = [], views = [];
const slug = (s) => s.replace(/^https?:\/\/[^/]+/, "").replace(/[^\w]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "root";

for (const vp of viewports) {
  const size = parseSize(vp);
  for (const theme of themes) {
    const ctx = await browser.newContext({ viewport: size, colorScheme: theme });
    if (cfg.theme_storage_key)
      await ctx.addInitScript(([k, t]) => { try { localStorage.setItem(k, t); } catch {} }, [cfg.theme_storage_key, theme]);
    const page = await ctx.newPage();
    page.setDefaultTimeout(5000);
    page.setDefaultNavigationTimeout(Number(cfg.nav_timeout_ms ?? 60000));
    const noise = [];
    let here = null; // the view being checked, so each error is filed under the view that caused it
    const push = (n) => noise.push({ ...n, view: here });
    page.on("console", (m) => m.type() === "error" && push({ check: "console-error", text: m.text().slice(0, 300) }));
    page.on("pageerror", (e) => push({ check: "console-error", text: String(e.message).slice(0, 300) }));
    page.on("response", (r) => r.status() >= 400 && !/favicon/.test(r.url()) && push({ check: "failed-request", text: `${r.status()} ${r.request().method()} ${r.url()}` }));
    page.on("requestfailed", (r) => !/favicon/.test(r.url()) && !/ERR_ABORTED|ERR_BLOCKED_BY_CLIENT/.test(r.failure()?.errorText ?? "") && push({ check: "failed-request", text: `${r.failure()?.errorText} ${r.method()} ${r.url()}` }));
    if (!args["no-login"]) await login(page, cfg.login, base);
    noise.length = 0;
    const blocked = new Set();
    let probing = false;
    const writes = [];
    await ctx.route("**/*", (route) => {
      const req = route.request();
      if (SAFE_METHODS.has(req.method()) || allowWrite.some((re) => re.test(req.url()))) return route.continue();
      if (probing) {
        writes.push(`${req.method()} ${req.url().replace(/\?.*$/, "")}`);
        return new Promise((r) => setTimeout(r, HOLD_MS)).then(() => route.abort("blockedbyclient")).catch(() => {});
      }
      blocked.add(`${req.method()} ${req.url().replace(/\?.*$/, "")}`);
      return route.abort("blockedbyclient");
    });
    const shotOf = (name) => views.find((v) => v.theme === theme && v.viewport === vp && v.name === name)?.screenshot ?? "";
    const loginPath = cfg.login?.url ? new URL(resolveUrl(cfg.login.url, base)).pathname : null;

    const opts = (rootSelector) => ({ rootSelector, theme, chatSelector: cfg.chat_selector, panelSelector: cfg.panel_selector, chatMessageSelector: cfg.chat_message_selector, allowNative: cfg.allow_native });
    const record = (view, shot, items) => {
      for (const f of items) findings.push({ severity: f.severity, check: f.check, view: view.name, theme, viewport: vp, selector: f.selector, text: f.text, ...(f.locations ? { locations: f.locations } : {}), screenshot: shot });
    };

    async function checkView(name, url) {
      const view = { name, url, theme, viewport: vp };
      const file = `${theme}-${vp}-${slug(name)}.jpg`;
      await page.screenshot({ path: path.join(out, file), fullPage: true, type: "jpeg", quality: 85 });
      view.screenshot = file;
      views.push(view);
      record(view, file, await page.evaluate(domChecks, opts(null)));
      await walkLayers(view);
    }

    async function closeLayers() {
      for (let i = 0; i < 3 && (await page.locator(LAYERS).filter({ visible: true }).count()); i++) {
        await page.keyboard.press("Escape");
        await page.waitForTimeout(150);
      }
    }

    async function walkLayers(view) {
      const home = page.url();
      const triggers = page.locator(TRIGGERS).filter({ visible: true });
      const total = Math.min(await triggers.count(), maxLayers);
      const seen = new Set();
      for (let i = 0; i < total; i++) {
        try {
          const t = triggers.nth(i);
          const said = await t.evaluate((el) => [el.getAttribute("aria-label"), el.getAttribute("title"), el.innerText, el.value, el.getAttribute("data-testid")].filter(Boolean).join(" ").trim().replace(/\s+/g, " "));
          const submits = await t.evaluate((el) => {
            const form = el.closest("form");
            if (el.matches('input[type="submit"], input[type="image"]')) return true;
            return !!form && el.tagName === "BUTTON" && (el.getAttribute("type") ?? "submit").toLowerCase() === "submit";
          });
          const key = said.slice(0, 50) || `trigger ${i + 1}`;
          if (seen.has(key) || skip.test(said) || submits) continue;
          if (await t.evaluate((el) => !!el.closest("nav, aside, [role='navigation']") && !el.closest("main"))) continue;
          seen.add(key);
          await closeLayers();
          await t.scrollIntoViewIfNeeded();
          await t.click({ timeout: 2000 }).catch(() => { throw 0; });
          await page.waitForTimeout(300);
          if (page.url() !== home) { await page.goto(home, { waitUntil: "networkidle" }); continue; }
          const layer = page.locator(LAYERS).filter({ visible: true }).last();
          if (!(await layer.count())) continue;
          const mark = `uic-${i}`;
          await layer.evaluate((el, m) => el.setAttribute("data-ui-check", m), mark);
          const items = await page.evaluate(domChecks, opts(`[data-ui-check="${mark}"]`));
          const box = await layer.boundingBox();
          if (box && (box.x < 0 || box.y < 0 || box.x + box.width > size.width + 1 || box.y + box.height > size.height + 1))
            items.push({ severity: "warning", check: "layer-outside-viewport", selector: `[trigger] ${key}`, text: `layer at ${Math.round(box.x)},${Math.round(box.y)} ${Math.round(box.width)}x${Math.round(box.height)} in a ${size.width}x${size.height} window` });
          const file = `${theme}-${vp}-${slug(view.name)}-layer-${String(i + 1).padStart(2, "0")}.jpg`;
          await page.screenshot({ path: path.join(out, file), type: "jpeg", quality: 85 });
          await page.keyboard.press("Escape");
          await page.waitForTimeout(200);
          if (!(await page.locator(`[data-ui-check="${mark}"]`).isVisible().catch(() => false))) {
            const back = await t.evaluate((el) => el === document.activeElement || el.contains(document.activeElement)).catch(() => true);
            if (!back) {
              const now = await page.evaluate(() => { const a = document.activeElement; return !a || a === document.body ? "the page body" : `<${a.tagName.toLowerCase()}>`; });
              items.push({ severity: "warning", check: "focus-not-restored", selector: `[trigger] ${key}`, text: `closing «${key}» with Escape left focus on ${now}, not on its trigger` });
            }
          }
          if (items.length) record({ name: `${view.name} / ${key}` }, file, items);
          else unlinkSync(path.join(out, file));
        } catch {
          if (page.url() !== home) await page.goto(home, { waitUntil: "networkidle" });
        }
      }
      await closeLayers();
    }

    async function probeView(name, url) {
      const scope = (await page.locator("main").count()) ? "main " : "";
      const sel = PROBE_SEL.split(", ").map((x) => scope + x).join(", ");
      const total = Math.min(await page.locator(sel).count(), maxProbes);
      const quiet = noise.length;
      let dirty = false;
      for (let i = 0; i < total; i++) {
        try {
          if (dirty) { await page.goto(url, { waitUntil: "networkidle" }); dirty = false; }
          const b = page.locator(sel).nth(i);
          if (!(await b.isVisible()) || (await b.isDisabled())) continue;
          const info = await b.evaluate((el) => ({
            said: [el.getAttribute("aria-label"), el.getAttribute("title"), el.innerText, el.value].filter(Boolean).join(" ").trim().replace(/\s+/g, " "),
            trigger: el.matches('[aria-haspopup]:not([aria-haspopup="false"]), [aria-expanded], [role="combobox"], [role="tab"]'),
            nav: !!el.closest("nav, aside, [role='navigation']") && !el.closest("main"),
          }));
          if (info.trigger || info.nav || NEVER_PROBE.test(info.said)) continue;
          writes.length = 0;
          probing = true;
          await b.dblclick({ timeout: 2000 });
          await page.waitForTimeout(HOLD_MS + 400);
          probing = false;
          if (writes.length || page.url() !== url || (await page.locator(LAYERS).filter({ visible: true }).count())) dirty = true;
          const counts = new Map();
          for (const w of writes) counts.set(w, (counts.get(w) ?? 0) + 1);
          for (const [w, k] of counts) if (k > 1)
            findings.push({ severity: "error", check: "double-submit", view: name, theme, viewport: vp, selector: `[button] ${info.said.slice(0, 50)}`, text: `a double click on «${info.said.slice(0, 50)}» sent ${w} ${k} times: disable it while its action runs`, screenshot: shotOf(name) });
        } catch {
          probing = false;
          dirty = true;
        }
      }
      noise.length = quiet;
    }

    for (const url of urls) {
      const name = url.replace(/^https?:\/\/[^/]+/, "") || "/";
      here = name;
      try {
        await page.goto(url, { waitUntil: "networkidle" });
      } catch (e) {
        findings.push({ severity: "error", check: "load-failed", view: name, theme, viewport: vp, selector: "", text: String(e.message).split("\n")[0], screenshot: "" });
        continue;
      }
      await page.waitForTimeout(300);
      if (loginPath && new URL(page.url()).pathname === loginPath && new URL(url).pathname !== loginPath) {
        findings.push({ severity: "error", check: "redirected-to-login", view: name, theme, viewport: vp, selector: "", text: `${name} sent the browser to the login page: the login failed or this role cannot open it`, screenshot: "" });
        continue;
      }
      await checkView(name, url);
      if (args.probe && vp === viewports[0] && theme === themes[0]) await probeView(name, url);
      if (args.tabs) {
        const labels = [];
        const tabs = page.locator(TABS).filter({ visible: true });
        for (let i = 0; i < (await tabs.count()); i++) {
          const el = tabs.nth(i);
          const label = (await el.innerText()).trim().split("\n")[0].trim();
          if (label && (await el.getAttribute("aria-selected")) !== "true" && !skip.test(label)) labels.push(label);
        }
        for (const label of labels) {
          try {
            await page.goto(url, { waitUntil: "networkidle" });
            await page.locator(TABS).filter({ visible: true, hasText: label }).first().click();
            await page.waitForLoadState("networkidle");
            await page.waitForTimeout(300);
            here = `${name} [tab: ${label}]`;
            await checkView(here, url);
          } catch (e) {
            findings.push({ severity: "warning", check: "could-not-check", view: `${name} [tab: ${label}]`, theme, viewport: vp, selector: "", text: String(e.message).split("\n")[0], screenshot: "" });
          }
        }
      }
    }
    for (const n of noise) findings.push({ severity: "error", check: n.check, view: n.view ?? "", theme, viewport: vp, selector: "", text: n.text, screenshot: shotOf(n.view) });
    for (const b of blocked) findings.push({ severity: "warning", check: "blocked-write", view: "", theme, viewport: vp, selector: "", text: `${b} was blocked: ui-check never writes. If it is a read (GraphQL, search), add it to ui.allow_write`, screenshot: "" });
    await ctx.close();
  }
}
await browser.close();

// One finding that shows up on every theme or repeats in many rows is reported once with a count.
const merged = new Map();
for (const f of findings) {
  const k = [f.severity, f.check, f.view, f.theme, f.viewport, f.selector, f.text].join("|");
  const prev = merged.get(k);
  if (prev) prev.count++;
  else merged.set(k, { ...f, count: 1 });
}
const result = [...merged.values()];
const errors = result.filter((f) => f.severity === "error").length;
const warnings = result.length - errors;
writeFileSync(path.join(out, "ui-check.json"), JSON.stringify({
  version: 1, generated: new Date().toISOString(), urls, viewports, themes, tabs: !!args.tabs,
  checks: ["cut-off-text", "unequal-spacing", "borderless-color", "visible-scrollbar", "native-control", "layer-outside-viewport", "horizontal-scroll", "console-error", "failed-request", "repeated-text", "unbounded-input", "focus-not-restored", ...(args.probe ? ["double-submit"] : []), ...(cfg.chat_selector && cfg.panel_selector ? ["chat-repeats-panel"] : [])],
  views, findings: result, summary: { errors, warnings },
}, null, 2));

for (const f of result) {
  console.log(`${f.severity === "error" ? "ERROR  " : "warning"} ${f.check} [${f.theme} ${f.viewport}] ${f.view}${f.selector ? " @ " + f.selector : ""}: ${f.text}${f.count > 1 ? ` (x${f.count})` : ""}`);
}
if (!args["only-failures"]) console.log(`${views.length} view(s) checked.`);
if (!args["only-failures"] || result.length) console.log(`${errors} error(s), ${warnings} warning(s). ${path.join(out, "ui-check.json")}`);
process.exit(errors ? 1 : 0);
