// Runs inside the browser (serialized by Playwright): must be self-contained.
// Returns [{severity, check, selector, text, locations?}].
export function domChecks({ rootSelector, theme, chatSelector, panelSelector, chatMessageSelector, allowNative }) {
  const out = [];
  const root = rootSelector ? document.querySelector(rootSelector) : document.body;
  if (!root) return out;
  const add = (severity, check, el, text, locations) =>
    out.push({ severity, check, selector: el ? pathOf(el) : "", text, ...(locations ? { locations } : {}) });

  function pathOf(el) {
    const parts = [];
    for (let n = el, d = 0; n && n.nodeType === 1 && n !== document.body && d < 4; n = n.parentElement, d++) {
      let s = n.tagName.toLowerCase();
      if (n.id && /^[\w-]+$/.test(n.id)) { parts.unshift(`${s}#${n.id}`); break; }
      const c = typeof n.className === "string" ? n.className.split(/\s+/).find((x) => /^[\w-]+$/.test(x)) : "";
      parts.unshift(c ? `${s}.${c}` : s);
    }
    return parts.join(" > ");
  }
  const visible = (el) => {
    const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && cs.visibility !== "hidden" && cs.display !== "none";
  };
  const label = (el) => `<${el.tagName.toLowerCase()}> "${(el.getAttribute("aria-label") || el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 50)}"`;
  const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  const luma = (color) => {
    canvas.clearRect(0, 0, 1, 1);
    canvas.fillStyle = "#00000000";
    canvas.fillStyle = color;
    canvas.fillRect(0, 0, 1, 1);
    const [r, g, b, a] = canvas.getImageData(0, 0, 1, 1).data;
    return a < 77 ? null : 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const covered = (el) => {
    const r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
    if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) return false;
    const top = document.elementFromPoint(x, y);
    return !!top && top !== el && !el.contains(top) && !top.contains(el);
  };

  if (!rootSelector && document.documentElement.scrollWidth > document.documentElement.clientWidth + 1)
    add("error", "horizontal-scroll", document.documentElement, `page is ${document.documentElement.scrollWidth}px wide in a ${document.documentElement.clientWidth}px window`);

  // Native controls where a component was expected.
  const nativeSel = 'select, input[type="checkbox"], input[type="radio"], input[type="date"], input[type="datetime-local"], input[type="month"], input[type="time"], datalist';
  for (const el of root.querySelectorAll(nativeSel)) {
    if (el.getAttribute("aria-hidden") === "true" || el.tabIndex === -1) continue;
    if (el.closest('[role="checkbox"], [role="switch"], [data-ui-native-ok]')) continue;
    if (allowNative && el.matches(allowNative)) continue;
    if (!visible(el) || covered(el)) continue;
    add("error", "native-control", el, label(el));
  }

  // Free text with no length limit: a paste of 10 000 characters reaches the API and breaks the layout.
  const textSel = 'input:not([type]), input[type="text"], input[type="search"], input[type="email"], input[type="tel"], input[type="url"], textarea';
  for (const el of root.querySelectorAll(textSel)) {
    if (el.maxLength >= 0 || el.readOnly || el.disabled || el.closest("[data-ui-unbounded-ok]")) continue;
    if (!visible(el) || covered(el)) continue;
    const name = el.getAttribute("aria-label") || el.labels?.[0]?.innerText || el.placeholder || el.name || el.id || "";
    add("warning", "unbounded-input", el, `<${el.tagName.toLowerCase()}> "${name.trim().replace(/\s+/g, " ").slice(0, 50)}" has no maxlength`);
  }

  const srOnly = (el) => el.getBoundingClientRect().width <= 1;
  for (const el of [root, ...root.querySelectorAll("*")]) {
    if (!visible(el) || srOnly(el)) continue;
    const cs = getComputedStyle(el);
    const ownText = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());

    if (ownText && el.scrollWidth > el.clientWidth + 1 && (cs.overflowX !== "visible" || cs.textOverflow === "ellipsis") && !el.title)
      add("warning", "cut-off-text", el, `${label(el)} (${el.scrollWidth}px of content in ${el.clientWidth}px)`);

    if (rootSelector && /(auto|scroll)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 1 && cs.scrollbarWidth !== "none")
      add("warning", "visible-scrollbar", el, `${label(el)} scrolls with a visible bar`);

    const bw = Math.max(...["Top", "Right", "Bottom", "Left"].map((s) => parseFloat(cs[`border${s}Width`])));
    if (bw > 0 && cs.borderTopStyle !== "none") {
      const l = luma(cs.borderTopColor), bg = luma(cs.backgroundColor);
      if (l !== null && (bg === null || Math.abs(bg - l) > 8) && ((theme === "light" && l < 45) || (theme === "dark" && l > 215)))
        add("warning", "borderless-color", el, `${label(el)} border ${cs.borderTopColor}`);
    }

    const band = el.matches("th, [role='columnheader'], [role='alert'], [role='status']") ||
      (parseFloat(cs.borderTopWidth) > 0 && parseFloat(cs.borderBottomWidth) > 0 && el.getBoundingClientRect().height < 90);
    if (band && (el.children.length || ownText)) {
      const rects = [];
      for (const n of el.childNodes) {
        if (n.nodeType === 3 && n.textContent.trim()) {
          const r = document.createRange();
          r.selectNodeContents(n);
          rects.push(r.getBoundingClientRect());
        } else if (n.nodeType === 1 && visible(n) && !srOnly(n)) rects.push(n.getBoundingClientRect());
      }
      if (rects.length && !(el.scrollHeight > el.clientHeight + 1)) {
        const box = el.getBoundingClientRect();
        const above = Math.min(...rects.map((r) => r.top)) - box.top - parseFloat(cs.borderTopWidth);
        const below = box.bottom - Math.max(...rects.map((r) => r.bottom)) - parseFloat(cs.borderBottomWidth);
        if (above >= 0 && below >= 0 && Math.abs(above - below) > 2.5)
          add("warning", "unequal-spacing", el, `${label(el)} ${above.toFixed(0)}px above / ${below.toFixed(0)}px below`);
      }
    }
  }

  // Repeated text: a title that comes back as a nearby subtitle or heading in the same view.
  {
    const norm = (t) => t.toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/[^\p{L}\p{N}\s]/gu, " ").replace(/\s+/g, " ").trim();
    const text = (el) => norm(el.textContent || "");
    const headingSel = 'h1, h2, h3, h4, [role="heading"]';
    const excluded = 'table, ul, ol, dl, li, [role="row"], [role="listitem"], [role="option"], [role="grid"], [role="menu"], [role="listbox"], [role="tablist"], [role="tab"], [role="navigation"], nav, button, a, label, select, option, th, td, [aria-hidden="true"]';
    const titles = new Set([...root.querySelectorAll(headingSel)]);
    const dialogs = root.matches?.('[role="dialog"], [role="alertdialog"]') ? [root] : [...root.querySelectorAll('[role="dialog"], [role="alertdialog"]')];
    for (const d of dialogs) {
      const ids = (d.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
      for (const id of ids) { const t = document.getElementById(id); if (t) titles.add(t); }
    }
    for (const el of root.querySelectorAll("[aria-labelledby]")) {
      if (el.matches('[role="dialog"], [role="alertdialog"], input, select, button')) continue;
      for (const id of el.getAttribute("aria-labelledby").split(/\s+/)) { const t = document.getElementById(id); if (t) titles.add(t); }
    }
    const heads = [...titles].filter((h) => visible(h) && text(h).length >= 4);
    const leaves = [...root.querySelectorAll("p, span, div, small, h5, h6, legend, caption, figcaption")]
      .filter((c) => c.children.length === 0 && visible(c) && !c.closest(excluded) && text(c).length >= 4);
    const seen = new Set();
    const report = (a, b, t) => {
      const key = [pathOf(a), pathOf(b)].sort().join("|");
      if (seen.has(key)) return;
      seen.add(key);
      add("error", "repeated-text", a, `"${t.slice(0, 60)}" appears twice in the same view`, [pathOf(a), pathOf(b)]);
    };
    for (const h of heads) {
      const t = text(h);
      for (const o of heads) if (o !== h && text(o) === t) report(h, o, (h.textContent || "").trim());
      for (const c of leaves) {
        if (c === h || h.contains(c) || c.contains(h) || text(c) !== t) continue;
        let anc = h.parentElement;
        for (let d = 0; anc && d < 3 && !anc.contains(c); d++) anc = anc.parentElement;
        if (anc && anc.contains(c)) report(h, c, (h.textContent || "").trim());
      }
    }
  }

  // Chat vs panel: the last chat message repeats what the side panel already shows.
  if (!rootSelector && chatSelector && panelSelector) {
    const chat = document.querySelector(chatSelector), panel = document.querySelector(panelSelector);
    if (chat && panel) {
      const stop = new Set("the a an and or but of to in on at for with from by is are was were be been it this that these those as if then so we you i they he she them your our their not no yes can will would should could has have had do does did into about than also just there here what which who when where how all any some more most".split(" "));
      const words = (t) => [...new Set((t.toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/(\d)[.,](?=\d)/g, "$1").match(/[\p{L}\p{N}]+/gu) || []).filter((w) => w.length >= 3 && !stop.has(w)))];
      const pool = [...chat.querySelectorAll(chatMessageSelector || '[data-message], [role="article"], [role="listitem"], li')].filter((m) => (m.textContent || "").trim());
      const last = pool.length ? pool[pool.length - 1] : [...chat.children].filter((m) => (m.textContent || "").trim()).pop();
      if (last) {
        const mine = words(last.innerText || last.textContent || ""), there = new Set(words(panel.innerText || panel.textContent || ""));
        const hit = mine.filter((w) => there.has(w)).length;
        if (mine.length >= 4 && hit / mine.length >= 0.6)
          add("warning", "chat-repeats-panel", last, `${Math.round((100 * hit) / mine.length)}% of the last chat message's words are already in the panel`, [pathOf(last), pathOf(panel)]);
      }
    }
  }
  return out;
}
