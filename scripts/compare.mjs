#!/usr/bin/env node
// Consistency of a screen against screens marked as approved ([ui] approved = [...]).
// Takes the "signature" of each repeated pattern and reports the properties that differ.
// Output: <out>/compare.json in the ui-check findings format (check "consistency", warning).
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { list, loadPlaywright, loadUi, login, parseArgs, parseSize, resolveUrl } from "./lib/common.mjs";

const args = parseArgs(process.argv.slice(2), ["help"]);
const project = path.resolve(args.project ?? process.cwd());
const cfg = loadUi(project);
const base = args["base-url"] ?? cfg.base_url;
const approved = (list(args.approved).length ? list(args.approved) : [].concat(cfg.approved ?? [])).map((u) => resolveUrl(String(u), base));
const targets = list(args.url ?? args._).map((u) => resolveUrl(u, base));
if (args.help || !targets.length || !approved.length) {
  console.error("usage: compare.mjs --url <screen> [--url ...] [--approved <url,...>] [--theme light|dark] [--viewport 1440x900] [--out dir]\n(approved screens default to [ui] approved; the first one that has a pattern is its reference)");
  process.exit(2);
}
const theme = args.theme === "dark" ? "dark" : "light";
const vp = String(args.viewport ?? [].concat(cfg.viewports ?? ["1440x900"])[0]);
const out = path.resolve(project, String(args.out ?? cfg.out ?? ".arp/ui-check"));
mkdirSync(out, { recursive: true });
const paginationSource = String(cfg.pagination_regex ?? "page\\s+\\d+\\s+of\\s+\\d+");

function signatures({ paginationSource, accent }) {
  const main = document.querySelector("main") ?? document.body;
  const visible = (el) => { const r = el.getBoundingClientRect(), cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== "hidden" && cs.display !== "none"; };
  const first = (sel, root = main, ok = () => true) => [...root.querySelectorAll(sel)].find((el) => visible(el) && ok(el));
  const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  const color = (c) => {
    canvas.clearRect(0, 0, 1, 1); canvas.fillStyle = "#00000000"; canvas.fillStyle = c; canvas.fillRect(0, 0, 1, 1);
    const [r, g, b, a] = canvas.getImageData(0, 0, 1, 1).data;
    if (a < 13) return "transparent";
    return `#${[r, g, b].map((n) => n.toString(16).padStart(2, "0")).join("")}${a < 250 ? ` (${Math.round((a / 255) * 100)}%)` : ""}`;
  };
  const px = (v) => (/^-?[\d.e+]+px$/.test(v) ? (parseFloat(v) >= 999 ? "pill" : `${Math.round(parseFloat(v))}px`) : v);
  const box = (cs, side) => ["Top", "Right", "Bottom", "Left"].map((s) => px(cs[`${side}${s}`])).join(" ");
  const text = (el) => (el.innerText ?? el.textContent ?? "").trim().split("\n")[0].slice(0, 40);
  const border = (cs, s) => (parseFloat(cs[`border${s}Width`]) > 0 && cs[`border${s}Style`] !== "none" ? `${px(cs[`border${s}Width`])} ${color(cs[`border${s}Color`])}` : "none");
  const h = (el) => px(`${el.getBoundingClientRect().height}px`);
  const res = {};
  const put = (name, el, props) => { if (el) res[name] = { sample: text(el), props }; };

  const h1 = first("h1");
  if (h1) {
    const cs = getComputedStyle(h1);
    put("title", h1, { size: px(cs.fontSize), weight: cs.fontWeight, color: color(cs.color), "line height": px(cs.lineHeight) });
    const sub = h1.nextElementSibling;
    if (sub && visible(sub) && /^(P|SPAN|DIV)$/.test(sub.tagName) && text(sub)) {
      const c2 = getComputedStyle(sub);
      put("subtitle", sub, { size: px(c2.fontSize), color: color(c2.color), "gap to title": px(`${sub.getBoundingClientRect().top - h1.getBoundingClientRect().bottom}px`) });
    }
  }

  const tabs = [...main.querySelectorAll('[role="tab"]')].filter(visible);
  if (tabs.length >= 2) {
    const on = tabs.find((t) => t.getAttribute("aria-selected") === "true" || t.dataset.state === "active") ?? tabs[0];
    const off = tabs.find((t) => t !== on), a = getComputedStyle(on), i = getComputedStyle(off);
    put("tabs", on, {
      size: px(a.fontSize), weight: `${a.fontWeight} / inactive ${i.fontWeight}`, height: h(on), "active color": color(a.color), "inactive color": color(i.color),
      "active mark": border(a, "Bottom") !== "none" ? `bottom border ${border(a, "Bottom")}` : a.boxShadow !== "none" ? "shadow" : color(a.backgroundColor) !== "transparent" ? `fill ${color(a.backgroundColor)}` : "color only",
    });
  }

  const search = first('input[type="search"], input[type="text"], input:not([type])', main, (el) => !el.closest('table, footer, [role="dialog"]'));
  if (search) {
    const cs = getComputedStyle(search), frame = search.parentElement ?? search, cf = getComputedStyle(frame);
    const framed = border(cs, "Top") === "none" && border(cf, "Top") !== "none";
    const real = framed ? cf : cs;
    put("search box", search, { height: h(framed ? frame : search), radius: px(real.borderTopLeftRadius), size: px(cs.fontSize), border: border(real, "Top"), fill: color(real.backgroundColor), icon: frame.querySelector("svg") ? "yes" : "no" });
  }

  const filter = first('[aria-haspopup]:not([aria-haspopup="false"]), [role="combobox"]', main, (el) => !el.closest("table, footer, nav, [role='tablist'], [role='dialog']") && el.tagName !== "INPUT");
  if (filter) {
    const cs = getComputedStyle(filter);
    put("filter trigger", filter, { height: h(filter), radius: px(cs.borderTopLeftRadius), size: px(cs.fontSize), weight: cs.fontWeight, border: border(cs, "Top"), fill: color(cs.backgroundColor), arrow: filter.querySelector("svg") ? "yes" : "no" });
  }

  const th = first("table thead th", main, (el) => text(el) && !el.querySelector("input"));
  if (th) {
    const cs = getComputedStyle(th);
    put("table header", th, { size: px(cs.fontSize), weight: cs.fontWeight, color: color(cs.color), fill: color(cs.backgroundColor), height: h(th), padding: box(cs, "padding"), transform: cs.textTransform, "letter spacing": cs.letterSpacing, "bottom border": border(cs, "Bottom") });
  }
  const row = first("table tbody tr", main, (tr) => tr.querySelectorAll("td").length >= 3);
  if (row) {
    const cs = getComputedStyle(row.querySelectorAll("td")[1]);
    put("table row", row, { height: h(row), size: px(cs.fontSize), color: color(cs.color), padding: box(cs, "padding"), "bottom border": border(cs, "Bottom") });
  }

  const wanted = accent || getComputedStyle(document.documentElement).getPropertyValue("--accent").trim() || getComputedStyle(document.documentElement).getPropertyValue("--primary").trim();
  if (wanted) {
    const target = color(wanted);
    const btn = first("button, a", main, (el) => color(getComputedStyle(el).backgroundColor) === target);
    if (btn) {
      const cs = getComputedStyle(btn);
      put("primary button", btn, { height: h(btn), radius: px(cs.borderTopLeftRadius), size: px(cs.fontSize), weight: cs.fontWeight, "side padding": px(cs.paddingLeft), icon: btn.querySelector("svg") ? "yes" : "no" });
    }
  }

  const re = new RegExp(paginationSource, "i");
  const holder = [...main.querySelectorAll("*")].find((el) => visible(el) && re.test(el.textContent) && ![...el.children].some((c) => re.test(c.textContent)));
  if (holder) {
    let foot = holder;
    while (foot.parentElement && foot !== main && foot.getBoundingClientRect().width < main.getBoundingClientRect().width * 0.6) foot = foot.parentElement;
    const parts = [];
    const walk = (n) => {
      for (const c of n.childNodes) {
        if (c.nodeType === 3) { const t = c.textContent.replace(/\s+/g, " ").trim(); if (t) parts.push(t.replace(/\d[\d\s.,]*\d|\d/g, "N")); continue; }
        if (c.nodeType !== 1 || !visible(c) || c.matches(".sr-only")) continue;
        if (c.matches('button, a, select, [role="combobox"], [role="button"], input')) parts.push(c.matches('select, [role="combobox"]') ? "[select]" : text(c) ? `[button ${text(c).replace(/\d+/g, "N")}]` : "[icon]");
        else walk(c);
      }
    };
    walk(foot);
    const cs = getComputedStyle(foot);
    put("table footer", foot, { pieces: parts.join(" | "), height: h(foot), "top border": border(cs, "Top"), padding: box(cs, "padding") });
  }
  return res;
}

const chromium = loadPlaywright(project, args["node-root"] ?? cfg.node_root);
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: parseSize(vp), colorScheme: theme });
const page = await ctx.newPage();
page.setDefaultTimeout(8000);
await login(page, cfg.login, base);
const shot = async (url) => {
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForTimeout(300);
  return page.evaluate(signatures, { paginationSource, accent: cfg.accent });
};
const refs = [];
for (const u of approved) refs.push({ name: new URL(u).pathname, sig: await shot(u) });
const findings = [], rows = [];
const same = (a, b) => a === b || (/^-?\d+px$/.test(a) && /^-?\d+px$/.test(b) && Math.abs(parseInt(a) - parseInt(b)) <= 1);
for (const u of targets) {
  const name = new URL(u).pathname;
  const sig = await shot(u);
  const file = `compare-${theme}-${name.replace(/[^\w]+/g, "-").replace(/^-|-$/g, "") || "root"}.jpg`;
  await page.screenshot({ path: path.join(out, file), type: "jpeg", quality: 85 });
  for (const [pattern, mine] of Object.entries(sig)) {
    const ref = refs.find((r) => r.sig[pattern]);
    if (!ref) continue;
    for (const [prop, val] of Object.entries(mine.props)) {
      const want = ref.sig[pattern].props[prop] ?? "-";
      if (same(val, want)) continue;
      const text = `${pattern}: ${prop} is ${val}, approved screen ${ref.name} has ${want}`;
      findings.push({ severity: "warning", check: "consistency", view: name, theme, viewport: vp, selector: pattern, text, screenshot: file });
      rows.push(text);
    }
  }
  for (const pattern of Object.keys(refs[0].sig))
    if (!sig[pattern]) { const t = `${pattern}: present on approved screens, missing here`; findings.push({ severity: "warning", check: "consistency", view: name, theme, viewport: vp, selector: pattern, text: t, screenshot: file }); rows.push(t); }
}
await browser.close();
writeFileSync(path.join(out, "compare.json"), JSON.stringify({ version: 1, generated: new Date().toISOString(), urls: targets, approved, viewports: [vp], themes: [theme], checks: ["consistency"], views: targets.map((u) => ({ name: new URL(u).pathname, theme, viewport: vp })), findings, summary: { errors: 0, warnings: findings.length } }, null, 2));
console.log(rows.length ? rows.join("\n") : "Consistent with the approved screens.");
console.log(`${findings.length} difference(s). ${path.join(out, "compare.json")}`);
process.exit(0);
