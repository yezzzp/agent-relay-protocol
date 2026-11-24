#!/usr/bin/env node
// One self-contained HTML page from ui-check.json files (and optional before/after + questions).
// No model writes it: everything comes from templates/report/ui-check.html and the JSON.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { list, parseArgs } from "./lib/common.mjs";

const args = parseArgs(process.argv.slice(2), ["help"]);
const inputs = [...list(args.input), ...args._];
if (args.help || (!inputs.length && !args.after)) {
  console.error("usage: report.mjs <ui-check.json ...> [--before a.json --after b.json] [--questions questions.json] [--title t] [--out report.html]\nquestions.json: [{\"question\": \"...\", \"context\": \"...\", \"screenshot\": \"path\"}]");
  process.exit(2);
}
const esc = (t) => String(t ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const load = (f) => ({ file: f, dir: path.dirname(path.resolve(f)), data: JSON.parse(readFileSync(f, "utf8")) });
const docs = inputs.map(load);
const before = args.before ? load(args.before) : null;
const after = args.after ? load(args.after) : null;
if (!docs.length && after) docs.push(after);

const img = (dir, rel, alt, cls = "") => {
  if (!rel) return "";
  const f = path.resolve(dir, rel);
  if (!existsSync(f)) return "";
  const mime = /\.png$/i.test(f) ? "image/png" : "image/jpeg";
  return `<img class="${cls}" tabindex="0" alt="${esc(alt)}" src="data:${mime};base64,${readFileSync(f).toString("base64")}">`;
};

const LABEL = {
  "cut-off-text": "Cut-off text", "unbounded-input": "Input without a length limit", "focus-not-restored": "Focus not restored", "double-submit": "Double submit", "unequal-spacing": "Unequal spacing", "borderless-color": "Border without color",
  "visible-scrollbar": "Visible scrollbar", "native-control": "Native control", "layer-outside-viewport": "Layer outside the window",
  "horizontal-scroll": "Horizontal scroll", "console-error": "Console error", "failed-request": "Failed request",
  "repeated-text": "Repeated text", "chat-repeats-panel": "Chat repeats the panel", consistency: "Inconsistent", "could-not-check": "Could not check",
  "business-rule": "Business rule", "broken-flow": "Broken flow",
};
const label = (c) => LABEL[c] ?? c;

const findings = docs.flatMap((d) => (d.data.findings ?? []).map((f) => ({ ...f, dir: d.dir })));
const views = docs.flatMap((d) => d.data.views ?? []);
const checks = [...new Set(docs.flatMap((d) => d.data.checks ?? []))];
const themes = [...new Set(docs.flatMap((d) => d.data.themes ?? []))];
const viewports = [...new Set(docs.flatMap((d) => d.data.viewports ?? []))];
const names = [...new Set(views.map((v) => v.name))];
const count = (s) => findings.filter((f) => f.severity === s).length;

const title = args.title ?? `UI check${names[0] ? " of " + names[0] : ""}${names.length > 1 ? ` and ${names.length - 1} more` : ""}`;

function checkedSection() {
  const scope = [`${names.length} view${names.length === 1 ? "" : "s"}`, themes.length ? themes.join(" and ") + " theme" : "", viewports.join(", ")].filter(Boolean).join(", ");
  const result = findings.length ? `${count("error")} error${count("error") === 1 ? "" : "s"} and ${count("warning")} warning${count("warning") === 1 ? "" : "s"}.` : '<span class="ok">Nothing found.</span>';
  return `<section><h2>What was checked</h2><p>${esc(scope)}. ${result}</p>${checks.length ? `<p class="muted">${checks.map(label).map(esc).join(" · ")}</p>` : ""}</section>`;
}

function findingsSection() {
  if (!findings.length) return "";
  let html = "";
  for (const sev of ["error", "warning"]) {
    const group = findings.filter((f) => f.severity === sev);
    if (!group.length) continue;
    const byView = new Map();
    for (const f of group) {
      const k = `${f.view}|${f.theme}|${f.screenshot}`;
      if (!byView.has(k)) byView.set(k, []);
      byView.get(k).push(f);
    }
    html += `<h3>${sev === "error" ? "Errors" : "Warnings"}</h3>`;
    for (const items of byView.values()) {
      const f0 = items[0];
      const where = [f0.view, f0.theme].filter(Boolean).join(" · ");
      html += `<div class="view ${sev}"><div class="name">${esc(where)}</div><ul>${items.map((f) => `<li><span class="tag">${esc(label(f.check))}</span>${esc(f.text)}${f.count > 1 ? ` <span class="muted">(${f.count} times)</span>` : ""}${f.locations ? `<span class="where muted">${f.locations.map((l) => `<code>${esc(l)}</code>`).join(" and ")}</span>` : f.selector ? `<span class="where muted"><code>${esc(f.selector)}</code></span>` : ""}</li>`).join("")}</ul>${img(f0.dir, f0.screenshot, where, "thumb")}</div>`;
    }
  }
  return `<section><h2>Findings</h2>${html}</section>`;
}

const key = (f) => [f.check, f.view, f.theme, f.selector, f.text].join("|");
function beforeAfterSection() {
  if (!before || !after) return "";
  const b = new Set((before.data.findings ?? []).map(key)), a = new Set((after.data.findings ?? []).map(key));
  const fixed = [...b].filter((k) => !a.has(k)).length, left = [...b].filter((k) => a.has(k)).length, added = [...a].filter((k) => !b.has(k)).length;
  const summary = `${fixed} fixed, ${left} still open${added ? `, ${added} new` : ""}.`;
  const pairs = [];
  for (const v of before.data.views ?? []) {
    const w = (after.data.views ?? []).find((x) => x.name === v.name && x.theme === v.theme && x.viewport === v.viewport);
    if (!w) continue;
    const l = img(before.dir, v.screenshot, `Before: ${v.name}`), r = img(after.dir, w.screenshot, `After: ${v.name}`);
    if (l && r) pairs.push(`<div class="name">${esc(v.name)} · ${esc(v.theme)}</div><div class="pair"><figure><figcaption>Before</figcaption>${l}</figure><figure><figcaption>After</figcaption>${r}</figure></div>`);
  }
  return `<section><h2>Before and after</h2><p>${summary}</p>${pairs.join("")}</section>`;
}

function questionsSection() {
  if (!args.questions) return "";
  const qs = JSON.parse(readFileSync(args.questions, "utf8"));
  if (!Array.isArray(qs) || !qs.length) return "";
  const dir = path.dirname(path.resolve(args.questions));
  return `<section><h2>Questions for you</h2>${qs.map((q) => `<div class="question"><p>${esc(q.question)}</p>${q.context ? `<p class="muted">${esc(q.context)}</p>` : ""}${img(dir, q.screenshot, q.question, "thumb")}</div>`).join("")}</section>`;
}

const template = readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "templates", "report", "ui-check.html"), "utf8");
const fill = { TITLE: esc(title), DATE: new Date().toISOString().slice(0, 10), CHECKED: checkedSection(), FINDINGS: findingsSection(), BEFORE_AFTER: beforeAfterSection(), QUESTIONS: questionsSection() };
const html = template.replace(/\{\{(\w+)\}\}/g, (_, k) => fill[k] ?? "");
const out = path.resolve(String(args.out ?? "ui-report.html"));
writeFileSync(out, html);
console.log(out);
