#!/usr/bin/env node
// Deterministic browser checks for one or more views. Settings: .arp/config.toml [ui], flags override.
// Output: <out>/ui-check.json plus screenshots. Exit 1 on errors, 0 on warnings only, 2 on usage.
import { mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { list, loadPlaywright, loadUi, login, parseArgs, parseSize, resolveUrl } from "./lib/common.mjs";
import { domChecks } from "./lib/page-checks.mjs";

const args = parseArgs(process.argv.slice(2), ["tabs", "only-failures", "help"]);
if (args.help || (!args.url && !args._.length)) {
  console.error(`usage: ui-check.mjs --url <url|path> [--url ...] [--tabs] [--only-failures]
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
const skip = new RegExp("delete|remove|void|archive|deactivate|sign out|log out|logout|confirm|save|pay|charge|send|submit|publish|approve|sign" + (cfg.skip_words ? "|" + [].concat(cfg.skip_words).join("|") : ""), "i");
const LAYERS = '[role="menu"], [role="listbox"], [role="dialog"], [role="alertdialog"], [data-radix-popper-content-wrapper], [popover]:popover-open';
const TRIGGERS = '[aria-haspopup]:not([aria-haspopup="false"]), [aria-expanded], [role="combobox"]';
const TABS = cfg.tab_selector ?? '[role="tab"]';

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
    const noise = [];
    page.on("console", (m) => m.type() === "error" && noise.push({ check: "console-error", text: m.text().slice(0, 300) }));
    page.on("pageerror", (e) => noise.push({ check: "console-error", text: String(e.message).slice(0, 300) }));
    page.on("response", (r) => r.status() >= 400 && !/favicon/.test(r.url()) && noise.push({ check: "failed-request", text: `${r.status()} ${r.request().method()} ${r.url()}` }));
    page.on("requestfailed", (r) => !/favicon/.test(r.url()) && !/ERR_ABORTED/.test(r.failure()?.errorText ?? "") && noise.push({ check: "failed-request", text: `${r.failure()?.errorText} ${r.method()} ${r.url()}` }));
    if (!args["no-login"]) await login(page, cfg.login, base);
    noise.length = 0;

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
          const text = ((await t.getAttribute("aria-label")) || (await t.innerText().catch(() => "")) || "").trim().replace(/\s+/g, " ").slice(0, 50);
          const key = text || `trigger ${i + 1}`;
          if (seen.has(key) || skip.test(key)) continue;
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
          if (items.length) record({ name: `${view.name} / ${key}` }, file, items);
          else unlinkSync(path.join(out, file));
        } catch {
          if (page.url() !== home) await page.goto(home, { waitUntil: "networkidle" });
        }
      }
      await closeLayers();
    }

    for (const url of urls) {
      await page.goto(url, { waitUntil: "networkidle" });
      await page.waitForTimeout(300);
      const name = url.replace(/^https?:\/\/[^/]+/, "") || "/";
      await checkView(name, url);
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
            await checkView(`${name} [tab: ${label}]`, url);
          } catch (e) {
            findings.push({ severity: "warning", check: "could-not-check", view: `${name} [tab: ${label}]`, theme, viewport: vp, selector: "", text: String(e.message).split("\n")[0], screenshot: "" });
          }
        }
      }
    }
    const last = views.filter((v) => v.theme === theme && v.viewport === vp).pop();
    for (const n of noise) findings.push({ severity: "error", check: n.check, view: last?.name ?? "", theme, viewport: vp, selector: "", text: n.text, screenshot: last?.screenshot ?? "" });
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
  checks: ["cut-off-text", "unequal-spacing", "borderless-color", "visible-scrollbar", "native-control", "layer-outside-viewport", "horizontal-scroll", "console-error", "failed-request", "repeated-text", ...(cfg.chat_selector && cfg.panel_selector ? ["chat-repeats-panel"] : [])],
  views, findings: result, summary: { errors, warnings },
}, null, 2));

for (const f of result) {
  console.log(`${f.severity === "error" ? "ERROR  " : "warning"} ${f.check} [${f.theme} ${f.viewport}] ${f.view}${f.selector ? " @ " + f.selector : ""}: ${f.text}${f.count > 1 ? ` (x${f.count})` : ""}`);
}
if (!args["only-failures"]) console.log(`${views.length} view(s) checked.`);
if (!args["only-failures"] || result.length) console.log(`${errors} error(s), ${warnings} warning(s). ${path.join(out, "ui-check.json")}`);
process.exit(errors ? 1 : 0);
