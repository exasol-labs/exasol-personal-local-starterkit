// The guided view's cards for the Exasol starter kit. Plain ES module, no network.
// Python sends a list of blocks; this file draws them and sends clicks back.

const MODE_KEY = "exakit-guide-view";
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else if (k === "value") el.value = v;
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const ICON = {
  check: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  warn: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M8 2.2l6.2 11H1.8z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="M8 6.5v3.2M8 11.6v.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  info: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M8 7.2v4M8 4.9v.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  arrow: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M3 8h9.5M8.5 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  refresh: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M13 8a5 5 0 1 1-1.5-3.6M13 2.5v3h-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
};
const icon = (n) => h("span", { class: "guide-icon", html: ICON[n] });
// The Exasol wordmark (the company's own logo file; its letters take the text colour, so it reads in light and dark).
const LOGO = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 110 26" role="img" aria-label="Exasol"><g fill="currentColor"><polygon points="0,0 0,25.5 16.1,25.5 16.1,21.5 4.7,21.5 4.7,14.7 13.4,14.7 13.4,10.7 4.7,10.7 4.7,4 15.5,4 15.5,0"/><path d="M54.7,22.9c-1.2,2-3.9,3-6.2,3c-5,0-9.3-3.7-9.3-9.5C39,11.4,42.9,7.2,48,7l0,0h0.5c2.2,0,4.9,0.9,6.2,2.9V7.4h4v18.2h-4V22.9L54.7,22.9z M49,22c3,0.1,5.6-2.2,5.7-5.2c0-0.1,0-0.3,0-0.4c0-3-2.4-5.5-5.4-5.5H49c-3-0.1-5.5,2.2-5.6,5.2v0.3c-0.1,3,2.3,5.5,5.4,5.6L49,22"/><path d="M64.4,20.1c1.4,1.3,3.2,2,5.1,2c1.3,0,2.4-0.6,2.4-1.7c0-2.7-9-2.4-9-8.3c0-3.4,3.1-5.4,7.1-5.4s6.2,2.1,6.2,2.1l-1.7,3.4c-1.3-1-2.9-1.6-4.6-1.6c-1.2,0-2.4,0.5-2.4,1.7c0,2.6,9,2.3,9,8.2c0,3.1-2.7,5.5-7.1,5.5c-2.7,0-5.2-0.9-7.2-2.7L64.4,20.1L64.4,20.1z"/><path d="M89.1,6.8c5.7,0,10.2,4,10.2,9.6S94.8,26,89.2,26C83.5,26,79,22,79,16.4S83.5,6.8,89.1,6.8 M89.2,22.1c3,0,5.5-2.5,5.5-5.5l0,0v-0.2c0.2-3-2.2-5.6-5.2-5.7c-3-0.2-5.6,2.2-5.8,5.2v0.6c-0.1,3,2.2,5.6,5.2,5.7L89.2,22.1"/><path d="M102.8,0h4.6v19.2c0,2,0.7,2.5,1.9,2.5c0.4,0,0.7,0,0.7,0v4c-0.5,0.1-1,0.1-1.5,0.1c-2.5,0-5.7-0.6-5.7-5.9V0L102.8,0z"/><polygon points="29.3,11.9 32,15.4 38.2,7.4 32.8,7.3"/><polygon points="29.3,21 32,17.5 38.2,25.5 32.8,25.5"/></g><polygon fill="#5fc33b" points="18.5,25.5 25.6,16.4 18.6,7.4 24,7.4 31,16.4 24,25.5"/></svg>`;
// The kit's mark at the top left of a page's first card: the logo, then STARTER KIT and the persona.
// After them, Docs: this page's guide in the kit's documentation (nb.docs() serves it from this computer), in a new tab.
const brand = (persona, docs) => h("div", { class: "guide-brand" }, h("span", { class: "guide-brand-logo", html: LOGO }),
  h("span", { class: "guide-brand-text" }, persona ? `Starter Kit - ${persona}` : "Starter Kit"),
  docs ? h("a", { class: "guide-docs", href: docs, target: "_blank", rel: "noopener", title: "Open the documentation for this page" },
    "Docs", icon("arrow")) : null);

// ------------------------------------------------------------ page-wide setup
// The guided view hides the code of every cell that shows a guided card, across the notebook.
const GLOBAL_CSS = `
body.guide-cards .jp-Cell:has(.guide-root:not(.guide-ask)) .jp-Cell-inputWrapper,
body.guide-cards .jp-Cell:has(.guide-root:not(.guide-ask)) .jp-Cell-inputCollapser { display: none !important; }
body.guide-cards .jp-Cell:has(.guide-root) .jp-OutputPrompt,
body.guide-cards .jp-Cell:has(.guide-root) .jp-OutputArea-prompt { display: none !important; }
body.guide-cards .jp-Cell:has(.guide-root) .jp-OutputArea-child { padding-left: 0 !important; }
body.guide-ready .jp-Cell:has(.guide-start-hint) { display: none !important; }
.guide-root:not(.guide-codeview) .guide-code-only { display: none !important; }
/* The notebook's own code cells: everything from the "code behind this page" heading on. Hidden: a card's Code switch
   shows that card's code in place. "All the notebook's code cells", at the foot of a card's Code view, shows them. */
body.guide-cards:not(.guide-allcode) .jp-Cell:has(.guide-code-start),
body.guide-cards:not(.guide-allcode) .jp-Cell:has(.guide-code-start) ~ .jp-Cell { display: none !important; }
`;
const ALLCODE_KEY = "exakit-guide-allcode";
function installGlobal() {
  if (!document.getElementById("guide-global-css")) {
    document.head.appendChild(h("style", { id: "guide-global-css" }, GLOBAL_CSS));
  }
  document.body.classList.add("guide-cards");
  let all = false;
  try { all = localStorage.getItem(ALLCODE_KEY) === "1"; } catch (e) { /* storage blocked */ }
  setAllCode(all, false);
  document.body.classList.add("guide-ready");
}
// Every card opens Guided. Code is that one card's choice while it is on screen, never carried to the next card or
// the next run (it used to be remembered, and one Code click turned every later card into code).
function defaultMode() {
  try { localStorage.removeItem(MODE_KEY); } catch (e) { /* storage blocked */ }   // an older kit's remembered "code"
  return "guided";
}
function rememberMode(_mode) { /* the view is per card and per run: nothing to keep */ }
function allCode() { return document.body.classList.contains("guide-allcode"); }
function setAllCode(on, save = true) {
  document.body.classList.toggle("guide-allcode", on);
  if (save) { try { localStorage.setItem(ALLCODE_KEY, on ? "1" : "0"); } catch (e) { /* ignore */ } }
  document.dispatchEvent(new CustomEvent("guide-mode"));
}

// Copy the exact code to the clipboard, to paste into a notebook cell; the control says it worked.
function copyCode(text, el) {
  const done = () => { if (!el) return; const was = el.textContent; el.textContent = "Copied"; setTimeout(() => { el.textContent = was; }, 1500); };
  try {
    navigator.clipboard.writeText(text).then(done, () => {});
  } catch (e) { /* no clipboard here: the code stays visible to select */ }
}

function detectDark(host) {
  const attr = document.body.getAttribute("data-jp-theme-light");
  if (attr === "true" || attr === "false") return attr === "false";
  const probe = h("div", { style: "position:absolute;visibility:hidden;background:var(--jp-layout-color0, transparent)" });
  host.appendChild(probe);
  const m = getComputedStyle(probe).backgroundColor.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/);
  probe.remove();
  if (m && (m[4] === undefined || Number(m[4]) > 0)) return 0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3] < 128;
  return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
}

const nf = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 });
const fmt = (v) => (v == null ? "" : nf.format(v));
const pct = (v) => (v == null ? "–" : `${(v * 100).toFixed(1)}%`);

function barChart(items, overall, isPct) {
  if (!items || !items.length) return h("p", { class: "guide-muted" }, "Nothing to show.");
  const W = 560, LW = 150, RH = 28, PW = W - LW - 64, H = RH * items.length + 6;
  const vmax = Math.max(...items.map((i) => i.value || 0), overall || 0) || 1;
  let s = `<svg viewBox="0 0 ${W} ${H}" class="guide-chart" role="img">`;
  items.forEach((it, k) => {
    const y = 3 + k * RH, w = Math.max(2, (PW * (it.value || 0)) / vmax);
    const hi = overall != null && it.value > overall;
    const lab = String(it.label).length > 20 ? String(it.label).slice(0, 19) + "…" : it.label;
    const val = it.display || (isPct ? pct(it.value) : fmt(it.value));
    s += `<text x="${LW - 10}" y="${y + 15}" text-anchor="end" class="guide-c-lbl">${esc(lab)}</text>`;
    s += `<rect x="${LW}" y="${y + 3}" width="${w.toFixed(1)}" height="${RH - 11}" rx="3" class="guide-c-bar${hi || overall == null ? " hi" : ""}"><title>${esc(it.label)}: ${val}${it.rows != null ? ` (${fmt(it.rows)} rows)` : ""}</title></rect>`;
    s += `<text x="${(LW + w + 6).toFixed(1)}" y="${y + 15}" class="guide-c-val">${val}</text>`;
  });
  if (overall != null) { const x = LW + (PW * overall) / vmax; s += `<line x1="${x.toFixed(1)}" x2="${x.toFixed(1)}" y1="0" y2="${H}" class="guide-c-ref"/>`; }
  return h("div", { html: s + "</svg>" });
}

function lineChart(points, isPct) {
  if (!points || points.length < 2) return h("p", { class: "guide-muted" }, "Not enough dates to show a trend.");
  const W = 560, H = 200, PL = 50, PR = 12, PT = 10, PB = 26;
  const vals = points.map((p) => p.value || 0);
  const vmin = Math.min(...vals), vmax = Math.max(...vals);
  const pad = (vmax - vmin) * 0.15 || Math.abs(vmax) * 0.1 || 1;
  const lo = Math.max(0, vmin - pad), hi = vmax + pad, n = points.length;
  const X = (i) => PL + ((W - PL - PR) * i) / (n - 1);
  const Y = (v) => PT + (H - PT - PB) * (1 - (v - lo) / (hi - lo));
  const lab = (v) => (isPct ? pct(v) : fmt(Math.round(v)));
  let s = `<svg viewBox="0 0 ${W} ${H}" class="guide-chart" role="img">`;
  for (let t = 0; t < 3; t++) {
    const v = lo + ((hi - lo) * t) / 2, y = Y(v);
    s += `<line x1="${PL}" x2="${W - PR}" y1="${y.toFixed(1)}" y2="${y.toFixed(1)}" class="guide-c-grid"/><text x="${PL - 8}" y="${(y + 4).toFixed(1)}" text-anchor="end" class="guide-c-lbl">${lab(v)}</text>`;
  }
  [...new Set([0, Math.floor(n / 2), n - 1])].forEach((i) => {
    s += `<text x="${X(i).toFixed(1)}" y="${H - 6}" text-anchor="${i === 0 ? "start" : i === n - 1 ? "end" : "middle"}" class="guide-c-lbl">${esc(points[i].period)}</text>`;
  });
  s += `<path d="M${vals.map((v, i) => `${X(i).toFixed(1)},${Y(v).toFixed(1)}`).join(" L")}" class="guide-c-line"/>`;
  vals.forEach((v, i) => { s += `<circle cx="${X(i).toFixed(1)}" cy="${Y(v).toFixed(1)}" r="7" class="guide-c-hit"><title>${esc(points[i].period)}: ${lab(v)} (${fmt(points[i].rows)} rows)</title></circle>`; });
  return h("div", { html: s + "</svg>" });
}

function readable(col) {
  const c = String(col);
  let m = c.match(/^(.*)_RATE_PCT$/);
  if (m) return `${m[1]} rate (%)`;
  if (c.startsWith("TOTAL_")) return `Total ${c.slice(6)}`;
  if (c.startsWith("AVG_")) return `Average ${c.slice(4)}`;
  return c.replace(/_START$/, " start").replace(/_PCT$/, " (%)");
}

// Open a notebook as a tab inside JupyterLab, without reloading the page (a reload makes the browser ask
// "Leave site?" when a notebook has unsaved changes). The guided view does what a person would: double-click the
// file in JupyterLab's file browser. If it isn't listed there, it opens in a new browser tab instead.
function openInLab(path, e) {
  if (e && (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1)) return;   // let new-tab clicks through
  if (e) e.preventDefault();
  const name = path.split("/").pop();
  const item = [...document.querySelectorAll(".jp-DirListing-item")]
    .find((el) => (el.getAttribute("title") || "").split("\n").some((l) => l.trim().endsWith(name)) ||
                  (el.querySelector(".jp-DirListing-itemText")?.textContent || "").trim() === name);
  if (item) {
    item.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, button: 0 }));
    item.dispatchEvent(new MouseEvent("click", { bubbles: true, button: 0 }));
    item.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, button: 0 }));
    return;
  }
  window.location.assign(labUrl(path));   // JupyterLab reopens your tabs and adds this one
}

function labUrl(path) {
  const base = window.location.pathname.split("/lab")[0];
  return `${base}/lab/tree/${path.split("/").map(encodeURIComponent).join("/")}`;
}

// ------------------------------------------------------------ render
function render({ model, el }) {
  installGlobal();
  const root = h("div", { class: model.get("kind") === "ask" ? "guide-root guide-ask" : "guide-root" });
  // Keep typing inside the card: JupyterLab's notebook shortcuts (A, B, D D, M, Enter...) must not see keys
  // pressed in our boxes. Standard Jupyter widgets do the same.
  root.setAttribute("data-lm-suppress-shortcuts", "true");
  const keepKeys = (e) => {
    const t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) {
      e.stopPropagation();
    }
  };
  ["keydown", "keypress", "keyup"].forEach((type) => root.addEventListener(type, keepKeys));
  el.appendChild(root);
  const ui = { busy: null, openForm: null, values: {}, fading: new Set(), dismissed: new Set(), mode: defaultMode() };
  // This card's own view: Guided draws its controls; Code draws, in this very place, the code behind them. The
  // session (data, connection, approvals) is the kernel's and does not change with the view.
  const getMode = () => ui.mode;
  const setMode = (mode) => { ui.mode = mode; rememberMode(mode); draw(); };
  const st = { choice: {}, fields: {}, roles: null, slots: null, mapKey: null, mapInit: null, secret: new Set(), cells: {} };
  const collect = () => ({ ...st.fields, ...st.choice, roles: { ...(st.roles || {}) }, slots: { ...(st.slots || {}) } });
  const mapDirty = () => !!st.mapInit && JSON.stringify({ r: st.roles, s: st.slots }) !== st.mapInit;

  // A field's or a button's condition: one {field, equals}, or a list that must all hold (a choice or a field).
  // {field, in: [...]} holds when the field is one of them.
  const shown = (cond) => !cond || (Array.isArray(cond) ? cond : [cond]).every((c) => {
    const now = String(st.fields[c.field] ?? st.choice[c.field] ?? "");
    return Array.isArray(c.in) ? c.in.map(String).includes(now) : now === String(c.equals);
  });

  const send = (id, values = {}, opts = {}) => {
    if (ui.busy) return;
    ui.busy = id;
    ui.progress = null;
    draw();
    ui.fading.clear(); ui.dismissed.clear();
    if (opts.noSecret) {               // an action that needs no password is never sent one, and keeps it typed
      values = { ...values };
      st.secret.forEach((k) => { delete values[k]; });
    }
    model.send({ type: "event", id, values });
    // A password goes to Python once and is not kept in the card (nor drawn back into its box).
    if (!opts.noSecret) st.secret.forEach((k) => { st.fields[k] = ""; });
  };

  function button(label, id, opts = {}) {
    const busy = ui.busy === id;
    if (opts.href) {
      return h("a", { class: `guide-btn ${opts.primary ? "guide-btn-primary" : "guide-btn-quiet"}`, href: opts.href, target: opts.target || "_blank", rel: "noopener" }, label, icon("arrow"));
    }
    return h("button", { type: "button", class: `guide-btn ${opts.primary ? "guide-btn-primary" : "guide-btn-quiet"}`, disabled: !!ui.busy,
      onClick: opts.onClick || (() => send(id, opts.values ? opts.values() : {}, { noSecret: !!opts.noSecret })) },
      busy ? h("span", { class: "guide-spinner" }) : null,
      busy ? (opts.busyLabel || "Working…") + (ui.progress && ui.progress.pct != null ? ` ${ui.progress.pct}%` : "") : label);
  }

  // A running command's progress, under its button: what it is doing now, a bar when it says how far it is, and
  // its last lines - the same lines `exakit data-load` shows in a terminal.
  function progressPanel(id) {
    if (!ui.busy || ui.busy !== id || !ui.progress) return null;
    const p = ui.progress;
    return h("div", { class: "guide-progress", role: "status", "aria-live": "polite" },
      h("div", { class: "guide-progress-label" }, p.label || "Working…"),
      h("div", { class: `guide-progress-bar${p.pct == null ? " guide-progress-bar-busy" : ""}` },
        h("span", { style: p.pct == null ? null : `width:${Math.max(2, Math.min(100, p.pct))}%` })),
      (p.lines || []).length > 1 ? h("pre", { class: "guide-progress-lines" }, p.lines.slice(0, -1).join("\n")) : null);
  }

  const B = {
    home_head(b) {
      const guided = getMode() === "guided";
      return h("div", { class: "guide-head" },
        h("div", {},
          b.brand !== undefined ? brand(b.brand, b.docs) : h("div", { class: "guide-kicker" }, "Exasol starter kit"),
          b.brand !== undefined ? null : h("h2", { class: "guide-title" }, "Your kit"),     // the mark is the heading
          h("div", { class: `guide-summary guide-summary-${b.state}` },
            b.state === "loading" ? h("span", { class: "guide-spinner" }) : icon(b.state === "ok" ? "check" : b.state === "bad" ? "warn" : "info"),
            b.summary), helpLinks(b.help)),
        h("div", { class: "guide-head-actions" },
          h("div", { class: "guide-switch", role: "group", "aria-label": "View" },
            h("button", { type: "button", class: guided ? "is-on" : "", "aria-pressed": guided ? "true" : "false", onClick: () => setMode("guided") }, "Guided"),
            h("button", { type: "button", class: !guided ? "is-on" : "", "aria-pressed": !guided ? "true" : "false", onClick: () => setMode("code") }, "Code")),
          b.state !== "loading" ? h("button", { type: "button", class: "guide-iconbtn", title: "Check again", "aria-label": "Check again", disabled: !!ui.busy, onClick: () => send("refresh") },
            ui.busy === "refresh" ? h("span", { class: "guide-spinner" }) : icon("refresh")) : null));
    },
    // Tabs of one card (Your kit | Marketplace): the screen draws the chosen one.
    tabs(b) {
      return h("div", { class: "guide-tabs", role: "tablist" }, b.items.map((i) =>
        h("button", { type: "button", role: "tab", "aria-selected": i.id === b.value ? "true" : "false",
          class: i.id === b.value ? "is-on" : "", disabled: !!ui.busy, onClick: () => { if (i.id !== b.value) send(`tab_${i.id}`); } }, i.label)));
    },
    section(b) { return h("h3", { class: "guide-section" }, b.v); },
    skeleton(b) { return h("div", { class: "guide-rows" }, Array.from({ length: b.rows || 4 }, () => h("div", { class: "guide-row guide-skel" }, h("span", {}), h("span", {}), h("span", {})))); },
    msg(b) {
      const kind = b.kind || "info";
      // A success note has done its job after a few seconds; warnings and errors stay until acted on.
      if (kind === "ok" && !b.keep && ui.dismissed.has(b.v)) return null;
      const node = h("div", { class: `guide-msg guide-msg-${kind}`, role: kind === "error" ? "alert" : "status" },
        icon(kind === "ok" ? "check" : kind === "error" || kind === "warn" ? "warn" : "info"), h("span", {}, b.v));
      if (kind === "ok" && !b.keep && !ui.fading.has(b.v)) {   // a result asked for (a test) stays until the next action
        ui.fading.add(b.v);
        setTimeout(() => { node.classList.add("guide-fade"); setTimeout(() => { ui.dismissed.add(b.v); draw(); }, 400); }, 6000);
      }
      return node;
    },
    setup(b) {
      return h("div", { class: "guide-rows" }, b.rows.map((r) => {
        const actions = r.actions || [];
        const formAction = actions.find((a) => a.form && ui.openForm === `${r.id}:${a.id}`);
        const confirming = r.confirming && actions.find((a) => a.id === r.confirming);
        return h("div", { class: `guide-row guide-row-${r.dot}` },
          h("span", { class: `guide-dot guide-dot-${r.dot}`, "aria-hidden": "true" }),
          h("div", { class: "guide-row-main" },
            h("div", { class: "guide-row-line" }, h("span", { class: "guide-row-name" }, r.name), h("span", { class: "guide-row-text" }, r.text)),
            r.sub ? h("div", { class: "guide-row-sub" }, r.sub) : null,
            r.cmd ? h("code", { class: "guide-code-only guide-cmd", title: "Click to copy as a cell", onClick: (e) => copyCode(r.cmd, e.currentTarget) }, r.cmd) : null,
            confirming ? h("div", { class: "guide-confirm" }, h("span", {}, confirming.confirm),
              button("Yes, continue", confirming.id, { primary: true, busyLabel: "Updating…" }), button("Cancel", "cancel")) : null,
            formAction ? form(r, formAction) : null,
            actions.filter((a) => !a.form).map((a) => progressPanel(a.id)),
            r.output ? kitSaid(r) : null),
          h("div", { class: "guide-row-actions" }, actions.map((a) => a.href
            ? button(a.label, a.id, { href: a.href })
            : a.form
              ? h("button", { type: "button", class: "guide-btn guide-btn-quiet", disabled: !!ui.busy,
                  onClick: () => { ui.openForm = ui.openForm === `${r.id}:${a.id}` ? null : `${r.id}:${a.id}`; draw(); } }, a.label)
              : button(a.label, a.id))));
      }));
    },
    chips(b) {
      if (!b.items || !b.items.length) return null;
      return h("div", { class: "guide-chips" }, b.label ? h("span", { class: "guide-chips-label" }, b.label) : null,
        b.items.map((c) => h("span", { class: `guide-chip guide-chip-${c.kind || "muted"}`, title: c.title || "" }, c.kind === "ok" ? icon("check") : null, c.label)));
    },
    journey(b) {
      return h("div", { class: `guide-journey${b.compact ? " guide-journey-compact" : ""}` }, b.items.map((j) => h("a", { class: `guide-step guide-step-${j.state}`, href: labUrl(j.path),
          "aria-current": j.state === "here" ? "step" : null, onClick: (e) => { if (j.state === "here") { e.preventDefault(); return; } openInLab(j.path, e); } },
        h("div", { class: "guide-step-top" },
          h("span", { class: "guide-step-num" }, j.state === "done" ? icon("check") : j.state === "home" ? "⌂" : j.n),
          h("span", { class: "guide-step-state" }, { done: "Done", next: "Next", attention: "Needs a look", here: "You are here", todo: "" }[j.state] || "")),
        h("div", { class: "guide-step-title" }, j.title),
        h("div", { class: "guide-step-text" }, j.note || j.text),
        h("code", { class: "guide-code-only guide-cmd" }, j.path.split("/").pop()))));
    },
    resume(b) {
      return h("div", { class: "guide-resume" },
        h("div", {}, h("div", { class: "guide-row-text" }, b.text), b.sub ? h("div", { class: "guide-row-sub" }, b.sub) : null,
          b.cmd ? h("code", { class: "guide-code-only guide-cmd" }, b.cmd) : null),
        b.path ? h("a", { class: "guide-btn guide-btn-primary", href: labUrl(b.path), onClick: (e) => openInLab(b.path, e) }, "Continue", icon("arrow")) : null);
    },
    foot(b) { return h("p", { class: "guide-foot" }, b.v); },
    head(b) {
      const guided = getMode() === "guided";
      return h("div", { class: "guide-head" },
        h("div", {}, b.brand !== undefined ? brand(b.brand, b.docs) : null, b.kicker ? h("div", { class: "guide-kicker" }, b.kicker) : null,
          h("h2", { class: "guide-title guide-title-sm" }, b.title), b.sub ? h("p", { class: "guide-sub" }, b.sub) : null,
          helpLinks(b.help)),
        h("div", { class: "guide-switch", role: "group", "aria-label": "View" },
          h("button", { type: "button", class: guided ? "is-on" : "", onClick: () => setMode("guided") }, "Guided"),
          h("button", { type: "button", class: !guided ? "is-on" : "", onClick: () => setMode("code") }, "Code")));
    },
    p(b) { return h("p", { class: b.muted ? "guide-p guide-muted" : "guide-p" }, b.v); },
    empty(b) { return h("div", { class: "guide-empty" }, icon("info"), b.v); },
    divider() { return h("hr", { class: "guide-divider" }); },
    subhead(b) { return h("h3", { class: "guide-subhead" }, b.v); },
    note(b) { return h("div", { class: "guide-note" }, b.v); },
    pre(b) { return h("pre", { class: "guide-pre" }, b.v); },
    code(b) {
      // The exact notebook code of what the card ran: copy it into a cell and it does the same.
      return h("div", { class: b.code_only ? "guide-code-only guide-codebox" : "guide-codebox" },
        h("div", { class: "guide-codebox-title" }, b.title || "Code",
          h("button", { type: "button", class: "guide-btn guide-btn-quiet guide-copy", onClick: (e) => copyCode(b.v, e.currentTarget) }, "Copy as cell")),
        h("pre", {}, b.v));
    },
    details(b) {
      // Open as the screen asks (the kit's own words always are), until the reader closes it.
      const d = h("details", { class: "guide-details", open: ui.values["open:" + b.title] ?? !!b.open },
        h("summary", {}, b.title), h("div", { class: "guide-details-body" }, (b.blocks || []).map(block).filter(Boolean)));
      d.addEventListener("toggle", () => { ui.values["open:" + b.title] = d.open; });
      return d;
    },
    next(b) {
      return h("div", { class: "guide-nextrow" }, h("a", { class: "guide-btn guide-btn-primary", href: labUrl(b.path), onClick: (e) => openInLab(b.path, e) }, b.v, icon("arrow")));
    },
    actions(b) {
      const items = b.items.filter((a) => shown(a.show_if));
      return h("div", {}, h("div", { class: "guide-actions" }, items.map((a) => {
        const label = a.changed_label ? (mapDirty() ? a.changed_label : (a.unchanged_label || a.label)) : a.label;
        return button(label, a.id, { primary: a.primary, busyLabel: a.busy, values: collect, noSecret: !!a.no_secret });
      })), items.map((a) => progressPanel(a.id)));
    },
    choice(b) {
      if (st.choice[b.id] === undefined) st.choice[b.id] = b.value;
      const sel = st.choice[b.id];
      // below: the options are boxes of one size in a row, and the chosen one's fields sit under the row, full width.
      const picked = b.below ? b.options.find((o) => o.value === sel) : null;
      const boxes = h("div", { class: `guide-choices${b.cols ? " guide-choices-" + b.cols : ""}${b.below ? " guide-choices-even" : ""}`, role: "radiogroup" }, b.options.map((o) => {
        const on = sel === o.value;
        const pick = () => { if (o.disabled || on) return; st.choice[b.id] = o.value; draw(); };
        return h("div", { class: `guide-choice${on ? " is-on" : ""}${o.disabled ? " is-off" : ""}`, role: "radio", tabindex: o.disabled ? "-1" : "0",
          "aria-checked": on ? "true" : "false", "aria-disabled": o.disabled ? "true" : "false",
          onClick: pick, onKeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(); } } },
          h("div", { class: "guide-choice-head" }, h("span", { class: "guide-radio" }), h("strong", {}, o.title)),
          h("div", { class: "guide-choice-text" }, o.disabled && o.disabled_reason ? o.disabled_reason : o.text),
          on && !b.below ? h("div", { class: "guide-choice-fields", onClick: (e) => e.stopPropagation() }, (o.fields || []).map(field)) : null);
      }));
      if (!b.below) return boxes;
      // The block's own actions (Back / Next / Use this data) sit inside the picked option's box, under its fields.
      // The fields are drawn first: drawing one records its value, which decides the buttons that show.
      const fields = (picked ? (picked.fields || []) : []).map(field).filter(Boolean);
      const acts = b.actions && b.actions.some((a) => shown(a.show_if)) ? B.actions({ items: b.actions }) : null;
      return h("div", { class: "guide-choice-wrap" }, boxes,
        fields.length || acts ? h("div", { class: "guide-choice-panel guide-choice-fields" }, fields, acts) : null);
    },
    fields(b) { return h("div", { class: "guide-fieldrow" }, b.items.map(field)); },
    checks(b) {
      return h("div", { class: "guide-checks" }, b.items.map((c) => {
        if (st.fields[c.id] === undefined) st.fields[c.id] = false;
        return h("label", { class: "guide-checkrow" },
          h("input", { type: "checkbox", checked: st.fields[c.id] ? true : null, onChange: (e) => { st.fields[c.id] = e.target.checked; } }),
          h("span", {}, c.label));
      }));
    },
    linkcard(b) {
      return h("div", { class: `guide-linkcard${b.kind === "ok" ? " guide-linkcard-ok" : ""}` },
        h("div", {}, h("div", { class: "guide-linkcard-title" }, icon("check"), b.title), h("div", { class: "guide-muted guide-small guide-break" }, b.text)),
        b.href ? h("a", { class: "guide-btn guide-btn-primary", href: b.href, target: "_blank", rel: "noopener" }, b.label, icon("arrow"))
          : b.button ? button(b.button.label, b.button.id) : null);
    },
    askbox(b) {
      if (st.fields.question === undefined) st.fields.question = b.value || "";
      const go = () => send("draft", { question: st.fields.question });
      return h("div", { class: "guide-askbox" },
        h("div", { class: "guide-askrow" },
          h("input", { class: "guide-input guide-input-lg", type: "text", value: st.fields.question, placeholder: b.placeholder, spellcheck: "true",
            "aria-label": "Your question", disabled: !!ui.busy,
            onInput: (e) => { st.fields.question = e.target.value; }, onKeydown: (e) => { if (e.key === "Enter") go(); } }),
          button("Draft", "draft", { primary: true, busyLabel: "Drafting…", onClick: go })),
        b.examples && b.examples.length ? h("div", { class: "guide-examples" }, h("span", { class: "guide-muted guide-small" }, "Try:"),
          b.examples.map((q) => h("button", { type: "button", class: "guide-example", disabled: !!ui.busy,
            onClick: () => { st.fields.question = q; send("draft", { question: q }); } }, q))) : null);
    },
    question(b) {
      return h("div", { class: "guide-question" }, h("span", { class: "guide-question-label" }, "Question"), h("span", {}, b.v));
    },
    proposal(b) {
      if (st.fields.sql === undefined || st.sqlFrom !== b.sql) { st.fields.sql = b.sql; st.sqlFrom = b.sql; }
      const sqlOpen = !!ui.values["open:sql"];
      const fold = h("details", { class: "guide-details", open: sqlOpen }, h("summary", {}, "Show the query"),
        h("div", { class: "guide-details-body" }, h("pre", { class: "guide-pre" }, b.sql),
          h("div", { class: "guide-code-only guide-sqledit" },
            h("label", { class: "guide-field" }, h("span", {}, "Edit the query (a single SELECT). Editing clears the approval."),
              h("textarea", { class: "guide-textarea", rows: "7", spellcheck: "false", onInput: (e) => { st.fields.sql = e.target.value; } }, st.fields.sql)),
            button("Use my query", "edit", { values: () => ({ sql: st.fields.sql }) }))));
      fold.addEventListener("toggle", () => { ui.values["open:sql"] = fold.open; });
      return h("div", { class: "guide-proposal" },
        h("div", { class: "guide-proposal-head" }, h("span", { class: "guide-q-num guide-q-num-sm" }, icon("info")),
          h("div", {}, h("div", { class: "guide-proposal-title" }, b.summary), h("div", { class: "guide-muted guide-small" }, `Drafted by ${b.by}.`))),
        b.assumptions.length ? h("div", {}, h("div", { class: "guide-group-title" }, "What it assumes"), h("ul", { class: "guide-list guide-list-muted" }, b.assumptions.map((a) => h("li", {}, a)))) : null,
        b.doubts.length ? h("div", { class: "guide-doubts" }, icon("warn"), h("div", {}, h("strong", {}, "Check before you approve"), h("ul", { class: "guide-list" }, b.doubts.map((a) => h("li", {}, a))))) : null,
        fold,
        h("div", { class: "guide-actions" },
          button(b.ran ? "Run again" : "Approve and run", "run", { primary: true, busyLabel: "Running…" }),
          b.ran ? null : h("span", { class: "guide-muted guide-small" }, "Nothing has run yet.")));
    },
    answer(b) {
      return h("div", { class: "guide-answer" }, h("div", { class: "guide-answer-line" }, icon("check"), h("span", {}, b.v)),
        h("div", { class: "guide-muted guide-small" }, `${fmt(b.rows)} row${b.rows === 1 ? "" : "s"} · ran ${b.ran_as}.`));
    },
    summary_row(b) {
      return h("div", { class: "guide-summaryrow" }, h("div", { class: "guide-summaryrow-v" }, b.v), b.sub ? h("div", { class: "guide-muted guide-small" }, b.sub) : null);
    },
    inline_form(b) {
      const fields = b.fields.map((f) => {
        if (st.fields[f.id] === undefined) st.fields[f.id] = f.value ?? "";
        const sel = h("select", { class: "guide-select", disabled: !!ui.busy,
          onChange: (e) => { st.fields[f.id] = e.target.value; if (b.live) send(b.action.id, collect()); } },
          (f.options || []).map((o) => h("option", { value: o.value, selected: st.fields[f.id] === o.value ? "selected" : null }, o.label)));
        return h("label", { class: "guide-inline-field" }, h("span", {}, f.label), sel);
      });
      return h("div", { class: "guide-inline-form" }, fields,
        b.live ? (ui.busy === b.action.id ? h("span", { class: "guide-spinner" }) : null) : button(b.action.label, b.action.id, { values: collect }));
    },
    list(b) { return h("ul", { class: "guide-list" }, (b.items || []).map((x) => h("li", {}, x))); },
    findings(b) {
      return h("div", { class: "guide-findings" }, b.items.map((x) => h("div", { class: `guide-finding guide-finding-${x.kind}` },
        h("span", { class: "guide-finding-icon" }, icon(x.kind === "warn" ? "warn" : "info")),
        h("div", {}, h("div", { class: "guide-finding-title" }, x.title), h("div", { class: "guide-finding-text" }, x.text)),
        h("div", { class: "guide-finding-count" }, h("strong", {}, fmt(x.count)), h("span", {}, `${x.pct}% of rows`)))));
    },
    plan(b) {
      return h("div", { class: "guide-plan" },
        h("div", { class: "guide-plan-v" }, icon("info"), h("span", {}, b.v)),
        (b.inputs || []).length ? h("div", { class: "guide-plan-row" }, h("span", { class: "guide-plan-label" }, "Uses"),
          h("div", { class: "guide-chips" }, b.inputs.map((c) => h("span", { class: "guide-chip guide-chip-ok" }, icon("check"), c)))) : null,
        b.left_out.length ? h("div", { class: "guide-plan-row" }, h("span", { class: "guide-plan-label" }, "Leaves out"),
          h("div", { class: "guide-plan-out" }, b.left_out.map((x) => h("div", {}, h("strong", {}, x.column), ` · ${x.why}`)))) : null);
    },
    metrics(b) {
      return h("div", { class: "guide-metrics" }, b.items.map((m) => h("div", { class: "guide-metric" },
        h("span", { class: "guide-muted guide-small" }, m.label), h("strong", {}, m.value), h("span", { class: "guide-muted guide-small" }, m.sub || ""))));
    },
    board(b) {
      const headers = b.headers || [`Cross-validated ${b.metric}`, "Held-out ROC AUC", "Held-out PR AUC", "F1", "Time"];
      const cells = (r) => r.cells || [r.cv, r.roc, r.pr, r.f1, r.secs];
      return h("div", { class: "guide-board" },
        h("div", { class: "guide-tablewrap" }, h("table", { class: "guide-table" },
          h("thead", {}, h("tr", {}, ["Model", ...headers].map((c, j) => h("th", { class: j ? "num" : "" }, c)))),
          h("tbody", {}, b.rows.map((r) => h("tr", { class: r.picked ? "is-picked" : "" },
            h("td", {}, r.model, r.family ? h("span", { class: "guide-family" }, r.family) : null,
              r.picked ? h("span", { class: "guide-chip guide-chip-accent guide-picked" }, "Picked") : null),
            cells(r).map((c) => h("td", { class: "num" }, c))))))),
        h("p", { class: "guide-muted guide-small guide-board-why" }, b.why));
    },
    line(b) {
      return h("div", { class: "guide-chartbox" }, b.title ? h("div", { class: "guide-chart-title" }, b.title) : null, lineChart(b.points, b.pct),
        b.note ? h("div", { class: "guide-chart-note" }, b.note) : null);
    },
    ideas(b) {
      return h("div", { class: "guide-ideas" }, b.items.map((x) => h("div", { class: `guide-idea${x.verdict ? " guide-idea-" + x.verdict : ""}${x.kept ? " is-kept" : ""}` },
        h("div", { class: "guide-idea-main" },
          h("div", { class: "guide-idea-title" }, x.title, x.source === "ai" ? h("span", { class: "guide-chip" }, "From AI") : null,
            x.kept ? h("span", { class: "guide-chip guide-chip-accent" }, "Kept") : null),
          h("div", { class: "guide-idea-why" }, x.why),
          x.text ? h("div", { class: "guide-idea-result" }, icon(x.verdict === "helps" ? "check" : x.verdict === "same" ? "info" : "warn"), x.text) : null,
          h("code", { class: "guide-code-only guide-cmd" }, x.sql)),
        h("div", { class: "guide-idea-actions" },
          button(x.verdict ? "Try again" : "Try it", `try:${x.id}`, { busyLabel: "Testing…" }),
          x.verdict === "helps" || x.kept ? button(x.kept ? "Remove" : "Keep", `keep:${x.id}`, { primary: !x.kept }) : null))));
    },
    version(b) {
      if (b.restore && st.fields.restore_to === undefined) st.fields.restore_to = b.restore.value;
      const hist = b.history || [];
      const histOpen = !!ui.values["open:history"];
      const d = hist.length > 1 ? h("details", { class: "guide-history", open: histOpen },
        h("summary", {}, `History · ${hist.length} versions`),
        h("ol", { class: "guide-history-list" }, hist.map((x) => h("li", {},
          h("span", { class: "guide-history-v" }, `Version ${x.version}`), h("span", { class: "guide-history-when" }, x.when),
          h("span", { class: "guide-history-text" }, x.text))))) : null;
      if (d) d.addEventListener("toggle", () => { ui.values["open:history"] = d.open; });
      return h("div", { class: "guide-version" },
        h("div", { class: "guide-version-line" }, icon("info"), h("span", {}, h("strong", {}, b.v), " ", b.about || "")),
        d,
        b.restore ? h("div", { class: "guide-version-restore" },
          h("span", {}, "Restore"),
          h("select", { class: "guide-select", "aria-label": "Version to restore", disabled: !!ui.busy,
            onChange: (e) => { st.fields.restore_to = e.target.value; } },
            b.restore.options.map((o) => h("option", { value: o.value, selected: st.fields.restore_to === o.value ? "selected" : null }, o.label))),
          button("Restore", b.restore.id, { busyLabel: "Restoring…", values: collect }),
          h("span", { class: "guide-muted guide-small" }, "Saves that version's choices as a new version.")) : null);
    },
    rolemap(b) {
      const key = JSON.stringify([b.rows.map((r) => [r.column, r.role]), b.target, b.slots.map((x) => [x.id, x.value])]);
      if (st.mapKey !== key) {
        st.mapKey = key;
        st.roles = Object.fromEntries(b.rows.map((r) => [r.column, r.role]));
        st.slots = Object.fromEntries([["target", b.target || ""], ...b.slots.map((x) => [x.id, x.value || ""])]);
        st.mapInit = JSON.stringify({ r: st.roles, s: st.slots });
      }
      const roleLabel = Object.fromEntries(b.roles.map((r) => [r.value, r.label]));
      const roleMeaning = Object.fromEntries(b.roles.map((r) => [r.value, r.meaning]));
      const rowBy = Object.fromEntries(b.rows.map((r) => [r.column, r]));
      const setRole = (col, val) => {
        st.roles[col] = val;
        if (st.slots.target === col && val !== "flag") st.slots.target = "";
        draw();
      };
      const roleSelect = (r) => h("select", { class: "guide-select", "aria-label": `Meaning of ${r.column}`, disabled: !!ui.busy,
        onChange: (e) => setRole(r.column, e.target.value) },
        b.roles.map((o) => h("option", { value: o.value, selected: st.roles[r.column] === o.value ? "selected" : null }, o.label)));
      const warnFor = (r) => (r.avoid || {})[st.roles[r.column]];

      // 1 · What do you want to predict?
      const flagCols = new Set(Object.keys(st.roles).filter((c) => st.roles[c] === "flag"));
      const targets = b.targets.filter((t) => flagCols.has(t.value) || t.value === st.slots.target);
      const tCard = (t) => {
        const on = st.slots.target === t.value;
        const pick = () => { st.slots.target = t.value; if (t.value) st.roles[t.value] = "flag"; draw(); };
        return h("div", { class: `guide-target guide-target-${t.verdict || "none"}${on ? " is-on" : ""}`, role: "radio", tabindex: "0",
          "aria-checked": on ? "true" : "false", onClick: pick, onKeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(); } } },
          h("span", { class: "guide-radio" }),
          h("div", {}, h("div", { class: "guide-target-name" }, t.label,
              t.verdict === "good" ? h("span", { class: "guide-chip guide-chip-ok-soft" }, "Good choice") : null,
              t.verdict === "no" ? h("span", { class: "guide-chip guide-chip-warn" }, "Can't be predicted") : null,
              t.verdict === "rare" ? h("span", { class: "guide-chip guide-chip-warn" }, "Too rare") : null),
            h("div", { class: "guide-target-text" }, t.text)));
      };
      const none = { value: "", label: "Nothing, just explore", text: "Look at counts and trends without predicting anything.", verdict: "none" };
      const q1 = h("section", { class: "guide-q" },
        h("div", { class: "guide-q-head" }, h("span", { class: "guide-q-num" }, "1"), h("div", {},
          h("div", { class: "guide-q-title" }, "What do you want to predict?"),
          h("div", { class: "guide-q-sub" }, "Pick a yes-or-no column. Everything else helps explain it. The kit never picks this for you."))),
        b.no_target_reason && !targets.length ? h("div", { class: "guide-explain" }, icon("info"), b.no_target_reason) : null,
        h("div", { class: "guide-targets", role: "radiogroup" }, [...targets.map(tCard), tCard(none)]));

      // 2 · Check the kit's guesses
      const guesses = b.rows.filter((r) => r.low);
      const guessRow = (r) => {
        const w = warnFor(r);
        return h("div", { class: "guide-guess" },
          h("div", { class: "guide-guess-main" },
            h("div", { class: "guide-guess-q" }, h("strong", {}, r.column), " looks like ", h("em", {}, roleLabel[r.role] || r.role), ". Is that right?"),
            h("div", { class: "guide-col-ev" }, `The kit saw: ${r.evidence}`),
            h("div", { class: "guide-meaning" }, roleMeaning[st.roles[r.column]] || ""),
            w ? h("div", { class: "guide-inline-warn" }, icon("warn"), w) : null),
          roleSelect(r));
      };
      const q2 = h("section", { class: "guide-q" },
        h("div", { class: "guide-q-head" }, h("span", { class: "guide-q-num" }, "2"), h("div", {},
          h("div", { class: "guide-q-title" }, "Check the kit's guesses"),
          h("div", { class: "guide-q-sub" }, guesses.length ? `The kit wasn't sure about ${guesses.length} column${guesses.length > 1 ? "s" : ""}. Keep its guess or pick another.` : "The kit is confident about every column. Nothing to check."))),
        guesses.length ? h("div", { class: "guide-guesses" }, guesses.map(guessRow)) : null);

      // 3 · The other choices
      const fits = (x, c) => {
        const r = rowBy[c] || {};
        if (x.required && st.roles[c] !== x.required) return false;
        if (!x.required && !x.roles.includes(st.roles[c])) return false;
        if (x.no_sensitive && r.sensitive) return false;
        if (x.plain_names && r.plain === false) return false;
        return true;
      };
      const usedElsewhere = (x, c) => c && Object.entries(st.slots).some(([k, v]) => k !== x.id && v === c);
      const slotRow = (x) => {
        const col = st.slots[x.id];
        const r = rowBy[col] || {};
        let problem = null, fixes = [];
        if (col && x.required && st.roles[col] !== x.required) {
          problem = `Must be a column marked ${x.required_label}, and ${col} is marked ${roleLabel[st.roles[col]]}.`;
          if (x.id === "key") problem += " Only a column that's different in every row can be the unique ID.";
          else fixes.push([`Mark ${col} as ${x.required_label}`, () => { st.roles[col] = x.required; draw(); }]);
        } else if (col && x.no_sensitive && r.sensitive) {
          problem = `${col} holds personal data, so it can't be used here.`;
        } else if (col && x.plain_names && r.plain === false) {
          problem = `${col} has spaces or symbols in its name, so it can't be used here yet.`;
        } else if (col && usedElsewhere(x, col)) {
          problem = `${col} is already used for another choice. A column can fill only one.`;
        } else if (col && !x.required && !x.roles.includes(st.roles[col])) {
          problem = `${col} is marked ${roleLabel[st.roles[col]]}, which doesn't usually fit here.`;
        }
        if (problem) fixes.push(["Leave empty", () => { st.slots[x.id] = ""; draw(); }]);
        const options = Object.keys(st.roles).filter((c) => fits(x, c) || c === col);
        const emptyText = options.filter((c) => c !== col).length || col ? "None"
          : (x.required ? `None (no column is marked ${x.required_label})` : "None");
        return h("label", { class: "guide-slot" },
          h("span", { class: "guide-slot-label" }, x.label), h("span", { class: "guide-slot-hint" }, x.hint),
          h("select", { class: "guide-select", disabled: !!ui.busy, onChange: (e) => { st.slots[x.id] = e.target.value; draw(); } },
            h("option", { value: "" }, emptyText),
            options.map((c) => h("option", { value: c, selected: col === c ? "selected" : null }, c))),
          problem ? h("span", { class: "guide-inline-warn" }, icon("warn"), h("span", {}, problem, " ",
            fixes.map(([label, fn]) => h("button", { type: "button", class: "guide-fixlink", onClick: (e) => { e.preventDefault(); fn(); } }, label)))) : null,
          !col && x.suggest ? h("span", { class: "guide-suggest" }, icon("info"), h("span", {}, `${x.suggest} is different in almost every row. `,
            h("button", { type: "button", class: "guide-fixlink", onClick: (e) => { e.preventDefault(); st.roles[x.suggest] = "key"; st.slots[x.id] = x.suggest; draw(); } }, `Use ${x.suggest}`))) : null);
      };
      const q3 = h("section", { class: "guide-q" },
        h("div", { class: "guide-q-head" }, h("span", { class: "guide-q-num" }, "3"), h("div", {},
          h("div", { class: "guide-q-title" }, "The other choices"),
          h("div", { class: "guide-q-sub" }, "The kit filled these in. Change them only if they look wrong."))),
        h("div", { class: "guide-slotgrid" }, b.slots.map(slotRow)));

      // All columns, folded
      const allRow = (r) => {
        const changed = st.roles[r.column] !== r.role;
        const w = warnFor(r);
        return h("div", { class: `guide-col${r.low ? " is-low" : ""}` },
          h("div", { class: "guide-col-name" }, h("strong", {}, r.column), h("span", { class: "guide-col-ev" }, r.evidence),
            w ? h("span", { class: "guide-inline-warn" }, icon("warn"), w) : null),
          h("div", { class: "guide-col-role" }, roleSelect(r),
            changed ? h("span", { class: "guide-chip guide-chip-accent" }, "Changed") : null,
            r.sensitive ? h("span", { class: "guide-chip", title: "Never charted, grouped or sent to an AI model." }, "Personal data") : null,
            r.leak ? h("span", { class: "guide-chip guide-chip-warn", title: "Filled in after the outcome. The model leaves it out." }, "Gives the answer away") : null));
      };
      const changedCount = b.rows.filter((r) => st.roles[r.column] !== r.role).length;
      const allOpen = !!ui.values["open:allcols"];
      const all = h("details", { class: "guide-details", open: allOpen },
        h("summary", {}, `All ${b.rows.length} columns${changedCount ? ` · ${changedCount} changed` : ""}`),
        h("div", { class: "guide-details-body" },
          h("div", { class: "guide-legend" }, b.roles.map((r) => h("div", {}, h("strong", {}, r.label), " ", h("span", {}, r.meaning)))),
          h("div", { class: "guide-cols" }, b.rows.map(allRow))));
      all.addEventListener("toggle", () => { ui.values["open:allcols"] = all.open; });
      return h("div", { class: "guide-rolemap2" }, q1, q2, q3, all);
    },
    bars(b) {
      return h("div", { class: "guide-chartbox" }, b.title ? h("div", { class: "guide-chart-title" }, b.title) : null,
        barChart(b.items, b.overall, b.pct), b.note ? h("div", { class: "guide-chart-note" }, b.note) : null);
    },
    split(b) {
      const task = st.choice[b.choice || "task"];
      if (!b.supervised.includes(task)) {
        return h("section", { class: "guide-split" }, h("div", { class: "guide-split-title" }, "Train and test split"),
          h("p", { class: "guide-muted guide-small" }, "Not needed here: finding groups and unusual rows looks at every row, and there is no answer to test against."));
      }
      const F = st.fields;
      if (F.train_pct === undefined) F.train_pct = 75;
      if (F.split_method === undefined) F.split_method = b.has_date ? "time" : "random";
      if (F.split_group === undefined) F.split_group = (b.groups || [])[0] || "";
      if (F.folds === undefined) F.folds = "5";
      const pct = Number(F.train_pct);
      const train = Math.round(b.rows * pct / 100), test = b.rows - train;
      const showPos = task === "predict_yes_no" && b.pos != null;
      const testPos = showPos ? Math.round(b.pos * (100 - pct) / 100) : null;
      const exact = F.split_method === "random";
      const methods = [
        ["time", "By time", b.has_date ? `Oldest rows to learn from, newest to test on (by ${b.date}). Closest to real use: the model never sees the future.` : "Needs a column marked Date or time.", !b.has_date],
        ["random", "Random", task === "predict_yes_no" ? "A random share, with the same share of 1s on both sides." : "A random share of rows.", false],
        ["group", "Keep groups apart", (b.groups || []).length ? "Every value of one column lands on one side only, so the test is on groups the model never saw." : "Needs a column marked Category.", !(b.groups || []).length],
      ];
      const warn = test < 100 ? `Only about ${test.toLocaleString()} rows are held out, so the held-out score is shaky. Hold out more.`
        : showPos && testPos < 30 ? `Only about ${testPos} rows with a 1 are held out, so the held-out score is shaky. Hold out more.` : null;
      const n = (x) => x.toLocaleString();
      return h("section", { class: "guide-split" },
        h("div", { class: "guide-split-title" }, "Train and test split"),
        h("div", { class: "guide-split-grid" },
          h("label", { class: "guide-field" }, h("span", {}, `Learn from ${pct}% · test on ${100 - pct}%`),
            h("input", { class: "guide-range", type: "range", min: "50", max: "90", step: "5", value: String(pct), disabled: !!ui.busy,
              "aria-label": "Share of rows to learn from", onInput: (e) => { F.train_pct = Number(e.target.value); draw(); } })),
          h("label", { class: "guide-field" }, h("span", {}, "Practice rounds (cross-validation)"),
            h("select", { class: "guide-select", disabled: !!ui.busy, onChange: (e) => { F.folds = e.target.value; draw(); } },
              ["3", "5", "10"].map((k) => h("option", { value: k, selected: F.folds === k ? "selected" : null }, `${k} rounds${k === "5" ? " (recommended)" : ""}`))))),
        h("p", { class: "guide-muted guide-small" }, `Before the final test, each model practises ${F.folds} times on the learning rows: they are cut into ${F.folds} slices, `
          + `it learns from ${Number(F.folds) - 1} and is scored on the one left out, a different slice each round. The average of those ${F.folds} scores picks the best model, `
          + "so the test rows stay untouched until the end. More rounds: a steadier score, but slower."),
        h("div", { class: "guide-splitbar", "aria-hidden": "true" },
          h("div", { class: "guide-splitbar-train", style: `width:${pct}%` }, `Learn · ${n(train)}`),
          h("div", { class: "guide-splitbar-test", style: `width:${100 - pct}%` }, `Test · ${n(test)}`)),
        showPos ? h("p", { class: "guide-muted guide-small" }, `${exact ? "" : "About "}${n(b.pos - testPos)} rows with a 1 to learn from, ${n(testPos)} to test on.` +
          (exact ? "" : " The exact counts depend on the split and are shown after Run.")) : null,
        h("div", { class: "guide-split-methods", role: "radiogroup" }, methods.map(([v, title, text, off]) => {
          const on = F.split_method === v;
          const pick = () => { if (off || on) return; F.split_method = v; draw(); };
          return h("div", { class: `guide-choice guide-choice-sm${on ? " is-on" : ""}${off ? " is-off" : ""}`, role: "radio", tabindex: off ? "-1" : "0",
            "aria-checked": on ? "true" : "false", onClick: pick, onKeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(); } } },
            h("div", { class: "guide-choice-head" }, h("span", { class: "guide-radio" }), h("strong", {}, title)),
            h("div", { class: "guide-choice-text" }, text),
            on && v === "group" ? h("div", { class: "guide-choice-fields", onClick: (e) => e.stopPropagation() },
              h("select", { class: "guide-select", "aria-label": "Column to keep apart", onChange: (e) => { F.split_group = e.target.value; } },
                b.groups.map((g) => h("option", { value: g, selected: F.split_group === g ? "selected" : null }, g)))) : null);
        })),
        warn ? h("div", { class: "guide-inline-warn" }, icon("warn"), warn) : null);
    },
    clusters(b) {
      const pct = (x) => `${Math.round(x * 100)}%`;
      return h("div", { class: "guide-clusters" }, b.groups.map((g) => h("div", { class: "guide-cluster" },
        h("div", { class: "guide-cluster-head" }, h("strong", {}, g.name), h("span", { class: "guide-muted guide-small" }, `${g.rows.toLocaleString()} rows · ${pct(g.share)}`)),
        h("div", { class: "guide-cluster-bar" }, h("span", { style: `width:${Math.max(2, g.share * 100)}%` })),
        g.rate != null && b.overall != null ? h("div", { class: "guide-cluster-rate" },
          `${b.outcome || "Outcome"} is 1 for ${pct(g.rate)}`, h("span", { class: "guide-muted" }, ` (all rows: ${pct(b.overall)})`)) : null,
        h("ul", { class: "guide-list guide-small" }, (g.traits && g.traits.length ? g.traits : ["Nothing stands out: these are the typical rows."]).map((t) => h("li", {}, t))))));
    },
    table(b) {
      const isNum = b.columns.map((_, j) => b.rows.length > 0 && b.rows.every((r) => r[j] == null || typeof r[j] === "number"));
      return h("div", { class: "guide-tablewrap" }, h("table", { class: b.wrap_first ? "guide-table guide-table-wrapfirst" : "guide-table" },
        h("thead", {}, h("tr", {}, b.columns.map((c, j) => h("th", { class: isNum[j] ? "num" : "", title: c }, readable(c))))),
        h("tbody", {}, b.rows.slice(0, 200).map((r) => h("tr", {}, r.map((v, j) => h("td", { class: isNum[j] ? "num" : "" }, typeof v === "number" ? fmt(v) : (v ?? ""))))))));
    },
  };
  const block = (b) => (B[b.t] ? B[b.t](b) : null);

  // A card's help: links to the kit's own docs, each to the section that explains this step (in a new tab).
  function helpLinks(items) {
    if (!items || !items.length) return null;
    return h("div", { class: "guide-help" }, h("span", { class: "guide-help-label" }, "Learn more:"),
      items.map((l) => h("a", { href: l.href, target: "_blank", rel: "noopener" }, l.label)));
  }

  function field(f) {
    if (st.fields[f.id] === undefined) st.fields[f.id] = f.value ?? "";
    if (!shown(f.show_if)) return null;
    if (f.type === "note") return h("div", { class: "guide-field" }, h("p", { class: "guide-p guide-muted guide-field-note" }, f.v),
      (f.help || []).length ? h("span", { class: "guide-field-help" }, f.help.map((l) => h("a", { href: l.href, target: "_blank", rel: "noopener" }, l.label))) : null);
    const opt = (o) => h("option", { value: o.value, selected: String(st.fields[f.id]) === String(o.value) ? "selected" : null }, o.hint ? `${o.label} · ${o.hint}` : o.label);
    const grouped = () => {
      const out = [], groups = new Map();
      (f.options || []).forEach((o) => {
        if (!o.group) { out.push(opt(o)); return; }
        if (!groups.has(o.group)) { const g = h("optgroup", { label: o.group }); groups.set(o.group, g); out.push(g); }
        groups.get(o.group).appendChild(opt(o));
      });
      return out;
    };
    if (f.type === "range") {
      return h("label", { class: "guide-field" }, h("span", {}, `${f.label}: ${st.fields[f.id]}${f.unit || ""}`),
        h("input", { class: "guide-range", type: "range", min: String(f.min), max: String(f.max), step: String(f.step || 1), value: String(st.fields[f.id]),
          disabled: !!ui.busy, onInput: (e) => { st.fields[f.id] = Number(e.target.value); draw(); } }));
    }
    // options_from: the options follow another field ({field, map: {its value: [options]}}), e.g. a model's effort
    // levels; none for the value shown: the field's empty note instead, and its value is cleared.
    if (f.options_from) {
      const picked = (f.options_from.map || {})[String(st.fields[f.options_from.field] ?? "")] || [];
      f = { ...f, options: picked };
      if (!picked.length) {
        st.fields[f.id] = "";
        return f.empty ? h("p", { class: "guide-p guide-muted guide-field-note" }, f.empty) : null;
      }
      if (!picked.some((o) => String(o.value) === String(st.fields[f.id]))) st.fields[f.id] = picked[0].value;
    }
    // editable: a pencil beside a dropdown switches it to a box to type any value (and back).
    const typing = f.type === "select" && f.editable && st.fields[`${f.id}:typing`];
    const pencil = f.type === "select" && f.editable
      ? h("button", { type: "button", class: "guide-pencil", title: typing ? "Pick from the list" : "Type your own value",
          "aria-label": typing ? "Pick from the list" : "Type your own value", disabled: !!ui.busy,
          onClick: (e) => { e.preventDefault(); st.fields[`${f.id}:typing`] = !typing; draw(); } }, typing ? "▾" : "✎")
      : null;
    const input = f.type === "select" && !typing
      ? h("select", { class: "guide-select", disabled: !!ui.busy, onChange: (e) => {
          st.fields[f.id] = e.target.value;
          // send_on_change: the card answers a pick by itself (the next step's fields follow the choice)
          if (f.send_on_change) send(f.send_on_change, { [f.id]: e.target.value }, { noSecret: true }); else draw();
        } }, grouped())
      : f.type === "number"
      ? h("input", { class: "guide-input guide-input-num", type: "text", inputmode: "decimal", value: st.fields[f.id], placeholder: f.placeholder || "", disabled: !!ui.busy,
          onInput: (e) => { st.fields[f.id] = e.target.value; } })
      : h("input", { class: "guide-input", type: f.type === "password" ? "password" : "text", value: st.fields[f.id],
          placeholder: f.placeholder || "", spellcheck: "false", autocomplete: f.type === "password" ? "new-password" : null,
          disabled: !!ui.busy, onInput: (e) => { st.fields[f.id] = e.target.value; } });
    if (f.type === "password") st.secret.add(f.id);
    // help: links under the field - "How do I get this?" to the kit's own docs, the provider's page - each in a new tab.
    const help = (f.help || []).length
      ? h("span", { class: "guide-field-help" }, f.help.map((l) => h("a", { href: l.href, target: "_blank", rel: "noopener" }, l.label)))
      : null;
    return h("label", { class: "guide-field" }, h("span", {}, f.label),
      pencil ? h("span", { class: "guide-field-edit" }, input, pencil) : input, help);
  }

  // What the kit printed for a row's action: open by itself when the command failed, so the reason is read without a
  // click; closed after one that worked. Each new output starts that way again.
  function kitSaid(r) {
    const key = `out:${r.id}:${r.output_open ? 1 : 0}:${r.output.length}`;
    const d = h("details", { class: "guide-output", open: ui.values[key] ?? !!r.output_open },
      h("summary", {}, "What the kit said"), h("pre", {}, r.output));
    d.addEventListener("toggle", () => { ui.values[key] = d.open; });
    return d;
  }

  function form(r, a) {
    const key = `${r.id}:${a.id}`;
    ui.values[key] = ui.values[key] || {};
    const vals = ui.values[key];
    (a.form || []).forEach((f) => { if (vals[f.id] === undefined) vals[f.id] = f.value ?? ""; });
    // A blank field is never sent: the button would spin on a command given nothing to do.
    const blank = () => (a.form || []).filter((f) => !f.optional && !String(vals[f.id] ?? "").trim());
    const submit = () => {
      const missing = blank();
      ui.formNote = missing.length ? { key, text: `Fill in: ${missing.map((f) => f.label).join(", ")}` } : null;
      if (missing.length) { draw(); return; }
      send(a.id, { ...vals });
    };
    const note = ui.formNote && ui.formNote.key === key ? h("div", { class: "guide-form-note" }, ui.formNote.text) : null;
    return h("div", { class: "guide-form" },
      a.form.map((f) => h("label", { class: "guide-field" }, h("span", {}, f.label),
        h("input", { class: "guide-input", type: f.type === "password" ? "password" : "text", value: vals[f.id], placeholder: f.placeholder || "",
          autocomplete: "off", spellcheck: "false",
          onInput: (e) => { vals[f.id] = e.target.value; }, onKeydown: (e) => { if (e.key === "Enter") submit(); } }))),
      note,
      h("div", { class: "guide-form-actions" }, button(a.submit || "Go", a.id, { primary: true, onClick: submit }),
        h("button", { type: "button", class: "guide-link", onClick: () => { ui.openForm = null; draw(); } }, "Cancel")),
      progressPanel(a.id));
  }

  // Every call this card's controls make, from the blocks the screen sent: a row's or a button's cmd, a code box.
  function controlCode(blocks) {
    const seen = new Map();
    const add = (code, label) => {
      const text = String(code || "").trim();
      if (text && !seen.has(text)) seen.set(text, label ? `# ${label}\n${text}` : text);
    };
    const visit = (o, label) => {
      if (!o || typeof o !== "object") return;
      if (Array.isArray(o)) { o.forEach((x) => visit(x, label)); return; }
      const here = o.label || o.name || o.title || label;
      if (typeof o.cmd === "string") add(o.cmd, here);
      if (o.t === "code" && typeof o.v === "string") add(o.v, o.title);
      Object.entries(o).forEach(([k, v]) => { if (k !== "cmd" && v && typeof v === "object") visit(v, here); });
    };
    blocks.filter((b) => b.t !== "ran" && b.t !== "cells").forEach((b) => visit(b));
    return [...seen.values()];
  }

  // A cell of the Code view: the code in a box you can edit, Run under it, and what it printed or returned below,
  // as a notebook cell. It runs in the notebook's own namespace (nb, connection, dataset ... as the cards left
  // them). Shift+Enter (or Ctrl/Cmd+Enter) runs it; an edit is kept until the code it started from changes.
  function cell(key, title, original, outputs) {
    const kept = st.cells[key];
    const edited = kept && kept.base === original ? kept.text : original;
    const out = outputs[key];
    const running = ui.busy === "run_code" && ui.cell === key;
    const run = () => { if (ui.busy) return; ui.cell = key; send("run_code", { cell: key, code: (st.cells[key] && st.cells[key].base === original ? st.cells[key].text : original) }); };
    const size = (el) => { el.style.height = "auto"; el.style.height = `${Math.min(el.scrollHeight + 2, 420)}px`; };
    const box = h("textarea", { class: "guide-cell-input", spellcheck: "false", autocapitalize: "off", autocomplete: "off",
      rows: String(Math.min(18, Math.max(2, edited.split("\n").length))), "aria-label": `${title}: code`,
      onInput: (e) => { st.cells[key] = { base: original, text: e.target.value }; size(e.target); },
      onKeydown: (e) => {
        if (e.key === "Enter" && (e.shiftKey || e.ctrlKey || e.metaKey)) { e.preventDefault(); run(); }
        if (e.key === "Tab" && !e.shiftKey) {                       // a tab indents, as in a cell
          e.preventDefault();
          const t = e.target, at = t.selectionStart;
          t.value = `${t.value.slice(0, at)}    ${t.value.slice(t.selectionEnd)}`;
          t.selectionStart = t.selectionEnd = at + 4;
          st.cells[key] = { base: original, text: t.value };
        }
      } }, edited);
    setTimeout(() => size(box), 0);
    return h("div", { class: "guide-cell" },
      h("div", { class: "guide-codebox-title" }, title,
        h("span", { class: "guide-cell-tools" },
          edited !== original ? h("button", { type: "button", class: "guide-link", onClick: () => { delete st.cells[key]; draw(); } }, "Reset") : null,
          h("button", { type: "button", class: "guide-btn guide-btn-quiet guide-copy", onClick: (e) => copyCode(box.value, e.currentTarget) }, "Copy as cell"))),
      box,
      h("div", { class: "guide-cell-run" },
        h("button", { type: "button", class: "guide-btn guide-btn-primary", disabled: !!ui.busy, onClick: run, title: "Run this code (Shift+Enter)" },
          running ? h("span", { class: "guide-spinner" }) : null, running ? "Running…" : "Run"),
        h("span", { class: "guide-cell-hint" }, "Shift+Enter runs it. It runs in this notebook, like a cell.")),
      out ? h("pre", { class: `guide-cell-out${out.ok ? "" : " guide-cell-err"}`, role: "status" }, out.text || (out.ok ? "Done: nothing to show." : "")) : null);
  }

  function codeView(blocks) {
    const keep = blocks.filter((b) => ["home_head", "head", "tabs", "msg"].includes(b.t)
      || (b.t === "details" && b.title === "What the kit said"));
    const ran = blocks.find((b) => b.t === "ran");
    const outputs = (blocks.find((b) => b.t === "cells") || {}).v || {};
    const calls = controlCode(blocks);
    return [
      ...keep.map(block),
      ran ? cell("ran", "What this card ran (this session, in order)", ran.v, outputs) : h("p", { class: "guide-p guide-muted" },
        "Nothing has run from this card yet. Each control below is one call: edit it and run it here, or copy it into a cell."),
      calls.length ? h("div", { class: "guide-codebox-title guide-cells-title" }, "What each control on this card runs") : null,
      ...calls.map((code, i) => cell(`call:${code}`, code.startsWith("# ") ? code.split("\n")[0].slice(2) : `Control ${i + 1}`, code, outputs)),
      h("div", { class: "guide-allcode" },
        h("button", { type: "button", class: "guide-link", onClick: () => setAllCode(!allCode()) },
          allCode() ? "Hide the notebook's code cells" : "Show all the notebook's code cells, below the cards")),
    ].filter(Boolean);
  }

  function draw() {
    const blocks = model.get("blocks") || [];
    const code = ui.mode === "code";
    root.classList.toggle("guide-codeview", code);
    root.replaceChildren(...(code ? codeView(blocks) : blocks.map(block).filter(Boolean)));
  }

  const applyTheme = () => root.classList.toggle("guide-dark", !!detectDark(root));
  applyTheme();
  const obs = new MutationObserver(applyTheme);
  obs.observe(document.body, { attributes: true, attributeFilter: ["data-jp-theme-light"] });
  const onMode = () => draw();
  document.addEventListener("guide-mode", onMode);

  const onBlocks = () => draw();
  const onMsg = (msg) => {
    if (msg && msg.type === "progress" && msg.id === ui.busy) {
      ui.progress = { label: msg.label, pct: msg.pct, lines: msg.lines || [] };
      draw();
      return;
    }
    if (msg && msg.type === "done") {
      ui.busy = null;
      ui.progress = null;
      if (msg.id && ui.openForm && ui.openForm.endsWith(`:${msg.id}`)) {
        const failed = (model.get("blocks") || []).some((b) => b.t === "msg" && b.kind === "error");
        if (!failed) { delete ui.values[ui.openForm]; ui.openForm = null; }
      }
      draw();
    }
  };
  model.on("change:blocks", onBlocks);
  model.on("msg:custom", onMsg);
  draw();
  return () => {
    obs.disconnect();
    document.removeEventListener("guide-mode", onMode);
    model.off("change:blocks", onBlocks);
    model.off("msg:custom", onMsg);
  };
}

export default { render };
