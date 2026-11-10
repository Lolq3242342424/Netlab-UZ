"use strict";
/* NetLab UZ — клиентская часть. Без внешних библиотек.
   Весь пользовательский текст выводится через textContent (защита от XSS). */

const SVG_NS = "http://www.w3.org/2000/svg";
const SWITCH_PORTS = Array.from({ length: 8 }, (_, i) => `fa0/${i + 1}`);
const MAX_DEVICES = 50;
const DEV_W = { pc: 110, switch: 150 };
const DEV_H = 70;

const state = {
  topo: { devices: [], links: [] },
  selected: null, // { kind: "device" | "link", id }
  tool: "select",
  pending: null, // id первого устройства при соединении кабелем
  project: null, // { id, name } открытого проекта
  taskId: null,
  lang: "ru",
  i18n: {},
};

const $ = (id) => document.getElementById(id);
const canvas = $("canvas");

// ------------------------------------------------------------ переводы
function lookup(key) {
  return key.split(".").reduce((o, k) => (o && o[k] !== undefined ? o[k] : undefined), state.i18n);
}
function t(key, params = {}) {
  const raw = lookup(key);
  if (typeof raw !== "string") return key;
  return raw.replace(/\{(\w+)\}/g, (_, k) => (params[k] !== undefined ? params[k] : `{${k}}`));
}
async function loadLang(lang) {
  const res = await fetch(`/i18n/${lang}.json`);
  if (!res.ok) throw new Error("i18n");
  state.i18n = await res.json();
  state.lang = lang;
  document.documentElement.lang = lang;
  try { localStorage.setItem("netlab.lang", lang); } catch (e) { /* приватный режим */ }
  applyStaticText();
  await refreshTasks();
  await refreshProjects();
  renderAll();
}
function applyStaticText() {
  document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll("[data-i18n-placeholder]").forEach((el) => { el.placeholder = t(el.dataset.i18nPlaceholder); });
  $("lang-select").value = state.lang;
}

// ------------------------------------------------------------ сервер
async function api(method, path, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  let res;
  try { res = await fetch(path, opts); } catch (e) { throw { code: "NETWORK" }; }
  let data = null;
  try { data = await res.json(); } catch (e) { /* пустой ответ */ }
  if (!res.ok) throw { code: (data && data.error && data.error.code) || "INTERNAL" };
  return data;
}
let toastTimer = null;
function toast(text, isError = false) {
  const el = $("toast");
  el.textContent = text;
  el.className = "toast" + (isError ? " err" : "");
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 4000);
}
function showError(err) {
  const code = err && err.code ? err.code : "INTERNAL";
  const text = lookup(`errors.${code}`);
  toast(typeof text === "string" ? text : t("errors.INTERNAL"), true);
}

// ------------------------------------------------------------ схема
function deviceById(id) { return state.topo.devices.find((d) => d.id === id); }
function portsOf(dev) { return dev.type === "pc" ? ["eth0"] : SWITCH_PORTS; }
function usedPorts(devId) {
  const used = new Set();
  state.topo.links.forEach((l) => {
    if (l.a.device === devId) used.add(l.a.port);
    if (l.b.device === devId) used.add(l.b.port);
  });
  return used;
}
function freePort(dev) {
  const used = usedPorts(dev.id);
  return portsOf(dev).find((p) => !used.has(p)) || null;
}
function nextNumber(prefix) {
  const taken = new Set(state.topo.devices.filter((d) => d.id.startsWith(prefix)).map((d) => d.id));
  let n = 1;
  while (taken.has(prefix + n)) n += 1;
  return n;
}
function nextLinkId() {
  const taken = new Set(state.topo.links.map((l) => l.id));
  let n = 1;
  while (taken.has("l" + n)) n += 1;
  return "l" + n;
}
function freeSpot(kind) {
  const baseY = kind === "pc" ? 300 : 180;
  for (let i = 0; i < 60; i += 1) {
    const x = 120 + (i % 8) * 120;
    const y = baseY + Math.floor(i / 8) * 110;
    const busy = state.topo.devices.some((d) => Math.abs(d.x - x) < 100 && Math.abs(d.y - y) < 80);
    if (!busy && y < 560) return { x, y };
  }
  return { x: 500, y: 300 };
}
function addDevice(kind) {
  if (state.topo.devices.length >= MAX_DEVICES) return toast(t("msg.limit"), true);
  const prefix = kind === "pc" ? "pc" : "sw";
  const n = nextNumber(prefix);
  const { x, y } = freeSpot(kind);
  state.topo.devices.push({
    id: prefix + n, type: kind, name: (kind === "pc" ? "PC" : "SW") + n, x, y, ip: "", mask: "",
  });
  state.selected = { kind: "device", id: prefix + n };
  renderAll();
}
function newSandbox(silent) {
  state.topo = { devices: [], links: [] };
  state.selected = null;
  state.pending = null;
  state.project = null;
  state.taskId = null;
  ["pc", "pc", "switch"].forEach((k) => addDevice(k));
  state.selected = null;
  // раскладываем в линию: PC1 — SW1 — PC2
  const [pc1, pc2, sw1] = [deviceById("pc1"), deviceById("pc2"), deviceById("sw1")];
  Object.assign(pc1, { x: 160, y: 300 });
  Object.assign(sw1, { x: 500, y: 300 });
  Object.assign(pc2, { x: 840, y: 300 });
  $("project-name").value = "";
  if (!silent) toast(t("msg.sandbox_reset"));
  renderAll();
}
function deleteSelected() {
  const sel = state.selected;
  if (!sel) return;
  if (sel.kind === "device") {
    state.topo.devices = state.topo.devices.filter((d) => d.id !== sel.id);
    state.topo.links = state.topo.links.filter((l) => l.a.device !== sel.id && l.b.device !== sel.id);
  } else {
    state.topo.links = state.topo.links.filter((l) => l.id !== sel.id);
  }
  state.selected = null;
  state.pending = null;
  renderAll();
}
function connect(aId, bId) {
  const a = deviceById(aId), b = deviceById(bId);
  if (!a || !b || a === b) return;
  const exists = state.topo.links.some((l) =>
    (l.a.device === aId && l.b.device === bId) || (l.a.device === bId && l.b.device === aId));
  if (exists) return toast(t("msg.already_linked"), true);
  const pa = freePort(a), pb = freePort(b);
  if (!pa) return toast(t("msg.no_free_port", { name: a.name }), true);
  if (!pb) return toast(t("msg.no_free_port", { name: b.name }), true);
  state.topo.links.push({ id: nextLinkId(), a: { device: aId, port: pa }, b: { device: bId, port: pb } });
}

// ------------------------------------------------------------ рисование
function svg(tag, attrs = {}, text) {
  const el = document.createElementNS(SVG_NS, tag);
  Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
  if (text !== undefined) el.textContent = text;
  return el;
}
function renderCanvas() {
  canvas.replaceChildren();
  canvas.setAttribute("class", state.tool === "connect" ? "canvas-mode-connect" : "");
  for (let x = 0; x <= 1000; x += 50) canvas.appendChild(svg("line", { class: "grid-line", x1: x, y1: 0, x2: x, y2: 600 }));
  for (let y = 0; y <= 600; y += 50) canvas.appendChild(svg("line", { class: "grid-line", x1: 0, y1: y, x2: 1000, y2: y }));

  state.topo.links.forEach((l) => {
    const a = deviceById(l.a.device), b = deviceById(l.b.device);
    if (!a || !b) return;
    const g = svg("g", { class: "link" + (state.selected && state.selected.kind === "link" && state.selected.id === l.id ? " selected" : "") });
    g.appendChild(svg("line", { class: "link-line", x1: a.x, y1: a.y, x2: b.x, y2: b.y }));
    g.appendChild(svg("line", { class: "link-hit", x1: a.x, y1: a.y, x2: b.x, y2: b.y }));
    const tx = (p, q) => p + (q - p) * 0.22, ty = (p, q) => p + (q - p) * 0.22;
    g.appendChild(svg("text", { class: "port-t", x: tx(a.x, b.x), y: ty(a.y, b.y) - 8, "text-anchor": "middle" }, l.a.port));
    g.appendChild(svg("text", { class: "port-t", x: tx(b.x, a.x), y: ty(b.y, a.y) - 8, "text-anchor": "middle" }, l.b.port));
    g.addEventListener("pointerdown", (e) => {
      e.stopPropagation();
      if (state.tool !== "select") return;
      state.selected = { kind: "link", id: l.id };
      renderAll();
    });
    canvas.appendChild(g);
  });

  state.topo.devices.forEach((d) => {
    const w = DEV_W[d.type];
    const cls = ["dev", d.type];
    if (state.selected && state.selected.kind === "device" && state.selected.id === d.id) cls.push("selected");
    if (state.pending === d.id) cls.push("pending");
    const g = svg("g", { class: cls.join(" "), "data-id": d.id });
    g.appendChild(svg("rect", { class: "body", x: d.x - w / 2, y: d.y - DEV_H / 2, width: w, height: DEV_H, rx: 12 }));
    g.appendChild(svg("text", { class: "nm", x: d.x, y: d.y - 2, "text-anchor": "middle" }, d.name));
    const sub = d.type === "pc" ? (d.ip ? `${d.ip}${d.mask ? " " + d.mask : ""}` : "—") : "switch";
    g.appendChild(svg("text", { class: "ipt", x: d.x, y: d.y + 20, "text-anchor": "middle" }, sub.length > 26 ? sub.slice(0, 25) + "…" : sub));
    g.addEventListener("pointerdown", (e) => onDevicePointerDown(e, d));
    canvas.appendChild(g);
  });
}
function renderProps() {
  const box = $("props");
  box.replaceChildren();
  const sel = state.selected;
  const none = () => { const p = document.createElement("p"); p.className = "hint"; p.textContent = t("props.none"); box.appendChild(p); };
  if (!sel) return none();
  if (sel.kind === "link") {
    const l = state.topo.links.find((x) => x.id === sel.id);
    if (!l) return none();
    const p = document.createElement("p");
    p.textContent = t("props.link", {
      a: deviceById(l.a.device).name, pa: l.a.port, b: deviceById(l.b.device).name, pb: l.b.port,
    });
    box.appendChild(p);
    return;
  }
  const d = deviceById(sel.id);
  if (!d) return none();
  const field = (labelKey, prop, maxlen, placeholder) => {
    const label = document.createElement("label");
    const span = document.createElement("span");
    span.textContent = t(labelKey);
    const input = document.createElement("input");
    input.type = "text";
    input.maxLength = maxlen;
    input.value = d[prop];
    if (placeholder) input.placeholder = placeholder;
    input.autocomplete = "off";
    input.spellcheck = false;
    input.addEventListener("input", () => {
      d[prop] = input.value;
      if (prop === "name" && !input.value.trim()) return; // пустое имя не сохраняем
      renderCanvas();
      renderPingSelects();
    });
    label.append(span, input);
    box.appendChild(label);
  };
  field("props.name", "name", 20);
  if (d.type === "pc") {
    field("props.ip", "ip", 18, t("props.ip_ph"));
    field("props.mask", "mask", 18, t("props.mask_ph"));
  } else {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = t("props.switch_note");
    box.appendChild(p);
  }
}
function renderToolState() {
  $("tool-select").classList.toggle("active", state.tool === "select");
  $("tool-connect").classList.toggle("active", state.tool === "connect");
  const hint = $("tool-hint");
  if (state.tool !== "connect") hint.textContent = "";
  else if (state.pending) hint.textContent = t("tools.connect_first", { name: deviceById(state.pending)?.name || "" });
  else hint.textContent = t("tools.connect_hint");
}
function renderPingSelects() {
  const pcs = state.topo.devices.filter((d) => d.type === "pc");
  [["ping-src", 0], ["ping-dst", 1]].forEach(([id, idx]) => {
    const sel = $(id);
    const prev = sel.value;
    sel.replaceChildren();
    pcs.forEach((d) => { const o = document.createElement("option"); o.value = d.id; o.textContent = d.name; sel.appendChild(o); });
    if (pcs.some((d) => d.id === prev)) sel.value = prev;
    else if (pcs[idx] || pcs[0]) sel.value = (pcs[idx] || pcs[0]).id;
  });
  $("ping-run").disabled = pcs.length < 2;
}
function renderProject() {
  $("project-current").textContent = state.project ? t("projects.current", { name: state.project.name }) : "";
}
function renderTaskInfo() {
  const box = $("task-info");
  if (!state.taskId) { box.textContent = t("tasks.none"); $("task-check").disabled = true; return; }
  box.textContent = `${t(`task_items.${state.taskId}.title`)}: ${t(`task_items.${state.taskId}.desc`)}`;
  $("task-check").disabled = false;
}
function renderAll() {
  renderCanvas(); renderProps(); renderToolState(); renderPingSelects(); renderProject(); renderTaskInfo();
}

// ------------------------------------------------------------ мышь
let drag = null;
function svgPoint(evt) {
  const pt = canvas.createSVGPoint();
  pt.x = evt.clientX; pt.y = evt.clientY;
  return pt.matrixTransform(canvas.getScreenCTM().inverse());
}
function onDevicePointerDown(e, d) {
  e.stopPropagation();
  if (state.tool === "connect") {
    if (!state.pending) { state.pending = d.id; }
    else if (state.pending !== d.id) { connect(state.pending, d.id); state.pending = null; }
    else { state.pending = null; }
    renderAll();
    return;
  }
  state.selected = { kind: "device", id: d.id };
  const p = svgPoint(e);
  drag = { id: d.id, dx: d.x - p.x, dy: d.y - p.y, moved: false };
  canvas.setPointerCapture(e.pointerId);
  renderProps(); renderCanvas();
}
canvas.addEventListener("pointermove", (e) => {
  if (!drag) return;
  const d = deviceById(drag.id);
  if (!d) return;
  const p = svgPoint(e);
  d.x = Math.round(Math.min(950, Math.max(50, p.x + drag.dx)));
  d.y = Math.round(Math.min(570, Math.max(40, p.y + drag.dy)));
  drag.moved = true;
  renderCanvas();
});
function endDrag() { drag = null; }
canvas.addEventListener("pointerup", endDrag);
canvas.addEventListener("pointercancel", endDrag);
canvas.addEventListener("pointerdown", () => {
  state.selected = null;
  state.pending = null;
  renderAll();
});
document.addEventListener("keydown", (e) => {
  const tag = (document.activeElement && document.activeElement.tagName) || "";
  if (tag === "INPUT" || tag === "SELECT" || tag === "TEXTAREA") return;
  if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); deleteSelected(); }
  if (e.key === "Escape") { state.pending = null; renderAll(); }
});

// ------------------------------------------------------------ ping
function stepList(steps) {
  const ul = document.createElement("ul");
  ul.className = "steps";
  steps.forEach((s) => {
    const li = document.createElement("li");
    li.className = s.ok ? "" : "bad";
    li.textContent = t(`steps.${s.id}`);
    ul.appendChild(li);
  });
  return ul;
}
async function runPing() {
  const box = $("ping-result");
  box.replaceChildren();
  try {
    const res = await api("POST", "/api/ping", { topology: state.topo, source: $("ping-src").value, target: $("ping-dst").value });
    const head = document.createElement("div");
    head.className = "res-head " + (res.success ? "ok" : "bad");
    head.textContent = t(`ping_codes.${res.code}`, res.params);
    box.append(head, stepList(res.steps));
  } catch (err) { showError(err); }
}

// ------------------------------------------------------------ задания
async function refreshTasks() {
  try {
    const { tasks } = await api("GET", "/api/tasks");
    const sel = $("task-select");
    const prev = sel.value;
    sel.replaceChildren();
    tasks.forEach((id) => { const o = document.createElement("option"); o.value = id; o.textContent = t(`task_items.${id}.title`); sel.appendChild(o); });
    if (tasks.includes(prev)) sel.value = prev;
  } catch (err) { showError(err); }
}
async function loadTask() {
  const id = $("task-select").value;
  if (!id) return;
  if (!window.confirm(t("tasks.confirm_replace"))) return;
  try {
    const res = await api("GET", `/api/tasks/${id}`);
    state.topo = res.topology;
    state.taskId = id;
    state.selected = null; state.pending = null; state.project = null;
    $("task-result").replaceChildren();
    $("ping-result").replaceChildren();
    renderAll();
  } catch (err) { showError(err); }
}
async function checkTask() {
  if (!state.taskId) return;
  const box = $("task-result");
  box.replaceChildren();
  try {
    const res = await api("POST", `/api/tasks/${state.taskId}/check`, { topology: state.topo });
    const head = document.createElement("div");
    head.className = "res-head " + (res.passed ? "ok" : "bad");
    head.textContent = res.passed ? t("tasks.passed") : t("tasks.not_passed");
    const ul = document.createElement("ul");
    ul.className = "steps";
    res.checks.forEach((c) => {
      const li = document.createElement("li");
      li.className = c.ok ? "" : "bad";
      let text = t(`checks.${c.id}`, c.params || {});
      if (!c.ok && c.code) text = `${t(`checks.${c.id}`)}: ${t(`ping_codes.${c.code}`, c.params || {})}`;
      li.textContent = text;
      ul.appendChild(li);
    });
    box.append(head, ul);
  } catch (err) { showError(err); }
}

// ------------------------------------------------------------ проекты
async function refreshProjects() {
  const ul = $("project-list");
  try {
    const { projects } = await api("GET", "/api/projects");
    ul.replaceChildren();
    if (!projects.length) {
      const li = document.createElement("li");
      li.className = "hint";
      li.textContent = t("projects.empty");
      ul.appendChild(li);
      return;
    }
    projects.forEach((p) => {
      const li = document.createElement("li");
      const name = document.createElement("span");
      name.className = "pname";
      name.textContent = p.name;
      const open = document.createElement("button");
      open.className = "btn"; open.textContent = t("projects.load");
      open.addEventListener("click", () => openProject(p.id));
      const del = document.createElement("button");
      del.className = "btn danger"; del.textContent = t("projects.delete");
      del.addEventListener("click", () => deleteProject(p));
      li.append(name, open, del);
      ul.appendChild(li);
    });
  } catch (err) { showError(err); }
}
async function saveProject(asNew) {
  const name = $("project-name").value.trim() || (state.project ? state.project.name : "");
  try {
    const body = { name, topology: state.topo };
    const res = (state.project && !asNew)
      ? await api("PUT", `/api/projects/${state.project.id}`, body)
      : await api("POST", "/api/projects", body);
    state.project = { id: res.project.id, name: res.project.name };
    $("project-name").value = res.project.name;
    toast(t("projects.saved", { name: res.project.name }));
    renderProject();
    await refreshProjects();
  } catch (err) { showError(err); }
}
async function openProject(id) {
  try {
    const { project } = await api("GET", `/api/projects/${id}`);
    state.topo = project.topology;
    state.project = { id: project.id, name: project.name };
    state.taskId = null; state.selected = null; state.pending = null;
    $("project-name").value = project.name;
    $("task-result").replaceChildren();
    $("ping-result").replaceChildren();
    toast(t("projects.loaded", { name: project.name }));
    renderAll();
  } catch (err) { showError(err); }
}
async function deleteProject(p) {
  if (!window.confirm(t("projects.confirm_delete", { name: p.name }))) return;
  try {
    await api("DELETE", `/api/projects/${p.id}`);
    if (state.project && state.project.id === p.id) state.project = null;
    toast(t("projects.deleted"));
    renderProject();
    await refreshProjects();
  } catch (err) { showError(err); }
}

// ------------------------------------------------------------ запуск
$("tool-select").addEventListener("click", () => { state.tool = "select"; state.pending = null; renderAll(); });
$("tool-connect").addEventListener("click", () => { state.tool = "connect"; state.pending = null; renderAll(); });
$("add-pc").addEventListener("click", () => addDevice("pc"));
$("add-switch").addEventListener("click", () => addDevice("switch"));
$("delete-sel").addEventListener("click", deleteSelected);
$("new-sandbox").addEventListener("click", () => {
  if (window.confirm(t("tasks.confirm_replace"))) newSandbox(false);
});
$("ping-run").addEventListener("click", runPing);
$("task-load").addEventListener("click", loadTask);
$("task-check").addEventListener("click", checkTask);
$("project-save").addEventListener("click", () => saveProject(false));
$("project-save-new").addEventListener("click", () => saveProject(true));
$("lang-select").addEventListener("change", (e) => loadLang(e.target.value).catch(showError));

(async function init() {
  let lang = "ru";
  try { lang = localStorage.getItem("netlab.lang") || "ru"; } catch (e) { /* ignore */ }
  if (!["ru", "uz"].includes(lang)) lang = "ru";
  newSandbox(true);
  try { await loadLang(lang); } catch (e) { toast("Failed to load translations", true); }
})();
