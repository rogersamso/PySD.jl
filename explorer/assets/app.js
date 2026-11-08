// PySD Explorer: the page.  Talks to the Julia server (api/…), or, in a page
// exported as one HTML file, reads the data written into it (PYSD_STATIC).
"use strict";

const STATIC = window.PYSD_STATIC || null;

// categorical slots (validated reference palette), light and dark steps
const SERIES = {
  light: ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"],
  dark: ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"],
};
const DIVERGING = { light: ["#2a78d6", "#e34948"], dark: ["#3987e5", "#e66767"] };
const DASHES = ["solid", "dash", "dot", "dashdot", "longdash", "longdashdot"];
const MAX_RUNS = SERIES.light.length;

const S = {
  model: null, byName: new Map(), runs: [], shown: [], slot: new Map(),
  panels: [], cache: new Map(), edits: new Map(), inputs: {}, views: [], sens: null,
  code: [], codeText: new Map(), codeFile: null,
  me: { user: "", admin: false, code: false, local: true, limits: {} }, analyses: [], jobs: [],
  anParams: new Set(), anOutputs: new Set(), adminTimer: null, jobsTimer: null,
};

// ---------------------------------------------------------------- data access
async function api(method, path, body) {
  if (STATIC) return staticApi(method, path);
  const headers = { "X-PySD-Request": "1" };          // (the server refuses changes without it)
  if (body) headers["Content-Type"] = "application/json";
  const r = await fetch("api/" + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (r.status === 401 && j.login) { showLogin(); throw new Error("Log in first."); }
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
function staticApi(method, path) {
  if (method !== "GET") throw new Error("This page is a copy: it can't run the model.");
  const [p, q] = path.split("?");
  if (p === "model") return STATIC.model;
  if (p === "runs") return STATIC.runs;
  if (p === "me") return { ...(STATIC.me || {}), admin: false };
  if (p === "jobs") return [];
  if (p === "analyses") return (STATIC.analyses || []).map(({ rows, ...a }) => a);
  if (p.startsWith("analyses/")) return (STATIC.analyses || []).find((a) => a.id === decodeURIComponent(p.slice(9)));
  if (p === "views") return STATIC.view ? [STATIC.view] : [];
  if (p === "code") return STATIC.code || [];
  if (p === "inputs") return STATIC.model.inputs;
  if (p.startsWith("code/")) return { text: (STATIC.texts || {})[decodeURIComponent(p.slice(5))] || "" };
  if (p === "series") {
    const name = new URLSearchParams(q).get("name");
    return STATIC.series[name] || { name, time: [], elements: [], runs: {} };
  }
  throw new Error("not in this copy: " + p);
}

// ---------------------------------------------------------------- helpers
const $ = (s, el = document) => el.querySelector(s);
const el = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined && v !== false) e.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k !== null && k !== undefined) e.append(k);
  return e;
};
const show = (name) => name.replace(/_/g, " ");
const titleOf = (v) => show(v.title || v.name);
const fmt = (x) => x === null || x === undefined ? "—" :
  Math.abs(x) >= 1e5 || (Math.abs(x) < 1e-3 && x !== 0) ? x.toExponential(3) : String(+x.toPrecision(5));
function toast(msg, ms = 3500) {
  const t = $("#toast");
  t.textContent = msg; t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), ms);
}
const status = (msg) => ($("#status").textContent = msg || "");
const theme = () => {
  const t = document.documentElement.dataset.theme;
  if (t) return t;
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
};
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const runById = (id) => S.runs.find((r) => r.id === id);
function download(name, blob) {
  const a = el("a", { href: URL.createObjectURL(blob), download: name });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}
const fileName = (s) => s.replace(/[^\w\-]+/g, "_").replace(/^_|_$/g, "").slice(0, 80) || "export";

// ---------------------------------------------------------------- start
async function start() {
  if (STATIC) document.body.classList.add("static");
  try { S.me = await api("GET", "me"); } catch (e) { if (!$("#login").hidden) return; throw e; }
  S.model = await api("GET", "model");
  for (const v of S.model.names) S.byName.set(v.name, v);
  document.title = (S.model.title || "Model") + " · PySD Explorer";
  $("#title").textContent = S.model.title || "PySD Explorer";
  S.runs = await api("GET", "runs");
  S.views = await api("GET", "views");
  S.analyses = await api("GET", "analyses");
  $("#who").textContent = S.me.local || STATIC || S.me.auth === "password" ? "" : S.me.user + (S.me.admin ? " (admin)" : "");
  if (S.me.auth === "password" && !STATIC) {
    $("#account").hidden = false;
    $("#account").textContent = S.me.user + (S.me.admin ? " (admin)" : "") + " ▾";
  }
  $("#tab-admin").hidden = !S.me.admin || !!STATIC;
  $("#tab-sens").hidden = !!STATIC && !S.analyses.length;
  if (S.analyses.length) S.sens = await api("GET", "analyses/" + encodeURIComponent(S.analyses[0].id));
  if (S.me.code) {
    $("#tab-code").hidden = false;
    S.code = await api("GET", "code");
  }
  restorePrefs();
  if (!S.shown.length && S.runs.length) toggleRun(S.runs[0].id, true);
  wire();
  renderTree(); renderRunChips(); renderBaseline(); renderViews(); renderRunsTable();
  renderInputs(); renderParams(); renderChanged(); renderSensPick(); renderSens(); renderCodeList();
  renderAnalysisForm(); refreshJobs();
  if (STATIC && STATIC.view) await applyView(STATIC.view);
  else await renderPanels();
  status(`${S.model.names.length} names · ${S.runs.length} runs${STATIC ? " · read-only copy" : ""}`);
}

function wire() {
  document.querySelectorAll(".tabs button").forEach((b) => b.addEventListener("click", () => tab(b.dataset.tab)));
  $("#search").addEventListener("input", debounce(renderTree, 150));
  document.querySelectorAll(".kinds input").forEach((c) => c.addEventListener("change", renderTree));
  $("#mode").addEventListener("change", () => { renderBaseline(); renderPanels(); });
  $("#baseline").addEventListener("change", renderPanels);
  $("#columns").addEventListener("change", () => { setColumns(); renderPanels(); savePrefs(); });
  $("#clear").addEventListener("click", () => { S.panels = []; renderPanels(); renderTree(); });
  $("#views").addEventListener("change", (e) => {
    const v = S.views.find((v) => v.name === e.target.value);
    if (v) applyView(v);
  });
  $("#view-save").addEventListener("click", saveView);
  $("#view-delete").addEventListener("click", deleteView);
  $("#export-png").addEventListener("click", () => exportView("png"));
  $("#export-svg").addEventListener("click", () => exportView("svg"));
  $("#export-csv").addEventListener("click", exportCSV);
  $("#export-html").addEventListener("click", exportHTML);
  $("#param-search").addEventListener("input", debounce(renderParams, 150));
  $("#reset-all").addEventListener("click", () => { S.edits.clear(); S.inputs = {}; renderInputs(); renderParams(); renderChanged(); });
  $("#run").addEventListener("click", newRun);
  $("#sens-output").addEventListener("change", renderSens);
  $("#sens-pick").addEventListener("change", pickAnalysis);
  $("#sens-share").addEventListener("click", () => changeAnalysis({ shared: !S.sens.shared }));
  $("#sens-rename").addEventListener("click", () => { const l = prompt("New name:", S.sens.label); if (l) changeAnalysis({ label: l }); });
  $("#sens-delete").addEventListener("click", deleteAnalysis);
  $("#an-par-search").addEventListener("input", debounce(renderAnalysisParams, 150));
  $("#an-out-search").addEventListener("input", debounce(renderAnalysisOutputs, 150));
  $("#an-par-all").addEventListener("click", () => { for (const v of foundParams()) S.anParams.add(v.name); renderAnalysisParams(); });
  $("#an-par-none").addEventListener("click", () => { S.anParams.clear(); renderAnalysisParams(); });
  $("#an-start").addEventListener("click", startAnalysis);
  $("#admin-save").addEventListener("click", saveSettings);
  $("#account").addEventListener("click", (e) => { e.stopPropagation(); $("#account-menu").hidden = !$("#account-menu").hidden; });
  document.addEventListener("click", () => ($("#account-menu").hidden = true));
  $("#menu-logout").addEventListener("click", async () => { try { await api("POST", "logout"); } catch (e) {} location.reload(); });
  $("#menu-password").addEventListener("click", () => { $("#pw-error").hidden = true; $("#password-form").reset(); $("#dlg-password").showModal(); });
  $("#password-form").addEventListener("submit", changePassword);
  $("#new-user").addEventListener("submit", addUser);
  $("#secret-copy").addEventListener("click", () => navigator.clipboard.writeText($("#secret-value").textContent).then(() => toast("Copied.")));
  $("#secret-close").addEventListener("click", () => { $("#secret-value").textContent = ""; $("#dlg-secret").close(); });
  $("#sens-top").addEventListener("change", renderSens);
  $("#sens-years").addEventListener("change", renderSens);
  $("#sens-png").addEventListener("click", () => Plotly.downloadImage("sens-chart", { format: "png", scale: 2, filename: "sensitivity" }));
  $("#sens-svg").addEventListener("click", () => Plotly.downloadImage("sens-chart", { format: "svg", filename: "sensitivity" }));
  $("#code-search").addEventListener("input", debounce(renderCodeList, 150));
  $("#code-text").addEventListener("click", (e) => {
    const a = e.target.closest("a.ref");
    if (!a) return;
    const name = a.dataset.name;
    if (!S.panels.some((p) => p.name === name)) { togglePanel(name); toast(`Plotted "${titleOf(S.byName.get(name))}" in Explore.`); }
    else toast(`"${titleOf(S.byName.get(name))}" is already plotted in Explore.`);
  });
  $("#theme").addEventListener("click", () => {
    document.documentElement.dataset.theme = theme() === "dark" ? "light" : "dark";
    savePrefs(); renderPanels(); renderSens();
  });
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { renderPanels(); renderSens(); });
  window.addEventListener("resize", debounce(() => document.querySelectorAll(".plot").forEach((p) => Plotly.Plots.resize(p)), 200));
  if (STATIC) {
    for (const id of ["#run", "#reset-all", "#view-save", "#view-delete", "#export-html"]) $(id).disabled = true;
  }
}

function debounce(f, ms) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => f(...a), ms); };
}
function tab(name) {
  document.querySelectorAll(".tabs button").forEach((b) => b.classList.toggle("active", b.dataset.tab === name));
  document.querySelectorAll("section.tab").forEach((s) => s.classList.toggle("active", s.id === name));
  if (name === "sensitivity") { renderSens(); renderAnalysisForm(); }
  clearInterval(S.adminTimer);
  if (name === "admin") { renderAdmin(); renderLogins(); S.adminTimer = setInterval(renderAdmin, 3000); }
  if (name === "runs" && !STATIC) api("GET", "inputs").then((i) => { S.model.inputs = i; renderInputs(); }).catch(() => {});
  if (name === "explore") document.querySelectorAll(".plot").forEach((p) => Plotly.Plots.resize(p));
}

// per-viewer conveniences only (may be unavailable)
function savePrefs() {
  try {
    localStorage.setItem("pysd-explorer", JSON.stringify({
      theme: document.documentElement.dataset.theme || "", columns: $("#columns").value,
    }));
  } catch (e) { /* no storage: fine */ }
}
function restorePrefs() {
  try {
    const p = JSON.parse(localStorage.getItem("pysd-explorer") || "{}");
    if (p.theme) document.documentElement.dataset.theme = p.theme;
    if (p.columns) $("#columns").value = p.columns;
  } catch (e) { /* no storage: fine */ }
  setColumns();
}
function setColumns() { $("#panels").className = "panels cols-" + $("#columns").value; }

// ---------------------------------------------------------------- tree of sets
function renderTree() {
  const q = $("#search").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const kinds = new Set([...document.querySelectorAll(".kinds input:checked")].map((c) => c.dataset.kind));
  const sep = S.model.separator;
  const root = { kids: new Map(), leaves: [], n: 0 };
  const onPanel = new Set(S.panels.map((p) => p.name));
  for (const v of S.model.names) {
    if (!kinds.has(v.kind)) continue;
    if (q.length) {
      const hay = (v.title + " " + v.name + " " + v.description).toLowerCase().replace(/_/g, " ");
      if (!q.every((w) => hay.includes(w.replace(/_/g, " ")))) continue;
    }
    const parts = (v.set || "(no set)").split(sep || "\u0000").map((s) => s.trim()).filter(Boolean);
    let node = root;
    node.n++;
    for (const p of parts) {
      if (!node.kids.has(p)) node.kids.set(p, { kids: new Map(), leaves: [], n: 0 });
      node = node.kids.get(p);
      node.n++;
    }
    node.leaves.push(v);
  }
  const open = q.length > 0;
  const draw = (node) => {
    const out = [];
    for (const [name, kid] of [...node.kids].sort((a, b) => a[0].localeCompare(b[0]))) {
      out.push(el("details", { open: open || (node === root && node.kids.size === 1) },
        el("summary", {}, name + " ", el("small", {}, String(kid.n))), ...draw(kid)));
    }
    for (const v of node.leaves.sort((a, b) => titleOf(a).localeCompare(titleOf(b)))) {
      out.push(el("div", {
        class: "leaf" + (onPanel.has(v.name) ? " on" : ""),
        title: `${titleOf(v)}${v.unit ? " [" + v.unit + "]" : ""}\n${v.name}\n\n${v.description || "No description."}`,
        onclick: () => togglePanel(v.name),
      }, el("span", { class: "badge " + v.kind }), el("span", { class: "t" }, titleOf(v)),
        el("span", { class: "u" }, v.unit)));
    }
    return out;
  };
  const tree = $("#tree");
  tree.replaceChildren(...draw(root));
  if (!root.n) tree.append(el("p", { class: "note" }, "Nothing matches."));
}

// ---------------------------------------------------------------- runs shown
function toggleRun(id, on) {
  const i = S.shown.indexOf(id);
  if (on === undefined) on = i < 0;
  if (on && i < 0) {
    if (S.shown.length >= MAX_RUNS) { toast(`At most ${MAX_RUNS} runs at once: hide one first.`); return; }
    const used = new Set(S.shown.map((r) => S.slot.get(r)));
    let s = 0;
    while (used.has(s)) s++;
    S.slot.set(id, s);
    S.shown.push(id);
  } else if (!on && i >= 0) {
    S.shown.splice(i, 1);
    S.slot.delete(id);
  }
}
const runColor = (id, th = theme()) => SERIES[th][S.slot.get(id) ?? 0];

function renderRunChips() {
  const box = $("#run-chips");
  box.replaceChildren(...S.runs.map((r) => {
    const on = S.shown.includes(r.id);
    return el("span", {
      class: "chip" + (on ? "" : " off"), title: changesText(r) || "No changes",
      onclick: () => { toggleRun(r.id); renderRunChips(); renderBaseline(); renderRunsTable(); renderPanels(); },
    }, el("span", { class: "dot", style: on ? `background:${runColor(r.id)}` : "" }), runLabel(r));
  }));
}
function renderBaseline() {
  const sel = $("#baseline");
  const keep = sel.value;
  sel.replaceChildren(...S.runs.map((r) => el("option", { value: r.id }, r.label)));
  sel.value = runById(keep) ? keep : (S.shown[0] || (S.runs[0] && S.runs[0].id) || "");
  sel.style.display = $("#mode").value === "values" ? "none" : "";
}
// a run's name, with its author's when it's someone else's
const runLabel = (r) => r.owner && r.owner !== S.me.user ? `${r.label} · ${r.owner}` : r.label;
const mayChange = (x) => S.me.admin || (x.owner && x.owner === S.me.user);

function changesText(r, max = 99) {
  const out = [];
  for (const [k, v] of Object.entries(r.params || {})) {
    const m = S.byName.get(k);
    out.push(`${m ? titleOf(m) : k} = ${Array.isArray(v) ? "[" + v.map(fmt).join(", ") + "]" : fmt(v)}`);
  }
  for (const [k, v] of Object.entries(r.inputs || {})) {
    const c = (S.model.inputs[k] || []).find((c) => c.id === v);
    out.push(`${show(k)}: ${c ? c.label : v}`);
  }
  return out.length > max ? out.slice(0, max).join("; ") + `; … ${out.length - max} more` : out.join("; ");
}

// ---------------------------------------------------------------- panels
function togglePanel(name) {
  const i = S.panels.findIndex((p) => p.name === name);
  if (i >= 0) S.panels.splice(i, 1);
  else S.panels.push({ name, elements: null, sum: false });
  renderTree();
  renderPanels();
}

async function series(name) {
  const need = S.shown.concat($("#mode").value !== "values" ? [$("#baseline").value] : []).filter(Boolean);
  let c = S.cache.get(name);
  const missing = need.filter((id) => !c || !(id in c.runs));
  if (missing.length) {
    const s = await api("GET", `series?name=${encodeURIComponent(name)}&runs=${missing.map(encodeURIComponent).join(",")}`);
    if (!c) c = { name, time: s.time, elements: s.elements, runs: {} };
    Object.assign(c.runs, s.runs);
    if (!c.time.length) { c.time = s.time; c.elements = s.elements; }
    S.cache.set(name, c);
  }
  return c || { name, time: [], elements: [""], runs: {} };
}

let renderToken = 0;
async function renderPanels() {
  const token = ++renderToken;
  const box = $("#panels");
  $("#empty").style.display = S.panels.length ? "none" : "";
  const keep = new Map([...box.children].map((n) => [n.dataset.name, n]));
  const nodes = [];
  for (const p of S.panels) nodes.push(keep.get(p.name) || panelNode(p));
  box.replaceChildren(...nodes);
  for (const p of S.panels) {
    let s;
    try { s = await series(p.name); } catch (e) { toast(e.message); continue; }
    if (token !== renderToken) return;
    const node = box.querySelector(`[data-name="${CSS.escape(p.name)}"]`);
    if (!node) continue;
    if (p.elements === null) p.elements = s.elements.slice(0, Math.min(s.elements.length, 4));
    renderElements(node, p, s);
    const fig = figure(p, s, theme());
    Plotly.react($(".plot", node), fig.data, fig.layout, { displaylogo: false, responsive: true,
      modeBarButtonsToRemove: ["select2d", "lasso2d", "autoScale2d"], toImageButtonOptions: { scale: 2, filename: fileName(titleOf(S.byName.get(p.name))) } });
  }
}

function panelNode(p) {
  const v = S.byName.get(p.name);
  const desc = el("div", { class: "desc", title: "Click to read it all", onclick: (e) => e.target.classList.toggle("open") },
    v.description || "No description.");
  return el("div", { class: "panel", "data-name": p.name },
    el("div", { class: "panel-head" },
      el("div", { class: "titles" },
        el("h3", {}, titleOf(v)),
        el("div", { class: "meta" }, [v.unit || "no unit", v.kind, v.set].filter(Boolean).join(" · ")),
        desc),
      el("div", { class: "tools" },
        v.code && v.code.length ? el("button", { title: "Its declaration and equations in the model's code", onclick: () => codeOf(v) }, "Code") : null,
        el("button", { title: "PNG", onclick: () => exportPanel(p, "png") }, "PNG"),
        el("button", { title: "SVG", onclick: () => exportPanel(p, "svg") }, "SVG"),
        el("button", { title: "Remove", class: "ghost", onclick: () => togglePanel(p.name) }, "✕"))),
    el("div", { class: "elements" }),
    el("div", { class: "plot" }));
}

function renderElements(node, p, s) {
  const box = $(".elements", node);
  if (s.elements.length <= 1 && s.elements[0] === "") { box.replaceChildren(); return; }
  const boxes = s.elements.map((e) => el("label", {},
    el("input", { type: "checkbox", checked: p.elements.includes(e), onchange: (ev) => {
      p.elements = ev.target.checked ? p.elements.concat([e]) : p.elements.filter((x) => x !== e);
      renderPanels();
    } }), e));
  const sum = el("label", { title: "The sum of all its elements" },
    el("input", { type: "checkbox", checked: p.sum, onchange: (ev) => { p.sum = ev.target.checked; renderPanels(); } }),
    el("b", {}, "Σ all"));
  box.replaceChildren(sum, ...boxes);
}

// the traces of a panel: runs × elements, in values or against the baseline
function traces(p, s) {
  const mode = $("#mode").value, base = $("#baseline").value;
  const scalar = s.elements.length === 1 && s.elements[0] === "";
  const picked = scalar ? [""] : p.elements.slice();
  if (p.sum && !scalar) picked.push("Σ");
  const pick = (runId, e) => {
    const r = s.runs[runId];
    if (!r) return null;
    if (e === "Σ") return s.time.map((_, i) => r.reduce((a, col) => (col[i] === null || a === null ? null : a + col[i]), 0));
    return r[s.elements.indexOf(e)] || null;
  };
  const out = [];
  for (const id of S.shown) {
    const run = runById(id);
    if (!run || (mode !== "values" && id === base)) continue;     // the baseline against itself: zero
    for (const e of picked) {
      let y = pick(id, e);
      if (!y) continue;
      if (mode !== "values") {
        const b = pick(base, e);
        if (!b) continue;
        y = y.map((x, i) => x === null || b[i] === null ? null :
          mode === "diff" ? x - b[i] : (b[i] === 0 ? null : 100 * (x - b[i]) / Math.abs(b[i])));
      }
      out.push({ run, element: e, y });
    }
  }
  return out;
}

function figure(p, s, th, opts = {}) {
  const v = S.byName.get(p.name);
  const mode = $("#mode").value;
  const ts = traces(p, s);
  const oneRun = new Set(ts.map((t) => t.run.id)).size <= 1;
  const elementsShown = [...new Set(ts.map((t) => t.element))];
  const ink = th === "dark" ? { text: "#f0efec", muted: "#c3c2b7", grid: "#2c2c2a", bg: "#1a1a19" } :
    { text: "#0b0b0b", muted: "#52514e", grid: "#e6e5e1", bg: "#fcfcfb" };
  const data = ts.map((t) => {
    const k = elementsShown.indexOf(t.element);
    const color = oneRun && elementsShown.length > 1 ? SERIES[th][k % SERIES[th].length] : runColor(t.run.id, th);
    const dash = oneRun ? "solid" : DASHES[k % DASHES.length];
    const name = [oneRun && S.shown.length <= 1 ? "" : t.run.label, t.element].filter(Boolean).join(" · ") || t.run.label;
    return { x: s.time, y: t.y, type: "scatter", mode: "lines", name, line: { color, width: 2, dash },
      hovertemplate: `%{y:.4~g} ${mode === "pct" ? "%" : v.unit}<extra>${name}</extra>` };
  });
  const yTitle = mode === "pct" ? "% difference" : (mode === "diff" ? "difference" + (v.unit ? ` (${v.unit})` : "") : v.unit);
  const baseLabel = mode === "values" ? "" : ` – vs ${(runById($("#baseline").value) || {}).label || ""}`;
  return {
    data,
    layout: {
      title: opts.title ? { text: titleOf(v) + baseLabel, font: { size: 15, color: ink.text }, x: 0.02, xanchor: "left" } : undefined,
      paper_bgcolor: ink.bg, plot_bgcolor: ink.bg, font: { color: ink.muted, size: 12 },
      margin: { l: 64, r: 16, t: (opts.title ? 40 : 10) + (data.length > 1 ? 22 * Math.ceil(data.length / 3) : 0), b: 46 },
      xaxis: { title: { text: `Time (${S.model.time_unit})` }, gridcolor: ink.grid, zeroline: false, linecolor: ink.grid },
      yaxis: { title: { text: yTitle }, gridcolor: ink.grid, zerolinecolor: ink.muted, linecolor: ink.grid, rangemode: mode === "values" ? "normal" : "tozero" },
      showlegend: data.length > 1, legend: { orientation: "h", x: 0, xanchor: "left", y: 1.02, yanchor: "bottom", font: { color: ink.text } },
      hovermode: "x unified", hoverlabel: { bgcolor: ink.bg, font: { color: ink.text } },
      width: opts.width, height: opts.height,
    },
  };
}

// ---------------------------------------------------------------- export
async function panelImage(p, format, width, height, title = true) {
  const s = await series(p.name);
  const fig = figure(p, s, "light", { title, width, height });
  const div = el("div", { style: `position:fixed;left:-10000px;top:0;width:${width}px;height:${height}px` });
  document.body.append(div);
  try {
    await Plotly.newPlot(div, fig.data, fig.layout, { staticPlot: true });
    return await Plotly.toImage(div, { format, width, height, scale: 1 });
  } finally { Plotly.purge(div); div.remove(); }
}

async function exportPanel(p, format) {
  const url = await panelImage(p, format, 900, 520);
  const name = fileName(titleOf(S.byName.get(p.name))) + "." + format;
  download(name, await (await fetch(url)).blob());
}

const SIZES = { slide: [1600, 900], a4: [794, 1123], a4l: [1123, 794] };

function captionLines() {
  const lines = [];
  const mode = $("#mode").value;
  const runs = S.shown.map(runById).filter(Boolean);
  lines.push(`${S.model.title || "Model"} · runs: ${runs.map((r) => r.label).join(", ")}` +
    (mode === "values" ? "" : ` · ${mode === "pct" ? "% difference" : "difference"} from ${(runById($("#baseline").value) || {}).label}`));
  for (const r of runs) {
    const c = changesText(r, 6);
    if (c) lines.push(`${r.label}: ${c}`);
  }
  const now = new Date(), two = (x) => String(x).padStart(2, "0");
  lines.push(`Exported ${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())} ${two(now.getHours())}:${two(now.getMinutes())} with PySD.jl`);
  return lines;
}

async function exportView(format) {
  if (!S.panels.length) return toast("Nothing to export: pick names first.");
  status("Exporting…");
  try {
    const cols = Math.min(+$("#columns").value, S.panels.length);
    const rows = Math.ceil(S.panels.length / cols);
    const size = $("#export-size").value;
    const caption = $("#export-caption").checked ? captionLines() : [];
    const capH = caption.length ? 18 * caption.length + 16 : 0;
    let W, H;
    if (size === "screen") { W = Math.max(600, $("#panels").clientWidth); H = rows * 380 + capH; }
    else { [W, H] = SIZES[size]; }
    const cw = Math.floor(W / cols), ch = Math.floor((H - capH) / rows);
    const imgs = [];
    if (format === "svg") for (const p of S.panels) imgs.push(await panelImage(p, "svg", cw, ch));
    const base = fileName(S.model.title || "view") + "-" + S.panels.length + "-plots";
    if (format === "svg") {
      const parts = imgs.map((u, i) => {
        let svg = decodeURIComponent(u.slice(u.indexOf(",") + 1)).replace(/<\?xml[^>]*\?>/, "");
        const x = (i % cols) * cw, y = Math.floor(i / cols) * ch;
        return svg.replace(/^<svg /, `<svg x="${x}" y="${y}" `);
      });
      const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;");
      const texts = caption.map((t, i) => `<text x="12" y="${H - capH + 22 + 18 * i}" font-family="sans-serif" font-size="${i ? 12 : 13}" fill="${i ? "#52514e" : "#0b0b0b"}">${esc(t)}</text>`);
      const out = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><rect width="100%" height="100%" fill="#ffffff"/>${parts.join("")}${texts.join("")}</svg>`;
      download(base + ".svg", new Blob([out], { type: "image/svg+xml" }));
    } else {
      const scale = size === "a4" || size === "a4l" ? 3 : 2;
      const canvas = el("canvas", { width: W * scale, height: H * scale });
      const g = canvas.getContext("2d");
      g.scale(scale, scale);
      g.fillStyle = "#ffffff"; g.fillRect(0, 0, W, H);
      for (let i = 0; i < S.panels.length; i++) {
        // the plot again at the export's scale, sharp
        const hi = await (async () => {
          const s = await series(S.panels[i].name);
          const fig = figure(S.panels[i], s, "light", { title: true, width: cw, height: ch });
          const div = el("div", { style: `position:fixed;left:-10000px;top:0;width:${cw}px;height:${ch}px` });
          document.body.append(div);
          try { await Plotly.newPlot(div, fig.data, fig.layout, { staticPlot: true });
            return await Plotly.toImage(div, { format: "png", width: cw, height: ch, scale });
          } finally { Plotly.purge(div); div.remove(); }
        })();
        const img = await loadImage(hi);
        g.drawImage(img, (i % cols) * cw, Math.floor(i / cols) * ch, cw, ch);
      }
      caption.forEach((t, i) => {
        g.font = `${i ? 12 : 13}px sans-serif`; g.fillStyle = i ? "#52514e" : "#0b0b0b";
        g.fillText(t, 12, H - capH + 22 + 18 * i, W - 24);
      });
      canvas.toBlob((b) => download(base + ".png", b), "image/png");
    }
  } catch (e) { toast("Export failed: " + e.message); }
  status("");
}
const loadImage = (src) => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = no; i.src = src; });

async function exportCSV() {
  if (!S.panels.length) return toast("Nothing to export: pick names first.");
  const cols = [], heads = [];
  let time = null;
  for (const p of S.panels) {
    const s = await series(p.name);
    time = time || s.time;
    const v = S.byName.get(p.name);
    for (const t of traces(p, s)) {
      heads.push(`${titleOf(v)}${t.element ? "[" + t.element + "]" : ""} (${t.run.label})${v.unit ? " [" + v.unit + "]" : ""}`);
      cols.push(t.y);
    }
  }
  const q = (x) => `"${String(x).replace(/"/g, '""')}"`;
  const lines = [["time", ...heads].map(q).join(",")];
  (time || []).forEach((t, i) => lines.push([t, ...cols.map((c) => c[i] ?? "")].join(",")));
  const mode = $("#mode").value;
  const note = mode === "values" ? "" : `# ${mode === "pct" ? "% difference" : "difference"} from ${(runById($("#baseline").value) || {}).label}\n`;
  download(fileName(S.model.title || "view") + ".csv", new Blob([note + lines.join("\n")], { type: "text/csv" }));
}

async function exportHTML() {
  if (!S.panels.length) return toast("Pick the names to include first: the copy keeps the plotted names only.");
  status("Making the HTML copy…");
  try {
    const r = await fetch("api/static", { method: "POST", headers: { "Content-Type": "application/json", "X-PySD-Request": "1" },
      body: JSON.stringify({ runs: S.runs.map((r) => r.id), names: S.panels.map((p) => p.name), view: currentView("Exported view") }) });
    if (!r.ok) throw new Error((await r.json()).error);
    download(fileName(S.model.title || "model") + "-explorer.html", await r.blob());
  } catch (e) { toast("Export failed: " + e.message); }
  status("");
}

// ---------------------------------------------------------------- saved views
function currentView(name) {
  return { name, panels: S.panels.map((p) => ({ name: p.name, elements: p.elements, sum: p.sum })),
    runs: S.shown.slice(), mode: $("#mode").value, baseline: $("#baseline").value, columns: $("#columns").value };
}
async function applyView(v) {
  S.panels = (v.panels || []).filter((p) => S.byName.has(p.name)).map((p) => ({ name: p.name, elements: p.elements || null, sum: !!p.sum }));
  for (const id of S.shown.slice()) toggleRun(id, false);
  for (const id of v.runs || []) if (runById(id)) toggleRun(id, true);
  if (!S.shown.length && S.runs.length) toggleRun(S.runs[0].id, true);
  $("#mode").value = v.mode || "values";
  $("#columns").value = v.columns || "2"; setColumns();
  renderBaseline();
  if (v.baseline && runById(v.baseline)) $("#baseline").value = v.baseline;
  renderRunChips(); renderRunsTable(); renderTree();
  $("#panels").replaceChildren();
  await renderPanels();
}
function renderViews() {
  const sel = $("#views");
  sel.replaceChildren(el("option", { value: "" }, "Saved views…"), ...S.views.map((v) => el("option", { value: v.name }, v.name)));
}
async function saveView() {
  if (!S.panels.length) return toast("Nothing to save: pick names first.");
  const name = prompt("Name of this view:", $("#views").value || "");
  if (!name) return;
  try { S.views = await api("POST", "views", currentView(name)); renderViews(); $("#views").value = name; toast("View saved."); }
  catch (e) { toast(e.message); }
}
async function deleteView() {
  const name = $("#views").value;
  if (!name || !confirm(`Delete the saved view "${name}"?`)) return;
  try { S.views = await api("DELETE", "views/" + encodeURIComponent(name)); renderViews(); } catch (e) { toast(e.message); }
}

// ---------------------------------------------------------------- runs tab
function renderRunsTable() {
  const tb = $("#runs-table tbody");
  const mine = S.runs.filter((r) => r.owner === S.me.user).length;
  $("#runs-quota").textContent = S.me.local || STATIC ? "" :
    (S.me.admin ? `yours: ${mine}` : `yours: ${mine} of ${S.me.limits.max_runs_per_user}`);
  tb.replaceChildren(...S.runs.slice().reverse().map((r) => {
    const on = S.shown.includes(r.id);
    const own = mayChange(r);
    return el("tr", {},
      el("td", {}, el("input", { type: "checkbox", checked: on, title: "Show in Explore",
        onchange: () => { toggleRun(r.id); renderRunChips(); renderBaseline(); renderRunsTable(); renderPanels(); } })),
      el("td", {}, el("span", { class: "badge", style: on ? `background:${runColor(r.id)};width:10px;height:10px;border-radius:50%;margin-right:6px` : "display:none" }),
        el("b", {}, r.label), el("br"), el("small", {}, r.seconds ? `${r.seconds} s` : "")),
      el("td", {}, el("small", {}, r.owner ? r.owner : "everyone"), el("br"),
        el("small", {}, r.owner === "" ? "" : r.shared ? "shared" : "private")),
      el("td", {}, el("small", {}, r.created)),
      el("td", { class: "changes" }, changesText(r) || "—"),
      el("td", { class: "static-hide" },
        el("button", { class: "ghost", title: "Start a new run from this one's changes", onclick: () => editFrom(r) }, "Edit copy"),
        own && r.owner !== "" ? el("button", { class: "ghost", title: r.shared ? "Only you will see it" : "Everyone will see it",
          onclick: () => changeRun(r, { shared: !r.shared }) }, r.shared ? "Unshare" : "Share") : null,
        own ? el("button", { class: "ghost", title: "Rename", onclick: () => renameRun(r) }, "Rename") : null,
        own ? el("button", { class: "ghost", title: "Delete", onclick: () => deleteRun(r) }, "✕") : null));
  }));
}
async function changeRun(r, change) {
  try { Object.assign(r, await api("PATCH", "runs/" + encodeURIComponent(r.id), change)); renderRunChips(); renderRunsTable(); }
  catch (e) { toast(e.message); }
}
function editFrom(r) {
  S.edits = new Map(Object.entries(r.params || {}));
  S.inputs = { ...(r.inputs || {}) };
  $("#run-label").value = r.label + " (copy)";
  renderInputs(); renderParams(); renderChanged();
}
async function renameRun(r) {
  const label = prompt("New name:", r.label);
  if (!label) return;
  await changeRun(r, { label });
  renderBaseline(); renderPanels();
}
async function deleteRun(r) {
  if (!confirm(`Delete the run "${r.label}"? Its results are removed from disk.`)) return;
  try {
    await api("DELETE", "runs/" + encodeURIComponent(r.id));
    toggleRun(r.id, false);
    S.runs = S.runs.filter((x) => x.id !== r.id);
    for (const c of S.cache.values()) delete c.runs[r.id];
    renderRunChips(); renderBaseline(); renderRunsTable(); renderPanels();
  } catch (e) { toast(e.message); }
}

function renderInputs() {
  const box = $("#inputs-box");
  const entries = Object.entries(S.model.inputs).filter(([, cs]) => cs.length > 1);
  if (!entries.length) {
    const own = Object.keys(S.model.inputs).length;
    box.replaceChildren(el("p", { class: "note" }, `Input sheets: the model reads ${own} Excel sheets, and there are no other versions of them yet. ` +
      "Another version of a sheet (a different scenario, say) is a copy of its file with other values, named like it " +
      "(scen_w_high.xlsx for scen_w.xlsx) and put in the explorer's input folder; it then appears here to choose from. " +
      "Single values from the sheets can also be changed one by one below."));
    return;
  }
  box.replaceChildren(el("h3", {}, "Input sheets"), ...entries.map(([k, cs]) => el("label", { class: "block" }, show(k),
    el("select", { onchange: (e) => { if (e.target.selectedIndex === 0) delete S.inputs[k]; else S.inputs[k] = e.target.value; renderChanged(); } },
      ...cs.map((c, i) => el("option", { value: c.id, selected: S.inputs[k] ? S.inputs[k] === c.id : i === 0 }, (i === 0 ? "model's: " : "") + c.label))))));
}

function editableParams() {
  return S.model.names.filter((v) => v.kind === "parameter" && v.value !== null && v.value !== undefined);
}
function renderParams() {
  const q = $("#param-search").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const all = editableParams();
  let list = all.filter((v) => {
    if (!q.length) return true;
    const hay = (v.title + " " + v.name + " " + v.description + " " + v.set).toLowerCase().replace(/_/g, " ");
    return q.every((w) => hay.includes(w.replace(/_/g, " ")));
  });
  const box = $("#param-list");
  const more = list.length > 40;
  list = list.slice(0, 40);
  box.replaceChildren(...list.map(paramRow),
    el("p", { class: "note" }, more ? `${all.length} parameters: showing the first 40 that match; type more to narrow.` :
      (list.length ? "" : "No parameter matches.")));
}

function paramRow(v) {
  const changed = S.edits.has(v.name);
  const cur = changed ? S.edits.get(v.name) : v.value;
  const row = el("div", { class: "param" + (changed ? " changed-row" : ""), title: `${v.name}\n\n${v.description || ""}` },
    el("div", { class: "name" }, el("span", { class: "t" }, titleOf(v)), el("span", { class: "u" }, v.unit)),
    el("div", { class: "set" }, v.set));
  const set = (x) => {
    const same = Array.isArray(x) ? x.every((y, i) => y === v.value[i]) : x === v.value;
    if (same) S.edits.delete(v.name); else S.edits.set(v.name, x);
    row.classList.toggle("changed-row", !same);
    renderChanged();
  };
  if (!Array.isArray(v.value)) {
    const lim = v.limits || [];
    const lo = lim[0], hi = lim[1];
    const num = el("input", { type: "number", value: cur, step: "any" });
    const ctl = el("div", { class: "ctl" });
    if (lo !== null && lo !== undefined && hi !== null && hi !== undefined && hi > lo) {
      const step = lim[2] || (hi - lo) / 200;
      const range = el("input", { type: "range", min: lo, max: hi, step, value: cur });
      range.addEventListener("input", () => { num.value = range.value; set(+range.value); });
      num.addEventListener("change", () => { range.value = num.value; set(+num.value); });
      ctl.append(el("small", {}, fmt(lo)), range, el("small", {}, fmt(hi)), num);
    } else {
      num.addEventListener("change", () => { if (num.value !== "") set(+num.value); });
      ctl.append(num);
    }
    ctl.append(el("span", { class: "base" }, "model: " + fmt(v.value)));
    row.append(ctl);
  } else {
    const labels = cartesian(v.elements);
    const vals = cur.slice();
    const grid = el("div", { class: "grid" }, ...labels.map((lab, i) => el("label", {}, lab,
      el("input", { type: "number", step: "any", value: vals[i] ?? "", title: "model: " + fmt(v.value[i]),
        onchange: (e) => { vals[i] = e.target.value === "" ? v.value[i] : +e.target.value; set(vals.slice()); } }))));
    row.append(el("details", {}, el("summary", {}, `${labels.length} values (${v.dims.join(" × ")})`), grid));
  }
  return row;
}
function cartesian(elements) {
  let out = [[]];
  for (const es of elements) out = out.flatMap((pre) => es.map((e) => pre.concat([e])));
  return out.map((x) => x.join(","));
}

function renderChanged() {
  const box = $("#changed");
  const items = [...S.edits].map(([k, val]) => {
    const v = S.byName.get(k);
    return el("div", {}, el("span", { class: "t" }, titleOf(v)),
      el("span", {}, Array.isArray(val) ? "changed values" : `${fmt(v.value)} → ${fmt(val)}`),
      el("button", { class: "ghost", title: "Back to the model's value", onclick: () => { S.edits.delete(k); renderParams(); renderChanged(); } }, "↺"));
  });
  for (const [k, id] of Object.entries(S.inputs)) {
    const c = (S.model.inputs[k] || []).find((c) => c.id === id);
    items.push(el("div", {}, el("span", { class: "t" }, show(k)), el("span", {}, c ? c.label : id),
      el("button", { class: "ghost", onclick: () => { delete S.inputs[k]; renderInputs(); renderChanged(); } }, "↺")));
  }
  box.replaceChildren(...items);
  const n = items.length;
  $("#changed-count").textContent = n ? `${n} change${n > 1 ? "s" : ""}` : "none changed: the run repeats the model";
}

async function newRun() {
  const btn = $("#run");
  btn.disabled = true;
  try {
    const job = await api("POST", "runs", { label: $("#run-label").value, params: Object.fromEntries(S.edits), inputs: S.inputs });
    $("#run-label").value = "";
    S.jobs.push({ ...job, status: "queued" });          // so that its end is seen, however soon it comes
    toast(job.status === "queued" && job.position > 1 ? `Queued: ${job.position - 1} before yours.` : "Running…");
    refreshJobs();
  } catch (e) { toast("The run can't start: " + e.message, 8000); }
  btn.disabled = false;
}

// ---------------------------------------------------------------- jobs: runs and analyses waiting or running
async function refreshJobs() {
  if (STATIC) return;
  clearTimeout(S.jobsTimer);
  let jobs;
  try { jobs = await api("GET", "jobs"); } catch (e) { return; }
  const mine = jobs.filter((j) => j.user === S.me.user);
  const was = new Map(S.jobs.map((j) => [j.id, j.status]));
  S.jobs = mine;
  for (const j of mine) {
    const before = was.get(j.id);
    if (before && before !== j.status && j.status === "done") await jobDone(j);
    if (before && before !== j.status && j.status === "failed") toast(`"${j.label}" failed: ${j.message}`, 10000);
  }
  renderJobs();
  if (mine.some((j) => j.status === "queued" || j.status === "running")) S.jobsTimer = setTimeout(refreshJobs, 1000);
}
async function jobDone(j) {
  if (j.kind === "run") {
    S.runs = await api("GET", "runs");
    const run = runById(j.result);
    if (run) {
      if (S.shown.length >= MAX_RUNS) toggleRun(S.shown[S.shown.length - 1], false);
      toggleRun(run.id, true);
      toast(`"${run.label}" ran in ${run.seconds} s; it's shown in Explore.`);
    }
    renderRunChips(); renderBaseline(); renderRunsTable(); renderAnalysisForm();
    if ($("#explore").classList.contains("active") || $("#runs").classList.contains("active")) await renderPanels();
  } else {
    S.analyses = await api("GET", "analyses");
    S.sens = await api("GET", "analyses/" + encodeURIComponent(j.result));
    renderSensPick(); renderSens(); renderAnalysisForm();
    toast(`The analysis "${j.label}" is ready in Sensitivity.`);
  }
}
function renderJobs() {
  const keep = S.jobs.filter((j) => j.status !== "done" && j.status !== "cancelled");
  $("#jobs").replaceChildren(...keep.map((j) => el("div", { class: "job" + (j.status === "failed" ? " failed" : "") },
    el("span", { class: "what" }, el("b", {}, j.label), ` (${j.kind}) — `,
      j.status === "queued" ? (j.position > 1 ? `waiting, ${j.position - 1} before it` : "next") :
      j.status === "running" ? (j.kind === "analysis" ? `running, ${Math.round(100 * j.progress)} %` : "running") :
      `failed: ${j.message}`),
    j.status === "running" && j.kind === "analysis" ? el("progress", { max: 1, value: j.progress }) : null,
    j.status === "queued" || (j.status === "running" && j.kind === "analysis") ?
      el("button", { class: "ghost", onclick: () => cancelJob(j) }, "Cancel") : null)));
}
async function cancelJob(j) {
  try { await api("DELETE", "jobs/" + encodeURIComponent(j.id)); refreshJobs(); } catch (e) { toast(e.message); }
}

// ---------------------------------------------------------------- sensitivity
// a result's name: the variable's title, and its element ("x[a,b]")
function outLabel(o) {
  const k = o.indexOf("[");
  const v = S.byName.get(k < 0 ? o : o.slice(0, k));
  return (v ? titleOf(v) : show(o.slice(0, k < 0 ? undefined : k))) + (k < 0 ? "" : " " + o.slice(k));
}

function renderSens() {
  const none = !S.sens;
  $("#sens-chart").style.display = none ? "none" : "";
  $("#sens-note").textContent = none ? "No analysis yet: start one below." : $("#sens-note").textContent;
  if (none) return;
  const sel = $("#sens-output");
  if (sel.dataset.for !== S.sens.id) {
    sel.dataset.for = S.sens.id;
    sel.replaceChildren(...S.sens.outputs.map((o) => el("option", { value: o }, outLabel(o))));
  }
  const out = sel.value || S.sens.outputs[0];
  const n = +$("#sens-top").value;
  const years = $("#sens-years").checked;
  const isYear = (r) => r.value !== null && r.value !== undefined && Number.isInteger(r.value) && r.value >= 1900 && r.value <= 2200;
  const rows = S.sens.rows.filter((r) => r[out] !== null && r[out] !== undefined && r[out] !== 0 && (years || !isYear(r)))
    .sort((a, b) => Math.abs(b[out]) - Math.abs(a[out])).slice(0, n).reverse();
  const th = theme();
  const ink = th === "dark" ? { text: "#f0efec", muted: "#c3c2b7", grid: "#2c2c2a", bg: "#1a1a19" } :
    { text: "#0b0b0b", muted: "#52514e", grid: "#e6e5e1", bg: "#fcfcfb" };
  const label = (r) => { const v = S.byName.get(r.parameter); return v ? titleOf(v) : show(r.parameter); };
  const around = S.sens.around ? runById(S.sens.around) : null;
  const skipped = (S.sens.skipped || []).length;
  $("#sens-note").textContent = `Elasticity of ${outLabel(out)} at the end of the run (${S.model.tf} ${S.model.time_unit}), ` +
    `around ${around ? "the run " + around.label : "the model's values"}: ` +
    `the % it changes when one parameter is 1 % higher, the others as in the model. ` +
    `Blue: it goes up; red: it goes down. Year parameters (a 1 % change moves them ~20 years) are left out unless included. ` +
    (skipped ? `${skipped} parameters left out (0, or years). ` : "") +
    `Click a bar to change that parameter in a new run.`;
  const data = [{
    type: "bar", orientation: "h", x: rows.map((r) => r[out]), y: rows.map(label),
    marker: { color: rows.map((r) => (r[out] >= 0 ? DIVERGING[th][0] : DIVERGING[th][1])) },
    customdata: rows.map((r) => { const v = S.byName.get(r.parameter) || {}; return [r.parameter, v.unit || "", fmt(r.value), v.set || ""]; }),
    hovertemplate: "<b>%{y}</b><br>%{customdata[0]}<br>value %{customdata[2]} %{customdata[1]}<br>%{customdata[3]}<br>elasticity %{x:.4~g}<extra></extra>",
  }];
  const layout = {
    paper_bgcolor: ink.bg, plot_bgcolor: ink.bg, font: { color: ink.muted, size: 12 },
    height: 110 + 28 * rows.length, margin: { l: 10, r: 30, t: 20, b: 50 },
    xaxis: { title: { text: "elasticity (% per 1 %)" }, gridcolor: ink.grid, zerolinecolor: ink.muted },
    yaxis: { automargin: true, tickfont: { color: ink.text } }, bargap: 0.25,
  };
  const div = $("#sens-chart");
  if (!$("#sensitivity").classList.contains("active")) return;
  Plotly.react(div, data, layout, { displaylogo: false, responsive: true });
  div.removeAllListeners && div.removeAllListeners("plotly_click");
  div.on("plotly_click", (ev) => {
    const name = ev.points[0].customdata[0];
    const v = S.byName.get(name);
    if (!v || STATIC) return;
    $("#param-search").value = name;
    renderParams();
    tab("runs");
  });
}

// ---------------------------------------------------------------- code
function renderCodeList() {
  const q = $("#code-search").value.trim().toLowerCase();
  const files = S.code.filter((c) => !q || (c.id + " " + c.sets.join(" ")).toLowerCase().includes(q));
  $("#code-list").replaceChildren(...files.map((c) => el("div", {
    class: "file" + (S.codeFile === c.id ? " on" : ""), onclick: () => openCode(c.id),
  }, c.sets.length ? c.sets.join(", ") : c.id, el("small", {}, c.id))));
}

function codeOf(v) {
  const file = v.code[0][0];
  openCode(file, v.code.filter((c) => c[0] === file).map((c) => c[1]), v);
}

async function openCode(id, lines = [], v = null) {
  tab("code");
  let text = S.codeText.get(id);
  if (text === undefined) {
    try { text = (await api("GET", "code/" + encodeURIComponent(id))).text; } catch (e) { return toast(e.message); }
    S.codeText.set(id, text);
  }
  S.codeFile = id;
  renderCodeList();
  const c = S.code.find((c) => c.id === id);
  $("#code-file").textContent = id;
  $("#code-sets").textContent = c && c.sets.length ? c.sets.join(", ") : "";
  const where = $("#code-where");
  where.replaceChildren();
  if (v) {
    where.append(`${titleOf(v)}:`);
    for (const [f, l] of v.code) where.append(el("a", { onclick: () => openCode(f, v.code.filter((x) => x[0] === f).map((x) => x[1]), v) }, `${f}:${l}`));
  }
  const hits = new Set();
  // a declaration or equation goes on until the next one starts: mark its lines
  const src = text.split("\n");
  for (const l of lines) {
    hits.add(l);
    for (let k = l; k < src.length && !/[,\]]\s*$|~|^\s*$/.test(src[k - 1]); k++) hits.add(k + 1);
    if (/,\s*$/.test(src[l - 1])) hits.add(l + 1);          // a declaration's metadata on the next line
  }
  const box = $("#code-text");
  box.replaceChildren(...src.map((line, i) => {
    const d = el("div", { class: "ln" + (hits.has(i + 1) ? " hit" : ""), "data-line": i + 1 },
      el("span", { class: "num" }, String(i + 1)), el("span", { class: "src" }));
    d.lastChild.innerHTML = highlight(line) || " ";
    return d;
  }));
  const first = lines.length ? box.querySelector(`[data-line="${Math.max(1, Math.min(...lines) - 3)}"]`) : null;
  if (first) first.scrollIntoView({ block: "start" }); else box.scrollTop = 0;
}

const KEYWORDS = new Set(["begin", "end", "for", "in", "if", "else", "elseif", "function", "let", "const", "using",
  "import", "include", "module", "return", "true", "false", "nothing", "where", "do"]);
const escapeHtml = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
function highlight(line) {
  let out = "", i = 0;
  const re = /(#.*$)|(u?"(?:[^"\\]|\\.)*")|(@[\w!]+)|(\b\d+(?:\.\d+)?(?:e[+-]?\d+)?\b)|([A-Za-z_\u00C0-\uFFFF][\w\u00C0-\uFFFF!]*)/g;
  let m;
  while ((m = re.exec(line))) {
    out += escapeHtml(line.slice(i, m.index));
    const t = escapeHtml(m[0]);
    if (m[1]) out += `<span class="tok-c">${t}</span>`;
    else if (m[2]) out += `<span class="tok-s">${t}</span>`;
    else if (m[3]) out += `<span class="tok-k">${t}</span>`;
    else if (m[4]) out += `<span class="tok-n">${t}</span>`;
    else if (KEYWORDS.has(m[0])) out += `<span class="tok-k">${t}</span>`;
    else if (S.byName.has(m[0])) {
      const v = S.byName.get(m[0]);
      out += `<a class="ref" data-name="${t}" title="${escapeHtml(titleOf(v) + (v.unit ? " [" + v.unit + "]" : "") + "\n" + (v.description || ""))}">${t}</a>`;
    } else out += t;
    i = m.index + m[0].length;
  }
  return out + escapeHtml(line.slice(i));
}

// ---------------------------------------------------------------- analyses: pick, share, start
function renderSensPick() {
  const sel = $("#sens-pick");
  sel.replaceChildren(...S.analyses.map((a) => el("option", { value: a.id, selected: S.sens && S.sens.id === a.id },
    a.label + (a.owner && a.owner !== S.me.user ? ` · ${a.owner}` : "") + (a.owner === S.me.user && !a.shared ? " (private)" : ""))));
  sel.disabled = !S.analyses.length;
  const own = S.sens && S.sens.id !== "file" && mayChange(S.sens);
  for (const id of ["#sens-share", "#sens-rename", "#sens-delete"]) $(id).hidden = !own || !!STATIC;
  if (own) $("#sens-share").textContent = S.sens.shared ? "Unshare" : "Share";
  $("#sens-meta").textContent = S.sens ? [S.sens.owner ? "by " + S.sens.owner : "", S.sens.created,
    S.sens.seconds ? `${S.sens.seconds} s` : ""].filter(Boolean).join(" · ") : "";
}
async function pickAnalysis() {
  try { S.sens = await api("GET", "analyses/" + encodeURIComponent($("#sens-pick").value)); } catch (e) { return toast(e.message); }
  renderSensPick(); renderSens();
}
async function changeAnalysis(change) {
  try {
    const a = await api("PATCH", "analyses/" + encodeURIComponent(S.sens.id), change);
    Object.assign(S.sens, a);
    S.analyses = await api("GET", "analyses");
    renderSensPick();
  } catch (e) { toast(e.message); }
}
async function deleteAnalysis() {
  if (!confirm(`Delete the analysis "${S.sens.label}"?`)) return;
  try {
    await api("DELETE", "analyses/" + encodeURIComponent(S.sens.id));
    S.analyses = await api("GET", "analyses");
    S.sens = S.analyses.length ? await api("GET", "analyses/" + encodeURIComponent(S.analyses[0].id)) : null;
    renderSensPick(); renderSens(); renderAnalysisForm();
  } catch (e) { toast(e.message); }
}

function foundParams() {
  const q = $("#an-par-search").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  return editableParams().filter((v) => {
    const hay = (v.title + " " + v.name + " " + v.description + " " + v.set).toLowerCase().replace(/_/g, " ");
    return q.every((w) => hay.includes(w.replace(/_/g, " ")));
  });
}
function renderAnalysisForm() {
  if (STATIC) return;
  const sel = $("#an-around");
  const keep = sel.value;
  sel.replaceChildren(el("option", { value: "" }, "the model's values"),
    ...S.runs.filter((r) => r.owner !== "").map((r) => el("option", { value: r.id }, runLabel(r))));
  sel.value = runById(keep) ? keep : "";
  const mine = S.analyses.filter((a) => a.owner === S.me.user).length;
  const L = S.me.limits;
  $("#an-limits").textContent = S.me.admin || S.me.local ? "" :
    `You keep ${mine} of ${L.max_analyses_per_user} analyses; at most ${L.max_params_per_analysis} parameters each.`;
  // the results: those plotted, picked first
  if (!S.anOutputs.size) for (const p of S.panels) { const v = S.byName.get(p.name); if (v && (v.kind === "stock" || v.kind === "aux")) S.anOutputs.add(p.name); }
  renderAnalysisParams(); renderAnalysisOutputs();
}
function renderAnalysisParams() {
  const found = foundParams();
  const list = found.slice(0, 200);
  const limit = S.me.admin || S.me.local ? Infinity : S.me.limits.max_params_per_analysis;
  $("#an-par-count").textContent = `${S.anParams.size} picked` + (limit < Infinity ? ` (at most ${limit})` : "") +
    ` · ${found.length} found` + (found.length > list.length ? ", the first 200 shown" : "");
  $("#an-params").replaceChildren(...list.map((v) => el("label", { title: `${v.name}\n${v.description || ""}` },
    el("input", { type: "checkbox", checked: S.anParams.has(v.name), onchange: (e) => {
      e.target.checked ? S.anParams.add(v.name) : S.anParams.delete(v.name); renderAnalysisParams(); } }),
    titleOf(v), el("small", {}, v.set))));
}
function renderAnalysisOutputs() {
  const q = $("#an-out-search").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const all = S.model.names.filter((v) => v.kind === "stock" || v.kind === "aux");
  const found = q.length ? all.filter((v) => q.every((w) => (v.title + " " + v.name + " " + v.description).toLowerCase().replace(/_/g, " ").includes(w.replace(/_/g, " "))))
    : all.filter((v) => S.anOutputs.has(v.name));
  $("#an-out-count").textContent = `${S.anOutputs.size} picked` + (q.length ? "" : " (search to add more)");
  $("#an-outputs").replaceChildren(...found.slice(0, 100).map((v) => el("label", { title: v.description || "" },
    el("input", { type: "checkbox", checked: S.anOutputs.has(v.name), onchange: (e) => {
      e.target.checked ? S.anOutputs.add(v.name) : S.anOutputs.delete(v.name); renderAnalysisOutputs(); } }),
    titleOf(v), el("small", {}, v.unit))));
}
async function startAnalysis() {
  const step = +$("#an-step").value / 100;
  try {
    const job = await api("POST", "analyses", { label: $("#an-label").value, around: $("#an-around").value,
      params: [...S.anParams], outputs: [...S.anOutputs], step, years: $("#an-years").checked });
    $("#an-label").value = "";
    S.jobs.push({ ...job, status: "queued" });
    toast(`The analysis is ${job.status === "queued" && job.position > 1 ? `queued, ${job.position - 1} before it` : "running"}; its progress is in Runs.`);
    refreshJobs();
  } catch (e) { toast("The analysis can't start: " + e.message, 8000); }
}

// ---------------------------------------------------------------- administrators
const SETTINGS = [
  ["max_parallel", "Simulations at once", "everyone's runs and analyses together; the server has THREADS threads"],
  ["max_jobs_per_user", "Jobs per user", "runs and analyses one user can have waiting or running"],
  ["max_runs_per_user", "Runs kept per user", "about 14 MB each for a large model"],
  ["max_analyses_per_user", "Analyses kept per user", "a small table each"],
  ["max_params_per_analysis", "Parameters per analysis", "one run each, one after another"],
  ["show_code", "Show the code to users", "administrators always see it"],
];
async function renderAdmin() {
  let a;
  try { a = await api("GET", "admin"); } catch (e) { return toast(e.message); }
  const box = $("#admin-settings");
  if (!box.children.length) {
    box.replaceChildren(...SETTINGS.map(([k, label, help]) => el("div", { class: "settings-row" },
      el("label", { for: "set-" + k }, label, el("small", {}, help.replace("THREADS", a.threads))),
      k === "show_code" ? el("input", { type: "checkbox", id: "set-" + k, checked: a.settings[k] }) :
        el("input", { type: "number", id: "set-" + k, value: a.settings[k], min: 1, step: 1 }))));
  }
  $("#admin-threads").textContent = `${a.running} simulation${a.running === 1 ? "" : "s"} running now; ${a.threads} Julia threads.`;
  $("#admin-users tbody").replaceChildren(...a.users.map((u) => el("tr", {},
    el("td", {}, u.user || "everyone"), el("td", {}, String(u.runs)), el("td", {}, String(u.shared)),
    el("td", {}, String(u.analyses)), el("td", {}, `${u.mb} MB`))));
  $("#admin-jobs tbody").replaceChildren(...a.jobs.slice().reverse().map((j) => el("tr", {},
    el("td", {}, j.user), el("td", {}, `${j.label} (${j.kind})`),
    el("td", {}, j.status + (j.status === "running" && j.kind === "analysis" ? ` ${Math.round(100 * j.progress)} %` : "") +
      (j.message && j.status === "failed" ? `: ${j.message}` : "")),
    el("td", {}, j.created || ""), el("td", {}, j.started || ""), el("td", {}, j.finished || ""),
    el("td", {}, j.status === "queued" || (j.status === "running" && j.kind === "analysis") ?
      el("button", { class: "ghost", onclick: async () => { try { await api("DELETE", "jobs/" + j.id); renderAdmin(); } catch (e) { toast(e.message); } } }, "Cancel") : ""))));
}
async function saveSettings() {
  const body = {};
  for (const [k] of SETTINGS) {
    const i = $("#set-" + k);
    body[k] = k === "show_code" ? i.checked : Math.round(+i.value);
  }
  try {
    await api("PUT", "admin/settings", body);
    S.me = await api("GET", "me");
    toast("Saved.");
    renderAdmin();
  } catch (e) { toast(e.message, 6000); }
}

// ---------------------------------------------------------------- logging in (users = :password)
function showLogin() {
  const box = $("#login");
  if (!box.hidden) return;
  box.hidden = false;
  $("#login-title").textContent = document.title.replace(" · PySD Explorer", "") || "PySD Explorer";
  $("#login-user").focus();
  $("#login-form").onsubmit = async (e) => {
    e.preventDefault();
    $("#login-go").disabled = true;
    $("#login-error").hidden = true;
    try {
      await api("POST", "login", { user: $("#login-user").value.trim(), password: $("#login-password").value });
      location.reload();
    } catch (err) {
      $("#login-error").textContent = err.message; $("#login-error").hidden = false;
      $("#login-password").value = "";
    }
    $("#login-go").disabled = false;
  };
}
async function changePassword(e) {
  if (e.submitter && e.submitter.value === "cancel") return;
  e.preventDefault();
  const err = $("#pw-error");
  const [cur, nw, again] = ["#pw-current", "#pw-new", "#pw-again"].map((x) => $(x).value);
  if (nw !== again) { err.textContent = "The two new passwords differ."; err.hidden = false; return; }
  try {
    await api("POST", "password", { current: cur, new: nw });
    $("#dlg-password").close();
    alert("Password changed. Log in again with the new one.");
    location.reload();
  } catch (x) { err.textContent = x.message; err.hidden = false; }
}
function showSecret(title, password) {
  $("#secret-title").textContent = title;
  $("#secret-value").textContent = password;
  $("#dlg-secret").showModal();
}
async function renderLogins() {
  if (S.me.auth !== "password") return;
  $("#admin-accounts").hidden = false;
  let users;
  try { users = await api("GET", "admin/users"); } catch (e) { return toast(e.message); }
  $("#admin-logins tbody").replaceChildren(...users.map((u) => el("tr", {},
    el("td", {}, el("b", {}, u.user), u.user === S.me.user ? el("small", {}, " (you)") : null),
    el("td", {}, el("input", { type: "checkbox", checked: u.admin, title: "Administrator", onchange: async (ev) => {
      try { await api("PATCH", "admin/users/" + encodeURIComponent(u.user), { admin: ev.target.checked }); }
      catch (x) { toast(x.message); ev.target.checked = !ev.target.checked; }
    } })),
    el("td", {}, el("small", {}, u.last_login || "never")),
    el("td", {}, String(u.runs)),
    el("td", {},
      el("button", { class: "ghost", onclick: async () => {
        if (!confirm(`Give ${u.user} a new password? Their current one stops working, and they're logged out.`)) return;
        try { showSecret(`New password for ${u.user}`, (await api("POST", `admin/users/${encodeURIComponent(u.user)}/password`)).password); }
        catch (x) { toast(x.message); }
      } }, "New password"),
      u.user === S.me.user ? null : el("button", { class: "ghost", onclick: async () => {
        if (!confirm(`Remove ${u.user}? They can't log in any more; their runs stay (you can delete them).`)) return;
        try { await api("DELETE", "admin/users/" + encodeURIComponent(u.user)); renderLogins(); } catch (x) { toast(x.message); }
      } }, "Remove")))));
}
async function addUser(e) {
  e.preventDefault();
  const name = $("#new-user-name").value.trim();
  try {
    const r = await api("POST", "admin/users", { name, admin: $("#new-user-admin").checked });
    $("#new-user").reset();
    showSecret(`Password for ${r.user}`, r.password);
    renderLogins();
  } catch (x) { toast(x.message, 6000); }
}

start().catch((e) => { status("Couldn't load: " + e.message); console.error(e); });
