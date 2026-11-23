// Shared helpers for the ui-check scripts: CLI flags, [ui] config, Playwright resolution, login.
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

export function parseArgs(argv, booleans = []) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) {
      args._.push(a);
      continue;
    }
    let [key, inline] = a.slice(2).split(/=(.*)/s, 2);
    let value = true;
    if (inline !== undefined) value = inline;
    else if (!booleans.includes(key) && argv[i + 1] !== undefined && !argv[i + 1].startsWith("--")) value = argv[++i];
    if (args[key] === undefined) args[key] = value;
    else args[key] = [].concat(args[key], value);
  }
  return args;
}

export const list = (v) => (v === undefined || v === true ? [] : [].concat(v).flatMap((x) => String(x).split(",")).map((s) => s.trim()).filter(Boolean));

// Tiny TOML subset: [a.b] tables, key = "string" | 'string' | number | bool | [array of those].
function splitTop(text) {
  const out = [];
  let cur = "", q = null;
  for (const c of text) {
    if (q) { cur += c; if (c === q) q = null; continue; }
    if (c === '"' || c === "'") { q = c; cur += c; continue; }
    if (c === ",") { out.push(cur); cur = ""; continue; }
    cur += c;
  }
  if (cur.trim()) out.push(cur);
  return out;
}
function value(raw) {
  const v = raw.trim();
  if (v.startsWith("[")) return splitTop(v.slice(1, v.lastIndexOf("]"))).map(value).filter((x) => x !== "");
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) return v.slice(1, -1);
  if (v === "true") return true;
  if (v === "false") return false;
  if (v !== "" && !Number.isNaN(Number(v))) return Number(v);
  return v;
}
function stripComment(line) {
  let q = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) { if (c === q) q = null; } else if (c === '"' || c === "'") q = c;
    else if (c === "#") return line.slice(0, i);
  }
  return line;
}
export function parseToml(text) {
  const root = {};
  let table = root;
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    let line = stripComment(lines[i]).trim();
    if (!line) continue;
    const h = /^\[([^\[\]]+)\]$/.exec(line);
    if (h) {
      table = root;
      for (const part of h[1].split(".").map((s) => s.trim())) table = table[part] ??= {};
      continue;
    }
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim().replace(/^["']|["']$/g, "");
    let raw = line.slice(eq + 1).trim();
    while (raw.startsWith("[") && (raw.match(/\[/g) || []).length > (raw.match(/\]/g) || []).length && i + 1 < lines.length)
      raw += " " + stripComment(lines[++i]).trim();
    table[key] = value(raw);
  }
  return root;
}

export function loadUi(projectRoot) {
  const file = path.join(projectRoot, ".arp", "config.toml");
  if (!existsSync(file)) return {};
  try { return parseToml(readFileSync(file, "utf8")).ui ?? {}; } catch { return {}; }
}

// Playwright is a dependency of the project being checked, never of agent-core.
export function loadPlaywright(projectRoot, configured) {
  const roots = configured
    ? [path.resolve(projectRoot, configured)]
    : [".", "web", "frontend", "app"].map((d) => path.resolve(projectRoot, d));
  for (const root of roots) {
    const req = createRequire(path.join(root, "package.json"));
    for (const name of ["playwright", "playwright-core", "@playwright/test"]) {
      try {
        const mod = req(name);
        if (mod.chromium) return mod.chromium;
      } catch {}
    }
  }
  console.error(`ui-check: Playwright not found in ${roots.join(", ")}; install it in the project (pnpm add -D playwright && npx playwright install chromium) or set ui.node_root.`);
  process.exit(2);
}

export function parseSize(s) {
  const m = /^(\d+)x(\d+)$/.exec(String(s));
  if (!m) throw new Error(`bad viewport "${s}", expected WIDTHxHEIGHT`);
  return { width: +m[1], height: +m[2] };
}

export function resolveUrl(u, base) {
  if (/^https?:\/\//.test(u)) return u;
  if (!base) throw new Error(`"${u}" is a path but no base_url is set`);
  return new URL(u, base.endsWith("/") ? base : base + "/").href.replace(/\/$/, u === "/" ? "/" : "");
}

// A selector is CSS, or "label:<text>" (the field's label) or "button:<name>" (a button's name).
function pick(page, sel) {
  if (sel.startsWith("label:")) return page.getByLabel(sel.slice(6), { exact: true });
  if (sel.startsWith("button:")) return page.getByRole("button", { name: sel.slice(7), exact: true });
  return page.locator(sel).first();
}

export async function login(page, cfg, base) {
  const l = cfg ?? {};
  if (!l.url) return;
  const email = process.env[l.email_env ?? ""], password = process.env[l.password_env ?? ""];
  if (!email || !password) throw new Error(`login: set env vars ${l.email_env} and ${l.password_env}`);
  await page.goto(resolveUrl(l.url, base), { waitUntil: "networkidle" });
  const user = pick(page, l.email_selector ?? 'input[type="email"], [name="email"], [name="username"]');
  const pw = pick(page, l.password_selector ?? 'input[type="password"]');
  const submit = l.submit_selector ? pick(page, l.submit_selector) : null;
  // Server-rendered apps can wipe fields typed before hydration: fill again until submit is enabled.
  const until = Date.now() + 30000;
  for (;;) {
    await user.fill(email);
    await pw.fill(password);
    if (!submit || (await submit.isEnabled().catch(() => false))) break;
    if (Date.now() > until) throw new Error("login: the submit button never became enabled");
    await page.waitForTimeout(500);
  }
  if (submit) await submit.click();
  else await pw.press("Enter");
  const here = page.url();
  await page.waitForURL((u) => u.href !== here, { waitUntil: "commit", timeout: 15000 }).catch(() => {});
  await page.waitForLoadState("networkidle").catch(() => {});
}
