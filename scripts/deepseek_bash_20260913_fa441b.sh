#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel IR Console — Dashboard + eicield daemon builder
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/eiciel-app-src"
OUT="$ROOT/eiciel-app-dist"

echo "═══════════════════════════════════════════════════════════════"
echo "  Eiciel IR Console — app + daemon builder"
echo "  Source: $SRC"
echo "  Output: $OUT"
echo "═══════════════════════════════════════════════════════════════"

command -v node >/dev/null || { echo "❌ node not found"; exit 1; }
command -v npm  >/dev/null || { echo "❌ npm not found";  exit 1; }

rm -rf "$SRC" "$OUT"
mkdir -p "$SRC/daemon"
cd "$SRC"

cat > package.json <<'EOF'
{
  "name": "eiciel-dashboard",
  "version": "1.3.0",
  "description": "Eiciel IR Console — compromise response control panel",
  "main": "main.js",
  "scripts": {
    "start": "electron .",
    "build": "electron-packager . EicielDashboard --platform=linux --arch=x64 --out=../eiciel-app-dist --overwrite"
  },
  "devDependencies": {
    "electron": "^33.0.0",
    "electron-packager": "^17.1.2"
  }
}
EOF

# ── main.js ──
cat > main.js <<'MAIN_EOF'
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const net = require('net');
const path = require('path');

const SOCK = process.env.EICIELD_SOCK || '/run/eicield.sock';

function callDaemon(op, args = {}) {
  return new Promise(resolve => {
    const sock = net.connect(SOCK);
    let buf = '';
    let done = false;
    const finish = v => { if (!done) { done = true; try { sock.destroy(); } catch {} resolve(v); } };
    sock.setTimeout(35000, () => finish({ ok: false, error: 'daemon timeout' }));
    sock.on('connect', () => sock.write(JSON.stringify({ op, args }) + '\n'));
    sock.on('data', d => {
      buf += d.toString('utf8');
      const nl = buf.indexOf('\n');
      if (nl === -1) return;
      try { finish(JSON.parse(buf.slice(0, nl))); }
      catch (e) { finish({ ok: false, error: 'bad daemon response' }); }
    });
    sock.on('error', e => finish({ ok: false, error: e.message }));
  });
}

let win;
function createWindow() {
  win = new BrowserWindow({
    width: 1200,
    height: 800,
    title: 'Eiciel IR Console',
    backgroundColor: '#0e1116',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'index.html'));
}

function promptTotp(reason) {
  return new Promise((resolve) => {
    const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
      body{margin:0;padding:20px;background:#161b22;color:#e6edf3;font:13px -apple-system,sans-serif}
      h2{margin:0 0 12px;font-size:14px;font-weight:600}
      p{margin:0 0 12px;color:#8b949e;font-size:12px}
      input{width:100%;padding:10px;font-size:20px;letter-spacing:6px;text-align:center;
            background:#0d1117;color:#e6edf3;border:1px solid #2b3138;border-radius:6px;
            box-sizing:border-box;font-family:ui-monospace,monospace}
      input:focus{outline:none;border-color:#58a6ff}
      .row{display:flex;gap:8px;justify-content:flex-end;margin-top:16px}
      button{padding:6px 16px;font-size:13px;cursor:pointer;border-radius:6px;
             border:1px solid #2b3138;background:#21262d;color:#e6edf3}
      button:hover{background:#2b3138}
      button.primary{border-color:#1f6feb;color:#58a6ff}
    </style></head><body>
      <h2>Server-side re-authentication</h2>
      <p>${reason.replace(/[<>&]/g, '')}</p>
      <input id="code" type="text" inputmode="numeric" maxlength="6" autofocus
             autocomplete="off" placeholder="000000">
      <div class="row">
        <button id="cancel">Cancel</button>
        <button id="ok" class="primary">Verify</button>
      </div>
      <script>
        const input = document.getElementById('code');
        const ok = document.getElementById('ok');
        const cancel = document.getElementById('cancel');
        function submit(){ if (input.value.length >= 6) window.totpAPI.send(input.value); }
        function cancelFn(){ window.totpAPI.send(null); }
        input.addEventListener('keydown', e => {
          if (e.key === 'Enter') submit();
          if (e.key === 'Escape') cancelFn();
        });
        ok.addEventListener('click', submit);
        cancel.addEventListener('click', cancelFn);
      </script>
    </body></html>`;

    const promptWin = new BrowserWindow({
      width: 380, height: 240,
      parent: win, modal: true, resizable: false,
      minimizable: false, maximizable: false,
      title: 'Re-authentication',
      backgroundColor: '#161b22',
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        preload: path.join(__dirname, 'totp-preload.js'),
      },
    });
    promptWin.removeMenu();
    promptWin.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));

    const channel = 'totp-result';
    const handler = (_e, code) => {
      ipcMain.removeListener(channel, handler);
      try { promptWin.close(); } catch {}
      resolve(code);
    };
    ipcMain.once(channel, handler);

    promptWin.on('closed', () => {
      ipcMain.removeListener(channel, handler);
      resolve(null);
    });
  });
}

ipcMain.handle('config',         ()           => callDaemon('config'));
ipcMain.handle('state',          ()           => callDaemon('state'));
ipcMain.handle('incidents',      ()           => callDaemon('incidents'));
ipcMain.handle('incident-log',   (_e, id)     => callDaemon('incident-log',   { id }));
ipcMain.handle('incident-files', (_e, id)     => callDaemon('incident-files', { id }));
ipcMain.handle('incident-file',  (_e, id, nm) => callDaemon('incident-file',  { id, name: nm }));
ipcMain.handle('events',         ()           => callDaemon('events'));
ipcMain.handle('audit',          ()           => callDaemon('audit'));
ipcMain.handle('license-state',  ()           => callDaemon('license-state'));
ipcMain.handle('license-info',   ()           => callDaemon('license-info'));

ipcMain.handle('trigger', async () => {
  const code = await promptTotp('Enter the 6-digit TOTP code to trigger containment.');
  if (!code) return { ok: false, error: 'cancelled' };
  const r = await callDaemon('trigger', { totp: code });
  if (r.reauth_required) {
    dialog.showErrorBox('Re-auth failed', 'Invalid or expired TOTP code.');
  }
  return r;
});

ipcMain.handle('lift', async () => {
  const code = await promptTotp('Enter the 6-digit TOTP code to lift network isolation.');
  if (!code) return { ok: false, error: 'cancelled' };
  const r = await callDaemon('lift', { totp: code });
  if (r.reauth_required) {
    dialog.showErrorBox('Re-auth failed', 'Invalid or expired TOTP code.');
  }
  return r;
});

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
MAIN_EOF

# ── totp-preload.js ──
cat > totp-preload.js <<'TOTP_PRE_EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('totpAPI', {
  send: (code) => ipcRenderer.send('totp-result', code),
});
TOTP_PRE_EOF

# ── preload.js ──
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
  licenseState:   ()       => ipcRenderer.invoke('license-state'),
  licenseInfo:    ()       => ipcRenderer.invoke('license-info'),
});
PRE_EOF

# ── index.html ──
cat > index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Eiciel IR Console</title>
<style>
:root{--bg:#0e1116;--panel:#161b22;--border:#2b3138;--text:#e6edf3;--muted:#8b949e;--green:#3fb950;--red:#f85149;--amber:#d29922;--blue:#58a6ff}
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{background:var(--bg);color:var(--text);font:13px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif;display:grid;grid-template-rows:48px 1fr;height:100vh;overflow:hidden}
header{display:flex;align-items:center;gap:16px;padding:0 16px;border-bottom:1px solid var(--border);background:var(--panel)}
header h1{font-size:14px;font-weight:600;margin:0}
header .badge{font-size:11px;padding:2px 8px;border-radius:10px;background:#21262d;color:var(--muted);border:1px solid var(--border)}
header .badge.ok{color:var(--green);border-color:#1f3b23;background:#0d1a12}
header .badge.bad{color:var(--red);border-color:#4a1f1f;background:#1a0d0d}
header .badge.warn{color:var(--amber);border-color:#4a3a1f;background:#1a1409}
header .spacer{flex:1}
header button{background:#21262d;color:var(--text);border:1px solid var(--border);border-radius:6px;padding:5px 12px;cursor:pointer;font-size:12px}
header button:hover{background:#2b3138}
header button.danger{border-color:#4a1f1f;color:var(--red)}
header button.good{border-color:#1f3b23;color:var(--green)}
main{display:grid;grid-template-columns:340px 1fr 380px;overflow:hidden}
.col{border-right:1px solid var(--border);overflow:hidden;display:flex;flex-direction:column}
.col:last-child{border-right:none}
.panel{padding:12px;border-bottom:1px solid var(--border)}
.panel h2{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0 0 8px 0;font-weight:600}
.kv{display:grid;grid-template-columns:1fr auto;gap:4px 12px;font-size:12px}
.kv .k{color:var(--muted)}.kv .v{text-align:right}
.v.ok{color:var(--green)}.v.bad{color:var(--red)}.v.warn{color:var(--amber)}
.incident-list{overflow-y:auto;flex:1}
.incident{padding:8px 12px;cursor:pointer;border-bottom:1px solid var(--border);font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
.incident:hover{background:#1a2028}.incident.selected{background:#1f2937}
.incident .meta{color:var(--muted);font-size:11px}
.viewer{display:flex;flex-direction:column;overflow:hidden;flex:1}
.viewer .tabs{display:flex;gap:4px;padding:8px 12px 0;flex-wrap:wrap}
.viewer .tabs button{background:transparent;border:1px solid var(--border);color:var(--muted);padding:3px 10px;border-radius:4px;font-size:11px;cursor:pointer;font-family:ui-monospace,monospace}
.viewer .tabs button.active{color:var(--text);background:#21262d}
pre{flex:1;margin:0;padding:12px 16px;overflow:auto;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;line-height:1.5;color:#c9d1d9;background:#0d1117;border-top:1px solid var(--border);white-space:pre}
.events{flex:1;overflow:hidden;display:flex;flex-direction:column}
.events .tabs{padding:8px 12px 0;display:flex;gap:4px}
.events .tabs button{background:transparent;border:1px solid var(--border);color:var(--muted);padding:3px 10px;border-radius:4px;font-size:11px;cursor:pointer}
.events .tabs button.active{color:var(--text);background:#21262d}
.empty{padding:20px;color:var(--muted);font-style:italic;font-size:12px}
.banner{font-size:11px;color:var(--muted);padding:6px 12px;background:#161b22;border-bottom:1px solid var(--border);font-style:italic}
</style></head><body>
<header>
  <h1>Eiciel IR Console</h1>
  <span class="badge" id="badge-daemon">daemon: ?</span>
  <span class="badge" id="badge-watcher">watcher: ?</span>
  <span class="badge" id="badge-auditd">auditd: ?</span>
  <span class="badge" id="badge-f2b">fail2ban: ?</span>
  <span class="badge" id="badge-license">license: ?</span>
  <span class="spacer"></span>
  <button id="btn-refresh">Refresh</button>
  <button id="btn-lift" class="good">Lift isolation</button>
  <button id="btn-trigger" class="danger">Trigger containment</button>
</header>
<main>
  <div class="col">
    <div class="panel"><h2>Containment state</h2><div class="kv" id="state-kv"><span class="k">loading…</span><span class="v"></span></div></div>
    <div class="panel"><h2>License</h2><div class="kv" id="license-kv"><span class="k">loading…</span><span class="v"></span></div></div>
    <div class="panel" style="padding-bottom:8px"><h2>Services</h2><div class="kv" id="services-kv"></div></div>
    <div class="panel" style="padding-bottom:6px"><h2>Incidents</h2></div>
    <div class="incident-list" id="incident-list"><div class="empty">Loading…</div></div>
  </div>
  <div class="col"><div class="viewer">
    <div class="banner">Detection coverage is limited. See Coverage panel for what this tool does and does not monitor.</div>
    <div class="tabs" id="file-tabs"><button data-file="containment.log" class="active">containment.log</button></div>
    <pre id="viewer-content">Select an incident on the left.</pre>
  </div></div>
  <div class="col">
    <div class="panel"><h2>Coverage</h2><div class="kv" id="coverage-kv"></div></div>
    <div class="events">
      <div class="tabs"><button data-src="watcher" class="active">eiciel-watch</button><button data-src="audit">audit priv_esc</button></div>
      <pre id="events-content">Loading…</pre>
    </div>
  </div>
</main>
<script>
const $=id=>document.getElementById(id);
let selectedIncident=null,currentFile='containment.log',eventsSource='watcher';
function badge(el,label,val,extraClass){el.textContent=`${label}: ${val}`;el.classList.remove('ok','bad','warn');if(extraClass)el.classList.add(extraClass);}
async function refreshState(){
  const s=await window.eiciel.state();
  badge($('badge-daemon'),'daemon',s.daemon||'unknown',(s.daemon==='active')?'ok':'bad');
  badge($('badge-watcher'),'watcher',s.watcher||'unknown',(s.watcher==='active')?'ok':'bad');
  badge($('badge-auditd'),'auditd',s.auditd||'unknown',(s.auditd==='active')?'ok':'bad');
  badge($('badge-f2b'),'fail2ban',s.fail2ban||'unknown',(s.fail2ban==='active')?'ok':'bad');
  const kv=$('state-kv');kv.innerHTML='';
  const rows=[['Isolation',s.containActive?'ACTIVE':'off',s.containActive?'bad':'ok'],['Running as','eiciel (unprivileged)','ok']];
  for(const[k,v,c]of rows)kv.insertAdjacentHTML('beforeend',`<span class="k">${k}</span><span class="v ${c}">${v}</span>`);
  const skv=$('services-kv');skv.innerHTML='';
  if(!s.services||!s.services.length)skv.innerHTML='<span class="k">(none configured)</span><span class="v"></span>';
  for(const svc of(s.services||[]))skv.insertAdjacentHTML('beforeend',`<span class="k">${svc.name}</span><span class="v ${svc.active?'ok':'bad'}">${svc.active?'running':'stopped'}</span>`);
  try{
    const lic=await window.eiciel.licenseInfo();
    const lkv=$('license-kv');lkv.innerHTML='';
    if(!lic.enabled){
      badge($('badge-license'),'license','n/a','warn');
      lkv.innerHTML='<span class="k">Gate</span><span class="v">disabled</span>';
    } else if(lic.valid){
      badge($('badge-license'),'license','valid','ok');
      lkv.insertAdjacentHTML('beforeend',`<span class="k">Issued to</span><span class="v">${lic.issued_to||'?'}</span>`);
      lkv.insertAdjacentHTML('beforeend',`<span class="k">ID</span><span class="v">${lic.license_id||'?'}</span>`);
      lkv.insertAdjacentHTML('beforeend',`<span class="k">Expires</span><span class="v">${lic.not_after||'?'}</span>`);
    } else {
      badge($('badge-license'),'license','invalid','bad');
      lkv.insertAdjacentHTML('beforeend',`<span class="k">Reason</span><span class="v bad">${lic.error||'unknown'}</span>`);
    }
  }catch(e){badge($('badge-license'),'license','error','bad');}
  renderCoverage();
}
function renderCoverage(){
  const cov = [
    ['Process execution',    'ok',  'auditd execve'],
    ['Privilege escalation', 'ok',  'auditd priv_esc (evidence only)'],
    ['File integrity',       'ok',  'auditd watches'],
    ['Kernel modules',       'ok',  'auditd module_load'],
    ['Watcher self-protect', 'ok',  'watcher_tamper + audit_tamper'],
    ['Isolation lift',       'ok',  'auditd isolation_lift'],
    ['Network (live flows)', 'warn','only at containment time'],
    ['DNS queries',          'bad', 'not monitored'],
    ['Egress volume',        'bad', 'not monitored'],
    ['Web application',      'bad', 'not monitored'],
    ['Database',             'bad', 'not monitored'],
    ['Containers',           'bad', 'not monitored'],
    ['Login anomalies',      'bad', 'not monitored'],
  ];
  const ckv = $('coverage-kv');
  ckv.innerHTML = '';
  for (const [name, state, note] of cov) {
    const glyph = state === 'ok' ? '✓' : (state === 'warn' ? '~' : '✗');
    ckv.insertAdjacentHTML('beforeend',
      `<span class="k">${name}</span><span class="v ${state}">${glyph} ${note}</span>`);
  }
}
async function refreshIncidents(){
  const r=await window.eiciel.incidents();const list=$('incident-list');list.innerHTML='';
  if(!r.incidents||!r.incidents.length){list.innerHTML='<div class="empty">No incidents recorded.</div>';return;}
  for(const inc of r.incidents){const el=document.createElement('div');el.className='incident';el.dataset.id=inc.id;
    const t=new Date(inc.mtime).toLocaleString();
    el.innerHTML=`<div class="id">${inc.id}</div><div class="meta">${t} · ${inc.logSize} B</div>`;
    el.addEventListener('click',()=>selectIncident(inc.id));list.appendChild(el);}
}
async function selectIncident(id){
  selectedIncident=id;
  document.querySelectorAll('.incident').forEach(el=>el.classList.toggle('selected',el.dataset.id===id));
  const r=await window.eiciel.incidentFiles(id);const tabs=$('file-tabs');tabs.innerHTML='';
  if(!r.ok||!r.files.length){tabs.innerHTML='<button disabled>(no files)</button>';$('viewer-content').textContent=r.error||'(empty)';return;}
  for(const f of r.files){const b=document.createElement('button');b.textContent=f;b.dataset.file=f;
    if(f===currentFile||(!r.files.includes(currentFile)&&f===r.files[0]))b.classList.add('active');
    b.addEventListener('click',()=>{currentFile=f;tabs.querySelectorAll('button').forEach(x=>x.classList.toggle('active',x===b));loadFile(id,f);});
    tabs.appendChild(b);}
  const first=r.files.includes(currentFile)?currentFile:r.files[0];currentFile=first;loadFile(id,first);
}
async function loadFile(id,name){const r=await window.eiciel.incidentFile(id,name);const pre=$('viewer-content');
  if(!r.ok){pre.textContent='Error: '+r.error;return;}pre.textContent=r.text;}
async function refreshEvents(){const pre=$('events-content');
  if(eventsSource==='watcher'){const r=await window.eiciel.events();pre.textContent=r.text||'(no events)';}
  else{const r=await window.eiciel.audit();pre.textContent=r.text||'(no audit events)';}
  pre.scrollTop=pre.scrollHeight;}
$('btn-refresh').addEventListener('click',()=>{refreshAll();});
$('btn-trigger').addEventListener('click',async()=>{
  const r=await window.eiciel.trigger();
  if(r.ok) alert('Containment triggered.');
  else if(r.error!=='cancelled') alert('Failed: '+(r.error||r.output||'unknown'));
  refreshAll();});
$('btn-lift').addEventListener('click',async()=>{
  const r=await window.eiciel.lift();
  if(r.ok) alert('Isolation lifted.');
  else if(r.error!=='cancelled') alert('Failed: '+(r.error||r.output||'unknown'));
  refreshAll();});
document.querySelectorAll('.events .tabs button').forEach(b=>{b.addEventListener('click',()=>{
  eventsSource=b.dataset.src;
  document.querySelectorAll('.events .tabs button').forEach(x=>x.classList.toggle('active',x===b));
  refreshEvents();});});
async function refreshAll(){await refreshState();await refreshIncidents();await refreshEvents();if(selectedIncident)selectIncident(selectedIncident);}
refreshAll();setInterval(refreshEvents,5000);setInterval(refreshState,10000);
</script></body></html>
HTML_EOF

# ── daemon/eicield.py ──
cat > daemon/eicield.py <<'DAEMON_EOF'
#!/usr/bin/env python3
"""eicield — root-owned Unix-socket daemon for the Eiciel IR Console."""
import datetime
import grp
import json
import os
import pwd
import re
import socket
import socketserver
import struct
import subprocess
import sys
import urllib.request
from pathlib import Path

SOCK_PATH       = "/run/eicield.sock"
SOCK_GROUP      = "eiciel"
CONFIG_PATH     = Path("/etc/eiciel/config.env")
LICENSE_JSON    = Path("/etc/eiciel/license.json")
LICENSE_PUB     = Path("/etc/eiciel/license.pub")
LICENSE_CHECK   = "/usr/local/sbin/eiciel-license-check"
REAUTH_SECRET   = Path("/etc/eiciel/reauth.secret")
INCIDENTS_ROOT  = Path("/var/lib/incidents").resolve()
CONTAIN_SCRIPT  = "/usr/local/sbin/eiciel-contain.sh"

INCIDENT_ID_RE = re.compile(r"^\d{8}T\d{6}Z-\d+$")
FILENAME_RE    = re.compile(r"^(?!\.{1,2}$)[A-Za-z0-9._-]{1,128}$")

def run(cmd, args=None, timeout=30):
    try:
        r = subprocess.run([cmd] + (args or []), capture_output=True, text=True, timeout=timeout)
        return {"ok": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr}
    except Exception as e:
        return {"ok": False, "stdout": "", "stderr": str(e)}

def parse_env(text):
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        out[k.strip()] = v
    return out

def read_config():
    try:
        return {"ok": True, "data": parse_env(CONFIG_PATH.read_text())}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def safe_incident_dir(incident_id):
    if not INCIDENT_ID_RE.match(incident_id):
        raise ValueError("invalid incident id")
    p = (INCIDENTS_ROOT / incident_id).resolve()
    if not str(p).startswith(str(INCIDENTS_ROOT) + os.sep):
        raise ValueError("path escape")
    return p

def safe_incident_file(incident_id, name):
    if not FILENAME_RE.match(name):
        raise ValueError("invalid file name")
    d = safe_incident_dir(incident_id)
    p = (d / name).resolve()
    if not str(p).startswith(str(d) + os.sep):
        raise ValueError("path escape")
    if not p.is_file() or p.is_symlink():
        raise ValueError("not a regular file")
    return p

def get_state():
    nft = run("nft", ["list", "table", "inet", "eiciel_contain"])
    cfg = read_config()
    wanted = (cfg.get("data", {}) or {}).get("STOP_SERVICES", "").split()
    services = []
    for s in wanted:
        r = run("systemctl", ["is-active", s])
        services.append({"name": s, "active": r["stdout"].strip() == "active"})
    return {
        "ok": True,
        "daemon": "active",
        "containActive": nft["ok"],
        "services": services,
        "watcher":  run("systemctl", ["is-active", "eiciel-watch"])["stdout"].strip() or "inactive",
        "auditd":   run("systemctl", ["is-active", "auditd"])["stdout"].strip() or "inactive",
        "fail2ban": run("systemctl", ["is-active", "fail2ban"])["stdout"].strip() or "inactive",
    }

def list_incidents():
    try:
        entries = [e for e in INCIDENTS_ROOT.iterdir() if e.is_dir()]
    except FileNotFoundError:
        return {"ok": True, "incidents": []}
    entries.sort(key=lambda p: p.name, reverse=True)
    out = []
    for d in entries[:50]:
        if not INCIDENT_ID_RE.match(d.name):
            continue
        log = d / "containment.log"
        try: mtime = int(d.stat().st_mtime * 1000)
        except OSError: mtime = 0
        try: size = log.stat().st_size
        except OSError: size = 0
        out.append({"id": d.name, "logSize": size, "mtime": mtime})
    return {"ok": True, "incidents": out}

def read_log(incident_id):
    try:
        p = safe_incident_file(incident_id, "containment.log")
        return {"ok": True, "text": p.read_text(errors="replace")}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def list_files(incident_id):
    try:
        d = safe_incident_dir(incident_id)
        names = sorted(n for n in os.listdir(d) if FILENAME_RE.match(n))
        return {"ok": True, "files": names}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def read_file(incident_id, name):
    try:
        p = safe_incident_file(incident_id, name)
        return {"ok": True, "text": p.read_text(errors="replace")}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def events():
    r = run("journalctl", ["-u", "eiciel-watch", "-n", "200", "--no-pager", "-o", "short-iso"])
    return {"ok": r["ok"], "text": r["stdout"] or r["stderr"]}

def audit():
    r = run("ausearch", ["-k", "priv_esc_unset", "--start", "today", "-i"])
    if not r["ok"]:
        return {"ok": True, "text": r["stderr"] or "(no audit events)"}
    return {"ok": True, "text": "\n".join(r["stdout"].splitlines()[-100:])}

def license_info():
    enabled = LICENSE_PUB.exists()
    if not enabled:
        return {"ok": True, "enabled": False, "valid": False}
    if not LICENSE_JSON.exists():
        return {"ok": True, "enabled": True, "valid": False, "error": "license.json not present"}
    try:
        data = json.loads(LICENSE_JSON.read_text())
    except Exception as e:
        return {"ok": True, "enabled": True, "valid": False, "error": f"cannot read license: {e}"}
    r = run(LICENSE_CHECK, timeout=10)
    out = {
        "ok": True,
        "enabled": True,
        "valid": r["ok"],
        "license_id": data.get("license_id"),
        "issued_to": data.get("issued_to"),
        "not_before": data.get("not_before"),
        "not_after": data.get("not_after"),
        "machine_id": data.get("machine_id"),
    }
    if not r["ok"]:
        out["error"] = (r["stderr"] or r["stdout"] or "verification failed").strip()
    return out

def _verify_totp(code):
    """Return True if the code is valid OR no re-auth secret is configured."""
    if not REAUTH_SECRET.exists():
        return True
    try:
        import pyotp
        secret = REAUTH_SECRET.read_text().strip()
        return pyotp.TOTP(secret).verify(code or "", valid_window=1)
    except Exception:
        return False

def log_offhost(event, details):
    """Send an action log to the webhook. Best-effort; never raises."""
    try:
        cfg = parse_env(CONFIG_PATH.read_text())
        url = cfg.get("WEBHOOK_URL", "")
        if not url:
            return
        payload = json.dumps({
            "type": "action_log",
            "event": event,
            "host": socket.gethostname(),
            "time": datetime.datetime.utcnow().isoformat() + "Z",
            "details": details,
        }).encode()
        req = urllib.request.Request(
            url, data=payload,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass

def trigger(args=None):
    code = (args or {}).get("totp", "")
    if not _verify_totp(code):
        log_offhost("containment_trigger_denied", {"reason": "bad_totp"})
        return {"ok": False, "reauth_required": True,
                "error": "server-side re-auth required"}
    try:
        subprocess.Popen(
            [CONTAIN_SCRIPT],
            stdout=open("/var/log/eiciel-contain.log", "ab"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        log_offhost("containment_triggered", {"by": "dashboard"})
        return {"ok": True, "output": "containment started"}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def lift(args=None):
    code = (args or {}).get("totp", "")
    if not _verify_totp(code):
        log_offhost("isolation_lift_denied", {"reason": "bad_totp"})
        return {"ok": False, "reauth_required": True,
                "error": "server-side re-auth required"}
    r = run("nft", ["delete", "table", "inet", "eiciel_contain"])
    log_offhost("isolation_lifted", {"ok": r["ok"]})
    return {"ok": r["ok"], "output": r["stdout"] + r["stderr"]}

HANDLERS = {
    "config":         lambda a: read_config(),
    "state":          lambda a: get_state(),
    "incidents":      lambda a: list_incidents(),
    "incident-log":   lambda a: read_log(a.get("id", "")),
    "incident-files": lambda a: list_files(a.get("id", "")),
    "incident-file":  lambda a: read_file(a.get("id", ""), a.get("name", "")),
    "events":         lambda a: events(),
    "audit":          lambda a: audit(),
    "trigger":        lambda a: trigger(a),
    "lift":           lambda a: lift(a),
    "license-state":  lambda a: license_info(),
    "license-info":   lambda a: license_info(),
}

def peer_allowed(sock):
    try:
        raw = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, gid = struct.unpack("3i", raw)
    except Exception:
        return False
    if uid == 0:
        return True
    try:
        user = pwd.getpwuid(uid)
        groups = os.getgrouplist(user.pw_name, gid)
        target = grp.getgrnam(SOCK_GROUP).gr_gid
        return target in groups
    except Exception:
        return False

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        if not peer_allowed(self.connection):
            self._send({"ok": False, "error": "permission denied"})
            return
        line = self.rfile.readline(65536)
        if not line:
            return
        try:
            req = json.loads(line.decode("utf-8"))
        except Exception:
            self._send({"ok": False, "error": "bad json"})
            return
        op = req.get("op")
        args = req.get("args") or {}
        fn = HANDLERS.get(op)
        if not fn:
            self._send({"ok": False, "error": f"unknown op {op!r}"})
            return
        try:
            self._send(fn(args))
        except Exception as e:
            self._send({"ok": False, "error": str(e)})

    def _send(self, obj):
        try:
            self.wfile.write((json.dumps(obj) + "\n").encode("utf-8"))
        except Exception:
            pass

class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

def main():
    if os.path.exists(SOCK_PATH):
        os.unlink(SOCK_PATH)
    srv = Server(SOCK_PATH, Handler)
    os.chmod(SOCK_PATH, 0o660)
    try:
        os.chown(SOCK_PATH, 0, grp.getgrnam(SOCK_GROUP).gr_gid)
    except KeyError:
        print(f"eicield: group {SOCK_GROUP!r} missing", file=sys.stderr)
        sys.exit(1)
    print(f"eicield listening on {SOCK_PATH}", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
DAEMON_EOF
chmod 755 daemon/eicield.py

cat > daemon/eicield.service <<'UNIT_EOF'
[Unit]
Description=Eiciel IR Console daemon (root, Unix socket)
After=network.target auditd.service
Requires=auditd.service
ConditionPathExists=/run/eiciel-licensed

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/python3 /usr/local/lib/eicield/eicield.py
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/run /var/lib/incidents /var/log /etc/eiciel
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > daemon/install-daemon.sh <<'INSTALL_EOF'
#!/bin/bash
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "run as root"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
getent group eiciel >/dev/null || groupadd --system eiciel
id -u eiciel >/dev/null 2>&1 || \
  useradd --system --gid eiciel --home-dir /var/lib/eiciel --create-home --shell /usr/sbin/nologin eiciel
install -d -m 755 /usr/local/lib/eicield
install -m 755 "$HERE/eicield.py" /usr/local/lib/eicield/eicield.py
install -m 644 "$HERE/eicield.service" /etc/systemd/system/eicield.service
systemctl daemon-reload
systemctl enable --now eicield.service
systemctl --no-pager status eicield.service | head -20
INSTALL_EOF
chmod 755 daemon/install-daemon.sh

echo "📦 Installing npm dependencies…"
npm install --no-audit --no-fund --loglevel=error

echo "📦 Packaging for linux-x64…"
npm run build

install -d -m 755 "$OUT/eicield"
install -m 755 daemon/eicield.py            "$OUT/eicield/eicield.py"
install -m 644 daemon/eicield.service       "$OUT/eicield/eicield.service"
install -m 755 daemon/install-daemon.sh     "$OUT/eicield/install-daemon.sh"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅  Done!  $OUT/EicielDashboard-linux-x64/"
echo "          $OUT/eicield/"
echo "═══════════════════════════════════════════════════════════════"