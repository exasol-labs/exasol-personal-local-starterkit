// The kit's dropdown as a widget of its own, for the code paths of the notebooks (JupyterLab's ipywidgets, Marimo's
// mo.ui.anywidget): the same look as the guided cards' dropdowns. The list opens in place under the button, inside
// the cell, never over the page. Plain ES module, no network.

function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const CHEVRON = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';

// Dark when JupyterLab says so; elsewhere (Marimo, any page) when the background behind the widget is dark - the
// first ancestor with a colour of its own - and, with none, when the system is.
function isDark(host) {
  const jp = document.body.getAttribute("data-jp-theme-light");
  if (jp === "true" || jp === "false") return jp === "false";
  for (let node = host.parentElement; node; node = node.parentElement) {
    const m = getComputedStyle(node).backgroundColor.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/);
    if (m && (m[4] === undefined || Number(m[4]) > 0.5)) return 0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3] < 128;
  }
  return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
}

function render({ model, el }) {
  const root = h("div", { class: "xpl-root" });
  el.appendChild(root);
  let open = false;
  const key = (v) => JSON.stringify(v ?? null);

  const draw = () => {
    root.classList.toggle("xpl-dark", !!isDark(root));
    const options = model.get("options") || [];
    const value = model.get("value");
    const now = options.find((o) => key(o.value) === key(value));
    const label = model.get("description") || "";
    const note = model.get("note") || "";
    const btn = h("button", { type: "button", class: `xpl-btn${open ? " is-open" : ""}${now ? "" : " is-empty"}`,
      "aria-haspopup": "listbox", "aria-expanded": open ? "true" : "false", "aria-label": label || null,
      onClick: (e) => { e.preventDefault(); open = !open; draw(); },
      onKeydown: (e) => { if (e.key === "Escape" && open) { open = false; draw(); } } },
      h("span", { class: "xpl-now" }, now ? now.label : (model.get("placeholder") || "Choose…")),
      now && now.hint ? h("span", { class: "xpl-nowhint" }, now.hint) : null,
      h("span", { class: "xpl-chev", html: CHEVRON }));
    const parts = [label ? h("div", { class: "xpl-label" }, label) : null, btn];
    if (open) {
      const rows = options.map((o) => h("button", { type: "button", role: "option", "aria-selected": now === o ? "true" : "false",
        class: `xpl-opt${now === o ? " is-on" : ""}`, "data-find": `${o.label} ${o.hint || ""}`.toLowerCase(),
        onClick: (e) => { e.preventDefault(); open = false; model.set("value", o.value); model.save_changes(); draw(); } },
        h("span", { class: "xpl-optlabel" }, o.label), o.hint ? h("span", { class: "xpl-hint" }, o.hint) : null));
      const find = options.length > 8 ? h("input", { class: "xpl-find", type: "text", placeholder: "Type to narrow the list", spellcheck: "false",
        "aria-label": "Narrow the list", onInput: (e) => {
          const q = e.target.value.trim().toLowerCase();
          rows.forEach((r) => { r.hidden = !!q && !r.dataset.find.includes(q); });
        }, onKeydown: (e) => { if (e.key === "Escape") { open = false; draw(); } } }) : null;
      parts.push(h("div", { class: "xpl-panel" }, find, h("div", { class: "xpl-list", role: "listbox" }, rows)));
    }
    if (note) parts.push(h("div", { class: "xpl-note" }, note));
    root.replaceChildren(...parts.filter(Boolean));
  };

  const outside = (e) => { if (open && !root.contains(e.target)) { open = false; draw(); } };
  document.addEventListener("mousedown", outside);
  const obs = new MutationObserver(draw);
  obs.observe(document.body, { attributes: true, attributeFilter: ["data-jp-theme-light", "class"] });
  obs.observe(document.documentElement, { attributes: true, attributeFilter: ["class", "data-theme"] });
  ["change:value", "change:options", "change:description", "change:note"].forEach((ev) => model.on(ev, draw));
  draw();
  return () => { document.removeEventListener("mousedown", outside); obs.disconnect(); };
}

export default { render };
