// devctl dashboard frontend. No frameworks, no innerHTML with data: every value is
// inserted with textContent, so nothing from history or settings can run as HTML.
"use strict";

const state = { csrf: null, page: null, events: null, seenMax: 0, refreshTimer: null };

const $ = (id) => document.getElementById(id);

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === "class") node.className = value;
    else node.setAttribute(key, value);
  }
  for (const child of children) node.append(child ?? "");
  return node;
}

async function api(path, options = {}) {
  const init = { credentials: "same-origin", headers: {} };
  if (options.body !== undefined) {
    init.method = "POST";
    init.headers["Content-Type"] = "application/json";
    init.headers["X-Devctl-CSRF"] = state.csrf;
    init.body = JSON.stringify(options.body);
  }
  const res = await fetch(path, init);
  if (res.status === 401) {
    location.reload(); // session gone (dashboard restarted): show the login hint
    throw new Error("not logged in");
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function toast(message, bad = false) {
  const box = $("toast");
  box.textContent = message;
  box.className = "toast" + (bad ? " bad" : "");
  box.hidden = false;
  clearTimeout(toast.timer);
  // Slide out, then hide (the CSS animation "toast-out" takes 0.3 s).
  toast.timer = setTimeout(() => {
    box.classList.add("leaving");
    toast.timer = setTimeout(() => { box.hidden = true; }, 300);
  }, 4500);
}

// Count a number up from 0 (respects reduced motion).
function countUp(node, target) {
  const end = Number(target) || 0;
  if (matchMedia("(prefers-reduced-motion: reduce)").matches || end === 0) { node.textContent = end; return; }
  const start = performance.now(), duration = 600;
  const step = (now) => {
    const t = Math.min(1, (now - start) / duration);
    node.textContent = Math.round(end * (1 - Math.pow(1 - t, 3)));
    if (t < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

// Placeholder rows while a table loads.
function skeletonRows(tbody, columns, rows = 4) {
  tbody.replaceChildren(...Array.from({ length: rows }, () =>
    el("tr", { class: "skeleton-row" }, ...Array.from({ length: columns }, () => el("td", {}, el("div", { class: "skeleton" }))))));
}

// ---- formatting ---------------------------------------------------------------------

const SOURCES = { cli: "Terminal", dashboard: "Dashboard", timer: "Timer", hook: "Git hook" };

function fmtTime(ts) {
  const d = new Date(ts);
  return isNaN(d) ? ts : d.toLocaleString();
}

function what(ev) {
  return ev.type === "action" ? ev.action.replace(".", " ") : ev.code;
}

function details(ev) {
  return ev.type === "action" ? (ev.args || []).join(" ") : ev.message || "";
}

function status(ev) {
  return ev.type === "action" ? ev.result : ev.level;
}

function historyRow(ev, full) {
  const s = status(ev);
  const isNew = state.seenMax > 0 && ev.id > state.seenMax;
  const cells = [
    el("td", {}, fmtTime(ev.ts)),
    el("td", {}, SOURCES[ev.source] || ev.source),
  ];
  if (full) cells.push(el("td", {}, el("span", { class: "badge" }, ev.type)));
  cells.push(el("td", {}, what(ev)));
  if (full) cells.push(el("td", { class: "details" }, details(ev)));
  cells.push(el("td", {}, el("span", { class: "pill r-" + s }, s)));
  return el("tr", isNew ? { class: "new" } : {}, ...cells);
}

// ---- pages --------------------------------------------------------------------------

const pages = {
  async overview() {
    const data = await api("/api/overview");
    const version = data.version.version || data.version.error || "?";
    $("ov-version").textContent = version;
    $("ov-version-foot").textContent = "devctl " + version;
    countUp($("ov-actions"), data.history.action || 0);
    countUp($("ov-alerts"), data.history.alert || 0);
    const coming = $("ov-coming");
    coming.replaceChildren(...data.coming.map((c) =>
      el("div", { class: "card soon" },
        el("div", { class: "label" }, el("span", { class: "badge" }, `module ${c.module}`)),
        el("div", { class: "value" }, c.title),
        el("div", { class: "muted" }, c.text))));
    try {
      const st = await api("/api/status");
      const card = (label, value, good) => el("div", { class: "card status-card " + (good ? "good" : "bad") },
        el("span", { class: "dot" }),
        el("div", {}, el("div", { class: "label" }, label), el("div", { class: "value small" }, value)));
      $("ov-status").replaceChildren(
        card("Docker", st.services.docker, st.services.docker === "active"),
        card("Caddy (web)", st.services.caddy, st.services.caddy === "active"),
        card("PHP-FPM", st.services.php_fpm, st.services.php_fpm === "active"),
        card("Memory", st.memory, true),
        card("Disk", st.disk, true),
        ...st.sites.map((s) => card(s.domain, s.health, s.health.startsWith("ok") || s.health === "stopped")));
    } catch (err) { $("ov-status").replaceChildren(el("p", { class: "error" }, err.message)); }
    const recent = await api("/api/history?limit=8");
    $("ov-recent").replaceChildren(...recent.events.map((ev) => historyRow(ev, false)));
    $("ov-recent-empty").hidden = recent.events.length > 0;
    markSeen(recent.events);
  },

  async sites() {
    if (!state.reposWarmed) { state.reposWarmed = true; api("/api/github/repos").catch(() => {}); }
    const sites = await api("/api/sites");
    $("site-rows").replaceChildren(...sites.map((s) => {
      const running = s.state === "running";
      const actions = el("div", { class: "row-actions" },
        el("a", { class: "link", href: s.url, target: "_blank", rel: "noopener" }, "Open"),
        button(running ? "Stop" : "Start", () => siteAction(s.name, running ? "stop" : "start"), "ghost"),
        ...(s.kind === "laravel" || s.kind === "proxy" ? [button(s.db_engine ? "Database…" : "Add database…", () => openDbForm(s), "ghost")] : []),
        button("Delete…", () => siteDelete(s), "danger"));
      if (!s.url) actions.firstChild.remove(); // no website (plain Java)
      return el("tr", {},
        el("td", {}, el("strong", {}, s.name), el("br"), el("span", { class: "muted small" }, s.url || s.kind)),
        el("td", {}, el("span", { class: "badge" }, s.category)),
        el("td", {}, s.db_engine || "—"),
        el("td", {}, el("span", { class: "pill state-" + s.state }, s.state)),
        el("td", {}, actions));
    }));
    $("site-empty").hidden = sites.length > 0;
  },

  async history() {
    const form = new FormData($("hist-filter"));
    const params = new URLSearchParams({ limit: "300" });
    for (const [key, value] of form) if (value) params.set(key, value);
    const data = await api("/api/history?" + params);
    $("hist-rows").replaceChildren(...data.events.map((ev) => historyRow(ev, true)));
    $("hist-empty").hidden = data.events.length > 0;
    markSeen(data.events);
  },

  async databases() {
    const [servers, dbs] = await Promise.all([api("/api/db"), api("/api/db/databases")]);
    $("db-servers").replaceChildren(...servers.map((s) => {
      const running = s.state === "running";
      return el("div", { class: "card server-card status-card " + (running ? "good" : "") },
        el("div", {},
          el("div", { class: "label" }, s.id),
          el("div", { class: "value" }, s.engine),
          el("div", { class: "meta" },
            el("span", { class: "pill state-" + (running ? "running" : "stopped") }, s.state),
            el("code", {}, `127.0.0.1:${s.port}`),
            el("span", { class: "muted small" }, s.users ? `used by ${s.users} site(s)` : "")),
          el("div", { class: "row-actions" },
            button(running ? "Stop" : "Start", () => runJob("/api/db/server", { server: s.id, action: running ? "stop" : "start" }), "ghost"))));
    }));
    $("db-servers-empty").hidden = servers.length > 0;
    $("db-rows").replaceChildren(...dbs.map((d) => el("tr", {},
      el("td", {}, el("strong", {}, d.name)),
      el("td", {}, el("span", { class: "badge" }, d.server)),
      el("td", {}, d.sites.length
        ? el("span", {}, ...d.sites.flatMap((s, i) => [i ? ", " : "", el("a", { class: "link", href: "#sites" }, s)]),
            d.sites.length > 1 ? el("span", { class: "pill busy" }, "shared") : "")
        : el("span", { class: "muted" }, "—")),
      el("td", {}, d.created),
      el("td", {}, el("div", { class: "row-actions" },
        button("Connect…", () => showCreds(d.name), "ghost"),
        button("Export", () => exportDb(d.name), "ghost"),
        button("Import…", () => openImport(d.name), "ghost"))))));
    $("db-empty").hidden = dbs.length > 0;
  },

  async services() {
    const list = await api("/api/svc");
    $("svc-cards").replaceChildren(...list.map((s) => {
      const running = s.state === "running";
      const card = el("div", { class: "card status-card " + (running ? "good" : "") },
        el("div", {},
          el("div", { class: "label" }, s.name + " · " + s.version),
          el("h3", {}, s.title),
          el("div", { class: "meta" }, el("span", { class: "pill state-" + (running ? "running" : "stopped") }, s.state)),
          s.connect !== "-" ? el("div", { class: "connect" }, s.connect) : "",
          el("div", { class: "row-actions" },
            button(running ? "Stop" : "Start", () => runJob("/api/svc/action", { name: s.name, action: running ? "stop" : "start" }), running ? "ghost" : "primary"))));
      if (running) {
        api("/api/svc/info?name=" + encodeURIComponent(s.name)).then((info) => {
          if (info.ui) card.querySelector(".row-actions").prepend(el("a", { class: "link", href: info.ui, target: "_blank", rel: "noopener" }, "Open"));
        }).catch(() => {});
      }
      return card;
    }));
  },

  async logs() {
    const sites = await api("/api/sites");
    const select = $("logs-site");
    const current = select.value;
    select.replaceChildren(...sites.map((s) => el("option", { value: s.name }, s.name)));
    if (current && sites.some((s) => s.name === current)) select.value = current;
    $("logs-empty").hidden = sites.length > 0;
    await loadLogs();
  },

  async setup() {
    const gh = await api("/api/github");
    const pill = $("gh-pill");
    $("gh-install").hidden = gh.gh_installed;
    $("gh-login").hidden = !gh.gh_installed || gh.logged_in || state.ghSigningIn;
    $("gh-logout").hidden = !gh.logged_in;
    $("gh-token-box").hidden = !gh.gh_installed || gh.logged_in;
    if (gh.logged_in) {
      pill.textContent = "connected"; pill.className = "pill ok";
      $("gh-text").textContent = `Signed in as ${gh.user}. Private repositories clone and push with this account.`;
    } else if (gh.gh_installed) {
      pill.textContent = "not connected"; pill.className = "pill busy";
      $("gh-text").textContent = "Sign in through your browser: GitHub shows you what devctl asks for, and no password goes through this page.";
    } else {
      pill.textContent = "not installed"; pill.className = "pill bad";
      $("gh-text").textContent = "devctl uses the official GitHub CLI (Fedora package gh). Installing asks for your administrator password.";
    }
    const form = $("git-form");
    if (document.activeElement?.form !== form) {
      form.elements.name.value = gh.git_name || "";
      form.elements.email.value = gh.git_email || "";
    }
    const gp = $("git-pill");
    gp.textContent = gh.git_name && gh.git_email ? "set" : "not set";
    gp.className = "pill " + (gh.git_name && gh.git_email ? "ok" : "busy");
  },

  async settings() {
    const rows = await api("/api/settings");
    $("set-rows").replaceChildren(...rows.map((r) =>
      el("tr", {}, el("td", {}, el("code", {}, r.key)), el("td", {}, r.value || "(empty)"),
        el("td", {}, el("span", { class: "badge" }, r.from)))));
  },
};

// Tables that show placeholder rows while their page loads (not on live refreshes).
const SKELETONS = { overview: ["ov-recent", 4], sites: ["site-rows", 5], history: ["hist-rows", 6], settings: ["set-rows", 3], databases: ["db-rows", 4] };

async function show(page, { refresh = false } = {}) {
  if (!pages[page]) page = "overview";
  const changed = state.page !== page;
  state.page = page;
  for (const section of document.querySelectorAll(".page")) section.hidden = section.id !== "page-" + page;
  for (const link of document.querySelectorAll("nav a")) link.classList.toggle("active", link.dataset.page === page);
  if (changed && !refresh && SKELETONS[page]) {
    const [tbody, cols] = SKELETONS[page];
    if (!$(tbody).children.length) skeletonRows($(tbody), cols);
  }
  try {
    await pages[page]();
  } catch (err) {
    toast(err.message, true);
  }
}

// ---- live updates (Server-Sent Events) -----------------------------------------------

// Remember the newest id shown, so rows arriving later can be highlighted.
function markSeen(events) {
  for (const ev of events) state.seenMax = Math.max(state.seenMax, ev.id);
}

// Many events can arrive at once (e.g. after a clear); re-render once, shortly after.
function refreshSoon() {
  clearTimeout(state.refreshTimer);
  state.refreshTimer = setTimeout(() => show(state.page, { refresh: true }), 300);
}

async function connectLive() {
  const newest = await api("/api/history?limit=1");
  const after = newest.events.length ? newest.events[0].id : 0;
  markSeen(newest.events);
  const source = new EventSource("/api/events?after=" + after);
  const live = $("live");
  source.addEventListener("hello", () => { live.textContent = "live"; live.classList.add("on"); });
  source.addEventListener("reset", () => { state.seenMax = 0; refreshSoon(); });
  source.addEventListener("history", (msg) => {
    const ev = JSON.parse(msg.data);
    if (ev.type === "alert") toast(`${ev.level}: ${ev.message}`, ev.level !== "info");
    refreshSoon();
  });
  source.onerror = () => { live.textContent = "reconnecting…"; live.classList.remove("on"); };
  state.events = source;
}

// ---- sites -------------------------------------------------------------------------

function button(label, onclick, cls = "") {
  // (cls: "", "ghost" or "danger")
  const b = el("button", cls ? { class: cls, type: "button" } : { type: "button" }, label);
  b.addEventListener("click", onclick);
  return b;
}

// Follow a background job's output until it finishes.
async function followJob(jobId) {
  const box = $("job"), log = $("job-log"), pill = $("job-state");
  box.hidden = false;
  box.className = "card job reveal running";
  log.replaceChildren();
  box.scrollIntoView({ behavior: "smooth", block: "nearest" });
  let from = 0;
  for (;;) {
    const j = await api(`/api/jobs/${jobId}?from=${from}`);
    $("job-title").textContent = j.title;
    if (j.lines.length) {
      log.append(...j.lines.map((line) => el("span", { class: "line" }, line + "\n")));
      log.scrollTop = log.scrollHeight;
    }
    from = j.next;
    pill.textContent = j.done ? (j.exit === 0 ? "done" : `failed (exit ${j.exit})`) : "running";
    pill.className = "pill " + (j.done ? (j.exit === 0 ? "ok" : "bad") : "busy");
    if (j.done) {
      box.className = "card job " + (j.exit === 0 ? "done" : "failed");
      toast(j.exit === 0 ? `${j.title}: done` : `${j.title}: failed`, j.exit !== 0);
      show("sites", { refresh: true });
      return j.exit;
    }
    await new Promise((r) => setTimeout(r, 800));
  }
}

async function siteAction(name, action) {
  try {
    const { job } = await api("/api/sites/action", { body: { name, action } });
    await followJob(job);
  } catch (err) { toast(err.message, true); }
}

async function siteDelete(site) {
  const { name, db_name: db, db_server: server } = site;
  let check = null, note = "";
  if (db && server) {
    // Only offer to delete a database no other site uses.
    let others = [];
    try {
      const dbs = await api("/api/db/databases");
      const d = dbs.find((x) => x.name === db && x.server === server);
      others = (d?.sites || []).filter((n) => n !== name);
    } catch { /* unknown: keep it */ others = ["(could not check)"]; }
    if (others.length) note = `Its database ${db} is kept: ${others.join(", ")} also use${others.length > 1 ? "" : "s"} it.`;
    else check = { label: `Also delete its database ${db} on ${server} — every table and all data, its user and password. This cannot be undone.` };
  }
  const answer = await confirmTyped({
    title: `Delete ${name}`,
    text: "Removes devctl's setup: web server config, the local name, SELinux labels, the web server's access. The project folder is kept." +
      (db ? " The database is kept unless you tick the box." : ""),
    expected: name, check, note,
  });
  if (answer === null) return;
  const typed = check ? answer.typed : answer;
  const withDb = check ? answer.checked : false;
  try {
    const { job } = await api("/api/sites/action", { body: { name, action: "delete", confirm: typed, with_db: withDb } });
    await followJob(job);
  } catch (err) { toast(err.message, true); }
}

// Poll a job until it finishes; onLines gets each batch of new output lines.
async function waitJob(jobId, onLines) {
  let from = 0;
  for (;;) {
    const j = await api(`/api/jobs/${jobId}?from=${from}`);
    if (j.lines.length && onLines) onLines(j.lines);
    from = j.next;
    if (j.done) return j;
    await new Promise((r) => setTimeout(r, 800));
  }
}

function setupSetupPage() {
  $("gh-install").addEventListener("click", async () => {
    try {
      const { job } = await api("/api/setup/github/install", { body: {} });
      toast("Installing the GitHub CLI… (a password dialog may appear)");
      const j = await waitJob(job);
      toast(j.exit === 0 ? "GitHub CLI installed" : "Installation failed", j.exit !== 0);
    } catch (err) { toast(err.message, true); }
    show("setup", { refresh: true });
  });

  $("gh-login").addEventListener("click", async () => {
    const device = $("gh-device");
    state.ghSigningIn = true;
    $("gh-login").hidden = true;
    $("gh-code").textContent = "····-····";
    device.hidden = false;
    try {
      const { job } = await api("/api/setup/github/login", { body: {} });
      const j = await waitJob(job, (lines) => {
        for (const line of lines) {
          const code = line.match(/\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/);
          if (code) $("gh-code").textContent = code[1];
        }
      });
      toast(j.exit === 0 ? "Connected to GitHub" : "GitHub sign-in did not finish", j.exit !== 0);
    } catch (err) { toast(err.message, true); }
    state.ghSigningIn = false;
    device.hidden = true;
    show("setup", { refresh: true });
  });

  $("gh-copy").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText($("gh-code").textContent);
      toast("Code copied");
    } catch { toast("Copy failed: select the code and copy it", true); }
  });

  $("gh-logout").addEventListener("click", async () => {
    const typed = await confirmTyped({ title: "Sign out of GitHub", text: "Private repositories stop cloning, pulling and pushing until you sign in again.", expected: "github" });
    if (typed === null) return;
    try { await api("/api/setup/github/logout", { body: {} }); toast("Signed out of GitHub"); }
    catch (err) { toast(err.message, true); }
    show("setup", { refresh: true });
  });

  $("gh-token-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const input = e.target.elements.token;
    try {
      await api("/api/setup/github/token", { body: { token: input.value.trim() } });
      toast("Connected to GitHub with your token");
    } catch (err) { toast(err.message, true); }
    input.value = ""; // never keep a secret in the page
    show("setup", { refresh: true });
  });

  $("git-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const data = Object.fromEntries(new FormData(e.target));
    try { await api("/api/setup/git-identity", { body: data }); toast("Git identity saved"); }
    catch (err) { toast(err.message, true); }
    document.activeElement?.blur();
    show("setup", { refresh: true });
  });
}

// Upload a dump with a real progress bar (fetch has no upload progress). Returns its id.
function uploadDump(file, box) {
  const bar = box.querySelector(".progress span"), label = box.querySelector("small");
  box.hidden = false;
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", "/api/upload");
    xhr.setRequestHeader("X-Devctl-CSRF", state.csrf);
    xhr.setRequestHeader("X-Filename", file.name);
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.upload.onprogress = (e) => {
      if (!e.lengthComputable) return;
      bar.style.transform = `scaleX(${e.loaded / e.total})`;
      label.textContent = `Uploading ${file.name}: ${Math.round((100 * e.loaded) / e.total)}%`;
    };
    xhr.onload = () => {
      const data = JSON.parse(xhr.responseText || "{}");
      if (xhr.status === 200) { label.textContent = `Uploaded ${file.name}`; resolve(data.upload); }
      else reject(new Error(data.error || `upload failed (HTTP ${xhr.status})`));
    };
    xhr.onerror = () => reject(new Error("upload failed"));
    xhr.send(file);
  });
}

// "Connect to": a new database, or one devctl already made (another site's, or one left
// from a deleted site). The existing one is sent as engine "use:NAME".
function ensureDbPicker(form) {
  if (form.elements.dbmode) return;
  const engineLabel = form.elements.engine.closest("label");
  const mode = el("label", {}, "Connect to ",
    el("select", { name: "dbmode" },
      el("option", { value: "new" }, "A new database for this site"),
      el("option", { value: "existing" }, "A database I already have")));
  const pick = el("label", { class: "existing-pick" }, "Existing database ", el("select", { name: "existing" }));
  pick.hidden = true;
  engineLabel.before(mode, pick);
}

function engineValue(form) {
  const mode = form.elements.dbmode;
  if (mode && mode.value === "existing" && form.elements.existing.value) return "use:" + form.elements.existing.value;
  return form.elements.engine.value;
}

// Fill the "Existing database" list (name, server, which sites already use it).
async function addExistingDbs(form) {
  ensureDbPicker(form);
  const mode = form.elements.dbmode, select = form.elements.existing;
  let dbs = [];
  try { dbs = await api("/api/db/databases"); } catch { /* the list is optional */ }
  select.replaceChildren(...dbs.map((d) => el("option", { value: d.name },
    `${d.name} — ${d.server}${d.sites?.length ? " · used by " + d.sites.join(", ") : " · not used"}`)));
  const has = dbs.length > 0;
  mode.options[1].disabled = !has;
  mode.options[1].textContent = has ? "A database I already have" : "A database I already have (none yet)";
  if (!has) mode.value = "new";
  mode.dispatchEvent(new Event("change"));
}

// Show the file field only for "Import a dump file"; hide the fill choice without a database.
function wireDbFields(form) {
  ensureDbPicker(form);
  const sync = (e) => {
    const existing = form.elements.dbmode.value === "existing";
    form.elements.engine.closest("label").hidden = existing;
    form.querySelector(".existing-pick").hidden = !existing;
    const engine = engineValue(form), none = engine === "none";
    // An existing database keeps its tables: default to "leave it as is".
    if (existing && e && e.target !== form.elements.fill) form.elements.fill.value = "none";
    form.elements.fill.closest("label").hidden = none;
    form.querySelector(".upload").hidden = none || form.elements.fill.value !== "import";
    form.elements.dump.required = !form.querySelector(".upload").hidden;
  };
  for (const name of ["dbmode", "existing", "engine", "fill"]) form.elements[name].addEventListener("change", sync);
  sync();
}

// Collect engine/fill (+ uploaded file id) from a form with database fields.
async function dbChoice(form) {
  const engine = engineValue(form), fill = form.elements.fill.value;
  const out = { engine };
  if (engine !== "none") out.fill = fill;
  if (engine !== "none" && fill === "import") {
    const file = form.elements.dump.files[0];
    if (!file) throw new Error("choose the dump file to import");
    out.upload = await uploadDump(file, form.querySelector(".upload-progress"));
  }
  return out;
}

function openDbForm(site) {
  const form = $("db-form");
  form.elements.name.value = site.name;
  $("db-form-site").textContent = site.name;
  form.elements.engine.value = "auto";
  form.elements.dbmode.value = "new";
  form.querySelector(".upload-progress").hidden = true;
  addExistingDbs(form);
  form.hidden = false;
  form.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

function setupDbForm() {
  const form = $("db-form");
  wireDbFields(form);
  $("db-cancel").addEventListener("click", () => { form.hidden = true; });
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      const body = { name: form.elements.name.value, ...(await dbChoice(form)) };
      form.hidden = true;
      const { job } = await api("/api/sites/db", { body });
      await followJob(job);
    } catch (err) { toast(err.message, true); }
  });
}

// Start a background job and show its output in the job panel (on the Sites page layout).
async function runJob(url, body) {
  try {
    const { job } = await api(url, { body });
    toast("Started… (a password dialog may appear)");
    const j = await waitJob(job);
    const last = j.lines.filter((l) => l.trim()).slice(-1)[0] || "";
    toast(j.exit === 0 ? (last.replace(/^[✓→–!] /, "") || "Done") : `Failed: ${last}`, j.exit !== 0);
    show(state.page, { refresh: true });
    return j;
  } catch (err) { toast(err.message, true); }
}

async function showCreds(name) {
  try {
    const c = await api("/api/db/creds?name=" + encodeURIComponent(name));
    $("creds-name").textContent = name;
    const rows = [["Engine", c.engine], ["Host", c.host], ["Port", String(c.port)], ["Database", c.database], ["User", c.username], ["Password", c.password]];
    $("creds-rows").replaceChildren(...rows.flatMap(([k, v]) => {
      const secret = k === "Password";
      const code = el("code", secret ? { class: "masked" } : {}, secret ? "••••••••••••" : v);
      const actions = el("div", { class: "row-actions" });
      if (secret) actions.append(button("Show", (e) => { code.textContent = v; code.className = ""; e.target.remove(); }, "ghost"));
      actions.append(button("Copy", async () => {
        try { await navigator.clipboard.writeText(v); toast(`${k} copied`); } catch { toast("Copy failed", true); }
      }, "ghost"));
      return [el("span", { class: "muted" }, k), code, actions];
    }));
    $("creds").hidden = false;
    $("creds").scrollIntoView({ behavior: "smooth", block: "nearest" });
  } catch (err) { toast(err.message, true); }
}

async function exportDb(name) {
  const j = await runJob("/api/db/export", { name });
  const line = j && j.lines.find((l) => l.includes("Exported"));
  const file = line && line.match(/\/([^/\s]+\.gz)/);
  if (file) {
    const a = el("a", { href: "/api/exports/" + file[1], download: file[1] });
    document.body.append(a); a.click(); a.remove();
  }
}

function openImport(name) {
  const form = $("dbimport-form");
  form.elements.name.value = name;
  $("dbimport-name").textContent = name;
  form.querySelector(".upload-progress").hidden = true;
  form.hidden = false;
  form.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

function setupDatabasesPage() {
  const nf = $("dbnew-form");
  $("db-new").addEventListener("click", () => { nf.hidden = false; nf.elements.name.focus(); });
  $("dbnew-cancel").addEventListener("click", () => { nf.hidden = true; });
  nf.addEventListener("submit", async (e) => {
    e.preventDefault();
    nf.hidden = true;
    await runJob("/api/db/create", Object.fromEntries(new FormData(nf)));
  });
  const imf = $("dbimport-form");
  $("dbimport-cancel").addEventListener("click", () => { imf.hidden = true; });
  imf.addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = imf.elements.name.value;
    try {
      const upload = await uploadDump(imf.elements.dump.files[0], imf.querySelector(".upload-progress"));
      const typed = await confirmTyped({ title: `Import into ${name}`, text: "If the database already has tables, the import adds to or overwrites them.", expected: name });
      if (typed === null) return;
      imf.hidden = true;
      await runJob("/api/db/import", { name, upload, confirm: typed });
    } catch (err) { toast(err.message, true); }
  });
  $("creds-close").addEventListener("click", () => { $("creds").hidden = true; $("creds-rows").replaceChildren(); });
}

// ---- logs ---------------------------------------------------------------------------

async function loadLogs() {
  const form = $("logs-form"), out = $("logs-out");
  const site = form.elements.site.value;
  if (!site) { out.replaceChildren(); return; }
  const params = new URLSearchParams({ site, part: form.elements.part.value, lines: form.elements.lines.value });
  try {
    const { lines } = await api("/api/logs?" + params);
    const atBottom = out.scrollHeight - out.scrollTop - out.clientHeight < 40;
    const old = state.logLines || [];
    const fresh = old.length && lines.length && lines[0] === old[0] ? lines.slice(old.length) : null;
    if (fresh) out.append(...fresh.map((l) => el("span", { class: "new" }, l + "\n")));
    else out.replaceChildren(lines.length ? lines.join("\n") + "\n" : "(nothing yet)");
    state.logLines = lines;
    if (atBottom || !fresh) out.scrollTop = out.scrollHeight;
  } catch (err) { out.textContent = err.message; }
}

function setupLogsPage() {
  const form = $("logs-form");
  form.addEventListener("change", () => { state.logLines = null; loadLogs(); });
  setInterval(() => {
    if (state.page === "logs" && form.elements.follow.checked && !document.hidden) loadLogs();
  }, 2500);
}

// Repositories: shown at once from devctl's cache, refreshed in the background when stale.
const repoState = { list: [], loading: false };

function renderRepos() {
  const select = $("clone-form").elements.repo;
  const q = $("repo-filter").value.trim().toLowerCase();
  const keep = select.value;
  const shown = repoState.list.filter((r) => !q || r.repo.toLowerCase().includes(q) || (r.language || "").toLowerCase().includes(q));
  select.replaceChildren(...shown.map((r) =>
    el("option", { value: r.repo }, `${r.repo}${r.private ? "  🔒" : ""}${r.language ? "  · " + r.language : ""}`)));
  if (shown.some((r) => r.repo === keep)) select.value = keep;
  else if (shown.length) select.selectedIndex = 0;
  $("clone-status").textContent = repoState.list.length
    ? `${shown.length} of ${repoState.list.length} repositories${repoState.loading ? " · updating…" : ""}`
    : (repoState.loading ? "Loading your repositories…" : "No repositories.");
}

async function loadRepos({ refresh = false } = {}) {
  const box = $("clone-form").querySelector(".repo-pick");
  if (!refresh) {
    try { repoState.list = await api("/api/github/repos?cached=1"); renderRepos(); } catch { /* no cache yet */ }
  }
  repoState.loading = true;
  box.classList.add("loading");
  renderRepos();
  try {
    repoState.list = await api("/api/github/repos" + (refresh ? "?refresh=1" : ""));
  } catch (err) {
    if (!repoState.list.length) {
      $("clone-status").textContent = /signed in/.test(err.message)
        ? "Not signed in to GitHub: open Setup and sign in, then come back."
        : err.message;
    }
  } finally {
    repoState.loading = false;
    box.classList.remove("loading");
    if (repoState.list.length) renderRepos();
  }
}

function setupCloneForm() {
  const form = $("clone-form");
  $("site-clone").addEventListener("click", () => {
    form.hidden = false;
    addExistingDbs(form);
    loadRepos();
    $("repo-filter").focus();
  });
  $("repo-filter").addEventListener("input", renderRepos);
  $("repo-refresh").addEventListener("click", () => loadRepos({ refresh: true }));
  $("clone-cancel").addEventListener("click", () => { form.hidden = true; });
  wireDbFields(form);
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      const data = { repo: form.elements.repo.value, category: form.elements.category.value, ...(await dbChoice(form)) };
      if (form.elements.name.value) data.name = form.elements.name.value;
      form.hidden = true;
      const { job } = await api("/api/sites/clone", { body: data });
      await followJob(job);
    } catch (err) { toast(err.message, true); }
  });
}

function setupSiteForm() {
  const form = $("site-form");
  $("site-new").addEventListener("click", () => {
    form.hidden = false;
    form.elements.name.focus();
    addExistingDbs(form).then(syncEngines);
  });
  $("site-cancel").addEventListener("click", () => { form.hidden = true; });
  form.elements.name.addEventListener("input", () => { $("site-form-host").textContent = form.elements.name.value || "name"; });
  // Only offer the databases the chosen template supports.
  ensureDbPicker(form);
  const syncEngines = () => {
    const allowed = form.elements.template.selectedOptions[0].dataset.db.split(" ");
    const hasDb = allowed.some((v) => v !== "none");
    const mode = form.elements.dbmode;
    if (!hasDb) mode.value = "new";
    mode.closest("label").hidden = !hasDb;
    const existing = mode.value === "existing";
    form.elements.engine.closest("label").hidden = existing;
    form.querySelector(".existing-pick").hidden = !existing;
    for (const opt of form.elements.engine.options) opt.hidden = !allowed.includes(opt.value);
    if (!allowed.includes(form.elements.engine.value)) form.elements.engine.value = allowed[0];
  };
  form.elements.template.addEventListener("change", syncEngines);
  form.elements.dbmode.addEventListener("change", syncEngines);
  syncEngines();
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const { name, category, template } = Object.fromEntries(new FormData(form));
    const data = { name, category, template, engine: engineValue(form) };
    form.hidden = true;
    try {
      const { job } = await api("/api/sites/create", { body: data });
      await followJob(job);
    } catch (err) { toast(err.message, true); }
  });
}

// ---- typed confirmation dialog -------------------------------------------------------

// check: optional checkbox {label} (unchecked by default); note: optional text under it.
// Resolves to the typed text (or null); with a checkbox, to {typed, checked}.
function confirmTyped({ title, text, expected, check, note }) {
  const dialog = $("confirm-dialog");
  const input = $("confirm-input");
  const ok = $("confirm-ok");
  const box = $("confirm-check");
  $("confirm-check-row").hidden = !check;
  $("confirm-check-label").textContent = check?.label || "";
  $("confirm-check-note").hidden = !note;
  $("confirm-check-note").textContent = note || "";
  box.checked = false;
  $("confirm-title").textContent = title;
  $("confirm-text").textContent = text;
  $("confirm-expected").textContent = expected;
  $("confirm-error").hidden = true;
  input.value = "";
  ok.disabled = true;
  input.oninput = () => { ok.disabled = input.value !== expected; };
  dialog.showModal();
  input.focus();
  return new Promise((resolve) => {
    dialog.onclose = () => {
      const typed = dialog.returnValue === "ok" ? input.value : null;
      resolve(check && typed !== null ? { typed, checked: box.checked } : typed);
    };
  });
}

async function clearHistory() {
  const typed = await confirmTyped({
    title: "Clear history",
    text: "This permanently deletes every recorded action and alert. The clear itself is recorded.",
    expected: "history",
  });
  if (typed === null) return;
  try {
    await api("/api/history/clear", { body: { confirm: typed } });
    toast("History cleared");
  } catch (err) {
    toast(err.message, true);
  }
}

// ---- start --------------------------------------------------------------------------

async function start() {
  state.csrf = (await api("/api/session")).csrf;
  $("hist-clear").addEventListener("click", clearHistory);
  setupSiteForm();
  setupCloneForm();
  setupSetupPage();
  setupDbForm();
  setupDatabasesPage();
  setupLogsPage();
  $("hist-filter").addEventListener("input", () => show("history"));
  $("hist-filter").addEventListener("submit", (e) => e.preventDefault());
  window.addEventListener("hashchange", () => show(location.hash.slice(1)));
  await show(location.hash.slice(1) || "overview");
  connectLive();
}

start().catch((err) => toast(err.message, true));
