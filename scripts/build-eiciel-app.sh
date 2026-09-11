#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel Dashboard — Electron app builder
#  Produces: ./eiciel-app-dist/EicielDashboard-linux-x64/
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/eiciel-app"
OUT="$ROOT/eiciel-app-dist"

echo "═══════════════════════════════════════════════════════════════"
echo "  Eiciel Dashboard builder"
echo "  Source: $SRC"
echo "  Output: $OUT"
echo "═══════════════════════════════════════════════════════════════"

command -v node >/dev/null || { echo "❌ node not found"; exit 1; }
command -v npm  >/dev/null || { echo "❌ npm not found";  exit 1; }

rm -rf "$SRC" "$OUT"
mkdir -p "$SRC"
cd "$SRC"

# ─────────────────────────────────────────────────────────────────
# 1. package.json
# ─────────────────────────────────────────────────────────────────
cat > package.json <<'EOF'
{
  "name": "eiciel-dashboard",
  "version": "1.0.0",
  "description": "Eiciel Server containment control panel",
  "main": "main.js",
  "scripts": {
    "start": "electron .",
    "build": "electron-packager . EicielDashboard --platform=linux --arch=x64 --out=../eiciel-app-dist --overwrite --no-prune"
  },
  "devDependencies": {
    "electron": "^28.0.0",
    "electron-packager": "^17.1.2"
  }
}
EOF

# ─────────────────────────────────────────────────────────────────
# 2. main.js — the actual backend
# ─────────────────────────────────────────────────────────────────
cat > main.js <<'MAIN_EOF'
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const { execFile, spawn } = require('child_process');
const fs = require('fs');
const fsp = require('fs').promises;
const path = require('path');
const os = require('os');

const CONFIG = '/etc/eiciel/config.env';
const INCIDENTS = '/var/lib/incidents';
const CONTAIN = '/usr/local/sbin/eiciel-contain.sh';

function exec(cmd, args = [], opts = {}) {
  return new Promise(resolve => {
    execFile(cmd, args, { timeout: 30000, ...opts }, (err, stdout, stderr) => {
      resolve({ ok: !err, stdout: stdout || '', stderr: stderr || '', err: err ? err.message : null });
    });
  });
}

function parseEnvFile(text) {
  const out = {};
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const k = line.slice(0, eq).trim();
    let v = line.slice(eq + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    out[k] = v;
  }
  return out;
}

function isRoot() { return process.getuid && process.getuid() === 0; }

async function getConfig() {
  try {
    const text = await fsp.readFile(CONFIG, 'utf8');
    return { ok: true, data: parseEnvFile(text) };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function getContainState() {
  const nft = await exec('nft', ['list', 'table', 'inet', 'eiciel_contain']);
  const containActive = nft.ok;

  const cfg = await getConfig();
  const wanted = (cfg.data && cfg.data.STOP_SERVICES || '').split(/\s+/).filter(Boolean);
  const services = [];
  for (const s of wanted) {
    const r = await exec('systemctl', ['is-active', s]);
    services.push({ name: s, active: r.stdout.trim() === 'active' });
  }

  const watcher = await exec('systemctl', ['is-active', 'eiciel-watch']);
  const auditd  = await exec('systemctl', ['is-active', 'auditd']);
  const f2b     = await exec('systemctl', ['is-active', 'fail2ban']);

  return {
    containActive,
    services,
    watcher: watcher.stdout.trim(),
    auditd:  auditd.stdout.trim(),
    fail2ban: f2b.stdout.trim(),
    isRoot: isRoot(),
  };
}

async function listIncidents() {
  try {
    const entries = await fsp.readdir(INCIDENTS, { withFileTypes: true });
    const dirs = entries.filter(e => e.isDirectory()).map(e => e.name).sort().reverse();
    const out = [];
    for (const d of dirs.slice(0, 50)) {
      const full = path.join(INCIDENTS, d);
      const logPath = path.join(full, 'containment.log');
      let size = 0, mtime = 0;
      try { const s = await fsp.stat(full); mtime = s.mtimeMs; } catch {}
      try { const s = await fsp.stat(logPath); size = s.size; } catch {}
      out.push({ id: d, path: full, logSize: size, mtime });
    }
    return { ok: true, incidents: out };
  } catch (e) {
    return { ok: true, incidents: [], error: e.message };
  }
}

async function readIncidentLog(id) {
  if (!/^[0-9TZ:+-]+-\d+$/.test(id)) return { ok: false, error: 'invalid id' };
  const p = path.join(INCIDENTS, id, 'containment.log');
  try {
    const text = await fsp.readFile(p, 'utf8');
    return { ok: true, text };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function readIncidentFile(id, name) {
  if (!/^[0-9TZ:+-]+-\d+$/.test(id)) return { ok: false, error: 'invalid id' };
  if (!/^[A-Za-z0-9._-]+$/.test(name)) return { ok: false, error: 'invalid name' };
  const p = path.join(INCIDENTS, id, name);
  try {
    const text = await fsp.readFile(p, 'utf8');
    return { ok: true, text };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function listIncidentFiles(id) {
  if (!/^[0-9TZ:+-]+-\d+$/.test(id)) return { ok: false, error: 'invalid id' };
  const dir = path.join(INCIDENTS, id);
  try {
    const entries = await fsp.readdir(dir);
    return { ok: true, files: entries.sort() };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function recentEvents(lines = 200) {
  const r = await exec('journalctl', ['-u', 'eiciel-watch', '-n', String(lines), '--no-pager', '-o', 'short-iso']);
  return { ok: r.ok, text: r.stdout || r.stderr };
}

async function recentAudit(limit = 100) {
  const r = await exec('ausearch', ['-k', 'priv_esc', '--start', 'today', '-i']);
  if (!r.ok) return { ok: true, text: r.stderr || '(no audit events)' };
  const lines = r.stdout.split('\n');
  return { ok: true, text: lines.slice(-limit).join('\n') };
}

async function triggerContainment() {
  if (!isRoot()) {
    return { ok: false, error: 'Must run as root to trigger containment.' };
  }
  return new Promise(resolve => {
    const child = spawn('sudo', [CONTAIN], { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', d => out += d);
    child.stderr.on('data', d => out += d);
    child.on('close', code => resolve({ ok: code === 0, code, output: out }));
  });
}

async function liftIsolation() {
  if (!isRoot()) {
    return { ok: false, error: 'Must run as root to lift isolation.' };
  }
  const r = await exec('nft', ['delete', 'table', 'inet', 'eiciel_contain']);
  return { ok: r.ok, output: r.stdout + r.stderr };
}

let win;
function createWindow() {
  win = new BrowserWindow({
    width: 1200,
    height: 800,
    title: 'Eiciel Server Control',
    backgroundColor: '#0e1116',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'index.html'));
}

ipcMain.handle('config',            () => getConfig());
ipcMain.handle('state',             () => getContainState());
ipcMain.handle('incidents',         () => listIncidents());
ipcMain.handle('incident-log',      (_e, id) => readIncidentLog(id));
ipcMain.handle('incident-files',    (_e, id) => listIncidentFiles(id));
ipcMain.handle('incident-file',     (_e, id, name) => readIncidentFile(id, name));
ipcMain.handle('events',            () => recentEvents());
ipcMain.handle('audit',             () => recentAudit());
ipcMain.handle('trigger',           () => triggerContainment());
ipcMain.handle('lift',              () => liftIsolation());

ipcMain.handle('confirm', async (_e, msg) => {
  const r = await dialog.showMessageBox(win, {
    type: 'warning',
    buttons: ['Cancel', 'Yes, proceed'],
    defaultId: 0,
    cancelId: 0,
    message: msg,
  });
  return r.response === 1;
});

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
MAIN_EOF

# ─────────────────────────────────────────────────────────────────
# 3. preload.js — the safe bridge
# ─────────────────────────────────────────────────────────────────
cat > preload.js <<'PRE_EOF'
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('eiciel', {
  config:         ()       => ipcRenderer.invoke('config'),
  state:          ()       => ipcRenderer.invoke('state'),
  incidents:      ()       => ipcRenderer.invoke('incidents'),
  incidentLog:    id       => ipcRenderer.invoke('incident-log', id),
  incidentFiles:  id       => ipcRenderer.invoke('incident-files', id),
  incidentFile:   (id, nm) => ipcRenderer.invoke('incident-file', id, nm),
  events:         ()       => ipcRenderer.invoke('events'),
  audit:          ()       => ipcRenderer.invoke('audit'),
  trigger:        ()       => ipcRenderer.invoke('trigger'),
  lift:           ()       => ipcRenderer.invoke('lift'),
  confirm:        msg      => ipcRenderer.invoke('confirm', msg),
});
PRE_EOF

# ─────────────────────────────────────────────────────────────────
# 4. index.html — the UI
# ─────────────────────────────────────────────────────────────────
cat > index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Eiciel Server Control</title>
<style>
  :root {
    --bg:      #0e1116;
    --panel:   #161b22;
    --border:  #2b3138;
    --text:    #e6edf3;
    --muted:   #8b949e;
    --green:   #3fb950;
    --red:     #f85149;
    --amber:   #d29922;
    --blue:    #58a6ff;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; }
  body {
    background: var(--bg);
    color: var(--text);
    font: 13px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif;
    display: grid;
    grid-template-rows: 48px 1fr;
    height: 100vh;
    overflow: hidden;
  }
  header {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 0 16px;
    border-bottom: 1px solid var(--border);
    background: var(--panel);
  }
  header h1 { font-size: 14px; font-weight: 600; margin: 0; letter-spacing: 0.02em; }
  header .badge {
    font-size: 11px;
    padding: 2px 8px;
    border-radius: 10px;
    background: #21262d;
    color: var(--muted);
    border: 1px solid var(--border);
  }
  header .badge.ok  { color: var(--green); border-color: #1f3b23; background: #0d1a12; }
  header .badge.bad { color: var(--red);   border-color: #4a1f1f; background: #1a0d0d; }
  header .spacer { flex: 1; }
  header button {
    background: #21262d;
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 5px 12px;
    cursor: pointer;
    font-size: 12px;
  }
  header button:hover { background: #2b3138; }
  header button.danger { border-color: #4a1f1f; color: var(--red); }
  header button.danger:hover { background: #2a1414; }
  header button.good   { border-color: #1f3b23; color: var(--green); }

  main {
    display: grid;
    grid-template-columns: 320px 1fr 380px;
    overflow: hidden;
  }
  .col { border-right: 1px solid var(--border); overflow: hidden; display: flex; flex-direction: column; }
  .col:last-child { border-right: none; }

  .panel {
    padding: 12px;
    border-bottom: 1px solid var(--border);
  }
  .panel h2 {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--muted);
    margin: 0 0 8px 0;
    font-weight: 600;
  }

  .kv { display: grid; grid-template-columns: 1fr auto; gap: 4px 12px; font-size: 12px; }
  .kv .k { color: var(--muted); }
  .kv .v { text-align: right; }
  .v.ok  { color: var(--green); }
  .v.bad { color: var(--red); }
  .v.warn{ color: var(--amber); }

  .incident-list { overflow-y: auto; flex: 1; }
  .incident {
    padding: 8px 12px;
    cursor: pointer;
    border-bottom: 1px solid var(--border);
    font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: 12px;
  }
  .incident:hover { background: #1a2028; }
  .incident.selected { background: #1f2937; }
  .incident .id  { color: var(--text); }
  .incident .meta{ color: var(--muted); font-size: 11px; }

  .viewer {
    display: flex;
    flex-direction: column;
    overflow: hidden;
    flex: 1;
  }
  .viewer .tabs {
    display: flex;
    gap: 4px;
    padding: 8px 12px 0;
    flex-wrap: wrap;
  }
  .viewer .tabs button {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--muted);
    padding: 3px 10px;
    border-radius: 4px;
    font-size: 11px;
    cursor: pointer;
    font-family: ui-monospace, monospace;
  }
  .viewer .tabs button.active { color: var(--text); background: #21262d; }
  pre {
    flex: 1;
    margin: 0;
    padding: 12px 16px;
    overflow: auto;
    font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: 12px;
    line-height: 1.5;
    color: #c9d1d9;
    background: #0d1117;
    border-top: 1px solid var(--border);
    white-space: pre;
  }
  pre .hl-red    { color: var(--red); }
  pre .hl-green  { color: var(--green); }
  pre .hl-amber  { color: var(--amber); }
  pre .hl-blue   { color: var(--blue); }

  .events { flex: 1; overflow: hidden; display: flex; flex-direction: column; }
  .events .tabs { padding: 8px 12px 0; display: flex; gap: 4px; }
  .events .tabs button {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--muted);
    padding: 3px 10px;
    border-radius: 4px;
    font-size: 11px;
    cursor: pointer;
  }
  .events .tabs button.active { color: var(--text); background: #21262d; }

  .empty { padding: 20px; color: var(--muted); font-style: italic; font-size: 12px; }

  .pulse {
    display: inline-block;
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--green);
    margin-right: 6px;
    animation: pulse 2s infinite;
  }
  .pulse.bad { background: var(--red); }
  @keyframes pulse {
    0%,100% { opacity: 1; }
    50%     { opacity: 0.4; }
  }
</style>
</head>
<body>
<header>
  <h1>🛡️ Eiciel Server Control</h1>
  <span class="badge" id="badge-root">root: ?</span>
  <span class="badge" id="badge-watcher">watcher: ?</span>
  <span class="badge" id="badge-auditd">auditd: ?</span>
  <span class="badge" id="badge-f2b">fail2ban: ?</span>
  <span class="spacer"></span>
  <button id="btn-refresh">Refresh</button>
  <button id="btn-lift" class="good">Lift isolation</button>
  <button id="btn-trigger" class="danger">Trigger containment</button>
</header>
<main>
  <div class="col">
    <div class="panel">
      <h2>Containment state</h2>
      <div class="kv" id="state-kv"><span class="k">loading…</span><span class="v"></span></div>
    </div>
    <div class="panel" style="padding-bottom:8px">
      <h2>Services</h2>
      <div class="kv" id="services-kv"></div>
    </div>
    <div class="panel" style="padding-bottom:6px">
      <h2>Incidents</h2>
    </div>
    <div class="incident-list" id="incident-list">
      <div class="empty">Loading…</div>
    </div>
  </div>

  <div class="col">
    <div class="viewer">
      <div class="tabs" id="file-tabs">
        <button data-file="containment.log" class="active">containment.log</button>
      </div>
      <pre id="viewer-content">Select an incident on the left.</pre>
    </div>
  </div>

  <div class="col">
    <div class="events">
      <div class="tabs">
        <button data-src="watcher" class="active">eiciel-watch</button>
        <button data-src="audit">audit priv_esc</button>
      </div>
      <pre id="events-content">Loading…</pre>
    </div>
  </div>
</main>

<script>
const $ = id => document.getElementById(id);
let selectedIncident = null;
let currentFile = 'containment.log';
let eventsSource = 'watcher';

function badge(el, label, val) {
  el.textContent = `${label}: ${val}`;
  el.classList.toggle('ok',  val === 'active' || val === 'true'  || val === 'yes');
  el.classList.toggle('bad', val !== 'active' && val !== 'true'  && val !== 'yes');
}

async function refreshState() {
  const s = await window.eiciel.state();
  badge($('badge-root'),    'root',     s.isRoot ? 'yes' : 'no');
  badge($('badge-watcher'), 'watcher',  s.watcher);
  badge($('badge-auditd'),  'auditd',   s.auditd);
  badge($('badge-f2b'),     'fail2ban', s.fail2ban);

  const kv = $('state-kv');
  kv.innerHTML = '';
  const rows = [
    ['Isolation',      s.containActive ? 'ACTIVE' : 'off', s.containActive ? 'bad' : 'ok'],
    ['Running as',     s.isRoot ? 'root' : 'non-root',      s.isRoot ? 'ok' : 'warn'],
  ];
  for (const [k, v, cls] of rows) {
    kv.insertAdjacentHTML('beforeend',
      `<span class="k">${k}</span><span class="v ${cls}">${v}</span>`);
  }

  const skv = $('services-kv');
  skv.innerHTML = '';
  if (!s.services.length) {
    skv.innerHTML = '<span class="k">(none configured)</span><span class="v"></span>';
  }
  for (const svc of s.services) {
    skv.insertAdjacentHTML('beforeend',
      `<span class="k">${svc.name}</span>
       <span class="v ${svc.active ? 'ok' : 'bad'}">${svc.active ? 'running' : 'stopped'}</span>`);
  }
}

async function refreshIncidents() {
  const r = await window.eiciel.incidents();
  const list = $('incident-list');
  list.innerHTML = '';
  if (!r.incidents.length) {
    list.innerHTML = '<div class="empty">No incidents recorded.</div>';
    return;
  }
  for (const inc of r.incidents) {
    const el = document.createElement('div');
    el.className = 'incident';
    el.dataset.id = inc.id;
    const t = new Date(inc.mtime).toLocaleString();
    el.innerHTML = `<div class="id">${inc.id}</div><div class="meta">${t} · ${inc.logSize} B</div>`;
    el.addEventListener('click', () => selectIncident(inc.id));
    list.appendChild(el);
  }
}

async function selectIncident(id) {
  selectedIncident = id;
  document.querySelectorAll('.incident').forEach(el =>
    el.classList.toggle('selected', el.dataset.id === id));

  const r = await window.eiciel.incidentFiles(id);
  const tabs = $('file-tabs');
  tabs.innerHTML = '';
  if (!r.ok || !r.files.length) {
    tabs.innerHTML = '<button disabled>(no files)</button>';
    $('viewer-content').textContent = r.error || '(empty)';
    return;
  }
  for (const f of r.files) {
    const b = document.createElement('button');
    b.textContent = f;
    b.dataset.file = f;
    if (f === currentFile || (!r.files.includes(currentFile) && f === r.files[0])) {
      b.classList.add('active');
    }
    b.addEventListener('click', () => {
      currentFile = f;
      tabs.querySelectorAll('button').forEach(x => x.classList.toggle('active', x === b));
      loadFile(id, f);
    });
    tabs.appendChild(b);
  }
  const first = r.files.includes(currentFile) ? currentFile : r.files[0];
  currentFile = first;
  loadFile(id, first);
}

async function loadFile(id, name) {
  const r = await window.eiciel.incidentFile(id, name);
  const pre = $('viewer-content');
  if (!r.ok) { pre.textContent = 'Error: ' + r.error; return; }
  pre.textContent = r.text;
}

async function refreshEvents() {
  const pre = $('events-content');
  if (eventsSource === 'watcher') {
    const r = await window.eiciel.events();
    pre.textContent = r.text || '(no events)';
  } else {
    const r = await window.eiciel.audit();
    pre.textContent = r.text || '(no audit events)';
  }
  pre.scrollTop = pre.scrollHeight;
}

$('btn-refresh').addEventListener('click', () => { refreshAll(); });

$('btn-trigger').addEventListener('click', async () => {
  if (!await window.eiciel.confirm('Trigger containment now?\n\nThis will:\n- preserve evidence\n- drop all outbound except MGMT_IP\n- kill non-admin TTYs\n- stop services in STOP_SERVICES\n- notify via webhook\n\nProceed?')) return;
  const r = await window.eiciel.trigger();
  alert(r.ok ? 'Containment triggered.\n\n' + (r.output || '') : 'Failed: ' + (r.error || r.output));
  refreshAll();
});

$('btn-lift').addEventListener('click', async () => {
  if (!await window.eiciel.confirm('Lift network isolation?\n\nOnly do this AFTER snapshot + evidence copy.')) return;
  const r = await window.eiciel.lift();
  alert(r.ok ? 'Isolation lifted.' : 'Failed: ' + (r.output || ''));
  refreshAll();
});

document.querySelectorAll('.events .tabs button').forEach(b => {
  b.addEventListener('click', () => {
    eventsSource = b.dataset.src;
    document.querySelectorAll('.events .tabs button')
      .forEach(x => x.classList.toggle('active', x === b));
    refreshEvents();
  });
});

async function refreshAll() {
  await refreshState();
  await refreshIncidents();
  await refreshEvents();
  if (selectedIncident) selectIncident(selectedIncident);
}

refreshAll();
setInterval(refreshEvents, 5000);
setInterval(refreshState, 10000);
</script>
</body>
</html>
HTML_EOF

echo "📦 Installing npm dependencies…"
npm install --no-audit --no-fund --loglevel=error

echo "📦 Packaging for linux-x64…"
npm run build

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅  Done!  $OUT/EicielDashboard-linux-x64/"
echo "═══════════════════════════════════════════════════════════════"
