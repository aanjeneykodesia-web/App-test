#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel IR Console — single build script
#  v2.5.0
#
#  Changes since v2.4.0:
#    S5.1  Passphrase-sealed secrets (hook 024). No plaintext secret on disk.
#    S5.2  TOTP is read from /run/eiciel/secrets.env (tmpfs).
#    S5.3  GitHub token is sealed; owner/repo/branch from config.env.
#    S5.4  pam_exec TOTP verification; pam_google_authenticator removed.
#    S5.5  eiciel-seal-secrets operator tool.
#    S5.6  Removed /var/lib/eiciel/totp/admin.secret and github-credentials.env.
#    S5.7  MOTD and RECOVERY.md reflect sealed-secrets flow.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHROOT="$ROOT/config/includes.chroot"
SRC="$ROOT/eiciel-app-src"
OUT="$ROOT/eiciel-app-dist"
APP_DIST="$OUT/EicielDashboard-linux-x64"
DAEMON_DIST="$OUT/eicield"
CONFIG_LOCAL="$ROOT/config/config.local.env"

[ -f "$CONFIG_LOCAL" ] || { echo "❌ Missing $CONFIG_LOCAL"; exit 1; }
while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    _k="${_k#"${_k%%[![:space:]]*}"}"; _k="${_k%"${_k##*[![:space:]]}"}"
    case "$_k" in ''|\#*) continue ;; esac
    _v="${_v#"${_v%%[![:space:]]*}"}"
    case "$_v" in
        \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;;
        \'*\') _v="${_v#\'}"; _v="${_v%\'}" ;;
    esac
    export "$_k=$_v"
done < "$CONFIG_LOCAL"

: "${MGMT_IP:?set MGMT_IP in config.local.env}"
: "${WEBHOOK_URL:?set WEBHOOK_URL in config.local.env}"

STOP_SERVICES="${STOP_SERVICES:-}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
ENABLE_PERSISTENCE="${ENABLE_PERSISTENCE:-1}"
INCLUDE_DASHBOARD="${INCLUDE_DASHBOARD:-auto}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-600}"
ISOLATION_TIMEOUT="${ISOLATION_TIMEOUT:-600}"
HOSTNAME_NEW="${HOSTNAME_NEW:-eiciel-srv}"
BUILD_MODE="${BUILD_MODE:-install}"
LICENSE_GATE_MODE="${LICENSE_GATE_MODE:-none}"
LICENSE_PUBKEY_FILE="${LICENSE_PUBKEY_FILE:-}"
ADMIN_CIDRS="${ADMIN_CIDRS:-}"
ALLOWED_PORTS="${ALLOWED_PORTS:-22}"
ENABLE_MFA="${ENABLE_MFA:-1}"
ENABLE_AUTO_UPDATES="${ENABLE_AUTO_UPDATES:-0}"
MFA_SUDO="${MFA_SUDO:-1}"
MFA_SSH="${MFA_SSH:-0}"
ENABLE_GUI="${ENABLE_GUI:-1}"
GUI_AUTOLOGIN="${GUI_AUTOLOGIN:-0}"
ENABLE_TOOLS="${ENABLE_TOOLS:-1}"
ENABLE_TOOLS_HEAVY="${ENABLE_TOOLS_HEAVY:-1}"
ENABLE_METRICS="${ENABLE_METRICS:-1}"

AUTO_TRIGGER="${AUTO_TRIGGER:-1}"
AUTO_TRIGGER_MIN_SEVERITY="${AUTO_TRIGGER_MIN_SEVERITY:-high}"
DETECT_AUTO_TRIGGER="${DETECT_AUTO_TRIGGER:-0}"
DETECT_INBOUND_EXPECTED_PORTS="${DETECT_INBOUND_EXPECTED_PORTS:-22 53}"
DETECT_INBOUND_TRUSTED_IPS="${DETECT_INBOUND_TRUSTED_IPS:-}"
DETECT_SSH_FAIL_THRESHOLD="${DETECT_SSH_FAIL_THRESHOLD:-100}"
DETECT_SSH_FAIL_WINDOW="${DETECT_SSH_FAIL_WINDOW:-300}"
DETECT_SSH_MIN_USERS="${DETECT_SSH_MIN_USERS:-3}"
DETECT_EGRESS_MB_PER_SEC="${DETECT_EGRESS_MB_PER_SEC:-20}"
DETECT_DNS_THRESHOLD="${DETECT_DNS_THRESHOLD:-500}"
DETECT_INBOUND_NEW_THRESHOLD="${DETECT_INBOUND_NEW_THRESHOLD:-60}"
DETECT_MAX_TRIGGERS_PER_HOUR="${DETECT_MAX_TRIGGERS_PER_HOUR:-3}"
DETECT_DRY_RUN="${DETECT_DRY_RUN:-0}"
DETECT_WEB_THRESHOLD="${DETECT_WEB_THRESHOLD:-5}"
DETECT_WEB_WINDOW="${DETECT_WEB_WINDOW:-60}"

GITHUB_UPLOAD_ENABLED="${GITHUB_UPLOAD_ENABLED:-0}"
GITHUB_UPLOAD_TOKEN="${GITHUB_UPLOAD_TOKEN:-}"
GITHUB_UPLOAD_OWNER="${GITHUB_UPLOAD_OWNER:-}"
GITHUB_UPLOAD_REPO="${GITHUB_UPLOAD_REPO:-}"
GITHUB_UPLOAD_BRANCH="${GITHUB_UPLOAD_BRANCH:-main}"
GITHUB_UPLOAD_TIMEOUT="${GITHUB_UPLOAD_TIMEOUT:-60}"

RESTIC_REPO="${RESTIC_REPO:-}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-}"
SYSLOG_TARGET="${SYSLOG_TARGET:-}"

export BUILD_MODE ISOLATION_TIMEOUT LICENSE_GATE_MODE
export ENABLE_MFA MFA_SUDO MFA_SSH ENABLE_GUI GUI_AUTOLOGIN
export ENABLE_TOOLS ENABLE_TOOLS_HEAVY ENABLE_METRICS
export AUTO_TRIGGER AUTO_TRIGGER_MIN_SEVERITY
export DETECT_AUTO_TRIGGER DETECT_INBOUND_EXPECTED_PORTS DETECT_INBOUND_TRUSTED_IPS
export DETECT_SSH_FAIL_THRESHOLD DETECT_SSH_FAIL_WINDOW DETECT_SSH_MIN_USERS
export DETECT_EGRESS_MB_PER_SEC DETECT_DNS_THRESHOLD DETECT_INBOUND_NEW_THRESHOLD
export DETECT_MAX_TRIGGERS_PER_HOUR DETECT_DRY_RUN DETECT_WEB_THRESHOLD DETECT_WEB_WINDOW
export GITHUB_UPLOAD_ENABLED GITHUB_UPLOAD_TOKEN GITHUB_UPLOAD_OWNER GITHUB_UPLOAD_REPO GITHUB_UPLOAD_BRANCH GITHUB_UPLOAD_TIMEOUT
export RESTIC_REPO RESTIC_PASSWORD_FILE

echo "═══════════════════════════════════════════════════════════════"
echo "  Eiciel IR Console v2.5.0 — build"
echo "  MGMT_IP        = $MGMT_IP"
echo "  BUILD_MODE     = $BUILD_MODE"
echo "  GUI            = $ENABLE_GUI (autologin=$GUI_AUTOLOGIN)"
echo "  Persistence    = $ENABLE_PERSISTENCE"
echo "  Toolkit        = $ENABLE_TOOLS (heavy=$ENABLE_TOOLS_HEAVY)"
echo "  Metrics        = $ENABLE_METRICS"
echo "  MFA sudo/ssh   = $ENABLE_MFA / $MFA_SUDO / $MFA_SSH"
echo "  Audit watcher  = $AUTO_TRIGGER (min_sev=$AUTO_TRIGGER_MIN_SEVERITY)"
echo "  Detector       = $([ "$DETECT_AUTO_TRIGGER" = "1" ] && echo "auto-trigger" || echo "log-only")"
echo "  Isolation t/o  = ${ISOLATION_TIMEOUT}s"
echo "  GitHub upload  = $GITHUB_UPLOAD_ENABLED"
echo "  License gate   = $LICENSE_GATE_MODE"
echo "  Secrets        = sealed (passphrase at boot)"
echo "═══════════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════
#  build_app
# ═══════════════════════════════════════════════════════════════════
build_app() {
  echo ""; echo "▶▶▶  [1/2] Building Electron dashboard + daemon"; echo ""
  command -v node >/dev/null || { echo "❌ node not found"; exit 1; }
  command -v npm  >/dev/null || { echo "❌ npm not found";  exit 1; }

  rm -rf "$SRC" "$OUT"
  mkdir -p "$SRC/daemon"
  cd "$SRC"

  cat > package.json <<'EOF'
{
  "name": "eiciel-dashboard",
  "version": "2.5.0",
  "description": "Eiciel IR Console",
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

  cat > main.js <<'MAIN_EOF'
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');

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
    width: 1480, height: 900,
    title: 'Eiciel IR Console',
    backgroundColor: '#0e1116',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true,
    },
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'index.html'));
  win.once('ready-to-show', () => win.show());
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
      button.primary{border-color:#1f6feb;color:#58a6ff}
    </style></head><body>
      <h2>Re-authentication</h2>
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
      title: 'Re-authentication', backgroundColor: '#161b22',
      webPreferences: {
        contextIsolation: true, nodeIntegration: false, sandbox: true,
        preload: path.join(__dirname, 'totp-preload.js'),
      },
    });
    promptWin.removeMenu();
    promptWin.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));

    const handler = (_e, code) => {
      ipcMain.removeListener('totp-result', handler);
      try { promptWin.close(); } catch {}
      resolve(code);
    };
    ipcMain.once('totp-result', handler);
    promptWin.on('closed', () => {
      ipcMain.removeListener('totp-result', handler);
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
ipcMain.handle('netinfo',        ()           => callDaemon('netinfo'));
ipcMain.handle('sessions',       ()           => callDaemon('sessions'));
ipcMain.handle('sysinfo',        ()           => callDaemon('sysinfo'));
ipcMain.handle('apt-history',    ()           => callDaemon('apt-history'));
ipcMain.handle('metrics',        ()           => callDaemon('metrics'));
ipcMain.handle('metric-history', (_e, limit)  => callDaemon('metric-history', { limit }));
ipcMain.handle('detections',     (_e, limit)  => callDaemon('detections',     { limit }));

ipcMain.handle('spawn-terminal', () => {
  const candidates = [
    { cmd: 'xterm', args: ['-fa', 'Monospace', '-fs', '11',
                           '-bg', '#0e1116', '-fg', '#e6edf3',
                           '-title', 'Eiciel Terminal'] },
    { cmd: 'x-terminal-emulator', args: [] },
  ];
  for (const c of candidates) {
    try {
      const child = spawn(c.cmd, c.args, {
        detached: true, stdio: 'ignore',
        env: { ...process.env, DISPLAY: process.env.DISPLAY || ':0' },
      });
      child.unref();
      return { ok: true, launched: c.cmd };
    } catch (e) { /* next */ }
  }
  return { ok: false, error: 'no terminal emulator available' };
});

async function reauthOp(op, reason) {
  const st = await callDaemon('state');
  if (st && st.reauthConfigured === false) {
    dialog.showErrorBox('Re-authentication not configured',
      'Secrets are locked. Either no sealed secrets file exists, or the\n' +
      'passphrase has not been entered at the console since boot.\n\n' +
      'If unsealed: reboot and enter the passphrase at the console.\n' +
      'If missing: run sudo eiciel-seal-secrets, then reboot.');
    return { ok: false, error: 'reauth_not_configured' };
  }
  const code = await promptTotp(reason);
  if (!code) return { ok: false, error: 'cancelled' };
  const r = await callDaemon(op, { totp: code });
  if (r.reauth_required && r.rate_limited)
    dialog.showErrorBox('Rate limited', r.error || 'Too many failed attempts. Wait 15 minutes.');
  else if (r.reauth_required && r.replay)
    dialog.showErrorBox('Code already used', 'This TOTP code was already accepted.');
  else if (r.reauth_required)
    dialog.showErrorBox('Re-auth failed', 'Invalid or expired TOTP code.');
  return r;
}

ipcMain.handle('trigger', () => reauthOp('trigger', 'Enter the 6-digit TOTP to trigger containment.'));
ipcMain.handle('lift',    () => reauthOp('lift',    'Enter the 6-digit TOTP to lift isolation.'));

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
MAIN_EOF

  cat > totp-preload.js <<'TOTP_PRE_EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('totpAPI', { send: (code) => ipcRenderer.send('totp-result', code) });
TOTP_PRE_EOF

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
  netinfo:        ()       => ipcRenderer.invoke('netinfo'),
  sessions:       ()       => ipcRenderer.invoke('sessions'),
  sysinfo:        ()       => ipcRenderer.invoke('sysinfo'),
  aptHistory:     ()       => ipcRenderer.invoke('apt-history'),
  metrics:        ()       => ipcRenderer.invoke('metrics'),
  metricHistory:  (limit)  => ipcRenderer.invoke('metric-history', limit),
  detections:     (limit)  => ipcRenderer.invoke('detections', limit),
  spawnTerminal:  ()       => ipcRenderer.invoke('spawn-terminal'),
});
PRE_EOF

  cat > index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Eiciel IR Console</title>
<style>
:root{--bg:#0e1116;--panel:#161b22;--border:#2b3138;--text:#e6edf3;--muted:#8b949e;--green:#3fb950;--red:#f85149;--amber:#d29922;--blue:#58a6ff;--purple:#a371f7}
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{background:var(--bg);color:var(--text);font:13px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif;display:grid;grid-template-rows:48px 1fr;height:100vh;overflow:hidden}
header{display:flex;align-items:center;gap:14px;padding:0 16px;border-bottom:1px solid var(--border);background:var(--panel)}
header h1{font-size:14px;font-weight:600;margin:0}
header .badge{font-size:11px;padding:2px 8px;border-radius:10px;background:#21262d;color:var(--muted);border:1px solid var(--border)}
header .badge.ok{color:var(--green);border-color:#1f3b23;background:#0d1a12}
header .badge.bad{color:var(--red);border-color:#4a1f1f;background:#1a0d0d}
header .badge.warn{color:var(--amber);border-color:#4a3a1f;background:#1a1409}
header .spacer{flex:1}
header button{background:#21262d;color:var(--text);border:1px solid var(--border);border-radius:6px;padding:5px 12px;cursor:pointer;font-size:12px}
header button:hover{background:#2b3138}
header button:disabled{opacity:.4;cursor:not-allowed}
header button.danger{border-color:#4a1f1f;color:var(--red)}
header button.good{border-color:#1f3b23;color:var(--green)}
.banner-warn{background:#1a1409;border-bottom:1px solid #4a3a1f;color:#d29922;padding:8px 16px;font-size:12px}
main{display:grid;grid-template-columns:340px 1fr 420px;overflow:hidden}
.col{border-right:1px solid var(--border);overflow:hidden;display:flex;flex-direction:column}
.col:last-child{border-right:none;overflow-y:auto}
.panel{padding:10px 12px;border-bottom:1px solid var(--border)}
.panel h2{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0 0 6px 0;font-weight:600}
.kv{display:grid;grid-template-columns:1fr auto;gap:3px 12px;font-size:12px}
.kv .k{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:200px}
.kv .v{text-align:right;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px}
.v.ok{color:var(--green)}.v.bad{color:var(--red)}.v.warn{color:var(--amber)}.v.muted{color:var(--muted)}
.incident-list{overflow-y:auto;flex:1;min-height:80px}
.incident{padding:8px 12px;cursor:pointer;border-bottom:1px solid var(--border);font-family:ui-monospace,monospace;font-size:12px}
.incident:hover{background:#1a2028}.incident.selected{background:#1f2937}
.incident .meta{color:var(--muted);font-size:11px}
.viewer{display:flex;flex-direction:column;overflow:hidden;flex:1}
.viewer .tabs{display:flex;gap:4px;padding:8px 12px 0;flex-wrap:wrap}
.viewer .tabs button{background:transparent;border:1px solid var(--border);color:var(--muted);padding:3px 10px;border-radius:4px;font-size:11px;cursor:pointer;font-family:ui-monospace,monospace}
.viewer .tabs button.active{color:var(--text);background:#21262d}
pre{flex:1;margin:0;padding:12px 16px;overflow:auto;font-family:ui-monospace,monospace;font-size:12px;line-height:1.5;color:#c9d1d9;background:#0d1117;border-top:1px solid var(--border);white-space:pre}
.events{flex:1;overflow:hidden;display:flex;flex-direction:column;min-height:200px}
.events .tabs{padding:8px 12px 0;display:flex;gap:4px;flex-wrap:wrap}
.events .tabs button{background:transparent;border:1px solid var(--border);color:var(--muted);padding:3px 10px;border-radius:4px;font-size:11px;cursor:pointer}
.events .tabs button.active{color:var(--text);background:#21262d}
.empty{padding:20px;color:var(--muted);font-style:italic;font-size:12px}
.banner{font-size:11px;color:var(--muted);padding:6px 12px;background:#161b22;border-bottom:1px solid var(--border);font-style:italic}
.iface{border-bottom:1px solid #21262d;padding:6px 0}
.iface:last-child{border-bottom:none}
.iface .name{font-weight:600;font-family:ui-monospace,monospace;font-size:12px}
.iface .addr{font-family:ui-monospace,monospace;font-size:11px;color:#c9d1d9;padding-left:10px}
.iface .meta{font-size:10px;color:var(--muted)}
.graph{height:48px;background:#0d1117;border-radius:4px;position:relative;overflow:hidden;margin-top:4px}
.graph canvas{width:100%;height:100%;display:block}
</style></head><body>
<header>
  <h1>Eiciel IR Console</h1>
  <span class="badge" id="badge-daemon">daemon: ?</span>
  <span class="badge" id="badge-watcher">watcher: ?</span>
  <span class="badge" id="badge-detect">detect: ?</span>
  <span class="badge" id="badge-auditd">auditd: ?</span>
  <span class="badge" id="badge-license">license: ?</span>
  <span class="badge" id="badge-ip">ip: ?</span>
  <span class="spacer"></span>
  <button id="btn-terminal">Terminal</button>
  <button id="btn-refresh">Refresh</button>
  <button id="btn-lift" class="good" disabled>Lift isolation</button>
  <button id="btn-trigger" class="danger" disabled>Trigger containment</button>
</header>
<div id="reauth-warning" class="banner-warn" style="display:none"></div>
<main>
  <div class="col">
    <div class="panel"><h2>Containment state</h2><div class="kv" id="state-kv"></div></div>
    <div class="panel"><h2>System</h2><div class="kv" id="system-kv"></div></div>
    <div class="panel"><h2>Network</h2><div id="network-ifaces"><div class="empty">loading…</div></div></div>
    <div class="panel"><h2>License</h2><div class="kv" id="license-kv"></div></div>
    <div class="panel" style="padding-bottom:8px"><h2>Services</h2><div class="kv" id="services-kv"></div></div>
    <div class="panel" style="padding-bottom:6px"><h2>Incidents</h2></div>
    <div class="incident-list" id="incident-list"><div class="empty">Loading…</div></div>
  </div>
  <div class="col"><div class="viewer">
    <div class="banner">Detection is best-effort. See Coverage panel.</div>
    <div class="tabs" id="file-tabs"><button data-file="containment.log" class="active">containment.log</button></div>
    <pre id="viewer-content">Select an incident on the left.</pre>
  </div></div>
  <div class="col">
    <div class="panel"><h2>Live coverage</h2><div class="kv" id="coverage-kv"></div></div>
    <div class="panel"><h2>Egress (bytes/s)</h2>
      <div class="graph"><canvas id="graph-egress"></canvas></div>
      <div class="kv" id="egress-kv" style="margin-top:6px"></div>
    </div>
    <div class="panel"><h2>DNS / Logins</h2><div class="kv" id="live-kv"></div></div>
    <div class="panel"><h2>Web / DB / Containers</h2><div class="kv" id="apps-kv"></div></div>
    <div class="events">
      <div class="tabs">
        <button data-src="detections" class="active">detections</button>
        <button data-src="watcher">eiciel-watch</button>
        <button data-src="audit">audit</button>
        <button data-src="netinfo">network</button>
        <button data-src="sessions">sessions</button>
        <button data-src="apt">apt history</button>
      </div>
      <pre id="events-content">Loading…</pre>
    </div>
  </div>
</main>
<script>
const $=id=>document.getElementById(id);
let selectedIncident=null,currentFile='containment.log',eventsSource='detections';
let egressHistory=[];
function badge(el,label,val,c){el.textContent=`${label}: ${val}`;el.classList.remove('ok','bad','warn');if(c)el.classList.add(c);}
function row(k,v,c){return `<span class="k">${k}</span><span class="v ${c||''}">${v}</span>`;}
function fmtB(b){if(b<1024)return b+' B/s';if(b<1048576)return (b/1024).toFixed(1)+' KiB/s';return (b/1048576).toFixed(1)+' MiB/s';}
function setDestructive(enabled){
  $('btn-trigger').disabled = !enabled;
  $('btn-lift').disabled    = !enabled;
  const b=$('reauth-warning');
  if(enabled){b.style.display='none';b.textContent='';}
  else{b.style.display='';b.textContent='⚠️  Secrets locked. Reboot and enter the passphrase at the console, then re-auth is available.';}
}
async function refreshState(){
  let s;
  try{s=await window.eiciel.state();}
  catch(e){s={daemon:'unreachable',watcher:'?',detect:'?',auditd:'?',reauthConfigured:false};}
  badge($('badge-daemon'),'daemon',s.daemon||'unknown',(s.daemon==='active')?'ok':'bad');
  badge($('badge-watcher'),'watcher',s.watcher||'unknown',(s.watcher==='active')?'ok':'bad');
  badge($('badge-detect'),'detect',s.detect||'unknown',(s.detect==='active')?'ok':'bad');
  badge($('badge-auditd'),'auditd',s.auditd||'unknown',(s.auditd==='active')?'ok':'bad');
  setDestructive(s.reauthConfigured === true);
  $('state-kv').innerHTML=[
    row('Isolation',s.containActive?'ACTIVE':'off',s.containActive?'bad':'ok'),
    row('Daemon','root (isolated)','ok'),
    row('Secrets',s.reauthConfigured?'unlocked':'locked',s.reauthConfigured?'ok':'bad'),
    row('Audit watcher',s.autoTrigger?'enabled':'disabled',s.autoTrigger?'ok':'muted'),
    row('Detector',s.detectorAutoTrigger?'auto-trigger':'log-only',s.detectorAutoTrigger?'warn':'muted')
  ].join('');
  const skv=$('services-kv');skv.innerHTML='';
  if(!s.services||!s.services.length)skv.innerHTML=row('(none configured)','','muted');
  for(const svc of(s.services||[]))skv.insertAdjacentHTML('beforeend',row(svc.name,svc.active?'running':'stopped',svc.active?'ok':'bad'));
  try{
    const lic=await window.eiciel.licenseInfo();
    const lkv=$('license-kv');lkv.innerHTML='';
    if(!lic.enabled){badge($('badge-license'),'license','n/a','warn');lkv.innerHTML=row('Gate','disabled','muted');}
    else if(lic.valid){
      badge($('badge-license'),'license','valid','ok');
      lkv.insertAdjacentHTML('beforeend',row('Issued to',lic.issued_to||'?','ok'));
      lkv.insertAdjacentHTML('beforeend',row('Expires',(lic.not_after||'?').slice(0,10),'ok'));
    }else{
      badge($('badge-license'),'license','invalid','bad');
      lkv.insertAdjacentHTML('beforeend',row('Reason',lic.error||'unknown','bad'));
    }
  }catch(e){badge($('badge-license'),'license','error','bad');}
  await refreshNetwork();
  await refreshSystem();
}
async function refreshSystem(){
  try{
    const s=await window.eiciel.sysinfo();const kv=$('system-kv');kv.innerHTML='';
    const rows=[
      s.persistence?['Persistence','ON','ok']:['Persistence','off','warn'],
      ['Packages',String(s.package_count??'?'),''],
      ['Disk',s.disk_used_pct!=null?s.disk_used_pct+'%':'?',(s.disk_used_pct>=85)?'bad':(s.disk_used_pct>=70?'warn':'ok')],
      ['Kernel',s.kernel||'?',''],
      ['Uptime',s.uptime||'?',''],
    ];
    for(const[k,v,c]of rows)kv.insertAdjacentHTML('beforeend',row(k,v,c));
  }catch(e){$('system-kv').innerHTML=row('error','?','bad');}
}
async function refreshNetwork(){
  try{
    const n=await window.eiciel.netinfo();const box=$('network-ifaces');
    if(!n.ok){box.innerHTML='<div class="empty">netinfo error</div>';return;}
    let primary='';
    for(const i of(n.interfaces||[])){if(i.name==='lo')continue;if(i.ipv4&&i.ipv4.length){primary=i.ipv4[0].split('/')[0];break;}}
    badge($('badge-ip'),'ip',primary||'none',primary?'ok':'warn');
    let html='';
    for(const i of(n.interfaces||[])){
      if(i.name==='lo')continue;
      const up=i.state==='UP';const addrs=[...(i.ipv4||[]),...(i.ipv6||[])];
      html+=`<div class="iface"><div class="name ${up?'':'bad'}">${i.name} ${up?'▲':'▼'}</div>`;
      if(i.mac)html+=`<div class="meta">${i.mac}</div>`;
      if(addrs.length){for(const a of addrs)html+=`<div class="addr">${a}</div>`;}
      else{html+=`<div class="meta">(no address)</div>`;}
      html+=`</div>`;
    }
    html+=`<div class="kv" style="margin-top:6px">
      <span class="k">default gw</span><span class="v">${n.default_gateway||'(none)'}</span>
      <span class="k">listeners</span><span class="v">${(n.listeners||[]).length}</span>
      <span class="k">established</span><span class="v">${(n.connections||[]).length}</span>
      <span class="k">sessions</span><span class="v">${(n.sessions||[]).length}</span>
    </div>`;
    box.innerHTML=html;
  }catch(e){$('network-ifaces').innerHTML='<div class="empty">netinfo error</div>';}
}
function drawEgress(){
  const c=$('graph-egress');if(!c)return;
  const dpr=window.devicePixelRatio||1;
  const w=c.clientWidth,h=c.clientHeight;
  c.width=w*dpr;c.height=h*dpr;
  const ctx=c.getContext('2d');ctx.scale(dpr,dpr);ctx.clearRect(0,0,w,h);
  if(egressHistory.length<2)return;
  const max=Math.max(...egressHistory.map(p=>Math.max(p.rx,p.tx)),1);
  function line(vals,color){
    ctx.beginPath();
    vals.forEach((v,i)=>{
      const x=(i/(vals.length-1))*w;
      const y=h-(v/max)*(h-4)-2;
      if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);
    });
    ctx.strokeStyle=color;ctx.lineWidth=1.5;ctx.stroke();
  }
  line(egressHistory.map(p=>p.rx),'#58a6ff');
  line(egressHistory.map(p=>p.tx),'#a371f7');
}
async function refreshMetrics(){
  const r=await window.eiciel.metrics();
  const cov=$('coverage-kv'),eg=$('egress-kv'),lv=$('live-kv'),ap=$('apps-kv');
  if(!r.ok||!r.metrics){
    const err=r.error||'sampler not running';
    cov.innerHTML=row('sampler',err,'bad');eg.innerHTML='';lv.innerHTML='';ap.innerHTML='';return;
  }
  const m=r.metrics;
  cov.innerHTML=[
    row('Process execution','✓ auditd','ok'),
    row('Privilege escalation','✓ auditd','ok'),
    row('File integrity','✓ auditd','ok'),
    row('Kernel modules','✓ auditd','ok'),
    row('BPF load','✓ auditd','ok'),
    row('Process injection','✓ auditd','ok'),
    row('Watcher self-protection','✓ auditd','ok'),
    row('Network interfaces',(m.interfaces||[]).length+' ifaces','ok'),
    row('Listening sockets',m.sockets.listening,m.sockets.listening>60?'warn':'ok'),
    row('Established conns',m.sockets.established,m.sockets.established>200?'warn':'ok'),
    row('DNS queries','live','ok'),
    row('Egress volume','live','ok'),
    row('Inbound new flows','live','ok'),
    row('Web application',m.web.active?'live':'n/a',m.web.active?'ok':'muted'),
    row('Database',Object.keys(m.databases||{}).length?'live':'n/a',Object.keys(m.databases||{}).length?'ok':'muted'),
    row('Containers',m.containers.runtime!=='none'?'live':'n/a',m.containers.runtime!=='none'?'ok':'muted'),
    row('Login anomalies','live','ok'),
  ].join('');
  eg.innerHTML=[
    row('↓ RX',fmtB(m.egress.rx_bps),'ok'),
    row('↑ TX',fmtB(m.egress.tx_bps),'ok'),
    row('Total RX',(m.egress.rx_total/1048576).toFixed(1)+' MiB','muted'),
    row('Total TX',(m.egress.tx_total/1048576).toFixed(1)+' MiB','muted'),
  ].join('');
  const newIps=(m.logins.new_ips||[]).length;
  lv.innerHTML=[
    row('DNS queries (total)',m.dns.queries_total.toLocaleString(),'ok'),
    row('Failed logins (5m)',m.logins.failed_5m,m.logins.failed_5m>5?'bad':(m.logins.failed_5m>0?'warn':'ok')),
    row('Successful logins (5m)',m.logins.success_5m,'ok'),
    row('New source IPs',newIps,newIps>0?'warn':'ok'),
  ].join('');
  const rows=[];
  if(m.web.active){
    rows.push(row('Web reqs (5m)',m.web.requests_5m,'ok'));
    rows.push(row('Web errors (5m)',m.web.errors_5m,m.web.errors_5m>0?'warn':'ok'));
  }else{rows.push(row('Web','inactive','muted'));}
  const dbs=Object.entries(m.databases||{});
  if(!dbs.length)rows.push(row('Databases','none detected','muted'));
  else dbs.forEach(([n,v])=>{if(v.active)rows.push(row(n,`${v.connections} conns`,'ok'));});
  if(m.containers.runtime==='none')rows.push(row('Containers','no runtime','muted'));
  else rows.push(row(`Containers (${m.containers.runtime})`,m.containers.count,m.containers.count>0?'warn':'ok'));
  ap.innerHTML=rows.join('');
  egressHistory.push({rx:m.egress.rx_bps,tx:m.egress.tx_bps});
  if(egressHistory.length>60)egressHistory.shift();
  drawEgress();
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
async function buildNetinfoText(){
  const n=await window.eiciel.netinfo();
  if(!n.ok)return '(netinfo error)';
  let out='══ Interfaces ══\n';
  for(const i of(n.interfaces||[])){
    out+=`${i.name}  state=${i.state}  mac=${i.mac||'-'}\n`;
    for(const a of(i.ipv4||[]))out+=`    inet  ${a}\n`;
    for(const a of(i.ipv6||[]))out+=`    inet6 ${a}\n`;
  }
  out+=`\n══ Default gateway ══\n${n.default_gateway||'(none)'}\n`;
  out+=`\n══ Listening sockets ══\n`;
  if((n.listeners||[]).length===0)out+='(none)\n';
  for(const l of(n.listeners||[]))out+=`${(l.local||'').padEnd(24)} ${l.process||''}\n`;
  out+=`\n══ Established connections ══\n`;
  if((n.connections||[]).length===0)out+='(none)\n';
  for(const c of(n.connections||[]))out+=`${(c.local||'').padEnd(24)} → ${(c.peer||'').padEnd(24)} ${c.process||''}\n`;
  return out;
}
async function buildSessionsText(){const s=await window.eiciel.sessions();return s.text||'(no sessions)';}
async function buildAptText(){const r=await window.eiciel.aptHistory();return r.text||'(no history)';}
async function buildDetectionsText(){
  const r=await window.eiciel.detections(200);
  if(!r.ok)return '(detections error)';
  if(!r.detections.length)return '(no detections recorded)';
  return r.detections.map(d=>{
    const sev=(d.severity||'?').toUpperCase().padEnd(8);
    return `${d.ts}  [${sev}]  ${(d.source||'').padEnd(10)}  ${d.reason||''}\n` +
           (d.details ? `    ${d.details}\n` : '');
  }).join('');
}
async function refreshEvents(){const pre=$('events-content');
  try{
    if(eventsSource==='detections'){pre.textContent=await buildDetectionsText();}
    else if(eventsSource==='watcher'){const r=await window.eiciel.events();pre.textContent=r.text||'(no events)';}
    else if(eventsSource==='audit'){const r=await window.eiciel.audit();pre.textContent=r.text||'(no audit events)';}
    else if(eventsSource==='netinfo'){pre.textContent=await buildNetinfoText();}
    else if(eventsSource==='sessions'){pre.textContent=await buildSessionsText();}
    else if(eventsSource==='apt'){pre.textContent=await buildAptText();}
  }catch(e){pre.textContent='(daemon not reachable)';}
  pre.scrollTop=pre.scrollHeight;}
$('btn-refresh').addEventListener('click',()=>{refreshAll();});
$('btn-terminal').addEventListener('click',async()=>{const r=await window.eiciel.spawnTerminal();if(!r.ok)alert('Could not open terminal: '+(r.error||'unknown'));});
$('btn-trigger').addEventListener('click',async()=>{
  const r=await window.eiciel.trigger();
  if(r.ok)alert('Containment triggered.');
  else if(r.error==='reauth_not_configured'){}
  else if(r.error==='cancelled'){}
  else if(r.rate_limited)alert('Rate limited: '+(r.error||''));
  else if(r.replay)alert('Code already used.');
  else alert('Failed: '+(r.error||r.output||'unknown'));
  refreshAll();});
$('btn-lift').addEventListener('click',async()=>{
  const r=await window.eiciel.lift();
  if(r.ok)alert('Isolation lifted.');
  else if(r.error==='reauth_not_configured'){}
  else if(r.error==='cancelled'){}
  else if(r.rate_limited)alert('Rate limited: '+(r.error||''));
  else if(r.replay)alert('Code already used.');
  else alert('Failed: '+(r.error||r.output||'unknown'));
  refreshAll();});
document.querySelectorAll('.events .tabs button').forEach(b=>{b.addEventListener('click',()=>{
  eventsSource=b.dataset.src;
  document.querySelectorAll('.events .tabs button').forEach(x=>x.classList.toggle('active',x===b));
  refreshEvents();});});
async function refreshAll(){
  await refreshState();
  await refreshIncidents();
  await refreshEvents();
  await refreshMetrics();
  if(selectedIncident)selectIncident(selectedIncident);
}
refreshAll();
setInterval(refreshEvents,5000);
setInterval(refreshState,10000);
setInterval(refreshMetrics,5000);
window.addEventListener('resize',drawEgress);
</script></body></html>
HTML_EOF

  cat > daemon/eicield.py <<'DAEMON_EOF'
#!/usr/bin/env python3
"""eicield — root-owned Unix-socket daemon for the Eiciel IR Console.

v2.5.0: secrets are read from /run/eiciel/secrets.env (tmpfs), unlocked
by a passphrase prompt at boot. No plaintext secret on disk.
"""
import datetime, grp, json, os, pwd, re, socket as pysocket, socketserver
import struct, subprocess, sys, threading, time, urllib.request
from pathlib import Path

SOCK_PATH       = "/run/eicield.sock"
SOCK_GROUP      = "eiciel"
CONFIG_PATH     = Path("/etc/eiciel/config.env")
LICENSE_JSON    = Path("/etc/eiciel/license.json")
LICENSE_PUB     = Path("/etc/eiciel/license.pub")
LICENSE_CHECK   = "/usr/local/sbin/eiciel-license-check"
RUNTIME_SECRETS = Path("/run/eiciel/secrets.env")
LICENSE_FLAG    = Path("/run/eiciel-licensed")
INCIDENTS_ROOT  = Path("/var/lib/incidents").resolve()
METRICS_DIR     = Path("/var/lib/eiciel-metrics")
DETECTIONS_LOG  = Path("/var/lib/eiciel-detections/events.jsonl")
CONTAIN_SCRIPT  = "/usr/local/sbin/eiciel-contain.sh"

REAUTH_MAX_FAILS = 5
REAUTH_LOCKOUT_S = 900
REAUTH_REPLAY_WINDOW_S = 95
_auth_lock = threading.Lock()
_reauth_fails = {}
_recent_codes = {}

def _prune_codes(now):
    cutoff = now - REAUTH_REPLAY_WINDOW_S
    for k in list(_recent_codes.keys()):
        if _recent_codes[k] < cutoff:
            del _recent_codes[k]

INCIDENT_ID_RE = re.compile(r"^\d{8}T\d{6}Z-\d+$")
FILENAME_RE    = re.compile(r"^(?!\.{1,2}$)[A-Za-z0-9._-]{1,128}$")

def run(cmd, args=None, timeout=30):
    try:
        r = subprocess.run([cmd] + (args or []), capture_output=True, text=True, timeout=timeout)
        return {"ok": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr}
    except Exception as e:
        return {"ok": False, "stdout": "", "stderr": str(e)}

def _jrun(cmd, args=None):
    r = run(cmd, args)
    if not r["ok"]: return []
    try: return json.loads(r["stdout"])
    except Exception: return []

def parse_env(text):
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k, v = line.split("=", 1); v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'): v = v[1:-1]
        out[k.strip()] = v
    return out

def read_config():
    try: return {"ok": True, "data": parse_env(CONFIG_PATH.read_text())}
    except Exception as e: return {"ok": False, "error": str(e)}

def _load_runtime_secrets():
    out = {}
    try:
        for line in RUNTIME_SECRETS.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            k, v = line.split("=", 1); v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'): v = v[1:-1]
            out[k.strip()] = v
    except Exception:
        pass
    return out

def _read_totp_secret():
    return _load_runtime_secrets().get("TOTP_SECRET", "")

def _reauth_configured():
    return bool(_read_totp_secret())

def safe_incident_dir(iid):
    if not INCIDENT_ID_RE.match(iid): raise ValueError("invalid incident id")
    p = (INCIDENTS_ROOT / iid).resolve()
    if not str(p).startswith(str(INCIDENTS_ROOT) + os.sep): raise ValueError("path escape")
    return p

def safe_incident_file(iid, name):
    if not FILENAME_RE.match(name): raise ValueError("invalid file name")
    d = safe_incident_dir(iid)
    p = (d / name).resolve()
    if not str(p).startswith(str(d) + os.sep): raise ValueError("path escape")
    if not p.is_file() or p.is_symlink(): raise ValueError("not a regular file")
    return p

def get_state():
    nft = run("nft", ["list", "table", "inet", "eiciel_contain"])
    cfg = read_config()
    data = cfg.get("data", {}) or {}
    wanted = data.get("STOP_SERVICES", "").split()
    services = []
    for s in wanted:
        r = run("systemctl", ["is-active", s])
        services.append({"name": s, "active": r["stdout"].strip() == "active"})
    auto = str(data.get("AUTO_TRIGGER", "1")) == "1"
    detect_auto = str(data.get("DETECT_AUTO_TRIGGER", "0")) == "1"
    return {"ok": True, "daemon": "active", "containActive": nft["ok"], "services": services,
            "reauthConfigured": _reauth_configured(),
            "autoTrigger": auto, "detectorAutoTrigger": detect_auto,
            "watcher":  run("systemctl", ["is-active", "eiciel-watch"])["stdout"].strip() or "inactive",
            "detect":   run("systemctl", ["is-active", "eiciel-detect"])["stdout"].strip() or "inactive",
            "auditd":   run("systemctl", ["is-active", "auditd"])["stdout"].strip() or "inactive",
            "fail2ban": run("systemctl", ["is-active", "fail2ban"])["stdout"].strip() or "inactive"}

def list_incidents():
    try: entries = [e for e in INCIDENTS_ROOT.iterdir() if e.is_dir()]
    except FileNotFoundError: return {"ok": True, "incidents": []}
    entries.sort(key=lambda p: p.name, reverse=True)
    out = []
    for d in entries[:50]:
        if not INCIDENT_ID_RE.match(d.name): continue
        log = d / "containment.log"
        try: mtime = int(d.stat().st_mtime * 1000)
        except OSError: mtime = 0
        try: size = log.stat().st_size
        except OSError: size = 0
        out.append({"id": d.name, "logSize": size, "mtime": mtime})
    return {"ok": True, "incidents": out}

def read_log(iid):
    try: return {"ok": True, "text": safe_incident_file(iid, "containment.log").read_text(errors="replace")}
    except Exception as e: return {"ok": False, "error": str(e)}

def list_files(iid):
    try:
        d = safe_incident_dir(iid)
        return {"ok": True, "files": sorted(n for n in os.listdir(d) if FILENAME_RE.match(n))}
    except Exception as e: return {"ok": False, "error": str(e)}

def read_file(iid, name):
    try: return {"ok": True, "text": safe_incident_file(iid, name).read_text(errors="replace")}
    except Exception as e: return {"ok": False, "error": str(e)}

def events():
    r = run("journalctl", ["-u", "eiciel-watch", "-n", "200", "--no-pager", "-o", "short-iso"])
    return {"ok": r["ok"], "text": r["stdout"] or r["stderr"]}

def audit():
    r = run("ausearch", ["-k", "priv_esc_unset", "--start", "today", "-i"])
    if not r["ok"]: return {"ok": True, "text": r["stderr"] or "(no audit events)"}
    return {"ok": True, "text": "\n".join(r["stdout"].splitlines()[-100:])}

def _parse_ss_line(line):
    parts = line.split(None, 5)
    if len(parts) < 5: return None
    rec = {"state": parts[0], "local": parts[3], "peer": parts[4],
           "process": parts[5] if len(parts) > 5 else ""}
    m = re.search(r'users:\(\(([^)]+)\)\)', rec["process"])
    if m:
        nm = re.match(r'"([^"]+)"', m.group(1)); pid = re.search(r'pid=(\d+)', m.group(1))
        if nm: rec["process_name"] = nm.group(1)
        if pid: rec["process_pid"] = pid.group(1)
    return rec

def netinfo():
    out = {"ok": True}
    ifaces = _jrun("ip", ["-j", "addr"]); links = _jrun("ip", ["-j", "link"])
    link_by_name = {l.get("ifname"): l for l in links}
    interfaces = []
    for i in ifaces:
        name = i.get("ifname"); link = link_by_name.get(name, {})
        addrs4, addrs6 = [], []
        for a in i.get("addr_info", []):
            fam = a.get("family"); local = a.get("local"); plen = a.get("prefixlen")
            if not local: continue
            if fam == "inet": addrs4.append(f"{local}/{plen}")
            elif fam == "inet6" and a.get("scope") != "link": addrs6.append(f"{local}/{plen}")
        interfaces.append({"name": name, "state": (link.get("operstate") or "UNKNOWN").upper(),
                           "mac": link.get("address",""), "ipv4": addrs4, "ipv6": addrs6})
    default_gw = ""
    for args in (["-j", "route"], ["-j", "-6", "route"]):
        for r in _jrun("ip", args):
            if r.get("dst") in ("default", "0.0.0.0/0", "::/0"):
                gw = r.get("gateway") or r.get("via") or ""
                if gw and not default_gw: default_gw = gw
                break
    listeners = []
    for proto, flag in (("tcp","-t"),("udp","-u")):
        r = run("ss", [flag, "-lnp"])
        for line in r["stdout"].splitlines()[1:]:
            rec = _parse_ss_line(line)
            if rec: rec["proto"] = proto; listeners.append(rec)
    connections = []
    r = run("ss", ["-tnp", "state", "established"])
    for line in r["stdout"].splitlines()[1:]:
        rec = _parse_ss_line(line)
        if rec: connections.append(rec)
    sessions = []
    r = run("who", ["-a"])
    for line in r["stdout"].splitlines():
        line = line.strip()
        if line: sessions.append({"raw": line})
    out["interfaces"] = interfaces; out["default_gateway"] = default_gw
    out["listeners"] = listeners[:100]; out["connections"] = connections[:100]
    out["sessions"] = sessions
    return out

def sessions_text():
    r = run("who", ["-a"]); w = run("w")
    return {"ok": True, "text": "══ who -a ══\n" + (r["stdout"] or "(none)") + "\n\n══ w ══\n" + (w["stdout"] or "(none)") + "\n"}

def sysinfo():
    out = {"ok": True}
    pk = run("dpkg-query", ["-f", "${binary:Package}\n", "-W"])
    out["package_count"] = len([l for l in pk["stdout"].splitlines() if l.strip()])
    try:
        st = os.statvfs("/"); total = st.f_blocks * st.f_frsize; free = st.f_bavail * st.f_frsize
        out["disk_used_pct"] = int(round(100.0 * (total - free) / total)) if total else 0
    except Exception: out["disk_used_pct"] = None
    out["kernel"] = run("uname", ["-r"])["stdout"].strip() or "?"
    out["uptime"] = run("uptime", ["-p"])["stdout"].strip() or "?"
    persist = False
    for p in ("/run/live/persistence", "/lib/live/mount/persistence"):
        if os.path.isdir(p) and os.listdir(p): persist = True; break
    out["persistence"] = persist
    return out

def apt_history():
    try: t = Path("/var/log/apt/history.log").read_text()
    except Exception as e: return {"ok": True, "text": f"(no apt history: {e})"}
    return {"ok": True, "text": "\n".join(t.splitlines()[-200:])}

def license_info():
    if not LICENSE_PUB.exists(): return {"ok": True, "enabled": False, "valid": False}
    if not LICENSE_JSON.exists(): return {"ok": True, "enabled": True, "valid": False, "error": "license.json not present"}
    try: data = json.loads(LICENSE_JSON.read_text())
    except Exception as e: return {"ok": True, "enabled": True, "valid": False, "error": f"cannot read: {e}"}
    r = run(LICENSE_CHECK, timeout=10)
    out = {"ok": True, "enabled": True, "valid": r["ok"], "license_id": data.get("license_id"),
           "issued_to": data.get("issued_to"), "not_before": data.get("not_before"),
           "not_after": data.get("not_after")}
    if not r["ok"]: out["error"] = (r["stderr"] or r["stdout"] or "verification failed").strip()
    return out

def metrics_current():
    try: return {"ok": True, "metrics": json.loads((METRICS_DIR / "current.json").read_text())}
    except FileNotFoundError: return {"ok": True, "metrics": None, "error": "sampler not running"}
    except Exception as e: return {"ok": False, "error": str(e)}

def metrics_history(limit=240):
    try: limit = max(10, min(int(limit), 2000))
    except (TypeError, ValueError): limit = 240
    try:
        with (METRICS_DIR / "history.jsonl").open() as f:
            lines = f.readlines()[-limit:]
    except FileNotFoundError: return {"ok": True, "history": []}
    out = []
    for line in lines:
        try: out.append(json.loads(line))
        except Exception: continue
    return {"ok": True, "history": out}

def detections(limit=200):
    try: limit = max(10, min(int(limit), 2000))
    except (TypeError, ValueError): limit = 200
    try:
        with DETECTIONS_LOG.open() as f:
            lines = f.readlines()[-limit:]
    except FileNotFoundError: return {"ok": True, "detections": []}
    out = []
    for line in lines:
        try: out.append(json.loads(line))
        except Exception: continue
    out.reverse()
    return {"ok": True, "detections": out}

def _verify_totp(code):
    try:
        secret = _read_totp_secret()
        if not secret: return False
        import pyotp
        return pyotp.TOTP(secret).verify(code or "", valid_window=1)
    except Exception: return False

def log_offhost(event, details):
    try:
        cfg = parse_env(CONFIG_PATH.read_text())
        url = cfg.get("WEBHOOK_URL", "")
        if not url: return
        payload = json.dumps({"type": "action_log", "event": event,
                              "host": pysocket.gethostname(),
                              "time": datetime.datetime.utcnow().isoformat() + "Z",
                              "details": details}).encode()
        req = urllib.request.Request(url, data=payload,
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
    except Exception: pass

def _refuse_unconfigured(op):
    log_offhost("destructive_op_refused", {"op": op, "reason": "secrets_locked"})
    return {"ok": False, "reauth_required": True, "reauth_not_configured": True,
            "error": "secrets are locked; enter the passphrase at boot"}

def _refuse_rate(uid, seconds):
    log_offhost("destructive_op_rate_limited", {"uid": uid, "seconds": seconds})
    return {"ok": False, "reauth_required": True, "rate_limited": True,
            "error": f"too many failures; locked for {seconds}s"}

def _refuse_replay(uid):
    log_offhost("reauth_replay", {"uid": uid})
    return {"ok": False, "reauth_required": True, "replay": True,
            "error": "this code was already used"}

def _handle_reauth(op, args, uid):
    if not _reauth_configured(): return _refuse_unconfigured(op)
    code = ((args or {}).get("totp") or "").strip()
    if not code:
        return {"ok": False, "reauth_required": True, "error": "missing TOTP"}

    if not _verify_totp(code):
        with _auth_lock:
            now = time.time()
            count, last = _reauth_fails.get(uid, (0, 0.0))
            if now - last > REAUTH_LOCKOUT_S: count = 0
            count += 1
            _reauth_fails[uid] = (count, now)
            if count > REAUTH_MAX_FAILS:
                wait = int(REAUTH_LOCKOUT_S - (now - last))
                if wait < 1: wait = 1
                log_offhost("reauth_denied", {"op": op, "uid": uid, "reason": "bad_totp_rate"})
                return _refuse_rate(uid, wait)
        log_offhost("reauth_denied", {"op": op, "uid": uid, "reason": "bad_totp"})
        return {"ok": False, "reauth_required": True, "error": "invalid TOTP"}

    with _auth_lock:
        now = time.time()
        _prune_codes(now)
        key = (uid, code)
        if key in _recent_codes:
            return _refuse_replay(uid)
        _recent_codes[key] = now
        _reauth_fails.pop(uid, None)

    return None

def trigger(args=None, uid=0):
    r = _handle_reauth("trigger", args, uid)
    if r is not None: return r
    try:
        subprocess.Popen([CONTAIN_SCRIPT, "--triggered-by", "dashboard"],
                         stdout=open("/var/log/eiciel-contain.log", "ab"),
                         stderr=subprocess.STDOUT, start_new_session=True)
        log_offhost("containment_triggered", {"by": "dashboard", "uid": uid})
        return {"ok": True, "output": "containment started"}
    except Exception as e: return {"ok": False, "error": str(e)}

def lift(args=None, uid=0):
    r = _handle_reauth("lift", args, uid)
    if r is not None: return r
    r2 = run("nft", ["delete", "table", "inet", "eiciel_contain"])
    log_offhost("isolation_lifted", {"ok": r2["ok"], "uid": uid})
    return {"ok": r2["ok"], "output": r2["stdout"] + r2["stderr"]}

HANDLERS = {
    "config":         lambda a, u: read_config(),
    "state":          lambda a, u: get_state(),
    "incidents":      lambda a, u: list_incidents(),
    "incident-log":   lambda a, u: read_log(a.get("id", "")),
    "incident-files": lambda a, u: list_files(a.get("id", "")),
    "incident-file":  lambda a, u: read_file(a.get("id", ""), a.get("name", "")),
    "events":         lambda a, u: events(),
    "audit":          lambda a, u: audit(),
    "trigger":        lambda a, u: trigger(a, u),
    "lift":           lambda a, u: lift(a, u),
    "license-state":  lambda a, u: license_info(),
    "license-info":   lambda a, u: license_info(),
    "netinfo":        lambda a, u: netinfo(),
    "sessions":       lambda a, u: sessions_text(),
    "sysinfo":        lambda a, u: sysinfo(),
    "apt-history":    lambda a, u: apt_history(),
    "metrics":        lambda a, u: metrics_current(),
    "metric-history": lambda a, u: metrics_history(a.get("limit", 240)),
    "detections":     lambda a, u: detections(a.get("limit", 200)),
}

def peer_uid(sock):
    try:
        raw = sock.getsockopt(pysocket.SOL_SOCKET, pysocket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, gid = struct.unpack("3i", raw)
    except Exception: return None
    return (uid, gid)

def peer_allowed(sock):
    cred = peer_uid(sock)
    if cred is None: return False
    uid, gid = cred
    if uid == 0: return True
    try:
        user = pwd.getpwuid(uid)
        groups = os.getgrouplist(user.pw_name, gid)
        return grp.getgrnam(SOCK_GROUP).gr_gid in groups
    except Exception: return False

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        if not peer_allowed(self.connection):
            self._send({"ok": False, "error": "permission denied"}); return
        cred = peer_uid(self.connection) or (0, 0)
        uid = cred[0]
        line = self.rfile.readline(65536)
        if not line: return
        try: req = json.loads(line.decode("utf-8"))
        except Exception:
            self._send({"ok": False, "error": "bad json"}); return
        op = req.get("op"); args = req.get("args") or {}
        fn = HANDLERS.get(op)
        if not fn:
            self._send({"ok": False, "error": f"unknown op {op!r}"}); return
        try: self._send(fn(args, uid))
        except Exception as e: self._send({"ok": False, "error": str(e)})
    def _send(self, obj):
        try: self.wfile.write((json.dumps(obj) + "\n").encode("utf-8"))
        except Exception: pass

class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128

def main():
    if LICENSE_PUB.exists() and not LICENSE_FLAG.exists():
        print("eicield: system is unlicensed", file=sys.stderr)
        sys.exit(1)
    if not _reauth_configured():
        print("eicield: secrets locked (no passphrase entered at boot)", file=sys.stderr)
    if os.path.exists(SOCK_PATH): os.unlink(SOCK_PATH)
    srv = Server(SOCK_PATH, Handler)
    os.chmod(SOCK_PATH, 0o660)
    try: os.chown(SOCK_PATH, 0, grp.getgrnam(SOCK_GROUP).gr_gid)
    except KeyError:
        print(f"eicield: group {SOCK_GROUP!r} missing", file=sys.stderr); sys.exit(1)
    print(f"eicield listening on {SOCK_PATH}", file=sys.stderr, flush=True)
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

[Service]
Type=simple
PAMName=eiciel-service
User=root
Group=root
ExecStart=/usr/bin/python3 /usr/local/lib/eicield/eicield.py
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/run /var/lib/incidents /var/log /etc/eiciel /var/lib/eiciel-detections /run/eiciel
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

  echo "📦 npm install…"
  npm install --no-audit --no-fund --loglevel=error
  echo "📦 electron-packager…"
  npm run build

  install -d -m 755 "$DAEMON_DIST"
  install -m 755 daemon/eicield.py          "$DAEMON_DIST/eicield.py"
  install -m 644 daemon/eicield.service     "$DAEMON_DIST/eicield.service"

  cd "$ROOT"
  echo "✅  [1/2] App: $APP_DIST"
}

# ═══════════════════════════════════════════════════════════════════
#  build_iso — v2.5.0
# ═══════════════════════════════════════════════════════════════════
build_iso() {
  echo ""; echo "▶▶▶  [2/2] Building live ISO v2.5.0"; echo ""
  [[ $EUID -eq 0 ]] || { echo "❌ Run as root"; exit 1; }
  for cmd in lb debootstrap xorriso mksquashfs jq openssl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ Missing tool: $cmd"; exit 1; }
  done

  if [ "$LICENSE_GATE_MODE" != "none" ]; then
    case "$LICENSE_GATE_MODE" in soft|hard) ;; *) echo "❌ bad LICENSE_GATE_MODE"; exit 1 ;; esac
    [ -n "$LICENSE_PUBKEY_FILE" ] && [ -f "$LICENSE_PUBKEY_FILE" ] || { echo "❌ LICENSE_PUBKEY_FILE required"; exit 1; }
  fi

  SHIP_DASHBOARD=0
  case "$INCLUDE_DASHBOARD" in
    1) SHIP_DASHBOARD=1 ;;
    0) SHIP_DASHBOARD=0 ;;
    auto) [ -d "$APP_DIST" ] && SHIP_DASHBOARD=1 ;;
  esac
  if [ "$SHIP_DASHBOARD" = "1" ]; then
    [ -d "$APP_DIST" ]    || { echo "❌ $APP_DIST missing"; exit 1; }
    [ -d "$DAEMON_DIST" ] || { echo "❌ $DAEMON_DIST missing"; exit 1; }
  fi

  echo "📦 Cleaning old build state…"
  lb clean --purge >/dev/null 2>&1 || true
  rm -rf auto chroot binary cache .build local bootstrap.log chroot.log binary.log 2>/dev/null || true
  rm -rf config/hooks config/package-lists config/bootloaders \
         config/includes.chroot config/includes.installer 2>/dev/null || true

  mkdir -p auto config/hooks config/package-lists config/bootloaders/grub \
           config/includes.chroot/etc/eiciel \
           config/includes.chroot/etc/audit/rules.d \
           config/includes.chroot/etc/fail2ban/jail.d \
           config/includes.chroot/etc/fail2ban/action.d \
           config/includes.chroot/etc/systemd/system \
           config/includes.chroot/etc/systemd/system/getty@tty1.service.d \
           config/includes.chroot/etc/ssh/sshd_config.d \
           config/includes.chroot/etc/profile.d \
           config/includes.chroot/etc/apt/apt.conf.d \
           config/includes.chroot/etc/pam.d \
           config/includes.chroot/etc/tmpfiles.d \
           config/includes.chroot/etc/X11 \
           config/includes.chroot/etc/xdg/openbox \
           config/includes.chroot/usr/local/sbin \
           config/includes.chroot/usr/local/bin \
           config/includes.chroot/usr/share/applications \
           config/includes.chroot/home/admin \
           config/includes.chroot/root/.ssh \
           config/includes.chroot/var/lib/incidents \
           config/includes.chroot/var/lib/eiciel-metrics \
           config/includes.chroot/var/lib/eiciel-detections

  BOOTAPPEND="boot=live components quiet loglevel=3 username=admin hostname=${HOSTNAME_NEW}"
  [ "$ENABLE_PERSISTENCE" = "1" ] && BOOTAPPEND="$BOOTAPPEND persistence persistence-storage=filesystem"
  if [ "$BUILD_MODE" = "install" ]; then INSTALLER_OPT="live"; else INSTALLER_OPT="none"; fi

  cat > auto/config <<EOF
#!/bin/bash
set -e
lb config noauto \\
  --mode debian --distribution bookworm --architectures amd64 \\
  --binary-images iso-hybrid \\
  --archive-areas "main contrib non-free non-free-firmware" \\
  --bootappend-live "$BOOTAPPEND" \\
  --linux-flavours amd64 --debian-installer $INSTALLER_OPT --memtest none \\
  --iso-application "Eiciel IR Console" --iso-publisher "Eiciel" --iso-volume "EICIEL_IR" \\
  --apt-options "--yes --no-install-recommends" --apt-indices false --apt-recommends false \\
  --firmware-binary false --firmware-chroot true \\
  --initramfs live-boot --compression xz \\
  --bootloader "grub-efi grub-pc" --system live --initsystem systemd \\
  --mirror-bootstrap "http://deb.debian.org/debian/" \\
  --mirror-chroot "http://deb.debian.org/debian/" \\
  --mirror-chroot-security "http://security.debian.org/debian-security/" \\
  --mirror-binary "http://deb.debian.org/debian/" \\
  --mirror-binary-security "http://security.debian.org/debian-security/"
EOF
  chmod +x auto/config

  cat > config/hooks/005-fix-sources.hook.chroot <<'EOF'
#!/bin/bash
set -e
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
cat > /etc/apt/sources.list <<'EOSRC'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOSRC
apt-get update -qq
EOF

  cat > config/hooks/006-sysctl.hook.chroot <<'EOF'
#!/bin/bash
set -e
install -d -m 755 /etc/sysctl.d
cat > /etc/sysctl.d/99-eiciel.conf <<'SYSCTL'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.kexec_load_disabled = 1
kernel.yama.ptrace_scope = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
SYSCTL
EOF
  chmod +x config/hooks/006-sysctl.hook.chroot

  if [ "$ENABLE_AUTO_UPDATES" = "1" ]; then
    cat > config/hooks/007-unattended.hook.chroot <<'EOF'
#!/bin/bash
set -e
apt-get install -y --no-install-recommends unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
systemctl enable unattended-upgrades.service
systemctl enable apt-daily.timer
systemctl enable apt-daily-upgrade.timer
EOF
    chmod +x config/hooks/007-unattended.hook.chroot
  fi

  cat > config/hooks/010-ssh.hook.chroot <<'EOF'
#!/bin/bash
set -e
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-eiciel.conf <<'EOSSH'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
EOSSH
systemctl enable ssh
EOF

  cat > config/hooks/011-mfa.hook.chroot <<'EOF'
#!/bin/bash
set -e
apt-get install -y --no-install-recommends python3-pyotp qrencode

if [ "${MFA_SUDO:-1}" = "1" ]; then
  cat > /etc/pam.d/sudo <<'PAM'
#%PAM-1.0
auth       required     pam_env.so
auth       required     pam_exec.so expose_authtok quiet /usr/local/sbin/eiciel-pam-totp.sh
auth       required     pam_permit.so
account    include      common-account
password   include      common-password
session    required     pam_limits.so
session    include      common-session
PAM
fi

if [ "${MFA_SSH:-0}" = "1" ]; then
  cat > /etc/ssh/sshd_config.d/10-mfa.conf <<'SSHD'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication yes
AuthenticationMethods publickey,keyboard-interactive
ChallengeResponseAuthentication yes
UsePAM yes
SSHD
  cat > /etc/pam.d/sshd <<'PAM'
#%PAM-1.0
auth       required     pam_env.so
auth       required     pam_exec.so expose_authtok quiet /usr/local/sbin/eiciel-pam-totp.sh
auth       required     pam_permit.so
account    include      common-account
password   include      common-password
session    required     pam_loginuid.so
session    include      common-session
session    optional     pam_motd.so
session    optional     pam_mail.so standard
PAM
fi
EOF
  chmod +x config/hooks/011-mfa.hook.chroot

  cat > config/hooks/012-wireshark.hook.chroot <<'EOF'
#!/bin/bash
set -e
if dpkg -l wireshark-common >/dev/null 2>&1; then
  echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive wireshark-common || true
fi
EOF
  chmod +x config/hooks/012-wireshark.hook.chroot

  cat > config/hooks/020-users.hook.chroot <<'EOF'
#!/bin/bash
set -e
if ! id -u admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,video,audio,netdev admin
  if [ "${BUILD_MODE:-live}" = "live" ]; then passwd -l admin; fi
fi
install -d -m 700 -o admin -g admin /home/admin/.ssh
cat > /etc/sudoers.d/admin <<'SUDO'
admin ALL=(ALL:ALL) ALL
SUDO
chmod 440 /etc/sudoers.d/admin
EOF

  cat > config/hooks/021-eiciel-daemon-user.hook.chroot <<'EOF'
#!/bin/bash
set -e
getent group eiciel >/dev/null || groupadd --system eiciel
id -u eiciel >/dev/null 2>&1 || \
  useradd --system --gid eiciel --home-dir /var/lib/eiciel --create-home --shell /usr/sbin/nologin eiciel
usermod -aG eiciel admin
getent group wireshark >/dev/null && usermod -aG wireshark admin || true
EOF
  chmod +x config/hooks/021-eiciel-daemon-user.hook.chroot

  cat > config/hooks/022-pam-eiciel.hook.chroot <<'EOF'
#!/bin/bash
set -e
cat > /etc/pam.d/eiciel-service <<'PAM'
#%PAM-1.0
auth    required  pam_permit.so
account required  pam_permit.so
session required  pam_loginuid.so
PAM
EOF
  chmod +x config/hooks/022-pam-eiciel.hook.chroot

  cat > config/hooks/024-eiciel-secrets.hook.chroot <<'EOF'
#!/bin/bash
set -e

install -d -m 755 /usr/local/sbin /usr/local/bin
install -d -m 755 /etc/eiciel

cat > /usr/local/sbin/eiciel-secrets-unlock.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail

SEALED=/etc/eiciel/secrets.gpg
OUT=/run/eiciel/secrets.env

install -d -m 700 /run/eiciel

if [ ! -s "$SEALED" ]; then
  logger -t eiciel-secrets "no sealed secrets; TOTP and GitHub upload disabled"
  exit 0
fi

for attempt in 1 2 3; do
  if [ ! -c /dev/tty ] && [ ! -t 0 ]; then
    logger -t eiciel-secrets "no console for passphrase prompt"
    exit 0
  fi

  pw="$(systemd-ask-password --echo=no "Eiciel passphrase: " </dev/console 2>/dev/null || true)"
  [ -n "$pw" ] || continue

  if printf '%s' "$pw" | gpg --batch --yes --quiet \
        --pinentry-mode loopback --passphrase-fd 0 \
        --decrypt "$SEALED" > "$OUT.tmp" 2>/dev/null; then
    mv "$OUT.tmp" "$OUT"
    chmod 600 "$OUT"
    logger -t eiciel-secrets "secrets unlocked"
    unset pw
    exit 0
  fi

  rm -f "$OUT.tmp"
  logger -t eiciel-secrets "wrong passphrase (attempt $attempt)"
done

logger -t eiciel-secrets "failed to unlock after 3 attempts"
exit 1
SCRIPT
chmod 755 /usr/local/sbin/eiciel-secrets-unlock.sh

cat > /usr/local/sbin/eiciel-secrets-lock.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
rm -f /run/eiciel/secrets.env
SCRIPT
chmod 755 /usr/local/sbin/eiciel-secrets-lock.sh

cat > /usr/local/bin/eiciel-seal-secrets <<'SCRIPT'
#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

SEALED=/etc/eiciel/secrets.gpg
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"

install -d -m 755 /etc/eiciel

echo "This will generate a new TOTP secret and, optionally, accept a GitHub token."
echo "Both will be sealed under a passphrase you provide now."
echo "The passphrase must be entered on every boot to unlock the secrets."
echo

TOTP="$(head -c 20 /dev/urandom | base32 | tr -d '=' | head -c 32)"
[ -n "$TOTP" ] || { echo "❌ failed to generate TOTP"; exit 1; }

printf 'GitHub token (leave empty to skip upload): '
read -r GH

read -r -s -p "Passphrase: " P1; echo
read -r -s -p "Confirm:    " P2; echo
[ "$P1" = "$P2" ] || { echo "❌ passphrase mismatch"; exit 1; }
[ -n "$P1" ] || { echo "❌ empty passphrase"; exit 1; }

{
  echo "TOTP_SECRET=$TOTP"
  [ -n "$GH" ] && echo "GITHUB_TOKEN=$GH"
} > "$TMP"

printf '%s' "$P1" | gpg --batch --yes --quiet \
  --symmetric --cipher-algo AES256 \
  --pinentry-mode loopback --passphrase-fd 0 \
  --output "$SEALED" "$TMP"

chmod 600 "$SEALED"
unset P1 P2

rm -f /var/lib/eiciel/totp/admin.secret 2>/dev/null || true
rm -f /etc/eiciel/github-credentials.env 2>/dev/null || true

echo
echo "✅ Sealed to $SEALED"
echo
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TOTP secret — enroll in your authenticator NOW          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo
echo "Secret: $TOTP"
echo
if command -v qrencode >/dev/null; then
  qrencode -t ANSIUTF8 "otpauth://totp/Eiciel:admin@$(hostname)?secret=$TOTP&issuer=Eiciel"
fi
echo
echo "Reboot for the sealed secrets to take effect."
SCRIPT
chmod 755 /usr/local/bin/eiciel-seal-secrets

cat > /usr/local/sbin/eiciel-pam-totp.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail

IFS= read -r code || true
code="$(printf '%s' "$code" | tr -d '[:space:]')"
[ -n "$code" ] || exit 1

SECRETS=/run/eiciel/secrets.env
[ -s "$SECRETS" ] || { logger -t eiciel-pam "secrets not unlocked"; exit 1; }

SECRET="$(awk -F= '/^TOTP_SECRET=/{sub(/^TOTP_SECRET=/,""); gsub(/"/,""); print; exit}' "$SECRETS")"
[ -n "$SECRET" ] || { logger -t eiciel-pam "no TOTP secret"; exit 1; }

exec python3 - "$SECRET" "$code" <<'PY'
import sys, pyotp
sys.exit(0 if pyotp.TOTP(sys.argv[1]).verify(sys.argv[2], valid_window=1) else 1)
PY
SCRIPT
chmod 755 /usr/local/sbin/eiciel-pam-totp.sh

cat > /etc/systemd/system/eiciel-secrets-unlock.service <<'UNIT'
[Unit]
Description=Eiciel secrets unlock (passphrase prompt)
DefaultDependencies=no
Before=sysinit.target eicield.service eiciel-watch.service eiciel-detect.service eiciel-license-gate.service
After=local-fs.target
ConditionPathExists=/etc/eiciel/secrets.gpg

[Service]
Type=oneshot
RemainAfterExit=yes
StandardInput=tty-force
StandardOutput=journal
StandardError=journal
TTYPath=/dev/console
TTYReset=yes
TTYVHangup=no
ExecStart=/usr/local/sbin/eiciel-secrets-unlock.sh

[Install]
WantedBy=sysinit.target
UNIT

cat > /etc/systemd/system/eiciel-secrets-lock.service <<'UNIT'
[Unit]
Description=Eiciel secrets lock (shutdown)
DefaultDependencies=no
Before=shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/sbin/eiciel-secrets-lock.sh

[Install]
WantedBy=shutdown.target
UNIT

cat > /etc/tmpfiles.d/eiciel.conf <<'TMPF'
d /run/eiciel 0700 root root -
TMPF
EOF
  chmod +x config/hooks/024-eiciel-secrets.hook.chroot

  cat > "$CHROOT/etc/eiciel/config.env" <<EOF
MGMT_IP="$MGMT_IP"
WEBHOOK_URL="$WEBHOOK_URL"
STOP_SERVICES="$STOP_SERVICES"
ISOLATION_TIMEOUT="${ISOLATION_TIMEOUT}"
INCIDENT_ROOT="/var/lib/incidents"
COOLDOWN_SECONDS=$COOLDOWN_SECONDS
AUTO_TRIGGER="$AUTO_TRIGGER"
AUTO_TRIGGER_MIN_SEVERITY="$AUTO_TRIGGER_MIN_SEVERITY"
DETECT_AUTO_TRIGGER="$DETECT_AUTO_TRIGGER"
DETECT_INBOUND_EXPECTED_PORTS="$DETECT_INBOUND_EXPECTED_PORTS"
DETECT_INBOUND_TRUSTED_IPS="$DETECT_INBOUND_TRUSTED_IPS"
DETECT_SSH_FAIL_THRESHOLD="$DETECT_SSH_FAIL_THRESHOLD"
DETECT_SSH_FAIL_WINDOW="$DETECT_SSH_FAIL_WINDOW"
DETECT_SSH_MIN_USERS="$DETECT_SSH_MIN_USERS"
DETECT_EGRESS_MB_PER_SEC="$DETECT_EGRESS_MB_PER_SEC"
DETECT_DNS_THRESHOLD="$DETECT_DNS_THRESHOLD"
DETECT_INBOUND_NEW_THRESHOLD="$DETECT_INBOUND_NEW_THRESHOLD"
DETECT_MAX_TRIGGERS_PER_HOUR="$DETECT_MAX_TRIGGERS_PER_HOUR"
DETECT_DRY_RUN="$DETECT_DRY_RUN"
DETECT_WEB_THRESHOLD="$DETECT_WEB_THRESHOLD"
DETECT_WEB_WINDOW="$DETECT_WEB_WINDOW"
GITHUB_ENABLED="$GITHUB_UPLOAD_ENABLED"
GITHUB_OWNER="$GITHUB_UPLOAD_OWNER"
GITHUB_REPO="$GITHUB_UPLOAD_REPO"
GITHUB_BRANCH="$GITHUB_UPLOAD_BRANCH"
GITHUB_CREDENTIALS="/run/eiciel/secrets.env"
RESTIC_REPO="$RESTIC_REPO"
RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
EOF
  chmod 600 "$CHROOT/etc/eiciel/config.env"

  cat > "$CHROOT/usr/local/sbin/eiciel-github-release.sh" <<'GHREL'
#!/bin/bash
set -euo pipefail
CREDS="${GITHUB_CREDENTIALS:-/run/eiciel/secrets.env}"
[ -f "$CREDS" ] || { echo "github: no creds"; exit 1; }
while IFS='=' read -r k v; do
  case "$k" in ''|\#*) continue ;; esac
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  export "$k=$v"
done < "$CREDS"

if [ -f /etc/eiciel/config.env ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$k" in
      GITHUB_OWNER)  [ -z "${GITHUB_OWNER:-}"  ] && export GITHUB_OWNER="$v" ;;
      GITHUB_REPO)   [ -z "${GITHUB_REPO:-}"   ] && export GITHUB_REPO="$v" ;;
      GITHUB_BRANCH) [ -z "${GITHUB_BRANCH:-}" ] && export GITHUB_BRANCH="$v" ;;
    esac
  done < /etc/eiciel/config.env
fi

for v in GITHUB_TOKEN GITHUB_OWNER GITHUB_REPO; do
  eval "[ -n \"\${$v:-}\" ]" || { echo "github: $v missing" >&2; exit 1; }
done

DIR="${1:-}"; [ -d "$DIR" ] || { echo "usage: $0 <incident-dir> [trigger] [reason]"; exit 2; }
INCIDENT_ID="$(basename "$DIR")"
TRIG="${2:-manual}"; REASON="${3:-}"
HOST="$(hostname)"; TS="$(date -u +%FT%TZ)"
TAG="incident-$INCIDENT_ID"
API="https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28" -H "User-Agent: eiciel-uploader")

REPO_META="$(curl -fsS --max-time 20 "${AUTH[@]}" "$API" 2>/dev/null || true)"
IS_PRIVATE="$(echo "$REPO_META" | jq -r '.private // empty' 2>/dev/null || true)"
if [ "$IS_PRIVATE" != "true" ]; then
  echo "github: refusing — repo not private" >&2
  exit 1
fi

BODY="$(mktemp)"
{
  echo "**Triggered by:** \`$TRIG\`"
  echo "**Host:** \`$HOST\`"
  echo "**Time:** $TS"
  [ -n "$REASON" ] && echo "**Reason:** $REASON"
  echo ""
  echo "<details><summary>containment.log</summary>"
  echo ""
  echo '```'
  head -c 61440 "$DIR/containment.log" 2>/dev/null || echo "(no log)"
  echo '```'
  echo ""
  echo "</details>"
} > "$BODY"

EXIST="$(curl -fsS --max-time 30 "${AUTH[@]}" "$API/releases/tags/$TAG" 2>/dev/null | jq -r '.id // empty' || true)"
if [ -n "$EXIST" ]; then
  REL_ID="$EXIST"
else
  REL="$(curl -fsS --max-time 60 -X POST "$API/releases" "${AUTH[@]}" \
        -H "Content-Type: application/json" \
        --data-binary "$(jq -nc --arg t "$TAG" --arg n "Incident $INCIDENT_ID — $HOST" \
          --arg b "$(cat "$BODY")" \
          '{tag_name:$t,name:$n,body:$b,draft:false,prerelease:false}')" 2>/dev/null || true)"
  REL_ID="$(echo "$REL" | jq -r '.id // empty')"
  [ -n "$REL_ID" ] || { echo "github: release create failed: $REL" >&2; rm -f "$BODY"; exit 1; }
fi

EX_NAMES="$(curl -fsS --max-time 30 "${AUTH[@]}" "$API/releases/$REL_ID/assets" | jq -r '.[].name' || true)"

ALLOW="containment.log ss.txt nft-before.txt ip-addr.txt ip-route.txt arp.txt
       ps.txt pstree.txt who.txt w.txt last.txt lastb.txt lsof-net.txt lsmod.txt
       mount.txt df.txt proc-exe-hashes.txt conntrack-before.txt keyfiles-stat.txt
       detections.jsonl metrics-current.json metrics-history.jsonl"

for n in $ALLOW; do
  f="$DIR/$n"
  [ -f "$f" ] || continue
  echo "$EX_NAMES" | grep -Fxq "$n" && continue
  enc="$(jq -rn --arg s "$n" '$s|@uri')"
  curl -fsS --max-time 900 -X POST \
    "https://uploads.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/$REL_ID/assets?name=$enc" \
    "${AUTH[@]}" -H "Content-Type: application/octet-stream" \
    --data-binary "@$f" >/dev/null 2>&1 || echo "github: $n failed" >&2
done

rm -f "$BODY"
echo "github: uploaded release $TAG"
GHREL
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-github-release.sh"

  if [ "$LICENSE_GATE_MODE" != "none" ]; then
    install -m 644 "$LICENSE_PUBKEY_FILE" "$CHROOT/etc/eiciel/license.pub"
    cat > "$CHROOT/usr/local/sbin/eiciel-license-check" <<'LICCHK_EOF'
#!/bin/bash
set -euo pipefail
PUBKEY="/etc/eiciel/license.pub"
LICENSE_JSON="/etc/eiciel/license.json"
LICENSE_SIG="/etc/eiciel/license.sig"
log() { logger -t eiciel-license "$*"; echo "[license] $*" >&2; }
if [ ! -f "$LICENSE_JSON" ] || [ ! -f "$LICENSE_SIG" ]; then
  dev="$(blkid -L EICIEL_LIC 2>/dev/null || true)"
  if [ -n "$dev" ]; then
    tmp="$(mktemp -d)"
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
      [ -f "$tmp/license.json" ] && install -m 600 "$tmp/license.json" "$LICENSE_JSON"
      [ -f "$tmp/license.sig" ]  && install -m 600 "$tmp/license.sig"  "$LICENSE_SIG"
      umount "$tmp" 2>/dev/null || true
    fi
    rmdir "$tmp" 2>/dev/null || true
  fi
fi
[ -f "$PUBKEY" ]       || { log "pubkey missing"; exit 1; }
[ -f "$LICENSE_JSON" ] || { log "license.json not found"; exit 1; }
[ -f "$LICENSE_SIG" ]  || { log "license.sig not found"; exit 1; }
if ! openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin \
       -in "$LICENSE_JSON" -sigfile "$LICENSE_SIG" >/dev/null 2>&1; then
  log "signature verification FAILED"; exit 1
fi
now="$(date -u +%s)"
nb="$(date -u -d "$(jq -r .not_before "$LICENSE_JSON")" +%s 2>/dev/null || echo 0)"
na="$(date -u -d "$(jq -r .not_after  "$LICENSE_JSON")" +%s 2>/dev/null || echo 0)"
[ "$now" -ge "$nb" ] || { log "not yet valid"; exit 1; }
[ "$now" -le "$na" ] || { log "expired"; exit 1; }
mid="$(jq -r '.machine_id // empty' "$LICENSE_JSON")"
if [ -n "$mid" ]; then
  actual="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr 'A-Z' 'a-z' || true)"
  [ "$mid" = "$actual" ] || { log "machine mismatch"; exit 1; }
fi
log "license OK"
exit 0
LICCHK_EOF
    chmod 755 "$CHROOT/usr/local/sbin/eiciel-license-check"

    cat > "$CHROOT/usr/local/sbin/eiciel-license-gate" <<'LICGATE_EOF'
#!/bin/bash
set -euo pipefail
rm -f /run/eiciel-licensed /run/eiciel-unlicensed
if /usr/local/sbin/eiciel-license-check; then
  touch /run/eiciel-licensed; echo "licensed" > /run/eiciel-license-state
else
  touch /run/eiciel-unlicensed; echo "unlicensed" > /run/eiciel-license-state
  logger -t eiciel-license "system running UNLICENSED"
fi
exit 0
LICGATE_EOF
    chmod 755 "$CHROOT/usr/local/sbin/eiciel-license-gate"

    cat > "$CHROOT/usr/local/bin/eiciel-license-install" <<'LICINST_EOF'
#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }
[ "$#" -eq 2 ] || { echo "usage: $0 <license.json|-> <license.sig>"; exit 2; }
install -d -m 755 /etc/eiciel
if [ "$1" = "-" ]; then cat > /etc/eiciel/license.json; chmod 600 /etc/eiciel/license.json
else install -m 600 "$1" /etc/eiciel/license.json; fi
install -m 600 "$2" /etc/eiciel/license.sig
if /usr/local/sbin/eiciel-license-check; then
  echo "✅ License installed. Rebooting in 5s…"; sleep 5; systemctl reboot
else
  echo "❌ License rejected."; rm -f /etc/eiciel/license.json /etc/eiciel/license.sig; exit 1
fi
LICINST_EOF
    chmod 755 "$CHROOT/usr/local/bin/eiciel-license-install"

    cat > "$CHROOT/etc/systemd/system/eiciel-license-gate.service" <<'GATE_UNIT'
[Unit]
Description=Eiciel license gate
DefaultDependencies=no
Before=sysinit.target basic.target eicield.service eiciel-watch.service eiciel-detect.service
After=local-fs.target systemd-remount-fs.service
ConditionPathExists=/etc/eiciel/license.pub

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/eiciel-license-gate

[Install]
WantedBy=sysinit.target
GATE_UNIT
  fi

  if [ "$ENABLE_METRICS" = "1" ]; then
    cat > "$CHROOT/usr/local/sbin/eiciel-metrics.sh" <<'METRICS_EOF'
#!/bin/bash
set -euo pipefail
STATE_DIR="/var/lib/eiciel-metrics"
HISTORY="$STATE_DIR/history.jsonl"
PREV="$STATE_DIR/prev.json"
KNOWN_IPS="$STATE_DIR/known_ips.txt"
MAX_HISTORY=2000
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"; touch "$KNOWN_IPS"

now=$(date +%s)
prev_rx=0; prev_tx=0; prev_ts=0
if [ -f "$PREV" ]; then
  prev_rx=$(jq -r '.rx_total // 0' "$PREV" 2>/dev/null || echo 0)
  prev_tx=$(jq -r '.tx_total // 0' "$PREV" 2>/dev/null || echo 0)
  prev_ts=$(jq -r '.ts // 0' "$PREV" 2>/dev/null || echo 0)
fi

read -r rx_total tx_total < <(
  awk 'NR>2 {gsub(":",""); if ($1 != "lo") {rx+=$2; tx+=$10}} END {print rx+0, tx+0}' /proc/net/dev
)
dt=$(( now - prev_ts )); [ "$dt" -le 0 ] && dt=1
rx_bps=$(( (rx_total - prev_rx) / dt ))
tx_bps=$(( (tx_total - prev_tx) / dt ))

ifaces_json=$(ip -o -j link show 2>/dev/null | jq -c '[.[] | {name: .ifname, state: .operstate, mtu: .mtu}]' 2>/dev/null || echo '[]')
listening=$(ss -H -tlun 2>/dev/null | wc -l)
established=$(ss -H -tun state established 2>/dev/null | wc -l)
listen_json=$(ss -H -tln 2>/dev/null | awk '{print $4}' | sort -u | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')

dns_total=0
if nft list chain inet eiciel_metrics dns_out >/dev/null 2>&1; then
  dns_total=$(nft list chain inet eiciel_metrics dns_out 2>/dev/null | grep -oE 'packets [0-9]+' | awk '{s+=$2} END {print s+0}')
fi

containers_json='{"runtime":"none","count":0,"names":[]}'
if [ -S /var/run/docker.sock ] && command -v docker >/dev/null 2>&1; then
  names=$(docker ps --format '{{.Names}}' 2>/dev/null | jq -R -s 'split("\n") | map(select(length>0))')
  count=$(echo "$names" | jq 'length')
  containers_json=$(jq -nc --arg rt docker --argjson n "$count" --argjson names "$names" '{runtime:$rt,count:$n,names:$names}')
elif [ -S /run/podman/podman.sock ] && command -v podman >/dev/null 2>&1; then
  names=$(podman ps --format '{{.Names}}' 2>/dev/null | jq -R -s 'split("\n") | map(select(length>0))')
  count=$(echo "$names" | jq 'length')
  containers_json=$(jq -nc --arg rt podman --argjson n "$count" --argjson names "$names" '{runtime:$rt,count:$n,names:$names}')
fi

db_json='{}'
for entry in "mysql:3306" "mariadb:3306" "postgresql:5432" "redis-server:6379" "mongod:27017"; do
  svc="${entry%%:*}"; port="${entry##*:}"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    conns=$(ss -H -tn state established "( sport = :$port or dport = :$port )" 2>/dev/null | wc -l)
    db_json=$(echo "$db_json" | jq -c --arg s "$svc" --argjson c "$conns" --argjson p "$port" '. + {($s):{active:true,port:$p,connections:$c}}')
  fi
done

web_json='{"active":false,"requests_5m":0,"errors_5m":0,"top_ips":[]}'
web_log=""
[ -r /var/log/nginx/access.log ] && web_log=/var/log/nginx/access.log
[ -r /var/log/apache2/access.log ] && web_log=/var/log/apache2/access.log
if [ -n "$web_log" ]; then
  tmp=$(mktemp)
  tail -n 2000 "$web_log" 2>/dev/null | awk '{ip=$1; n=split($4,t,":"); if(n<3)next; hm=t[2]":"t[3]; m=match($0,/" [0-9][0-9][0-9] /); status=m?substr($0,RSTART+2,3):"000"; print hm,ip,status}' > "$tmp"
  latest=$(tail -n 1 "$tmp" | awk '{print $1}')
  cutoff=""
  [ -n "$latest" ] && cutoff=$(date -u -d "$(date +%Y-%m-%d) $latest -5 minutes" +%H:%M 2>/dev/null || echo "$latest")
  reqs=$(awk -v c="$cutoff" 'c=="" || $1 >= c' "$tmp" | wc -l)
  errs=$(awk -v c="$cutoff" 'c=="" || ($1 >= c && $3+0 >= 400)' "$tmp" | wc -l)
  top=$(awk -v c="$cutoff" 'c=="" || $1 >= c {print $2}' "$tmp" | sort | uniq -c | sort -rn | head -5 | awk '{print $2,$1}' | jq -R -s 'split("\n") | map(select(length>0) | split(" ") | {ip:.[0],count:(.[1]|tonumber)})')
  rm -f "$tmp"
  web_json=$(jq -nc --argjson r "$reqs" --argjson e "$errs" --argjson t "$top" '{active:true,requests_5m:$r,errors_5m:$e,top_ips:$t}')
fi

failed_5m=0; success_5m=0
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
  sshlog=$(journalctl --since "5 minutes ago" -u ssh -u sshd --no-pager -o cat 2>/dev/null || true)
  failed_5m=$(echo "$sshlog" | grep -ci 'Failed password' || true)
  success_5m=$(echo "$sshlog" | grep -ci 'Accepted' || true)
fi
cur_ips=$(journalctl --since "1 hour ago" -u ssh -u sshd --no-pager -o cat 2>/dev/null | grep -oE 'from [0-9.]+' | awk '{print $2}' | sort -u || true)
new_ips=$(comm -13 <(sort "$KNOWN_IPS" 2>/dev/null) <(echo "$cur_ips" | sort -u) || true)
echo "$cur_ips" > "$KNOWN_IPS"
new_ips_json=$(echo "$new_ips" | jq -R -s 'split("\n") | map(select(length>0))')

snapshot=$(jq -nc \
  --argjson ts "$now" \
  --argjson rx "$rx_total" --argjson tx "$tx_total" \
  --argjson rxb "$rx_bps" --argjson txb "$tx_bps" \
  --argjson ifaces "$ifaces_json" \
  --argjson listen "$listening" --argjson est "$established" --argjson ljson "$listen_json" \
  --argjson dns "$dns_total" \
  --argjson cont "$containers_json" \
  --argjson db "$db_json" \
  --argjson web "$web_json" \
  --argjson f "$failed_5m" --argjson s "$success_5m" --argjson n "$new_ips_json" \
  '{ts:$ts,egress:{rx_total:$rx,tx_total:$tx,rx_bps:$rxb,tx_bps:$txb},interfaces:$ifaces,sockets:{listening:$listen,established:$est,listen_addrs:$ljson},dns:{queries_total:$dns},containers:$cont,databases:$db,web:$web,logins:{failed_5m:$f,success_5m:$s,new_ips:$n}}')

echo "$snapshot" > "$STATE_DIR/current.json.new"
mv "$STATE_DIR/current.json.new" "$STATE_DIR/current.json"
echo "$snapshot" >> "$HISTORY"
echo "$snapshot" > "$PREV"

if [ "$(wc -l < "$HISTORY")" -gt "$MAX_HISTORY" ]; then
  tail -n "$MAX_HISTORY" "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
fi
METRICS_EOF
    chmod 755 "$CHROOT/usr/local/sbin/eiciel-metrics.sh"

    cat > "$CHROOT/etc/systemd/system/eiciel-metrics.service" <<'MSVC'
[Unit]
Description=Eiciel metrics sampler (one pass)

[Service]
Type=oneshot
PAMName=eiciel-service
ExecStart=/usr/local/sbin/eiciel-metrics.sh
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=6
MSVC

    cat > "$CHROOT/etc/systemd/system/eiciel-metrics.timer" <<'MTMR'
[Unit]
Description=Eiciel metrics sampler (every 5s)

[Timer]
OnBootSec=20s
OnUnitActiveSec=5s
AccuracySec=1s

[Install]
WantedBy=timers.target
MTMR

    install -d -m 700 "$CHROOT/var/lib/eiciel-metrics"
  fi

  cat > "$CHROOT/usr/local/sbin/eiciel-detect.sh" <<'DETECT_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env

AUTO_TRIGGER="${AUTO_TRIGGER:-1}"
DETECT_AUTO_TRIGGER="${DETECT_AUTO_TRIGGER:-0}"
MIN_SEV="${AUTO_TRIGGER_MIN_SEVERITY:-high}"
INBOUND_EXPECTED_PORTS="${DETECT_INBOUND_EXPECTED_PORTS:-22 53}"
INBOUND_TRUSTED_IPS="${DETECT_INBOUND_TRUSTED_IPS:-}"
SSH_FAIL_THRESHOLD="${DETECT_SSH_FAIL_THRESHOLD:-100}"
SSH_FAIL_WINDOW="${DETECT_SSH_FAIL_WINDOW:-300}"
SSH_MIN_USERS="${DETECT_SSH_MIN_USERS:-3}"
EGRESS_MB_PER_SEC="${DETECT_EGRESS_MB_PER_SEC:-20}"
DNS_THRESHOLD="${DETECT_DNS_THRESHOLD:-500}"
INBOUND_NEW_THRESHOLD="${DETECT_INBOUND_NEW_THRESHOLD:-60}"
MAX_TRIGGERS_PER_HOUR="${DETECT_MAX_TRIGGERS_PER_HOUR:-3}"
DRY_RUN="${DETECT_DRY_RUN:-0}"
WEB_THRESHOLD="${DETECT_WEB_THRESHOLD:-5}"
WEB_WINDOW="${DETECT_WEB_WINDOW:-60}"

STATE_DIR=/var/lib/eiciel-detections
EVENTS="$STATE_DIR/events.jsonl"
RATE_FILE="$STATE_DIR/triggers.hour"
LOCK="/run/eiciel-contain.lock"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$EVENTS" "$RATE_FILE"

sev_rank() { case "$1" in low) echo 1;; medium) echo 2;; high) echo 3;; critical) echo 4;; *) echo 0;; esac; }
MIN_RANK=$(sev_rank "$MIN_SEV")
log() { logger -t eiciel-detect "$*"; echo "[$(date -u +%FT%TZ)] $*" >&2; }

emit_event() {
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg src "$1" --arg sev "$2" --arg r "$3" --arg d "$4" \
    '{ts:$ts,source:$src,severity:$sev,reason:$r,details:$d}' >> "$EVENTS"
  if [ "$(wc -l < "$EVENTS")" -gt 5000 ]; then
    tail -n 5000 "$EVENTS" > "$EVENTS.tmp" && mv "$EVENTS.tmp" "$EVENTS"
  fi
  log "detection: src=$1 sev=$2 $3"
}
rate_limit_ok() {
  local now last; now=$(date +%s); last=$(stat -c %Y "$RATE_FILE" 2>/dev/null || echo 0)
  [ $(( now - last )) -gt 3600 ] && { : > "$RATE_FILE"; return 0; }
  [ "$(wc -l < "$RATE_FILE")" -lt "$MAX_TRIGGERS_PER_HOUR" ]
}
cooldown_ok() {
  local cooldown="${COOLDOWN_SECONDS:-600}"
  [ -f "$LOCK" ] || return 0
  local last now; last=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0); now=$(date +%s)
  [ $(( now - last )) -ge "$cooldown" ]
}
trigger_containment() {
  local src="$1" sev="$2" reason="$3"
  if [ "$DETECT_AUTO_TRIGGER" != "1" ]; then
    log "detector auto-trigger disabled; logged only: $src/$sev $reason"
    return
  fi
  [ "$AUTO_TRIGGER" = "1" ] || { log "audit auto-trigger off"; return; }
  [ "$(sev_rank "$sev")" -ge "$MIN_RANK" ] || { log "sev below threshold"; return; }
  cooldown_ok || { log "cooldown"; return; }
  rate_limit_ok || { log "rate limit"; return; }
  [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: $src/$sev $reason"; return; }
  date -u +%FT%TZ >> "$RATE_FILE"; touch "$LOCK"
  log "AUTO-TRIGGER: $src/$sev — $reason"
  /usr/local/sbin/eiciel-contain.sh --triggered-by "detect:$src" --reason "$reason" \
    >>/var/log/eiciel-contain.log 2>&1 || log "containment FAILED"
}

watch_fail2ban() {
  journalctl -f -n0 -o cat -u fail2ban 2>/dev/null | while read -r line; do
    case "$line" in *"Ban "*)
      ip=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      emit_event "fail2ban" "medium" "fail2ban banned $ip" "$line" ;;
    esac
  done
}

watch_ssh() {
  local buf="$STATE_DIR/ssh-fails.tmp"; : > "$buf"
  journalctl -f -n0 -o cat -u ssh -u sshd 2>/dev/null | while read -r line; do
    case "$line" in
      *"Failed password"*|*"Invalid user"*)
        ip=$(echo "$line" | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')
        [ -n "$ip" ] || continue
        user="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="for"||$i=="user"){print $(i+1); exit}}')"
        [ -n "$user" ] || user="?"
        now=$(date +%s)
        echo "$now $ip $user" >> "$buf"
        awk -v c="$(( now - SSH_FAIL_WINDOW ))" '$1 >= c' "$buf" > "$buf.n" && mv "$buf.n" "$buf"
        top_ip="$(awk '{print $2}' "$buf" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
        [ -n "$top_ip" ] || continue
        count="$(awk -v ip="$top_ip" '$2==ip' "$buf" | wc -l)"
        users="$(awk -v ip="$top_ip" '$2==ip {print $3}' "$buf" | sort -u | wc -l)"
        if [ "$count" -ge "$SSH_FAIL_THRESHOLD" ] && [ "$users" -ge "$SSH_MIN_USERS" ]; then
          emit_event "ssh" "high" "$count failed SSH from $top_ip across $users users" "ip=$top_ip users=$users"
          trigger_containment "ssh" "high" "$count failed SSH from $top_ip"
          : > "$buf"
        fi ;;
    esac
  done
}

watch_metrics() {
  local cur="$STATE_DIR/metrics.prev"
  while sleep 10; do
    [ -f /var/lib/eiciel-metrics/current.json ] || continue
    tx_bps=$(jq -r '.egress.tx_bps // 0' /var/lib/eiciel-metrics/current.json 2>/dev/null || echo 0)
    dns_now=$(jq -r '.dns.queries_total // 0' /var/lib/eiciel-metrics/current.json 2>/dev/null || echo 0)
    dns_prev=0; [ -f "$cur" ] && dns_prev=$(jq -r '.dns // 0' "$cur" 2>/dev/null || echo 0)
    tx_mib=$(( tx_bps / 1048576 ))
    if [ "$tx_mib" -ge "$EGRESS_MB_PER_SEC" ]; then
      emit_event "egress" "high" "egress ${tx_mib} MiB/s outbound" "tx_bps=$tx_bps"
      trigger_containment "egress" "high" "outbound egress ${tx_mib} MiB/s"
    fi
    dns_delta=$(( dns_now - dns_prev ))
    if [ "$dns_delta" -gt "$DNS_THRESHOLD" ]; then
      emit_event "dns" "high" "DNS burst $dns_delta/10s" "delta=$dns_delta"
      trigger_containment "dns" "high" "DNS burst"
    fi
    echo "{\"dns\":$dns_now}" > "$cur"
  done
}

watch_inbound() {
  command -v conntrack >/dev/null || { log "watch_inbound: conntrack unavailable"; sleep infinity; return; }

  local local_ips
  local_ips="$(ip -o -4 addr show scope global 2>/dev/null \
                | awk '{print $4}' | cut -d/ -f1 | sort -u | paste -sd'|')"
  if [ -z "$local_ips" ]; then
    log "watch_inbound: no local IPs"; sleep infinity; return
  fi

  local expected_re
  expected_re="$(printf '%s' "$INBOUND_EXPECTED_PORTS" | tr ' ' '\n' | grep -v '^$' | paste -sd'|')"

  local trusted_re
  trusted_re="$(printf '%s %s' "${MGMT_IP:-}" "$INBOUND_TRUSTED_IPS" \
              | tr ' ' '\n' | grep -v '^$' | paste -sd'|')"

  log "watch_inbound: local=$local_ips expected=${expected_re:-none} trusted=${trusted_re:-none}"

  local buf="$STATE_DIR/inbound-new.tmp"; : > "$buf"
  conntrack -E -p tcp --state NEW 2>/dev/null | while read -r line; do
    src_ip="$(printf '%s' "$line"  | grep -oE 'src=[0-9.]+'   | head -1 | cut -d= -f2)"
    dst_ip="$(printf '%s' "$line"  | grep -oE 'dst=[0-9.]+'   | head -1 | cut -d= -f2)"
    dst_port="$(printf '%s' "$line" | grep -oE 'dport=[0-9]+' | head -1 | cut -d= -f2)"
    [ -n "$src_ip" ] && [ -n "$dst_ip" ] && [ -n "$dst_port" ] || continue

    printf '%s' "$dst_ip" | grep -qE "^(${local_ips})$" || continue

    if [ -n "$expected_re" ] && printf '%s' "$dst_port" | grep -qE "^(${expected_re})$"; then
      continue
    fi

    if [ -n "$trusted_re" ] && printf '%s' "$src_ip" | grep -qE "^(${trusted_re})$"; then
      continue
    fi

    now=$(date +%s)
    echo "$now $src_ip $dst_port" >> "$buf"
    awk -v c="$(( now - 30 ))" '$1 >= c' "$buf" > "$buf.n" && mv "$buf.n" "$buf"
    count=$(wc -l < "$buf")
    if [ "$count" -ge "$INBOUND_NEW_THRESHOLD" ]; then
      emit_event "inbound" "high" "$count unexpected inbound flows/30s" "last=$src_ip:$dst_port"
      trigger_containment "inbound" "high" "$count unexpected inbound flows"
      : > "$buf"
    fi
  done
}

watch_web() {
  local lg=""
  [ -r /var/log/nginx/access.log ] && lg=/var/log/nginx/access.log
  [ -r /var/log/apache2/access.log ] && lg=/var/log/apache2/access.log
  [ -n "$lg" ] || { log "watch_web: no access log"; sleep infinity; return; }
  local buf="$STATE_DIR/web-hits.tmp"; : > "$buf"
  local pat='(\.\./\.\./|%2e%2e%2f|%252e%252e|union[[:space:]]+(all[[:space:]]+)?select[[:space:]]|/etc/passwd|/proc/self/|/proc/1/|/wp-config\.php|/\.git/config)'
  tail -F -n0 "$lg" 2>/dev/null | while read -r line; do
    echo "$line" | grep -qiE "$pat" || continue
    status="$(echo "$line" | grep -oE '" [0-9][0-9][0-9] ' | head -1 | awk '{print $2}')"
    case "$status" in 2??|3??) ;; *) continue ;; esac
    ip=$(echo "$line" | awk '{print $1}')
    [ -n "$ip" ] || continue
    now=$(date +%s)
    echo "$now $ip" >> "$buf"
    awk -v c="$(( now - WEB_WINDOW ))" '$1 >= c' "$buf" > "$buf.n" && mv "$buf.n" "$buf"
    count=$(awk -v ip="$ip" '$2==ip' "$buf" | wc -l)
    if [ "$count" -ge "$WEB_THRESHOLD" ]; then
      emit_event "web" "high" "web attack: $count from ${ip}" "ip=$ip"
      log "web detection logged; auto-trigger disabled"
      awk -v ip="$ip" '$2!=ip' "$buf" > "$buf.n" && mv "$buf.n" "$buf"
    fi
  done
}

watch_new_ip() {
  local seen="$STATE_DIR/seen-ssh-ips.txt"; touch "$seen"
  journalctl -f -n0 -o cat -u ssh -u sshd 2>/dev/null | while read -r line; do
    case "$line" in *"Accepted publickey"*|*"Accepted password"*)
      ip=$(echo "$line" | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')
      [ -n "$ip" ] || continue
      if ! grep -qx "$ip" "$seen"; then
        echo "$ip" >> "$seen"
        emit_event "login" "medium" "first-ever SSH from $ip" "ip=$ip"
      fi ;;
    esac
  done
}

log "detect: starting (audit_trig=$AUTO_TRIGGER detect_trig=$DETECT_AUTO_TRIGGER min_sev=$MIN_SEV)"
watch_fail2ban &
watch_ssh &
watch_metrics &
watch_inbound &
watch_web &
watch_new_ip &
wait
DETECT_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-detect.sh"

  cat > "$CHROOT/etc/systemd/system/eiciel-detect.service" <<'DS'
[Unit]
Description=Eiciel multi-source attacker detector
After=network.target auditd.service fail2ban.service
Wants=fail2ban.service

[Service]
Type=simple
PAMName=eiciel-service
ExecStart=/usr/local/sbin/eiciel-detect.sh
RefuseManualStop=yes
Restart=always
RestartSec=5
Nice=2

[Install]
WantedBy=multi-user.target
DS

  cat > "$CHROOT/etc/fail2ban/action.d/eiciel-notify.conf" <<'F2B_ACTION'
[Definition]
actionstart =
actionstop  =
actioncheck =
actionban   = logger -t fail2ban-action "Ban <ip> from <name> (eiciel-notify)"
actionunban = logger -t fail2ban-action "Unban <ip> from <name>"
F2B_ACTION

  cat > "$CHROOT/usr/local/sbin/eiciel-contain.sh" <<'CONTAIN_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env

# S5: mutex prevents two containments racing on nft table create/delete.
exec 9>/run/eiciel-contain.mutex
if ! flock -n 9; then
  logger -t eiciel "containment already in progress; refusing concurrent run"
  exit 0
fi

GITHUB_ENABLED="${GITHUB_ENABLED:-0}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RESTIC_REPO="${RESTIC_REPO:-}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-}"

TRIGGERED_BY="manual"; TRIGGER_REASON=""; INVOKING_TTY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --triggered-by) TRIGGERED_BY="$2"; shift 2 ;;
    --reason)       TRIGGER_REASON="$2"; shift 2 ;;
    --keep-tty)     INVOKING_TTY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "$INVOKING_TTY" ]; then
  _t="$(tty 2>/dev/null || true)"
  case "$_t" in
    /dev/*) INVOKING_TTY="${_t#/dev/}" ;;
    *)      INVOKING_TTY="" ;;
  esac
fi

INCIDENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INCIDENT_DIR="$INCIDENT_ROOT/$INCIDENT_ID"
mkdir -p "$INCIDENT_DIR"; chmod 700 "$INCIDENT_DIR"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$INCIDENT_DIR/containment.log" >&2; }
log "=== Incident $INCIDENT_ID (triggered_by=$TRIGGERED_BY) ==="
[ -n "$TRIGGER_REASON" ] && log "Reason: $TRIGGER_REASON"

resolve_host() {
  local url="$1"; [ -n "$url" ] || return 0
  local h; h="$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$h"; return; fi
  getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u
}
ALLOW_IPS=()
if [ -n "${MGMT_IP:-}" ]; then
  if [[ "$MGMT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ALLOW_IPS+=("$MGMT_IP")
  else
    while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done < <(resolve_host "$MGMT_IP")
  fi
fi
[ -n "${WEBHOOK_URL:-}" ] && while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done < <(resolve_host "$WEBHOOK_URL")
[ -n "$RESTIC_REPO" ] && while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done < <(resolve_host "$RESTIC_REPO")

DNS_SERVERS=()
while read -r ip; do [ -n "$ip" ] && DNS_SERVERS+=("$ip"); done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | sort -u)

if [ "$GITHUB_ENABLED" = "1" ]; then
  for host in api.github.com uploads.github.com github.com; do
    while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done \
      < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  done
fi

log "Allow-list: ${ALLOW_IPS[*]:-none}"

ss -tunap        > "$INCIDENT_DIR/ss.txt"        2>&1 || true
nft list ruleset > "$INCIDENT_DIR/nft-before.txt" 2>&1 || true
ip addr          > "$INCIDENT_DIR/ip-addr.txt"    2>&1 || true
ip route         > "$INCIDENT_DIR/ip-route.txt"   2>&1 || true
ip neigh         > "$INCIDENT_DIR/arp.txt"        2>&1 || true
ps auxfww        > "$INCIDENT_DIR/ps.txt"         2>&1 || true
pstree -ap       > "$INCIDENT_DIR/pstree.txt"     2>&1 || true
who -a           > "$INCIDENT_DIR/who.txt"        2>&1 || true
w                > "$INCIDENT_DIR/w.txt"          2>&1 || true
last -n 200      > "$INCIDENT_DIR/last.txt"       2>&1 || true
lastb -n 200     > "$INCIDENT_DIR/lastb.txt"      2>&1 || true
lsof -nP -i      > "$INCIDENT_DIR/lsof-net.txt"   2>&1 || true
lsmod            > "$INCIDENT_DIR/lsmod.txt"      2>&1 || true
mount            > "$INCIDENT_DIR/mount.txt"      2>&1 || true
df -h            > "$INCIDENT_DIR/df.txt"         2>&1 || true
env | sort       > "$INCIDENT_DIR/env.txt"        2>&1 || true
conntrack -L 2>/dev/null > "$INCIDENT_DIR/conntrack-before.txt" || true

for f in /var/log/auth.log /var/log/syslog /var/log/secure /var/log/messages /var/log/kern.log; do
  [ -f "$f" ] && cp -a "$f" "$INCIDENT_DIR/" 2>/dev/null || true
done
journalctl --since "2 hours ago" --no-pager > "$INCIDENT_DIR/journal.txt" 2>&1 || true
cp -a /var/log/audit/audit.log "$INCIDENT_DIR/" 2>/dev/null || true
[ -f /var/lib/eiciel-metrics/history.jsonl ] && cp -a /var/lib/eiciel-metrics/history.jsonl "$INCIDENT_DIR/metrics-history.jsonl" 2>/dev/null || true
[ -f /var/lib/eiciel-metrics/current.json ] && cp -a /var/lib/eiciel-metrics/current.json "$INCIDENT_DIR/metrics-current.json" 2>/dev/null || true
[ -f /var/lib/eiciel-detections/events.jsonl ] && cp -a /var/lib/eiciel-detections/events.jsonl "$INCIDENT_DIR/detections.jsonl" 2>/dev/null || true

stat /etc/passwd /etc/shadow /etc/sudoers /etc/ssh/sshd_config /root/.ssh/authorized_keys 2>/dev/null > "$INCIDENT_DIR/keyfiles-stat.txt" || true

{
  echo "# pid exe_path sha256"
  for pid in /proc/[0-9]*; do
    p="${pid#/proc/}"
    exe="$(readlink -f "$pid/exe" 2>/dev/null || true)"
    [ -n "$exe" ] && [ -f "$exe" ] || continue
    sum="$(sha256sum "$exe" 2>/dev/null | awk '{print $1}')"
    echo "$p $exe $sum"
  done
} > "$INCIDENT_DIR/proc-exe-hashes.txt" 2>/dev/null || true

log "Isolating network ..."
nft delete table inet eiciel_contain 2>/dev/null || true
nft add table inet eiciel_contain
nft add chain inet eiciel_contain output '{ type filter hook output priority -10; policy drop; }'
nft add rule inet eiciel_contain output oif lo accept

for ip in "${ALLOW_IPS[@]}"; do
  [ -n "$ip" ] && nft add rule inet eiciel_contain output ct state established,related ip daddr "$ip" accept
done

for dns in "${DNS_SERVERS[@]}"; do
  [ -n "$dns" ] && nft add rule inet eiciel_contain output ip daddr "$dns" udp dport 53 accept
  [ -n "$dns" ] && nft add rule inet eiciel_contain output ip daddr "$dns" tcp dport 53 accept
done

for ip in "${ALLOW_IPS[@]}"; do
  [ -n "$ip" ] && nft add rule inet eiciel_contain output ip daddr "$ip" accept
done

log "Outbound locked."

if command -v conntrack >/dev/null 2>&1; then
  log "Flushing stale conntrack entries ..."
  ALLOWED_RE="$(printf '%s\n' "${ALLOW_IPS[@]}" "${DNS_SERVERS[@]}" \
                 | grep -v '^$' | sort -u | paste -sd'|')"
  if [ -n "$ALLOWED_RE" ]; then
    conntrack -L 2>/dev/null \
      | grep -oE 'dst=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
      | cut -d= -f2 \
      | sort -u \
      | while read -r dst; do
          [ -n "$dst" ] || continue
          if ! printf '%s' "$dst" | grep -qE "^(${ALLOWED_RE})$"; then
            conntrack -D -d "$dst" 2>/dev/null || true
          fi
        done
  fi
  log "Conntrack flushed."
fi

if [ -n "${ISOLATION_TIMEOUT:-}" ] && [ "${ISOLATION_TIMEOUT}" -gt 0 ] 2>/dev/null; then
  log "Scheduling auto-lift in ${ISOLATION_TIMEOUT}s"
  systemd-run --on-active="${ISOLATION_TIMEOUT}s" \
              --unit=eiciel-autolift \
              --description="Eiciel auto-lift for $INCIDENT_ID" \
              /usr/sbin/nft delete table inet eiciel_contain || true
fi

# Spare tty1 (local console) and sessions from trusted sources.
declare -A TTY_SRC
while read -r _w_user _w_tty _w_from _w_rest; do
  [ -z "$_w_user" ] && continue
  TTY_SRC["$_w_tty"]="$_w_from"
done < <(w -h 2>/dev/null || true)

trusted_session_re="$(printf '%s %s %s' \
    "${MGMT_IP:-}" "$ADMIN_CIDRS" "${DETECT_INBOUND_TRUSTED_IPS:-}" \
    | tr ' ' '\n' | grep -v '^$' | paste -sd'|')"

log "Terminating network sessions ..."
while read -r user tty _; do
  [ -z "${user:-}" ] && continue
  case "$tty" in tty*|pts/*) ;; *) continue ;; esac
  if [ "$tty" = "tty1" ]; then
    log "  sparing $tty ($user) — local console"
    continue
  fi
  if [ -n "$INVOKING_TTY" ] && [ "$tty" = "$INVOKING_TTY" ]; then
    log "  sparing $tty ($user) — invoking session"
    continue
  fi
  src="${TTY_SRC[$tty]:-}"
  if [ -n "$src" ] && [ -n "$trusted_session_re" ] \
     && printf '%s' "$src" | grep -qE "^(${trusted_session_re})$"; then
    log "  sparing $tty ($user from $src) — trusted source"
    continue
  fi
  log "  killing user=$user tty=$tty (from ${src:-unknown})"
  pkill -9 -t "$tty" 2>/dev/null || true
done < <(who)

for svc in $STOP_SERVICES; do
  systemctl is-active --quiet "$svc" 2>/dev/null && systemctl stop "$svc" 2>/dev/null || true
done

if [ -n "$RESTIC_REPO" ] && [ -n "$RESTIC_PASSWORD_FILE" ] && [ -f "$RESTIC_PASSWORD_FILE" ]; then
  restic -r "$RESTIC_REPO" --password-file "$RESTIC_PASSWORD_FILE" backup "$INCIDENT_DIR" >/dev/null 2>&1 || true
fi

if [ "$GITHUB_ENABLED" = "1" ] && [ -n "$GITHUB_OWNER" ] && [ -n "$GITHUB_REPO" ]; then
  RUNTIME_SECRETS=/run/eiciel/secrets.env
  if [ -s "$RUNTIME_SECRETS" ]; then
    log "Uploading incident to GitHub ($GITHUB_OWNER/$GITHUB_REPO) ..."
    if GITHUB_CREDENTIALS="$RUNTIME_SECRETS" \
       /usr/local/sbin/eiciel-github-release.sh "$INCIDENT_DIR" "$TRIGGERED_BY" "$TRIGGER_REASON" \
         >>/var/log/eiciel-github.log 2>&1; then
      log "github release upload ok"
    else
      log "github release upload FAILED — see /var/log/eiciel-github.log"
    fi
  else
    log "github: secrets locked — skipping upload"
  fi
elif [ "$GITHUB_ENABLED" = "1" ]; then
  log "github: GITHUB_OWNER/GITHUB_REPO missing — skipping"
fi

if [ -n "${WEBHOOK_URL:-}" ]; then
  payload=$(jq -nc --arg inc "$INCIDENT_ID" --arg host "$(hostname)" \
    --arg time "$(date -u +%FT%TZ)" --arg dir "$INCIDENT_DIR" \
    --arg svc "$STOP_SERVICES" --arg tb "$TRIGGERED_BY" --arg rs "$TRIGGER_REASON" \
    '{incident:$inc,host:$host,time:$time,dir:$dir,services_stopped:$svc,triggered_by:$tb,reason:$rs}')
  curl -fsS --max-time 10 -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 || true
fi

logger -t eiciel "CONTAINMENT COMPLETE — $INCIDENT_ID — triggered_by=$TRIGGERED_BY"
log "=== Containment complete ==="
echo "$INCIDENT_DIR"
CONTAIN_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-contain.sh"

  cat > "$CHROOT/usr/local/sbin/eiciel-watch.sh" <<'WATCH_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env
if [ -f /etc/eiciel/license.pub ] && [ ! -f /run/eiciel-licensed ]; then
  logger -t eiciel "watch: unlicensed — refusing to start"; exit 1
fi
LOCK="/run/eiciel-contain.lock"
COOLDOWN="${COOLDOWN_SECONDS:-600}"
logger -t eiciel "watch: starting (audit.log + journald)"

handle_line() {
  local line="$1"
  case "$line" in
    *"key=\"priv_esc_unset"*|*"key=\"sudoers"*|*"key=\"module_load"*|\
    *"key=\"watcher_tamper"*|*"key=\"audit_tamper"*|*"key=\"isolation_lift"*|\
    *"key=\"eiciel_config"*|*"key=\"eiciel_scripts"*) ;;
    *) return 0 ;;
  esac
  if [ -f "$LOCK" ]; then
    local last now
    last=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $(( now - last )) -lt "$COOLDOWN" ] && return 0
  fi
  touch "$LOCK"
  logger -t eiciel "watch: triggered by audit event"
  /usr/local/sbin/eiciel-contain.sh --triggered-by "watch:audit" \
      --reason "audit event: $line" >>/var/log/eiciel-contain.log 2>&1 || \
    logger -t eiciel "watch: containment FAILED"
}
export -f handle_line

if [ -f /var/log/audit/audit.log ]; then
  tail -F -n0 /var/log/audit/audit.log 2>/dev/null | while read -r line; do handle_line "$line"; done &
fi
journalctl -f -n0 -u auditd -o cat --no-pager 2>/dev/null | while read -r line; do handle_line "$line"; done &
wait
WATCH_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-watch.sh"

  cat > "$CHROOT/etc/audit/rules.d/eiciel.rules" <<'AUDIT_EOF'
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid=4294967295 -k priv_esc_unset
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=0 -F auid!=4294967295 -k priv_esc_evidence
-w /etc/sudoers    -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /root/.ssh/     -p wa -k ssh_keys
-w /home/          -p wa -k ssh_keys
-w /etc/passwd     -p wa -k accounts
-w /etc/shadow     -p wa -k accounts
-w /etc/group      -p wa -k accounts
-a always,exit -F arch=b64 -S init_module   -k module_load
-a always,exit -F arch=b64 -S finit_module  -k module_load
-a always,exit -F arch=b64 -S delete_module -k module_load
-a always,exit -F arch=b64 -S bpf -F a0=5 -F euid=0 -k bpf_load
-a always,exit -F arch=b64 -S process_vm_writev -F euid=0 -k process_inject
-a always,exit -F arch=b64 -S ptrace -F euid=0 -k ptrace
-a always,exit -F arch=b64 -S mount   -k mount
-a always,exit -F arch=b64 -S umount2 -k mount
-w /etc/systemd/system/eiciel-watch.service  -p wa -k watcher_tamper
-w /etc/systemd/system/eicield.service       -p wa -k watcher_tamper
-w /etc/systemd/system/eiciel-detect.service -p wa -k watcher_tamper
-w /etc/systemd/system/auditd.service        -p wa -k audit_tamper
-w /etc/audit/rules.d/                       -p wa -k audit_tamper
-w /etc/eiciel/                              -p wa -k eiciel_config
-w /usr/local/sbin/eiciel-contain.sh         -p wa -k eiciel_scripts
-w /usr/local/sbin/eiciel-watch.sh           -p wa -k eiciel_scripts
-w /usr/local/sbin/eiciel-detect.sh          -p wa -k eiciel_scripts
-e 2
AUDIT_EOF

  cat > "$CHROOT/etc/fail2ban/jail.d/eiciel.local" <<'F2B_EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = %(sshd_log)s
action   = nftables-multiport[name=sshd, port="ssh", protocol=tcp]
           eiciel-notify[name=sshd]
F2B_EOF

  {
    cat <<'NFT_HEAD'
#!/usr/sbin/nft -f
table inet eiciel {}
delete table inet eiciel
table inet eiciel {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
NFT_HEAD
    if [ -n "$ADMIN_CIDRS" ]; then
      for cidr in $ADMIN_CIDRS; do echo "        ip saddr $cidr tcp dport 22 accept"; done
    else echo "        tcp dport 22 accept"; fi
    for port in $ALLOWED_PORTS; do
      [ "$port" = "22" ] && continue
      echo "        tcp dport $port accept"
    done
    cat <<'NFT_TAIL'
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
table inet eiciel_metrics {}
delete table inet eiciel_metrics
table inet eiciel_metrics {
    chain dns_out {
        type filter hook output priority 0; policy accept;
        udp dport 53 counter
        tcp dport 53 counter
    }
}
NFT_TAIL
  } > "$CHROOT/etc/nftables.conf"

  cat > "$CHROOT/etc/systemd/system/eiciel-watch.service" <<'UNIT_EOF'
[Unit]
Description=Eiciel audit watcher
After=auditd.service
Requires=auditd.service

[Service]
Type=simple
PAMName=eiciel-service
ExecStart=/usr/local/sbin/eiciel-watch.sh
RefuseManualStop=yes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

  cat > "$CHROOT/usr/local/sbin/eiciel-watchdog.sh" <<'WD_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env
COOLDOWN="${COOLDOWN_SECONDS:-600}"
LOCK="/run/eiciel-contain.lock"

if ! systemctl is-active --quiet auditd; then
  logger -t eiciel "watchdog: auditd down — restarting"
  systemctl start auditd || true
fi

if ! systemctl is-active --quiet eiciel-watch; then
  logger -t eiciel "watchdog: eiciel-watch down — restarting"
  systemctl start eiciel-watch || true
  if [ -f "$LOCK" ]; then
    last=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $(( now - last )) -lt "$COOLDOWN" ] && exit 0
  fi
  touch "$LOCK"
  /usr/local/sbin/eiciel-contain.sh --triggered-by "watchdog" \
      --reason "eiciel-watch was down" >>/var/log/eiciel-contain.log 2>&1 &
fi
WD_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-watchdog.sh"

  cat > "$CHROOT/etc/systemd/system/eiciel-watchdog.service" <<'WD_SVC'
[Unit]
Description=Eiciel watcher watchdog
After=eiciel-watch.service
[Service]
Type=oneshot
PAMName=eiciel-service
ExecStart=/usr/local/sbin/eiciel-watchdog.sh
WD_SVC

  cat > "$CHROOT/etc/systemd/system/eiciel-watchdog.timer" <<'WD_TMR'
[Unit]
Description=Check eiciel-watch every minute
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
[Install]
WantedBy=timers.target
WD_TMR

  cat > "$CHROOT/usr/local/sbin/eiciel-heartbeat.sh" <<'HB'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env
[ -n "${WEBHOOK_URL:-}" ] || exit 0
curl -fsS --max-time 5 -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' \
  -d "{\"heartbeat\":\"$(hostname)\",\"time\":\"$(date -u +%FT%TZ)\"}" >/dev/null 2>&1 || true
HB
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-heartbeat.sh"

  cat > "$CHROOT/etc/systemd/system/eiciel-heartbeat.service" <<'HB_SVC'
[Unit]
Description=Eiciel heartbeat
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
PAMName=eiciel-service
ExecStart=/usr/local/sbin/eiciel-heartbeat.sh
HB_SVC

  cat > "$CHROOT/etc/systemd/system/eiciel-heartbeat.timer" <<'HB_TMR'
[Unit]
Description=Eiciel heartbeat every 5m
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
HB_TMR

  cat > "$CHROOT/root/RECOVERY.md" <<'REC'
# Eiciel IR Console — post-incident recovery

## 0. DO NOT
- Do not power off.
- Do not delete /var/lib/incidents.
- Rebuild from a known-good image once evidence is preserved.

## 1. RECOVERY PRIMER

If containment has fired and you cannot connect or lift isolation, use
the GRUB recovery-shell entry:

  a. Reboot the appliance.
  b. At GRUB, select "Eiciel IR Console (console only)".
  c. You are root on tty1 with no TOTP, no MFA, no network.
  d. Run:  nft delete table inet eiciel_contain
  e. Reboot normally.

If secrets were never unlocked at boot, sudo will deny. Recovery shell
is the only path.

## 2. Snapshot the hypervisor FIRST
Proxmox:  qm snapshot <vmid> incident-<date>
VMware:   vim-cmd vmsvc/snapshot.create <vmid> incident-<date>
AWS EC2:  aws ec2 create-snapshot --volume-id <vol>

## 3. Copy evidence off-host
ssh admin@<server>
sudo cp -a /var/lib/incidents/ /root/incidents-preserved/
rsync -av /root/incidents-preserved/ admin@mgmt-host:/srv/incidents/

## 4. Inspect
cat /var/lib/incidents/*/containment.log
cat /var/lib/incidents/*/detections.jsonl
ausearch -k priv_esc_unset --start today | less
ausearch -k bpf_load       --start today | less
ausearch -k watcher_tamper --start today | less
journalctl -u eiciel-watch -u eiciel-detect --since "2 hours ago"

## 5. Rotate every secret
- rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys
- passwd root; passwd admin
- Rotate sealed secrets:
    sudo rm -f /etc/eiciel/secrets.gpg /run/eiciel/secrets.env
    sudo eiciel-seal-secrets
    reboot, enter new passphrase
- DB creds; ~/.aws; cloud tokens; TLS certs

## 6. Lift isolation
From recovery shell:
  nft delete table inet eiciel_contain

## 7. Post-mortem
REC
  chmod 644 "$CHROOT/root/RECOVERY.md"

  cat > "$CHROOT/etc/profile.d/eiciel-motd.sh" <<'MOTD'
#!/bin/sh
if [ -t 0 ]; then
  LIC="unknown"; [ -f /run/eiciel-license-state ] && LIC="$(cat /run/eiciel-license-state)"
  PERSIST="off"
  for p in /run/live/persistence /lib/live/mount/persistence; do
    [ -d "$p" ] && [ -n "$(ls -A "$p" 2>/dev/null)" ] && PERSIST="on"
  done
  SEALED="no"; [ -f /etc/eiciel/secrets.gpg ] && SEALED="yes"
  UNLOCKED="no"; [ -s /run/eiciel/secrets.env ] && UNLOCKED="yes"
  AUDIT_TRIG="enabled"
  grep -q '^AUTO_TRIGGER="0"' /etc/eiciel/config.env 2>/dev/null && AUDIT_TRIG="disabled"
  DETECT_TRIG="log-only"
  grep -q '^DETECT_AUTO_TRIGGER="1"' /etc/eiciel/config.env 2>/dev/null && DETECT_TRIG="auto-trigger"
  cat <<BANNER

  ╔══════════════════════════════════════════════════════════╗
  ║  Eiciel IR Console v2.5 — containment active             ║
  ║                                                          ║
  ║  License   : ${LIC}
  ║  Secrets   : sealed=${SEALED} unlocked=${UNLOCKED}
  ║  Audit     : ${AUDIT_TRIG}
  ║  Detector  : ${DETECT_TRIG}
  ║  Persist   : ${PERSIST}
  ║  Config    : /etc/eiciel/config.env
  ║  Evidence  : /var/lib/incidents/<timestamp>-<pid>/
  ║  Seal      : sudo eiciel-seal-secrets
  ║  Recovery  : /root/RECOVERY.md
  ║  GUI       : sudo eiciel-gui
  ╚══════════════════════════════════════════════════════════╝

BANNER
fi
MOTD
  chmod 755 "$CHROOT/etc/profile.d/eiciel-motd.sh"

  if [ -n "$SSH_AUTHORIZED_KEY" ]; then
    echo "$SSH_AUTHORIZED_KEY" > "$CHROOT/root/.ssh/authorized_keys"
    chmod 600 "$CHROOT/root/.ssh/authorized_keys"
    cat > config/hooks/025-authorized-keys.hook.chroot <<'EOF'
#!/bin/bash
set -e
if [ -f /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o admin -g admin /home/admin/.ssh
  cp /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys
  chown admin:admin /home/admin/.ssh/authorized_keys
  chmod 600 /home/admin/.ssh/authorized_keys
fi
EOF
    chmod +x config/hooks/025-authorized-keys.hook.chroot
  fi

  cat > "$CHROOT/usr/local/sbin/eiciel-persist-init" <<'PERS'
#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
eiciel-persist-init /dev/sdX

Partition a disk for Eiciel live persistence. ERASES the target disk.
USAGE
  exit 0
fi
if [ "$#" -lt 1 ]; then
  echo "Usage: eiciel-persist-init /dev/sdX"; echo
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL,MODEL
  exit 2
fi
DEV="$1"
[ -b "$DEV" ] || { echo "❌ Not a block device: $DEV" >&2; exit 1; }
ROOT_SRC="$(findmnt -n -o SOURCE / | sed 's/\[.*//')"
ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
LIVE_SRC="$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null || true)"
LIVE_DISK="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null || true)"
TARGET_DISK="$(basename "$DEV")"
[ -n "$ROOT_DISK" ] && [ "$TARGET_DISK" = "$ROOT_DISK" ] && { echo "❌ $DEV backs running system"; exit 1; }
[ -n "$LIVE_DISK" ] && [ "$TARGET_DISK" = "$LIVE_DISK" ] && { echo "❌ $DEV is boot medium"; exit 1; }
echo "ERASE $DEV:"; lsblk "$DEV"
read -r -p "Type 'yes': " A; [ "$A" = "yes" ] || { echo "aborted"; exit 1; }
for p in "$DEV"*; do [ -b "$p" ] && umount "$p" 2>/dev/null || true; done
wipefs -a "$DEV" >/dev/null 2>&1 || true
parted -s "$DEV" mklabel gpt
parted -s "$DEV" mkpart primary ext4 1MiB 100%
sleep 1; partprobe "$DEV" 2>/dev/null || true; sleep 1
PART=""
for p in "${DEV}1" "${DEV}p1"; do [ -b "$p" ] && PART="$p" && break; done
[ -n "$PART" ] || { echo "❌ no new partition"; exit 1; }
mkfs.ext4 -F -L persistence "$PART" >/dev/null
TMP="$(mktemp -d)"; mount "$PART" "$TMP"; echo "/ union" > "$TMP/persistence.conf"; sync
umount "$TMP"; rmdir "$TMP"
echo; echo "✅ $DEV is now a persistence volume."
echo "   Reboot the live session."
PERS
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-persist-init"

  cat > "$CHROOT/usr/local/bin/eiciel-tools" <<'TOOLS'
#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi

persistence_active() {
  local p
  for p in /run/live/persistence /lib/live/mount/persistence; do
    if [ -d "$p" ] && [ -n "$(ls -A "$p" 2>/dev/null)" ]; then return 0; fi
  done
  return 1
}

group_packages() {
  case "$1" in
    browsers)   echo "firefox-esr chromium" ;;
    forensic)   echo "sleuthkit foremost binwalk scalpel testdisk dc3dd gddrescue icoutils" ;;
    network)    echo "wireshark tshark nmap tcpdump socat netcat-openbsd dsniff traceroute" ;;
    malware)    echo "yara clamav clamav-freshclam pev radare2" ;;
    office)     echo "libreoffice-writer libreoffice-calc evince mousepad xarchiver" ;;
    dev)        echo "build-essential git python3-dev python3-pip python3-venv gdb strace ltrace" ;;
    desktop)    echo "pcmanfm lxterminal galculator scrot feh" ;;
    containers) echo "docker.io docker-compose" ;;
    *)          return 1 ;;
  esac
}
GROUPS_LIST="browsers forensic network malware office dev desktop containers"

usage() {
  cat <<'USAGE'
eiciel-tools — install package groups on the running Eiciel system.

  eiciel-tools list
  eiciel-tools install <group> [<group>...]
  eiciel-tools install all
  eiciel-tools search <term>

Groups: browsers forensic network malware office dev desktop containers
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "$#" -eq 0 ]; then
  usage; exit 0
fi
cmd="$1"; shift

case "$cmd" in
  list)
    echo "Available groups:"
    for g in $GROUPS_LIST; do printf "  %-12s %s\n" "$g" "$(group_packages "$g")"; done
    echo
    if persistence_active; then echo "Persistence: ACTIVE"
    else echo "Persistence: not active"; echo "Setup: eiciel-persist-init <disk>"
    fi ;;
  search)
    [ "$#" -ge 1 ] || { echo "usage: eiciel-tools search <term>"; exit 2; }
    apt-cache search "$@" ;;
  install)
    [ "$#" -ge 1 ] || { echo "usage: eiciel-tools install <group>..."; exit 2; }
    if ! persistence_active; then
      echo "⚠️  Persistence not active — installs lost at reboot."
      sleep 5
    fi
    PKGS=""
    for g in "$@"; do
      if [ "$g" = "all" ]; then
        for gg in $GROUPS_LIST; do PKGS="$PKGS $(group_packages "$gg")"; done
      else
        p="$(group_packages "$g")" || { echo "Unknown group: $g" >&2; usage >&2; exit 2; }
        PKGS="$PKGS $p"
      fi
    done
    UNIQ="$(echo $PKGS | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
    echo "Installing: $UNIQ"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends $UNIQ
    echo; echo "✅ Done." ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
TOOLS
  chmod 755 "$CHROOT/usr/local/bin/eiciel-tools"

  cat > "$CHROOT/root/TOOLS.md" <<'TOOLSMD'
# Eiciel IR Console — installing tools

## 1. Persistence (once)
    eiciel-persist-init /dev/sdX

## 2. Install tools
    eiciel-tools list
    eiciel-tools install browsers
    eiciel-tools install all

## 3. TOTP and GitHub token
    sudo eiciel-seal-secrets
    # generates TOTP, prompts for optional GitHub token, seals under passphrase
    # reboot, enter passphrase at console

## 4. Live metrics
    cat /var/lib/eiciel-metrics/current.json | jq .
    tail -n 20 /var/lib/eiciel-detections/events.jsonl | jq .
TOOLSMD
  chmod 644 "$CHROOT/root/TOOLS.md"

  if [ "$ENABLE_GUI" = "1" ]; then
    cat > "$CHROOT/etc/X11/Xwrapper.config" <<'XW'
allowed_users=anybody
needs_root_rights=yes
XW

    cat > "$CHROOT/home/admin/.xinitrc" <<'XINIT'
#!/bin/bash
xset -dpms 2>/dev/null || true
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xsetroot -solid "#0e1116" 2>/dev/null || true
mkdir -p ~/.config/openbox
cp /etc/xdg/openbox/rc.xml ~/.config/openbox/rc.xml 2>/dev/null || true
openbox --config-file ~/.config/openbox/rc.xml &
sleep 1
for i in $(seq 1 30); do [ -S /run/eicield.sock ] && break; sleep 1; done
if [ -x /usr/local/bin/eiciel-dashboard ]; then exec /usr/local/bin/eiciel-dashboard
else exec xterm -fa Monospace -fs 11 -bg "#0e1116" -fg "#e6edf3"
fi
XINIT
    chmod 755 "$CHROOT/home/admin/.xinitrc"
    chown 1000:1000 "$CHROOT/home/admin/.xinitrc" 2>/dev/null || true

    cat > "$CHROOT/home/admin/.bash_profile" <<'BPROF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] \
   && [ "$(cat /etc/eiciel/gui-autologin 2>/dev/null)" = "1" ]; then
  exec startx -- -nocursor 2>/tmp/startx.log
fi
[ -f ~/.bashrc ] && . ~/.bashrc
BPROF
    chmod 644 "$CHROOT/home/admin/.bash_profile"
    chown 1000:1000 "$CHROOT/home/admin/.bash_profile" 2>/dev/null || true

    if [ "$GUI_AUTOLOGIN" = "1" ]; then
      echo "1" > "$CHROOT/etc/eiciel/gui-autologin"
      cat > "$CHROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin admin --noclear %I $TERM
AUTOLOGIN
    else
      echo "0" > "$CHROOT/etc/eiciel/gui-autologin"
    fi
    chmod 644 "$CHROOT/etc/eiciel/gui-autologin"

    cat > "$CHROOT/usr/local/bin/eiciel-gui" <<'GUI'
#!/bin/bash
export XDG_SESSION_TYPE=x11
exec startx /etc/X11/Xsession /usr/local/bin/eiciel-dashboard -- :0 vt$(fgconsole)
GUI
    chmod 755 "$CHROOT/usr/local/bin/eiciel-gui"

    cat > "$CHROOT/usr/share/applications/eiciel-dashboard.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Eiciel IR Console
Comment=Compromise response control panel
Exec=/usr/local/bin/eiciel-dashboard
Terminal=false
Categories=System;Security;
DESK
    chmod 644 "$CHROOT/usr/share/applications/eiciel-dashboard.desktop"

    cat > "$CHROOT/etc/xdg/openbox/rc.xml" <<'OBRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <keyboard>
    <keybind key="W-Return"><action name="Execute"><command>xterm</command></action></keybind>
    <keybind key="W-t"><action name="Execute"><command>xterm</command></action></keybind>
    <keybind key="W-d"><action name="Execute"><command>/usr/local/bin/eiciel-dashboard</command></action></keybind>
    <keybind key="W-f"><action name="Execute"><command>firefox-esr</command></action></keybind>
    <keybind key="W-w"><action name="Execute"><command>wireshark</command></action></keybind>
    <keybind key="A-F4"><action name="Close"/></keybind>
  </keyboard>
  <applications>
    <application class="*"><decor>no</decor><maximized>yes</maximized></application>
  </applications>
</openbox_config>
OBRC

    cat > "$CHROOT/etc/xdg/openbox/menu.xml" <<'OBMENU'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Eiciel IR">
  <item label="Terminal"><action name="Execute"><command>xterm -fa Monospace -fs 11 -bg "#0e1116" -fg "#e6edf3"</command></action></item>
  <item label="Eiciel Dashboard"><action name="Execute"><command>/usr/local/bin/eiciel-dashboard</command></action></item>
  <separator/>
  <menu id="ir-tools" label="IR tools">
    <item label="Wireshark"><action name="Execute"><command>wireshark</command></action></item>
    <item label="testdisk"><action name="Execute"><command>xterm -e testdisk</command></action></item>
  </menu>
  <separator/>
  <item label="Reconfigure openbox"><action name="Reconfigure"/></item>
</menu>
</openbox_menu>
OBMENU
  fi

  if [ "$SHIP_DASHBOARD" = "1" ]; then
    install -d -m 755 "$CHROOT/opt/eiciel-dashboard"
    cp -a "$APP_DIST/." "$CHROOT/opt/eiciel-dashboard/"
    chmod -R 755 "$CHROOT/opt/eiciel-dashboard"
    install -d -m 755 "$CHROOT/usr/local/lib/eicield"
    install -m 755 "$DAEMON_DIST/eicield.py"      "$CHROOT/usr/local/lib/eicield/eicield.py"
    install -m 644 "$DAEMON_DIST/eicield.service" "$CHROOT/etc/systemd/system/eicield.service"
    cat > "$CHROOT/usr/local/bin/eiciel-dashboard" <<'L'
#!/bin/bash
exec /opt/eiciel-dashboard/EicielDashboard "$@"
L
    chmod 755 "$CHROOT/usr/local/bin/eiciel-dashboard"
  fi

  if [ "$LICENSE_GATE_MODE" != "none" ]; then
    GATE="systemctl enable eiciel-license-gate.service"
  else
    GATE=":"
  fi
  if [ "$ENABLE_GUI" = "1" ] && [ "$GUI_AUTOLOGIN" = "1" ]; then AUTOG="systemctl enable getty@tty1.service"; else AUTOG=":"; fi
  if [ "$ENABLE_METRICS" = "1" ]; then METRICS="systemctl enable eiciel-metrics.timer"; else METRICS=":"; fi

  cat > config/hooks/030-enable-services.hook.chroot <<EOF
#!/bin/bash
set -e
if [ ! -s /etc/audit/rules.d/eiciel.rules ]; then echo "❌ audit rules missing"; exit 1; fi
grep -q 'bpf_load' /etc/audit/rules.d/eiciel.rules || { echo "❌ bpf_load missing"; exit 1; }
grep -q 'a0=5' /etc/audit/rules.d/eiciel.rules || { echo "❌ bpf a0 missing"; exit 1; }
grep -q 'ptrace -F euid=0' /etc/audit/rules.d/eiciel.rules || { echo "❌ ptrace filter missing"; exit 1; }
systemctl enable auditd
systemctl enable fail2ban
systemctl enable nftables
systemctl enable ssh
systemctl enable eiciel-secrets-unlock.service
systemctl enable eiciel-secrets-lock.service
systemctl enable eiciel-watch
systemctl enable eiciel-detect
systemctl enable eiciel-watchdog.timer
systemctl enable eiciel-heartbeat.timer
$METRICS
systemctl enable eicield.service
$GATE
$AUTOG
install -d -m 2755 /var/log/journal
systemctl enable systemd-journald
EOF
  chmod +x config/hooks/030-enable-services.hook.chroot

  cat > config/hooks/040-verify.hook.chroot <<'EOF'
#!/bin/bash
set -e
fail=0

FILES="/usr/local/sbin/eiciel-contain.sh
/usr/local/sbin/eiciel-watch.sh
/usr/local/sbin/eiciel-detect.sh
/usr/local/sbin/eiciel-watchdog.sh
/usr/local/sbin/eiciel-heartbeat.sh
/usr/local/sbin/eiciel-github-release.sh
/usr/local/sbin/eiciel-pam-totp.sh
/usr/local/sbin/eiciel-secrets-unlock.sh
/usr/local/sbin/eiciel-secrets-lock.sh
/usr/local/bin/eiciel-seal-secrets
/usr/local/bin/eiciel-tools
/usr/local/sbin/eiciel-persist-init
/root/TOOLS.md
/etc/eiciel/config.env
/etc/audit/rules.d/eiciel.rules
/etc/fail2ban/jail.d/eiciel.local
/etc/fail2ban/action.d/eiciel-notify.conf
/etc/nftables.conf
/etc/pam.d/eiciel-service
/etc/systemd/system/eiciel-watch.service
/etc/systemd/system/eiciel-detect.service
/etc/systemd/system/eiciel-secrets-unlock.service
/etc/systemd/system/eicield.service
/usr/local/lib/eicield/eicield.py
/root/RECOVERY.md
/etc/profile.d/eiciel-motd.sh
/var/lib/eiciel-detections"

[ -f /etc/eiciel/license.pub ] && FILES="$FILES
/usr/local/sbin/eiciel-license-check
/usr/local/sbin/eiciel-license-gate
/usr/local/bin/eiciel-license-install
/etc/systemd/system/eiciel-license-gate.service"

[ -x /usr/bin/startx ] && FILES="$FILES
/usr/local/bin/eiciel-gui
/etc/X11/Xwrapper.config
/home/admin/.xinitrc
/home/admin/.bash_profile
/etc/xdg/openbox/rc.xml
/etc/xdg/openbox/menu.xml"

[ "${ENABLE_METRICS:-0}" = "1" ] && FILES="$FILES
/usr/local/sbin/eiciel-metrics.sh
/etc/systemd/system/eiciel-metrics.service
/etc/systemd/system/eiciel-metrics.timer
/var/lib/eiciel-metrics"

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -e "$f" ] || { echo "  ❌ missing: $f"; fail=1; }
done <<< "$FILES"

[ -x /usr/local/sbin/eiciel-contain.sh ] || { echo "  ❌ contain not executable"; fail=1; }
[ -x /usr/local/sbin/eiciel-watch.sh ]   || { echo "  ❌ watch not executable";   fail=1; }
[ -x /usr/local/sbin/eiciel-detect.sh ]  || { echo "  ❌ detect not executable";  fail=1; }
[ "$(stat -c '%a' /etc/eiciel/config.env)" = "600" ] || { echo "  ❌ config.env mode"; fail=1; }

grep -rqE 'NOPASSWD:[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null && { echo "  ❌ NOPASSWD:ALL"; fail=1; }

grep -q 'bpf_load' /etc/audit/rules.d/eiciel.rules || { echo "  ❌ bpf_load missing"; fail=1; }
grep -q 'a0=5' /etc/audit/rules.d/eiciel.rules || { echo "  ❌ bpf a0 missing"; fail=1; }
grep -qE 'ptrace -F euid=0' /etc/audit/rules.d/eiciel.rules || { echo "  ❌ ptrace filter"; fail=1; }
grep -qE 'bpf -F a0=5 -F euid=0' /etc/audit/rules.d/eiciel.rules || { echo "  ❌ bpf euid"; fail=1; }
grep -q '/var/lib/eiciel/totp' /etc/audit/rules.d/eiciel.rules && { echo "  ❌ totp watch present"; fail=1; }

grep -q 'tty1' /usr/local/sbin/eiciel-contain.sh || { echo "  ❌ tty1 not spared"; fail=1; }
grep -q 'flock -n 9' /usr/local/sbin/eiciel-contain.sh || { echo "  ❌ contain missing mutex"; fail=1; }
grep -q 'TTY_SRC' /usr/local/sbin/eiciel-contain.sh || { echo "  ❌ contain missing session source map"; fail=1; }

if grep -q 'pam_google_authenticator' /etc/pam.d/sudo 2>/dev/null; then
  echo "  ❌ pam_google_authenticator still present"; fail=1
fi
[ -f /var/lib/eiciel/totp/admin.secret ] && { echo "  ❌ legacy TOTP file present"; fail=1; }
[ -f /etc/eiciel/github-credentials.env ] && { echo "  ❌ legacy github creds present"; fail=1; }

grep -q 'dst=' /usr/local/sbin/eiciel-contain.sh || { echo "  ❌ contain missing dst= parsing"; fail=1; }
grep -q '/dev/urandom' /usr/local/bin/eiciel-seal-secrets || { echo "  ❌ seal-secrets missing /dev/urandom"; fail=1; }

grep -q 'DETECT_AUTO_TRIGGER' /usr/local/sbin/eiciel-detect.sh || { echo "  ❌ detect missing gate"; fail=1; }
grep -q 'INBOUND_EXPECTED_PORTS' /usr/local/sbin/eiciel-detect.sh || { echo "  ❌ detect missing expected ports"; fail=1; }
grep -q 'INBOUND_TRUSTED_IPS' /usr/local/sbin/eiciel-detect.sh || { echo "  ❌ detect missing trusted IPs"; fail=1; }
grep -q 'trigger_containment "web"' /usr/local/sbin/eiciel-detect.sh && { echo "  ❌ web still auto-triggers"; fail=1; }

grep -q 'threading.Lock' /usr/local/lib/eicield/eicield.py || { echo "  ❌ daemon missing Lock"; fail=1; }
grep -q '_recent_codes' /usr/local/lib/eicield/eicield.py || { echo "  ❌ daemon missing replay cache"; fail=1; }
grep -q 'request_queue_size = 128' /usr/local/lib/eicield/eicield.py || { echo "  ❌ daemon backlog"; fail=1; }
grep -q 'RUNTIME_SECRETS' /usr/local/lib/eicield/eicield.py || { echo "  ❌ daemon missing runtime secrets"; fail=1; }

if grep -q 'journalctl -f ' /usr/local/sbin/eiciel-detect.sh | grep -v ' -n0 ' >/dev/null; then
  echo "  ❌ journalctl -f without -n0"; fail=1
fi

grep -q '^flush ruleset' /etc/nftables.conf && { echo "  ❌ flush ruleset"; fail=1; }

for unit in eiciel-watch eiciel-detect eiciel-watchdog eiciel-heartbeat eicield eiciel-secrets-unlock; do
  f="/etc/systemd/system/$unit.service"
  if [ -f "$f" ]; then
    grep -q '^PAMName=eiciel-service' "$f" || { echo "  ❌ $unit missing PAMName"; fail=1; }
  fi
done
if [ -f /etc/systemd/system/eiciel-metrics.service ]; then
  grep -q '^PAMName=eiciel-service' /etc/systemd/system/eiciel-metrics.service || \
    { echo "  ❌ metrics missing PAMName"; fail=1; }
fi

grep -q -- '--triggered-by' /usr/local/sbin/eiciel-contain.sh || { echo "  ❌ --triggered-by missing"; fail=1; }

if [ "${ENABLE_TOOLS:-0}" = "1" ]; then
  for bin in nmap tcpdump tshark binwalk foremost fls sqlite3 yara ghex xxd parted; do
    command -v "$bin" >/dev/null 2>&1 || { echo "  ❌ IR tool missing: $bin"; fail=1; }
  done
fi

[ "$fail" -eq 0 ] || exit 1
echo "[040] All checks passed."
EOF
  chmod +x config/hooks/040-verify.hook.chroot

  cat > config/hooks/060-cleanup.hook.chroot <<'EOF'
#!/bin/bash
set -e
apt-get autoremove -y || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
if [ "${BUILD_MODE:-live}" = "live" ]; then
  rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
  find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
fi
chmod 644 /root/RECOVERY.md /root/TOOLS.md
for f in eiciel-contain eiciel-watch eiciel-detect eiciel-github-release eiciel-pam-totp eiciel-secrets-unlock eiciel-secrets-lock; do
  [ -f "/usr/local/sbin/$f.sh" ] && chmod 755 "/usr/local/sbin/$f.sh"
done
chmod 755 /usr/local/bin/eiciel-seal-secrets
chmod 755 /usr/local/sbin/eiciel-persist-init
chmod 755 /usr/local/bin/eiciel-tools
chmod 600 /etc/eiciel/config.env
[ -f /usr/local/sbin/eiciel-metrics.sh ] && chmod 755 /usr/local/sbin/eiciel-metrics.sh
chown -R root:root /var/lib/eiciel-metrics /var/lib/eiciel-detections 2>/dev/null || true
chmod 700 /var/lib/eiciel-metrics /var/lib/eiciel-detections 2>/dev/null || true
EOF
  chmod +x config/hooks/060-cleanup.hook.chroot
  chmod +x config/hooks/*.hook.chroot

  cat > config/package-lists/eiciel.list.chroot <<'EOF'
linux-image-amd64
live-boot
live-config
systemd
systemd-sysv
sudo
locales
console-setup
kbd
hostname
ca-certificates

openssh-server
nano
vim-tiny
htop
psmisc
lsof
strace
x11-utils

auditd
audispd-plugins
fail2ban
nftables
conntrack-tools
acl
attr
rsyslog

gpg
restic
curl
wget
jq
unzip
p7zip-full
rsync
python3
openssl
python3-pyotp
qrencode
coreutils

parted
gdisk
dosfstools
e2fsprogs
util-linux

firmware-linux-free
firmware-linux-nonfree
firmware-iwlwifi
firmware-realtek
firmware-atheros
firmware-brcm80211

network-manager
rfkill
wireless-tools

libnss3
libatk1.0-0
libatk-bridge2.0-0
libcups2
libdrm2
libxkbcommon0
libxcomposite1
libxdamage1
libxfixes3
libxrandr2
libgbm1
libpango-1.0-0
libcairo2
libasound2
libatspi2.0-0
libgtk-3-0
fonts-liberation
fonts-dejavu
EOF

  [ "$ENABLE_TOOLS" = "1" ] && cat >> config/package-lists/eiciel.list.chroot <<'EOF'

nmap
tcpdump
tshark
netcat-openbsd
socat
traceroute
dnsutils
iputils-ping
iputils-arping
net-tools
python3-pip
python3-venv
python3-scapy
python3-requests
python3-dnspython
python3-pefile
python3-yara
sqlite3
sqlitebrowser
ghex
xxd
file
binutils
yara
clamav
clamav-freshclam
binwalk
foremost
sleuthkit
testdisk
icoutils
ltrace
gdb
hexedit
less
moreutils
pv
tree
EOF

  [ "$ENABLE_TOOLS_HEAVY" = "1" ] && cat >> config/package-lists/eiciel.list.chroot <<'EOF'

firefox-esr
chromium
wireshark
wireshark-qt
gparted
xarchiver
mousepad
gpicview
EOF

  [ "$ENABLE_GUI" = "1" ] && cat >> config/package-lists/eiciel.list.chroot <<'EOF'

xserver-xorg-core
xserver-xorg-video-all
xserver-xorg-input-all
xserver-xorg-legacy
xinit
xauth
x11-xserver-utils
x11-utils
x11-apps
openbox
xterm
EOF

  [ "$ENABLE_MFA" = "1" ] && echo "libpam-google-authenticator" >> config/package-lists/eiciel.list.chroot
  [ "$ENABLE_AUTO_UPDATES" = "1" ] && echo "unattended-upgrades" >> config/package-lists/eiciel.list.chroot
  [ "$BUILD_MODE" = "install" ] && echo "debian-installer-launcher" >> config/package-lists/eiciel.list.chroot

  echo "$HOSTNAME_NEW" > "$CHROOT/etc/hostname"
  cat > "$CHROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_NEW
::1         localhost ip6-localhost ip6-loopback
EOF

  cat > config/bootloaders/grub/config.cfg <<EOF
set timeout=3
set default=0
set gfxmode=auto
set gfxpayload=keep
insmod all_video
terminal_output console

menuentry "Eiciel IR Console v2.5" {
    linux  /live/vmlinuz boot=live components quiet loglevel=3 username=admin hostname=${HOSTNAME_NEW} persistence persistence-storage=filesystem
    initrd /live/initrd.img
}
menuentry "Eiciel IR Console (no persistence)" {
    linux  /live/vmlinuz boot=live components quiet loglevel=3 username=admin hostname=${HOSTNAME_NEW}
    initrd /live/initrd.img
}
menuentry "Eiciel IR Console (verbose)" {
    linux  /live/vmlinuz boot=live components username=admin hostname=${HOSTNAME_NEW}
    initrd /live/initrd.img
}
menuentry "Eiciel IR Console (console only)" {
    linux  /live/vmlinuz boot=live components single username=admin hostname=${HOSTNAME_NEW}
    initrd /live/initrd.img
}
EOF

  ./auto/config
  lb bootstrap 2>&1 | tee bootstrap.log
  BUILD_MODE="$BUILD_MODE" \
  LICENSE_GATE_MODE="$LICENSE_GATE_MODE" \
  ENABLE_MFA="$ENABLE_MFA" MFA_SUDO="$MFA_SUDO" MFA_SSH="$MFA_SSH" \
  ENABLE_TOOLS="$ENABLE_TOOLS" ENABLE_TOOLS_HEAVY="$ENABLE_TOOLS_HEAVY" \
  ENABLE_METRICS="$ENABLE_METRICS" \
  lb chroot 2>&1 | tee chroot.log
  lb binary 2>&1 | tee binary.log

  ISO=$(ls -1 *.iso 2>/dev/null | head -1 || true)
  [ -n "$ISO" ] || { echo "❌ No ISO produced."; exit 1; }
  [ "$ISO" = "eiciel-server.iso" ] || { mv "$ISO" eiciel-server.iso; ISO="eiciel-server.iso"; }

  echo "✅  [2/2] ISO: $ROOT/$ISO ($(du -h "$ISO" | cut -f1))"
}

case "${1:-all}" in
  app) build_app ;;
  iso) build_iso ;;
  all)
    build_app
    build_iso
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "✅  Done.  ISO: $ROOT/eiciel-server.iso"
    echo "      BUILD_MODE        = $BUILD_MODE"
    echo "      Audit watcher     = $AUTO_TRIGGER"
    echo "      Detector          = $([ "$DETECT_AUTO_TRIGGER" = "1" ] && echo "auto-trigger" || echo "log-only")"
    echo "      Isolation timeout = ${ISOLATION_TIMEOUT}s"
    echo "      Secrets           = sealed"
    echo "═══════════════════════════════════════════════════════════════"
    ;;
  *) echo "usage: $0 [app|iso|all]" >&2; exit 2 ;;
esac