#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel IR Console — single build script
#  v1.9.0
#
#  Changes since v1.8.0:
#    A1  PAMName=eiciel-service on every eiciel unit — stops the
#        priv_esc_unset self-trigger loop from the previous version.
#    A2  eiciel-detect.sh: 5-source attacker detector
#        (fail2ban, ssh brute-force, egress spike, DNS burst,
#         web attack patterns, first-ever IP).
#    A3  Detection events logged to /var/lib/eiciel-detections/events.jsonl
#    A4  Auto-trigger gated by severity + cooldown + hourly rate limit
#    A5  Daemon op: detections; dashboard Detections tab
#    A6  eiciel-contain.sh accepts --triggered-by / --reason
#    A7  fail2ban action eiciel-notify for unambiguous ban lines
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

# ─── Load config.local.env (parse, never source) ───
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

# Defaults
STOP_SERVICES="${STOP_SERVICES:-}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
ENABLE_PERSISTENCE="${ENABLE_PERSISTENCE:-1}"
INCLUDE_DASHBOARD="${INCLUDE_DASHBOARD:-auto}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-600}"
ISOLATION_TIMEOUT="${ISOLATION_TIMEOUT:-}"
HOSTNAME_NEW="${HOSTNAME_NEW:-eiciel-srv}"
BUILD_MODE="${BUILD_MODE:-install}"
REAUTH_TOTP_SECRET="${REAUTH_TOTP_SECRET:-}"
LICENSE_GATE_MODE="${LICENSE_GATE_MODE:-none}"
LICENSE_PUBKEY_FILE="${LICENSE_PUBKEY_FILE:-}"
ADMIN_CIDRS="${ADMIN_CIDRS:-}"
ALLOWED_PORTS="${ALLOWED_PORTS:-22}"
ENABLE_MFA="${ENABLE_MFA:-0}"
ENABLE_AUTO_UPDATES="${ENABLE_AUTO_UPDATES:-0}"
MFA_SSH="${MFA_SSH:-1}"
MFA_SUDO="${MFA_SUDO:-1}"
ENABLE_GUI="${ENABLE_GUI:-1}"
GUI_AUTOLOGIN="${GUI_AUTOLOGIN:-0}"
ENABLE_TOOLS="${ENABLE_TOOLS:-1}"
ENABLE_TOOLS_HEAVY="${ENABLE_TOOLS_HEAVY:-1}"
ENABLE_METRICS="${ENABLE_METRICS:-1}"

# ── A2: auto-trigger detector config ──
AUTO_TRIGGER="${AUTO_TRIGGER:-1}"
AUTO_TRIGGER_MIN_SEVERITY="${AUTO_TRIGGER_MIN_SEVERITY:-high}"
DETECT_SSH_FAIL_THRESHOLD="${DETECT_SSH_FAIL_THRESHOLD:-10}"
DETECT_SSH_FAIL_WINDOW="${DETECT_SSH_FAIL_WINDOW:-60}"
DETECT_EGRESS_MB_THRESHOLD="${DETECT_EGRESS_MB_THRESHOLD:-100}"
DETECT_DNS_THRESHOLD="${DETECT_DNS_THRESHOLD:-500}"
DETECT_MAX_TRIGGERS_PER_HOUR="${DETECT_MAX_TRIGGERS_PER_HOUR:-3}"
DETECT_DRY_RUN="${DETECT_DRY_RUN:-0}"

export BUILD_MODE ISOLATION_TIMEOUT REAUTH_TOTP_SECRET LICENSE_GATE_MODE
export ENABLE_MFA MFA_SSH MFA_SUDO ENABLE_GUI GUI_AUTOLOGIN
export ENABLE_TOOLS ENABLE_TOOLS_HEAVY ENABLE_METRICS
export AUTO_TRIGGER AUTO_TRIGGER_MIN_SEVERITY DETECT_SSH_FAIL_THRESHOLD
export DETECT_SSH_FAIL_WINDOW DETECT_EGRESS_MB_THRESHOLD DETECT_DNS_THRESHOLD
export DETECT_MAX_TRIGGERS_PER_HOUR DETECT_DRY_RUN

# ── B1/B2 build-time sanity ──
REAUTH_ON=0
[ -n "$REAUTH_TOTP_SECRET" ] && REAUTH_ON=1
LICENSE_ON=0
[ "$LICENSE_GATE_MODE" != "none" ] && LICENSE_ON=1

if [ "$REAUTH_ON" = "0" ] && [ "$LICENSE_ON" = "0" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  ⚠️  WARNING: NEITHER LICENSE GATE NOR TOTP RE-AUTH ARE   ║"
  echo "║     CONFIGURED.                                           ║"
  echo "║                                                          ║"
  echo "║  trigger/lift will be REFUSED by the daemon (fail-closed) ║"
  echo "║  and the dashboard buttons will be DISABLED.              ║"
  echo "║                                                          ║"
  echo "║  To enable destructive actions, set either:               ║"
  echo "║    REAUTH_TOTP_SECRET=\"<base32>\"   (openssl rand -base32 20) ║"
  echo "║  or                                                       ║"
  echo "║    LICENSE_GATE_MODE=soft  + LICENSE_PUBKEY_FILE=...      ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
fi

if [ "$AUTO_TRIGGER" = "1" ] && [ "$DETECT_DRY_RUN" = "1" ]; then
  echo "  ℹ️  AUTO_TRIGGER=1 with DETECT_DRY_RUN=1 — detections will be"
  echo "      logged but NOT acted on. Set DETECT_DRY_RUN=0 when ready."
  echo ""
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Eiciel IR Console — single build"
echo "  MGMT_IP        = $MGMT_IP"
echo "  BUILD_MODE     = $BUILD_MODE"
echo "  GUI            = $ENABLE_GUI (autologin=$GUI_AUTOLOGIN)"
echo "  Persistence    = $ENABLE_PERSISTENCE"
echo "  Toolkit        = $ENABLE_TOOLS (heavy=$ENABLE_TOOLS_HEAVY)"
echo "  Metrics        = $ENABLE_METRICS"
echo "  Auto-trigger   = $AUTO_TRIGGER (min_sev=$AUTO_TRIGGER_MIN_SEVERITY, dry_run=$DETECT_DRY_RUN)"
echo "  License gate   = $LICENSE_GATE_MODE"
echo "  Re-auth TOTP   = $([ -n "$REAUTH_TOTP_SECRET" ] && echo on || echo off)"
echo "═══════════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════
#  build_app
# ═══════════════════════════════════════════════════════════════════
build_app() {
  echo ""
  echo "▶▶▶  [1/2] Building Electron dashboard + daemon"
  echo ""

  command -v node >/dev/null || { echo "❌ node not found"; exit 1; }
  command -v npm  >/dev/null || { echo "❌ npm not found";  exit 1; }

  rm -rf "$SRC" "$OUT"
  mkdir -p "$SRC/daemon"
  cd "$SRC"

  cat > package.json <<'EOF'
{
  "name": "eiciel-dashboard",
  "version": "1.9.0",
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

  # ─── main.js ───
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
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
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

ipcMain.handle('trigger', async () => {
  const st = await callDaemon('state');
  if (st && st.reauthConfigured === false) {
    dialog.showErrorBox(
      'Re-authentication not configured',
      'This system was built without a TOTP secret. Trigger/lift are disabled.\n\n' +
      'Set REAUTH_TOTP_SECRET in config.local.env and rebuild, or install a license ' +
      'if LICENSE_GATE_MODE is enabled.'
    );
    return { ok: false, error: 'reauth_not_configured' };
  }
  const code = await promptTotp('Enter the 6-digit TOTP code to trigger containment.');
  if (!code) return { ok: false, error: 'cancelled' };
  const r = await callDaemon('trigger', { totp: code });
  if (r.reauth_required) dialog.showErrorBox('Re-auth failed', 'Invalid or expired TOTP code.');
  return r;
});

ipcMain.handle('lift', async () => {
  const st = await callDaemon('state');
  if (st && st.reauthConfigured === false) {
    dialog.showErrorBox(
      'Re-authentication not configured',
      'This system was built without a TOTP secret. Trigger/lift are disabled.\n\n' +
      'Set REAUTH_TOTP_SECRET in config.local.env and rebuild, or install a license ' +
      'if LICENSE_GATE_MODE is enabled.'
    );
    return { ok: false, error: 'reauth_not_configured' };
  }
  const code = await promptTotp('Enter the 6-digit TOTP code to lift network isolation.');
  if (!code) return { ok: false, error: 'cancelled' };
  const r = await callDaemon('lift', { totp: code });
  if (r.reauth_required) dialog.showErrorBox('Re-auth failed', 'Invalid or expired TOTP code.');
  return r;
});

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
MAIN_EOF

  cat > totp-preload.js <<'TOTP_PRE_EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('totpAPI', {
  send: (code) => ipcRenderer.send('totp-result', code),
});
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

  # ─── index.html ───
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
.incident{padding:8px 12px;cursor:pointer;border-bottom:1px solid var(--border);font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
.incident:hover{background:#1a2028}.incident.selected{background:#1f2937}
.incident .meta{color:var(--muted);font-size:11px}
.viewer{display:flex;flex-direction:column;overflow:hidden;flex:1}
.viewer .tabs{display:flex;gap:4px;padding:8px 12px 0;flex-wrap:wrap}
.viewer .tabs button{background:transparent;border:1px solid var(--border);color:var(--muted);padding:3px 10px;border-radius:4px;font-size:11px;cursor:pointer;font-family:ui-monospace,monospace}
.viewer .tabs button.active{color:var(--text);background:#21262d}
pre{flex:1;margin:0;padding:12px 16px;overflow:auto;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;line-height:1.5;color:#c9d1d9;background:#0d1117;border-top:1px solid var(--border);white-space:pre}
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
    <div class="panel"><h2>Containment state</h2><div class="kv" id="state-kv"><span class="k">loading…</span><span class="v"></span></div></div>
    <div class="panel"><h2>System</h2><div class="kv" id="system-kv"><span class="k">loading…</span><span class="v"></span></div></div>
    <div class="panel"><h2>Network</h2><div id="network-ifaces"><div class="empty">loading…</div></div></div>
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
  else{b.style.display='';b.textContent='⚠️  Re-authentication is not configured. Trigger and Lift are disabled. Set REAUTH_TOTP_SECRET in config.local.env and rebuild.';}
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
  const kv=$('state-kv');kv.innerHTML='';
  const rows=[
    ['Isolation',s.containActive?'ACTIVE':'off',s.containActive?'bad':'ok'],
    ['Running as','eiciel (unprivileged)','ok'],
    ['Re-auth',s.reauthConfigured?'configured':'NOT configured',s.reauthConfigured?'ok':'bad'],
    ['Auto-trigger',s.autoTrigger?'enabled':'disabled',s.autoTrigger?'ok':'muted']
  ];
  for(const[k,v,c]of rows)kv.insertAdjacentHTML('beforeend',row(k,v,c));
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
      lkv.insertAdjacentHTML('beforeend',row('ID',lic.license_id||'?','muted'));
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
    row('Watcher self-protection','✓ auditd','ok'),
    row('Isolation lift','✓ auditd','ok'),
    row('Network interfaces',(m.interfaces||[]).length+' ifaces','ok'),
    row('Listening sockets',m.sockets.listening,m.sockets.listening>60?'warn':'ok'),
    row('Established conns',m.sockets.established,m.sockets.established>200?'warn':'ok'),
    row('DNS queries','live','ok'),
    row('Egress volume','live','ok'),
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
    (m.web.top_ips||[]).slice(0,3).forEach(e=>rows.push(row('  '+e.ip,e.count,'muted')));
  }else{rows.push(row('Web','inactive','muted'));}
  const dbs=Object.entries(m.databases||{});
  if(!dbs.length)rows.push(row('Databases','none detected','muted'));
  else dbs.forEach(([n,v])=>{if(v.active)rows.push(row(n,`${v.connections} conns · :${v.port}`,'ok'));});
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
  if(!n.ok)return '(netinfo error: '+(n.error||'')+')';
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
  else if(r.error!=='cancelled')alert('Failed: '+(r.error||r.output||'unknown'));
  refreshAll();});
$('btn-lift').addEventListener('click',async()=>{
  const r=await window.eiciel.lift();
  if(r.ok)alert('Isolation lifted.');
  else if(r.error==='reauth_not_configured'){}
  else if(r.error!=='cancelled')alert('Failed: '+(r.error||r.output||'unknown'));
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

  # ─── daemon/eicield.py ───
  cat > daemon/eicield.py <<'DAEMON_EOF'
#!/usr/bin/env python3
"""eicield — root-owned Unix-socket daemon for the Eiciel IR Console.

v1.9: adds detections op, autoTrigger state flag.
v1.7 B1 fix: _verify_totp FAILS CLOSED when no secret is configured.
"""
import datetime, grp, json, os, pwd, re, socket as pysocket, socketserver
import struct, subprocess, sys, urllib.request
from pathlib import Path

SOCK_PATH       = "/run/eicield.sock"
SOCK_GROUP      = "eiciel"
CONFIG_PATH     = Path("/etc/eiciel/config.env")
LICENSE_JSON    = Path("/etc/eiciel/license.json")
LICENSE_PUB     = Path("/etc/eiciel/license.pub")
LICENSE_CHECK   = "/usr/local/sbin/eiciel-license-check"
REAUTH_SECRET   = Path("/etc/eiciel/reauth.secret")
LICENSE_FLAG    = Path("/run/eiciel-licensed")
INCIDENTS_ROOT  = Path("/var/lib/incidents").resolve()
METRICS_DIR     = Path("/var/lib/eiciel-metrics")
DETECTIONS_LOG  = Path("/var/lib/eiciel-detections/events.jsonl")
CONTAIN_SCRIPT  = "/usr/local/sbin/eiciel-contain.sh"

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

def _reauth_configured():
    try: return REAUTH_SECRET.is_file() and bool(REAUTH_SECRET.read_text().strip())
    except Exception: return False

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
    return {"ok": True, "daemon": "active", "containActive": nft["ok"], "services": services,
            "reauthConfigured": _reauth_configured(),
            "autoTrigger": auto,
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
    rec = {"state": parts[0], "recvq": parts[1], "sendq": parts[2],
           "local": parts[3], "peer": parts[4], "process": parts[5] if len(parts) > 5 else ""}
    m = re.search(r'users:\(\(([^)]+)\)\)', rec["process"])
    if m:
        inner = m.group(1)
        nm = re.match(r'"([^"]+)"', inner); pid = re.search(r'pid=(\d+)', inner)
        if nm: rec["process_name"] = nm.group(1)
        if pid: rec["process_pid"] = pid.group(1)
    return rec

def netinfo():
    out = {"ok": True}
    ifaces = _jrun("ip", ["-j", "addr"])
    links  = _jrun("ip", ["-j", "link"])
    link_by_name = {l.get("ifname"): l for l in links}
    interfaces = []
    for i in ifaces:
        name = i.get("ifname")
        if not name: continue
        link = link_by_name.get(name, {})
        addrs4, addrs6 = [], []
        for a in i.get("addr_info", []):
            fam = a.get("family"); local = a.get("local"); plen = a.get("prefixlen")
            if not local: continue
            if fam == "inet": addrs4.append(f"{local}/{plen}")
            elif fam == "inet6" and a.get("scope") != "link": addrs6.append(f"{local}/{plen}")
        interfaces.append({"name": name, "state": (link.get("operstate") or "UNKNOWN").upper(),
                           "mac": link.get("address", ""), "mtu": link.get("mtu"),
                           "ipv4": addrs4, "ipv6": addrs6})
    default_gw = ""
    for args in (["-j", "route"], ["-j", "-6", "route"]):
        for r in _jrun("ip", args):
            if r.get("dst") in ("default", "0.0.0.0/0", "::/0"):
                gw = r.get("gateway") or r.get("via") or ""
                if gw and not default_gw: default_gw = gw
                break
    listeners = []
    for proto, flag in (("tcp", "-t"), ("udp", "-u")):
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
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize; free = st.f_bavail * st.f_frsize
        used = total - free
        out["disk_used_pct"] = int(round(100.0 * used / total)) if total else 0
        out["disk_total_gb"] = round(total / (1024**3), 1)
        out["disk_used_gb"]  = round(used / (1024**3), 1)
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
    lines = t.splitlines()
    return {"ok": True, "text": "\n".join(lines[-200:])}

def license_info():
    if not LICENSE_PUB.exists(): return {"ok": True, "enabled": False, "valid": False}
    if not LICENSE_JSON.exists(): return {"ok": True, "enabled": True, "valid": False, "error": "license.json not present"}
    try: data = json.loads(LICENSE_JSON.read_text())
    except Exception as e: return {"ok": True, "enabled": True, "valid": False, "error": f"cannot read license: {e}"}
    r = run(LICENSE_CHECK, timeout=10)
    out = {"ok": True, "enabled": True, "valid": r["ok"], "license_id": data.get("license_id"),
           "issued_to": data.get("issued_to"), "not_before": data.get("not_before"),
           "not_after": data.get("not_after"), "machine_id": data.get("machine_id")}
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
    except FileNotFoundError:
        return {"ok": True, "detections": []}
    out = []
    for line in lines:
        try: out.append(json.loads(line))
        except Exception: continue
    out.reverse()
    return {"ok": True, "detections": out}

def _verify_totp(code):
    try:
        if not REAUTH_SECRET.is_file(): return False
        secret = REAUTH_SECRET.read_text().strip()
        if not secret: return False
        import pyotp
        return pyotp.TOTP(secret).verify(code or "", valid_window=1)
    except Exception: return False

def log_offhost(event, details):
    try:
        cfg = parse_env(CONFIG_PATH.read_text()); url = cfg.get("WEBHOOK_URL", "")
        if not url: return
        payload = json.dumps({"type": "action_log", "event": event,
                              "host": pysocket.gethostname(),
                              "time": datetime.datetime.utcnow().isoformat() + "Z",
                              "details": details}).encode()
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
    except Exception: pass

def _refuse_unconfigured(op):
    log_offhost("destructive_op_refused", {"op": op, "reason": "reauth_not_configured"})
    return {"ok": False, "reauth_required": True, "reauth_not_configured": True,
            "error": "re-auth is not configured on this system"}

def trigger(args=None):
    if not _reauth_configured(): return _refuse_unconfigured("trigger")
    code = (args or {}).get("totp", "")
    if not _verify_totp(code):
        log_offhost("containment_trigger_denied", {"reason": "bad_totp"})
        return {"ok": False, "reauth_required": True, "error": "invalid or missing TOTP"}
    try:
        subprocess.Popen([CONTAIN_SCRIPT, "--triggered-by", "dashboard"],
                         stdout=open("/var/log/eiciel-contain.log", "ab"),
                         stderr=subprocess.STDOUT, start_new_session=True)
        log_offhost("containment_triggered", {"by": "dashboard"})
        return {"ok": True, "output": "containment started"}
    except Exception as e: return {"ok": False, "error": str(e)}

def lift(args=None):
    if not _reauth_configured(): return _refuse_unconfigured("lift")
    code = (args or {}).get("totp", "")
    if not _verify_totp(code):
        log_offhost("isolation_lift_denied", {"reason": "bad_totp"})
        return {"ok": False, "reauth_required": True, "error": "invalid or missing TOTP"}
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
    "netinfo":        lambda a: netinfo(),
    "sessions":       lambda a: sessions_text(),
    "sysinfo":        lambda a: sysinfo(),
    "apt-history":    lambda a: apt_history(),
    "metrics":        lambda a: metrics_current(),
    "metric-history": lambda a: metrics_history(a.get("limit", 240)),
    "detections":     lambda a: detections(a.get("limit", 200)),
}

def peer_allowed(sock):
    try:
        raw = sock.getsockopt(pysocket.SOL_SOCKET, pysocket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, gid = struct.unpack("3i", raw)
    except Exception: return False
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
        line = self.rfile.readline(65536)
        if not line: return
        try: req = json.loads(line.decode("utf-8"))
        except Exception:
            self._send({"ok": False, "error": "bad json"}); return
        op = req.get("op"); args = req.get("args") or {}
        fn = HANDLERS.get(op)
        if not fn:
            self._send({"ok": False, "error": f"unknown op {op!r}"}); return
        try: self._send(fn(args))
        except Exception as e: self._send({"ok": False, "error": str(e)})
    def _send(self, obj):
        try: self.wfile.write((json.dumps(obj) + "\n").encode("utf-8"))
        except Exception: pass

class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

def main():
    if LICENSE_PUB.exists() and not LICENSE_FLAG.exists():
        print("eicield: system is unlicensed (no /run/eiciel-licensed)", file=sys.stderr)
        sys.exit(1)
    if not _reauth_configured():
        print("eicield: WARNING — no TOTP secret configured. trigger/lift will be refused.",
              file=sys.stderr)
    if os.path.exists(SOCK_PATH): os.unlink(SOCK_PATH)
    srv = Server(SOCK_PATH, Handler)
    os.chmod(SOCK_PATH, 0o660)
    try: os.chown(SOCK_PATH, 0, grp.getgrnam(SOCK_GROUP).gr_gid)
    except KeyError:
        print(f"eicield: group {SOCK_GROUP!r} missing", file=sys.stderr); sys.exit(1)
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
ReadWritePaths=/run /var/lib/incidents /var/log /etc/eiciel /var/lib/eiciel-detections
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

  echo "📦 npm install…"
  npm install --no-audit --no-fund --loglevel=error
  echo "📦 electron-packager…"
  npm run build

  install -d -m 755 "$DAEMON_DIST"
  install -m 755 daemon/eicield.py          "$DAEMON_DIST/eicield.py"
  install -m 644 daemon/eicield.service     "$DAEMON_DIST/eicield.service"
  install -m 755 daemon/install-daemon.sh   "$DAEMON_DIST/install-daemon.sh"

  cd "$ROOT"
  echo "✅  [1/2] App: $APP_DIST"
  echo "          Daemon: $DAEMON_DIST"
}

# ═══════════════════════════════════════════════════════════════════
#  build_iso
# ═══════════════════════════════════════════════════════════════════
build_iso() {
  echo ""
  echo "▶▶▶  [2/2] Building live ISO"
  echo ""

  [[ $EUID -eq 0 ]] || { echo "❌ Run as root"; exit 1; }
  for cmd in lb debootstrap xorriso mksquashfs jq openssl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ Missing tool: $cmd"; exit 1; }
  done

  if [ "$LICENSE_GATE_MODE" != "none" ]; then
    case "$LICENSE_GATE_MODE" in soft|hard) ;; *) echo "❌ LICENSE_GATE_MODE must be none|soft|hard"; exit 1 ;; esac
    [ -n "$LICENSE_PUBKEY_FILE" ] && [ -f "$LICENSE_PUBKEY_FILE" ] || { echo "❌ LICENSE_GATE_MODE=$LICENSE_GATE_MODE requires LICENSE_PUBKEY_FILE"; exit 1; }
  fi

  SHIP_DASHBOARD=0
  case "$INCLUDE_DASHBOARD" in
    1) SHIP_DASHBOARD=1 ;;
    0) SHIP_DASHBOARD=0 ;;
    auto) [ -d "$APP_DIST" ] && SHIP_DASHBOARD=1 ;;
  esac
  if [ "$SHIP_DASHBOARD" = "1" ]; then
    [ -d "$APP_DIST" ]    || { echo "❌ $APP_DIST missing — run 'app' first"; exit 1; }
    [ -d "$DAEMON_DIST" ] || { echo "❌ $DAEMON_DIST missing — run 'app' first"; exit 1; }
  fi

  echo "📦 Cleaning old build state…"
  lb clean --purge >/dev/null 2>&1 || true
  rm -rf config auto chroot binary cache .build local bootstrap.log chroot.log binary.log 2>/dev/null || true

  mkdir -p auto config/hooks config/package-lists config/bootloaders/grub \
           config/includes.installer \
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

  # ── auto/config ──
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

  if [ "$ENABLE_MFA" = "1" ]; then
    cat > config/hooks/011-mfa.hook.chroot <<'EOF'
#!/bin/bash
set -e
apt-get install -y --no-install-recommends libpam-google-authenticator qrencode
if [ "${MFA_SSH:-1}" = "1" ]; then
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
auth       required     pam_google_authenticator.so nullok
auth       include      common-auth
account    include      common-account
password   include      common-password
session    required     pam_loginuid.so
session    include      common-session
session    optional     pam_motd.so
session    optional     pam_mail.so standard
PAM
fi
if [ "${MFA_SUDO:-1}" = "1" ]; then
  cat > /etc/pam.d/sudo <<'PAM'
#%PAM-1.0
auth       required     pam_env.so
auth       required     pam_google_authenticator.so nullok
auth       include      common-auth
account    include      common-account
password   include      common-password
session    required     pam_limits.so
session    include      common-session
PAM
fi
EOF
    chmod +x config/hooks/011-mfa.hook.chroot
  fi

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

  # ── A1: PAMName helper ──
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

  cat > "$CHROOT/etc/eiciel/config.env" <<EOF
MGMT_IP="$MGMT_IP"
WEBHOOK_URL="$WEBHOOK_URL"
STOP_SERVICES="$STOP_SERVICES"
ISOLATION_TIMEOUT="${ISOLATION_TIMEOUT}"
INCIDENT_ROOT="/var/lib/incidents"
COOLDOWN_SECONDS=$COOLDOWN_SECONDS
AUTO_TRIGGER="$AUTO_TRIGGER"
AUTO_TRIGGER_MIN_SEVERITY="$AUTO_TRIGGER_MIN_SEVERITY"
DETECT_SSH_FAIL_THRESHOLD="$DETECT_SSH_FAIL_THRESHOLD"
DETECT_SSH_FAIL_WINDOW="$DETECT_SSH_FAIL_WINDOW"
DETECT_EGRESS_MB_THRESHOLD="$DETECT_EGRESS_MB_THRESHOLD"
DETECT_DNS_THRESHOLD="$DETECT_DNS_THRESHOLD"
DETECT_MAX_TRIGGERS_PER_HOUR="$DETECT_MAX_TRIGGERS_PER_HOUR"
DETECT_DRY_RUN="$DETECT_DRY_RUN"
EOF
  chmod 600 "$CHROOT/etc/eiciel/config.env"

  # ── License gate ──
  if [ "$LICENSE_GATE_MODE" != "none" ]; then
    install -m 644 "$LICENSE_PUBKEY_FILE" "$CHROOT/etc/eiciel/license.pub"

    cat > "$CHROOT/usr/local/sbin/eiciel-license-check" <<'LICCHK_EOF'
#!/bin/bash
set -euo pipefail
PUBKEY="/etc/eiciel/license.pub"
LICENSE_JSON="/etc/eiciel/license.json"
LICENSE_SIG="/etc/eiciel/license.sig"
LICENSE_LABEL="EICIEL_LIC"
log() { logger -t eiciel-license "$*"; echo "[license] $*" >&2; }
if [ ! -f "$LICENSE_JSON" ] || [ ! -f "$LICENSE_SIG" ]; then
  dev="$(blkid -L "$LICENSE_LABEL" 2>/dev/null || true)"
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
log "license OK ($(jq -r .license_id "$LICENSE_JSON"))"
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
  echo "✅ License installed and verified. Rebooting in 5s…"; sleep 5; systemctl reboot
else
  echo "❌ License rejected. See: journalctl -t eiciel-license"
  rm -f /etc/eiciel/license.json /etc/eiciel/license.sig; exit 1
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

    if [ "$LICENSE_GATE_MODE" = "hard" ]; then
      cat > "$CHROOT/usr/local/sbin/eiciel-license-hard-lock" <<'HARD_EOF'
#!/bin/bash
set -euo pipefail
sleep 3
if [ ! -f /run/eiciel-licensed ]; then
  logger -t eiciel-license "HARD LOCK — no valid license"
  systemctl isolate emergency.target || true
fi
HARD_EOF
      chmod 755 "$CHROOT/usr/local/sbin/eiciel-license-hard-lock"

      cat > "$CHROOT/etc/systemd/system/eiciel-license-hard-lock.service" <<'HARD_UNIT'
[Unit]
Description=Eiciel license hard lock
After=eiciel-license-gate.service multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/eiciel-license-hard-lock
[Install]
WantedBy=multi-user.target
HARD_UNIT
    fi
  fi

  # ── Re-auth (TOTP) ──
  if [ -n "$REAUTH_TOTP_SECRET" ]; then
    printf '%s\n' "$REAUTH_TOTP_SECRET" > "$CHROOT/etc/eiciel/reauth.secret"
    chmod 600 "$CHROOT/etc/eiciel/reauth.secret"
    cat > "$CHROOT/usr/local/sbin/eiciel-reauth-show" <<'SHOW_EOF'
#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }
SECRET="$(cat /etc/eiciel/reauth.secret)"
echo "TOTP secret: $SECRET"
command -v qrencode >/dev/null && qrencode -t ANSIUTF8 "otpauth://totp/Eiciel:admin@$(hostname)?secret=$SECRET&issuer=Eiciel"
SHOW_EOF
    chmod 755 "$CHROOT/usr/local/sbin/eiciel-reauth-show"
  else
    rm -f "$CHROOT/etc/eiciel/reauth.secret" 2>/dev/null || true
  fi

  # ═══════════════════════════════════════════════════════════════
  #  METRICS SAMPLER
  # ═══════════════════════════════════════════════════════════════
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

  # ═══════════════════════════════════════════════════════════════
  #  A2: DETECTOR
  # ═══════════════════════════════════════════════════════════════
  cat > "$CHROOT/usr/local/sbin/eiciel-detect.sh" <<'DETECT_EOF'
#!/bin/bash
# eiciel-detect.sh — multi-source attacker detector with auto-trigger.
set -euo pipefail

source /etc/eiciel/config.env

AUTO_TRIGGER="${AUTO_TRIGGER:-1}"
MIN_SEV="${AUTO_TRIGGER_MIN_SEVERITY:-high}"
SSH_FAIL_THRESHOLD="${DETECT_SSH_FAIL_THRESHOLD:-10}"
SSH_FAIL_WINDOW="${DETECT_SSH_FAIL_WINDOW:-60}"
EGRESS_MB_THRESHOLD="${DETECT_EGRESS_MB_THRESHOLD:-100}"
DNS_THRESHOLD="${DETECT_DNS_THRESHOLD:-500}"
MAX_TRIGGERS_PER_HOUR="${DETECT_MAX_TRIGGERS_PER_HOUR:-3}"
DRY_RUN="${DETECT_DRY_RUN:-0}"

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
  local source="$1" severity="$2" reason="$3" details="$4"
  local ts; ts="$(date -u +%FT%TZ)"
  jq -nc \
    --arg ts "$ts" --arg src "$source" --arg sev "$severity" \
    --arg reason "$reason" --arg details "$details" \
    '{ts:$ts,source:$src,severity:$sev,reason:$reason,details:$details}' >> "$EVENTS"
  if [ "$(wc -l < "$EVENTS")" -gt 5000 ]; then
    tail -n 5000 "$EVENTS" > "$EVENTS.tmp" && mv "$EVENTS.tmp" "$EVENTS"
  fi
  log "detection: src=$source sev=$severity $reason"
}

rate_limit_ok() {
  local now last
  now=$(date +%s)
  last=$(stat -c %Y "$RATE_FILE" 2>/dev/null || echo 0)
  if [ $(( now - last )) -gt 3600 ]; then
    : > "$RATE_FILE"; return 0
  fi
  local n; n=$(wc -l < "$RATE_FILE")
  [ "$n" -lt "$MAX_TRIGGERS_PER_HOUR" ]
}

cooldown_ok() {
  local cooldown="${COOLDOWN_SECONDS:-600}"
  [ -f "$LOCK" ] || return 0
  local last now
  last=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - last )) -ge "$cooldown" ]
}

trigger_containment() {
  local source="$1" severity="$2" reason="$3"
  if [ "$AUTO_TRIGGER" != "1" ]; then
    log "auto-trigger disabled; detection logged only"
    return
  fi
  if [ "$(sev_rank "$severity")" -lt "$MIN_RANK" ]; then
    log "severity $severity below threshold $MIN_SEV; not triggering"
    return
  fi
  if ! cooldown_ok; then
    log "cooldown active; not triggering"
    return
  fi
  if ! rate_limit_ok; then
    log "rate limit reached ($MAX_TRIGGERS_PER_HOUR/h); not triggering"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN — would trigger: $source/$severity $reason"
    return
  fi
  date -u +%FT%TZ >> "$RATE_FILE"
  touch "$LOCK"
  log "AUTO-TRIGGER: $source/$severity — $reason"
  /usr/local/sbin/eiciel-contain.sh \
      --triggered-by "detect:$source" \
      --reason "$reason" \
      >>/var/log/eiciel-contain.log 2>&1 || log "containment FAILED"
}

watch_fail2ban() {
  journalctl -f -o cat -u fail2ban 2>/dev/null | while read -r line; do
    case "$line" in
      *"Ban "*)
        ip=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        emit_event "fail2ban" "medium" "fail2ban banned $ip" "$line"
        ;;
    esac
  done
}

watch_ssh() {
  local buf="$STATE_DIR/ssh-fails.tmp"
  : > "$buf"
  journalctl -f -o cat -u ssh -u sshd 2>/dev/null | while read -r line; do
    case "$line" in
      *"Failed password"*|*"Invalid user"*)
        ip=$(echo "$line" | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')
        [ -n "$ip" ] || continue
        now=$(date +%s)
        echo "$now $ip" >> "$buf"
        awk -v cutoff="$(( now - SSH_FAIL_WINDOW ))" '$1 >= cutoff' "$buf" > "$buf.n" && mv "$buf.n" "$buf"
        hit=$(awk '{print $2}' "$buf" | sort | uniq -c | sort -rn | head -1)
        count=$(echo "$hit" | awk '{print $1}')
        top_ip=$(echo "$hit" | awk '{print $2}')
        if [ "${count:-0}" -ge "$SSH_FAIL_THRESHOLD" ]; then
          emit_event "ssh" "high" \
            "$count failed SSH logins from $top_ip in ${SSH_FAIL_WINDOW}s" \
            "ip=$top_ip count=$count window=$SSH_FAIL_WINDOW"
          trigger_containment "ssh" "high" \
            "$count failed SSH logins from $top_ip in ${SSH_FAIL_WINDOW}s"
          : > "$buf"
        fi
        ;;
    esac
  done
}

watch_metrics() {
  local cur="$STATE_DIR/metrics.prev"
  while sleep 10; do
    if [ ! -f /var/lib/eiciel-metrics/current.json ]; then continue; fi
    rx_bps=$(jq -r '.egress.rx_bps // 0' /var/lib/eiciel-metrics/current.json 2>/dev/null || echo 0)
    tx_bps=$(jq -r '.egress.tx_bps // 0' /var/lib/eiciel-metrics/current.json 2>/dev/null || echo 0)
    dns_now=$(jq -r '.dns.queries_total // 0' /var/lib/eiciel-metrics/current.json 2>/dev/null || echo 0)
    dns_prev=0
    [ -f "$cur" ] && dns_prev=$(jq -r '.dns // 0' "$cur" 2>/dev/null || echo 0)

    if [ "$tx_bps" -gt $(( EGRESS_MB_THRESHOLD * 1048576 / 60 )) ]; then
      tx_mb_per_sec=$(( tx_bps / 1048576 ))
      emit_event "egress" "high" \
        "egress spike: ${tx_mb_per_sec} MiB/s outbound" \
        "tx_bps=$tx_bps rx_bps=$rx_bps"
      trigger_containment "egress" "high" \
        "outbound egress ${tx_mb_per_sec} MiB/s exceeds threshold"
    fi

    dns_delta=$(( dns_now - dns_prev ))
    if [ "$dns_delta" -gt "$DNS_THRESHOLD" ]; then
      emit_event "dns" "high" \
        "DNS burst: $dns_delta queries in 10s" \
        "delta=$dns_delta threshold=$DNS_THRESHOLD"
      trigger_containment "dns" "high" \
        "DNS burst: $dns_delta queries in 10s"
    fi

    echo "{\"dns\":$dns_now}" > "$cur"
  done
}

watch_web() {
  local log=""
  [ -r /var/log/nginx/access.log ]   && log=/var/log/nginx/access.log
  [ -r /var/log/apache2/access.log ] && log=/var/log/apache2/access.log
  if [ -z "$log" ]; then
    log "web: no access log found, watcher idle"
    sleep infinity
    return
  fi
  local pat='(\.\./|%2e%2e|union[[:space:]]+select|select[[:space:]]+.+from|<script|/etc/passwd|/proc/self/environ|cmd=|exec=|system\(|eval\(|base64_decode|wget[[:space:]]+http|curl[[:space:]]+http|/wp-admin|/phpmyadmin|/\.env|/\.git)'
  tail -F -n0 "$log" 2>/dev/null | while read -r line; do
    if echo "$line" | grep -qiE "$pat"; then
      ip=$(echo "$line" | awk '{print $1}')
      path=$(echo "$line" | grep -oE '"[A-Z]+ [^"]+"' | head -1)
      emit_event "web" "high" \
        "web attack pattern from $ip: $path" \
        "ip=$ip path=$path"
      trigger_containment "web" "high" "web attack pattern from $ip"
    fi
  done
}

watch_new_ip() {
  local seen="$STATE_DIR/seen-ssh-ips.txt"
  touch "$seen"
  journalctl -f -o cat -u ssh -u sshd 2>/dev/null | while read -r line; do
    case "$line" in
      *"Accepted publickey"*|*"Accepted password"*)
        ip=$(echo "$line" | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')
        [ -n "$ip" ] || continue
        if ! grep -qx "$ip" "$seen"; then
          echo "$ip" >> "$seen"
          emit_event "login" "medium" "first-ever successful SSH from $ip" "ip=$ip"
          trigger_containment "login" "medium" "first login from $ip"
        fi
        ;;
    esac
  done
}

log "detect: starting (auto_trigger=$AUTO_TRIGGER min_sev=$MIN_SEV dry_run=$DRY_RUN)"
log "detect: sources=fail2ban ssh metrics web login"

watch_fail2ban &
watch_ssh &
watch_metrics &
watch_web &
watch_new_ip &
wait
DETECT_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-detect.sh"

  cat > "$CHROOT/etc/systemd/system/eiciel-detect.service" <<'DETECT_SVC'
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
StandardOutput=journal
StandardError=journal
Nice=2

[Install]
WantedBy=multi-user.target
DETECT_SVC

  # ── A7: fail2ban action ──
  cat > "$CHROOT/etc/fail2ban/action.d/eiciel-notify.conf" <<'F2B_ACTION'
[Definition]
actionstart =
actionstop  =
actioncheck =
actionban   = logger -t fail2ban-action "Ban <ip> from <name> (eiciel-notify)"
actionunban = logger -t fail2ban-action "Unban <ip> from <name>"
F2B_ACTION

  # ═══════════════════════════════════════════════════════════════
  #  A6: CONTAINMENT SCRIPT — accepts --triggered-by / --reason
  # ═══════════════════════════════════════════════════════════════
  cat > "$CHROOT/usr/local/sbin/eiciel-contain.sh" <<'CONTAIN_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env

TRIGGERED_BY="manual"
TRIGGER_REASON=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --triggered-by) TRIGGERED_BY="$2"; shift 2 ;;
    --reason)       TRIGGER_REASON="$2"; shift 2 ;;
    *) shift ;;
  esac
done

INCIDENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INCIDENT_DIR="$INCIDENT_ROOT/$INCIDENT_ID"
mkdir -p "$INCIDENT_DIR"; chmod 700 "$INCIDENT_DIR"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$INCIDENT_DIR/containment.log" >&2; }
log "=== Incident $INCIDENT_ID (triggered_by=$TRIGGERED_BY) ==="
[ -n "$TRIGGER_REASON" ] && log "Reason: $TRIGGER_REASON"

resolve_host() {
  local url="$1"; [ -n "$url" ] || return 0
  local h; h="$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
  getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u
}
ALLOW_IPS=()
[ -n "${WEBHOOK_URL:-}" ] && while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done < <(resolve_host "$WEBHOOK_URL")
[ -n "${RESTIC_REPO:-}" ] && while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done < <(resolve_host "$RESTIC_REPO")

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

for f in /var/log/auth.log /var/log/syslog /var/log/secure /var/log/messages /var/log/kern.log; do
  [ -f "$f" ] && cp -a "$f" "$INCIDENT_DIR/" 2>/dev/null || true
done
journalctl --since "2 hours ago" --no-pager > "$INCIDENT_DIR/journal.txt" 2>&1 || true
cp -a /var/log/audit/audit.log "$INCIDENT_DIR/" 2>/dev/null || true
[ -f /var/lib/eiciel-metrics/history.jsonl ] && \
  cp -a /var/lib/eiciel-metrics/history.jsonl "$INCIDENT_DIR/metrics-history.jsonl" 2>/dev/null || true
[ -f /var/lib/eiciel-metrics/current.json ] && \
  cp -a /var/lib/eiciel-metrics/current.json "$INCIDENT_DIR/metrics-current.json" 2>/dev/null || true
[ -f /var/lib/eiciel-detections/events.jsonl ] && \
  cp -a /var/lib/eiciel-detections/events.jsonl "$INCIDENT_DIR/detections.jsonl" 2>/dev/null || true

stat /etc/passwd /etc/shadow /etc/sudoers /etc/ssh/sshd_config /root/.ssh/authorized_keys 2>/dev/null \
  > "$INCIDENT_DIR/keyfiles-stat.txt" || true

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

nft delete table inet eiciel_contain 2>/dev/null || true
nft add table inet eiciel_contain
nft add chain inet eiciel_contain output '{ type filter hook output priority -10; policy drop; }'
nft add rule inet eiciel_contain output oif lo accept
nft add rule inet eiciel_contain output ct state established,related accept
nft add rule inet eiciel_contain output udp dport 53 accept
nft add rule inet eiciel_contain output tcp dport 53 accept
nft add rule inet eiciel_contain output ip daddr "$MGMT_IP" accept
for ip in "${ALLOW_IPS[@]:-}"; do [ -n "$ip" ] && nft add rule inet eiciel_contain output ip daddr "$ip" accept; done

if [ -n "${ISOLATION_TIMEOUT:-}" ] && [ "${ISOLATION_TIMEOUT}" -gt 0 ] 2>/dev/null; then
  systemd-run --on-active="${ISOLATION_TIMEOUT}s" \
              --unit=eiciel-autolift \
              --description="Eiciel auto-lift for $INCIDENT_ID" \
              /usr/sbin/nft delete table inet eiciel_contain || true
fi

while read -r user tty _; do
  [ -z "${user:-}" ] && continue
  [ "$user" = "root" ] && continue
  [ "$user" = "admin" ] && continue
  case "$tty" in tty*|pts/*) ;; *) continue ;; esac
  log "  killing user=$user tty=$tty"
  pkill -9 -t "$tty" 2>/dev/null || true
done < <(who)

for svc in $STOP_SERVICES; do
  systemctl is-active --quiet "$svc" 2>/dev/null && systemctl stop "$svc" 2>/dev/null || true
done

if [ -n "${RESTIC_REPO:-}" ] && [ -n "${RESTIC_PASSWORD_FILE:-}" ] && [ -f "$RESTIC_PASSWORD_FILE" ]; then
  restic -r "$RESTIC_REPO" --password-file "$RESTIC_PASSWORD_FILE" backup "$INCIDENT_DIR" >/dev/null 2>&1 || true
fi

if [ -n "${WEBHOOK_URL:-}" ]; then
  payload=$(jq -nc --arg inc "$INCIDENT_ID" --arg host "$(hostname)" \
    --arg time "$(date -u +%FT%TZ)" --arg dir "$INCIDENT_DIR" \
    --arg svc "$STOP_SERVICES" --arg tb "$TRIGGERED_BY" --arg rs "$TRIGGER_REASON" \
    '{incident:$inc,host:$host,time:$time,dir:$dir,services_stopped:$svc,triggered_by:$tb,reason:$rs}')
  curl -fsS --max-time 10 -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 || true
fi

logger -t eiciel "CONTAINMENT COMPLETE — $INCIDENT_ID — triggered_by=$TRIGGERED_BY"
echo "$INCIDENT_DIR"
CONTAIN_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-contain.sh"

  cat > "$CHROOT/usr/local/sbin/eiciel-watch.sh" <<'WATCH_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env

if [ -f /etc/eiciel/license.pub ] && [ ! -f /run/eiciel-licensed ]; then
  logger -t eiciel "watch: system unlicensed — refusing to start"
  exit 1
fi

LOCK="/run/eiciel-contain.lock"
COOLDOWN="${COOLDOWN_SECONDS:-600}"
logger -t eiciel "watch: starting (audit.log + journald)"

handle_line() {
  local line="$1"
  case "$line" in
    *"key=\"priv_esc_unset"*|*"key=\"sudoers"*|*"key=\"module_load"*|\
    *"key=\"ptrace"*|*"key=\"watcher_tamper"*|*"key=\"audit_tamper"*|\
    *"key=\"isolation_lift"*|*"key=\"eiciel_config"*|*"key=\"eiciel_scripts"*) ;;
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
      --reason "audit event: $line" \
      >>/var/log/eiciel-contain.log 2>&1 || \
    logger -t eiciel "watch: containment FAILED"
}
export -f handle_line

if [ -f /var/log/audit/audit.log ]; then
  tail -F -n0 /var/log/audit/audit.log 2>/dev/null | while read -r line; do handle_line "$line"; done &
fi
journalctl -f -u auditd -o cat --no-pager 2>/dev/null | while read -r line; do handle_line "$line"; done &
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
-a always,exit -F arch=b64 -S ptrace -k ptrace
-a always,exit -F arch=b64 -S mount   -k mount
-a always,exit -F arch=b64 -S umount2 -k mount
-w /etc/systemd/system/eiciel-watch.service -p wa -k watcher_tamper
-w /etc/systemd/system/eicield.service      -p wa -k watcher_tamper
-w /etc/systemd/system/eiciel-detect.service -p wa -k watcher_tamper
-w /etc/audit/rules.d/                      -p wa -k audit_tamper
-w /etc/eiciel/                             -p wa -k eiciel_config
-w /usr/local/sbin/eiciel-contain.sh        -p wa -k eiciel_scripts
-w /usr/local/sbin/eiciel-watch.sh          -p wa -k eiciel_scripts
-w /usr/local/sbin/eiciel-detect.sh         -p wa -k eiciel_scripts
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/systemctl -F a1=stop    -F a2=auditd        -k audit_tamper
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/systemctl -F a1=stop    -F a2=eiciel-watch  -k watcher_tamper
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/systemctl -F a1=stop    -F a2=eiciel-detect -k watcher_tamper
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/systemctl -F a1=disable -F a2=auditd        -k audit_tamper
-a always,exit -F arch=b64 -S execve -F path=/usr/sbin/nft -F a1=delete -F a2=table -F a3=inet -F a4=eiciel_contain -k isolation_lift
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
flush ruleset
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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

  cat > "$CHROOT/usr/local/sbin/eiciel-watchdog.sh" <<'WD_EOF'
#!/bin/bash
set -euo pipefail
if ! systemctl is-active --quiet eiciel-watch; then
  logger -t eiciel "watchdog: eiciel-watch down — restarting"
  systemctl start eiciel-watch || true
  /usr/local/sbin/eiciel-contain.sh --triggered-by "watchdog" \
      --reason "eiciel-watch was down" \
      >>/var/log/eiciel-contain.log 2>&1 &
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

  cat > "$CHROOT/usr/local/sbin/eiciel-heartbeat.sh" <<'HB_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env
[ -n "${WEBHOOK_URL:-}" ] || exit 0
curl -fsS --max-time 5 -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' \
  -d "{\"heartbeat\":\"$(hostname)\",\"time\":\"$(date -u +%FT%TZ)\"}" >/dev/null 2>&1 || true
HB_EOF
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

  cat > "$CHROOT/root/RECOVERY.md" <<'REC_EOF'
# Eiciel IR Console — post-incident recovery runbook

## 0. DO NOT
- Do not power off.
- Do not delete /var/lib/incidents.
- Do not "clean up". Rebuild.

## 1. Snapshot the hypervisor FIRST
Proxmox:  qm snapshot <vmid> incident-<date>
VMware:   vim-cmd vmsvc/snapshot.create <vmid> incident-<date>
AWS EC2:  aws ec2 create-snapshot --volume-id <vol>

## 2. SSH from MGMT_IP
ssh admin@<server>

## 3. Copy evidence off-host
sudo cp -a /var/lib/incidents/ /root/incidents-preserved/
rsync -av /root/incidents-preserved/ admin@mgmt-host:/srv/incidents/

## 4. Inspect
cat /var/lib/incidents/*/containment.log
cat /var/lib/incidents/*/detections.jsonl
cat /var/lib/incidents/*/metrics-history.jsonl
ausearch -k priv_esc_unset --start today | less
ausearch -k watcher_tamper --start today | less
ausearch -k audit_tamper   --start today | less
ausearch -k isolation_lift --start today | less
journalctl -u eiciel-watch --since "2 hours ago"
journalctl -u eiciel-detect --since "2 hours ago"

## 5. Rotate every secret
- rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; re-add only yours
- passwd root; passwd admin
- DB creds; app .env; ~/.aws; cloud tokens; TLS certs
- Re-enroll MFA; rotate TOTP via `eiciel-reauth-show`

## 6. Rebuild from known-good image

## 7. Lift isolation
sudo nft delete table inet eiciel_contain

## 8. After patching
- Check: cat /var/run/reboot-required

## 9. Post-mortem
REC_EOF
  chmod 644 "$CHROOT/root/RECOVERY.md"

  cat > "$CHROOT/etc/profile.d/eiciel-motd.sh" <<'MOTD_EOF'
#!/bin/sh
if [ -t 0 ]; then
  LIC="unknown"; [ -f /run/eiciel-license-state ] && LIC="$(cat /run/eiciel-license-state)"
  PERSIST="off"
  for p in /run/live/persistence /lib/live/mount/persistence; do
    [ -d "$p" ] && [ -n "$(ls -A "$p" 2>/dev/null)" ] && PERSIST="on"
  done
  REAUTH="configured"
  [ -s /etc/eiciel/reauth.secret ] || REAUTH="NOT configured (trigger/lift disabled)"
  AUTO="enabled"
  grep -q '^AUTO_TRIGGER="0"' /etc/eiciel/config.env 2>/dev/null && AUTO="disabled"
  cat <<BANNER

  ╔══════════════════════════════════════════════════════════╗
  ║  Eiciel IR Console — compromise response active          ║
  ║                                                          ║
  ║  License   : ${LIC}
  ║  Re-auth   : ${REAUTH}
  ║  Auto-trig : ${AUTO}
  ║  Persist   : ${PERSIST}
  ║  Config    : /etc/eiciel/config.env                      ║
  ║  Evidence  : /var/lib/incidents/<timestamp>-<pid>/       ║
  ║  Metrics   : /var/lib/eiciel-metrics/                    ║
  ║  Detections: /var/lib/eiciel-detections/                 ║
  ║  Recovery  : /root/RECOVERY.md                           ║
  ║  Tools doc : /root/TOOLS.md                              ║
  ║  GUI       : sudo eiciel-gui                             ║
  ║  Install   : eiciel-tools list                           ║
  ║  Persist   : eiciel-persist-init <disk>  (one-time)      ║
  ╚══════════════════════════════════════════════════════════╝

BANNER
fi
MOTD_EOF
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

  cat > "$CHROOT/usr/local/sbin/eiciel-persist-init" <<'PERS_EOF'
#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
eiciel-persist-init /dev/sdX

Partition a disk for use with Eiciel live persistence.
WARNING: this ERASES the entire target disk.

After this, reboot the live session. Changes made to the running
system (apt install, files, configs) survive reboots of the ISO.
USAGE
  exit 0
fi
if [ "$#" -lt 1 ]; then
  echo "Usage: eiciel-persist-init /dev/sdX   (see --help)"
  echo; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL,MODEL
  exit 2
fi
DEV="$1"
[ -b "$DEV" ] || { echo "❌ Not a block device: $DEV" >&2; exit 1; }
ROOT_SRC="$(findmnt -n -o SOURCE / | sed 's/\[.*//')"
ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
LIVE_SRC="$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null || true)"
LIVE_DISK="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null || true)"
TARGET_DISK="$(basename "$DEV")"
[ -n "$ROOT_DISK" ] && [ "$TARGET_DISK" = "$ROOT_DISK" ] && { echo "❌ $DEV backs the running system. Refusing." >&2; exit 1; }
[ -n "$LIVE_DISK" ] && [ "$TARGET_DISK" = "$LIVE_DISK" ] && { echo "❌ $DEV is the boot medium. Refusing." >&2; exit 1; }
echo "About to ERASE $DEV:"; lsblk "$DEV"; echo
read -r -p "Type 'yes' to proceed: " A; [ "$A" = "yes" ] || { echo "aborted"; exit 1; }
for p in "$DEV"*; do [ -b "$p" ] && umount "$p" 2>/dev/null || true; done
wipefs -a "$DEV" >/dev/null 2>&1 || true
parted -s "$DEV" mklabel gpt
parted -s "$DEV" mkpart primary ext4 1MiB 100%
sleep 1; partprobe "$DEV" 2>/dev/null || true; sleep 1
PART=""
for p in "${DEV}1" "${DEV}p1"; do [ -b "$p" ] && PART="$p" && break; done
[ -n "$PART" ] || { echo "❌ could not find new partition on $DEV"; exit 1; }
mkfs.ext4 -F -L persistence "$PART" >/dev/null
TMP="$(mktemp -d)"; mount "$PART" "$TMP"; echo "/ union" > "$TMP/persistence.conf"; sync
umount "$TMP"; rmdir "$TMP"
echo; echo "✅ $DEV is now a persistence volume (partition $PART)."
echo "   Reboot the live session to activate persistence."
PERS_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-persist-init"

  cat > "$CHROOT/usr/local/bin/eiciel-tools" <<'TOOLS_EOF'
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

declare -A GROUPS=(
  [browsers]="firefox-esr chromium"
  [forensic]="sleuthkit foremost binwalk scalpel testdisk dc3dd gddrescue icoutils"
  [network]="wireshark tshark nmap tcpdump socat netcat-openbsd dsniff traceroute"
  [malware]="yara clamav clamav-freshclam pev radare2"
  [office]="libreoffice-writer libreoffice-calc evince mousepad xarchiver"
  [dev]="build-essential git python3-dev python3-pip python3-venv gdb strace ltrace"
  [desktop]="pcmanfm lxterminal galculator scrot feh"
  [containers]="docker.io docker-compose"
)

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

[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "$#" -eq 0 ] && { usage; exit 0; }
cmd="$1"; shift

case "$cmd" in
  list)
    echo "Available groups:"
    for g in browsers forensic network malware office dev desktop containers; do
      printf "  %-12s %s\n" "$g" "${GROUPS[$g]}"
    done
    echo
    if persistence_active; then echo "Persistence: ACTIVE"; else
      echo "Persistence: not active — installs will be lost at reboot."
      echo "Set up persistence: eiciel-persist-init <disk>"
    fi ;;
  search)
    [ "$#" -ge 1 ] || { echo "usage: eiciel-tools search <term>"; exit 2; }
    apt-cache search "$@" ;;
  install)
    [ "$#" -ge 1 ] || { echo "usage: eiciel-tools install <group>..."; exit 2; }
    if ! persistence_active; then
      echo "⚠️  Persistence is NOT active — installs lost at reboot."
      echo "    Set up: eiciel-persist-init <disk>; reboot; rerun."
      echo "    Continuing in 5 seconds; Ctrl-C to abort."
      sleep 5
    fi
    PKGS=""
    for g in "$@"; do
      if [ "$g" = "all" ]; then
        for gg in browsers forensic network malware office dev desktop containers; do PKGS="$PKGS ${GROUPS[$gg]}"; done
      elif [ -n "${GROUPS[$g]:-}" ]; then PKGS="$PKGS ${GROUPS[$g]}"
      else echo "Unknown group: $g" >&2; usage >&2; exit 2; fi
    done
    UNIQ="$(echo $PKGS | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')"
    echo "Installing: $UNIQ"; echo
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends $UNIQ
    echo; echo "✅ Done."
    persistence_active && echo "   Installed to persistence — survives reboots." \
                       || echo "   ⚠️  Installed to RAM overlay — will be lost at reboot." ;;
  *) echo "Unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
TOOLS_EOF
  chmod 755 "$CHROOT/usr/local/bin/eiciel-tools"

  cat > "$CHROOT/root/TOOLS.md" <<'TOOLSMD_EOF'
# Eiciel IR Console — installing tools and persisting them

The ISO is a read-only live system. Packages you install end up in a
RAM overlay and disappear at reboot **unless** persistence is active.

## 1. Prepare a persistence disk (once)
    eiciel-persist-init /dev/sdX

## 2. Install tools
    eiciel-tools list
    eiciel-tools install browsers
    eiciel-tools install all

## 3. Status
    eiciel-tools list

## 4. Live metrics and detections
    cat /var/lib/eiciel-metrics/current.json | jq .
    tail -n 20 /var/lib/eiciel-detections/events.jsonl | jq .

## 5. Auto-trigger
    grep AUTO_TRIGGER /etc/eiciel/config.env
    systemctl status eiciel-detect

TOOLSMD_EOF
  chmod 644 "$CHROOT/root/TOOLS.md"

  # ── GUI ──
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

SPLASH_PID=""
if command -v xmessage >/dev/null 2>&1; then
  xmessage -center -bg "#161b22" -fg "#e6edf3" -buttons "" \
           -title "Eiciel IR Console" \
           "Starting Eiciel IR Console…
Waiting for services." &
  SPLASH_PID=$!
fi

for i in $(seq 1 30); do
  [ -S /run/eicield.sock ] && break
  sleep 1
done

[ -n "$SPLASH_PID" ] && kill "$SPLASH_PID" 2>/dev/null || true

if [ -x /usr/local/bin/eiciel-dashboard ]; then
  exec /usr/local/bin/eiciel-dashboard
else
  exec xterm -fa Monospace -fs 11 -bg "#0e1116" -fg "#e6edf3"
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
    <item label="nmap (help)"><action name="Execute"><command>xterm -e "nmap --help | less"</command></action></item>
    <item label="tcpdump (help)"><action name="Execute"><command>xterm -e "tcpdump --help | less"</command></action></item>
    <item label="tshark (help)"><action name="Execute"><command>xterm -e "tshark -h | less"</command></action></item>
    <item label="testdisk"><action name="Execute"><command>xterm -e testdisk</command></action></item>
  </menu>
  <menu id="editors" label="Editors">
    <item label="Text editor"><action name="Execute"><command>mousepad</command></action></item>
    <item label="Hex editor (ghex)"><action name="Execute"><command>ghex</command></action></item>
    <item label="Hex editor (bless)"><action name="Execute"><command>bless</command></action></item>
  </menu>
  <menu id="system" label="System">
    <item label="Firefox"><action name="Execute"><command>firefox-esr</command></action></item>
    <item label="GParted"><action name="Execute"><command>gparted</command></action></item>
    <item label="SQLite Browser"><action name="Execute"><command>sqlitebrowser</command></action></item>
    <item label="Install tools (terminal)"><action name="Execute"><command>xterm -e "eiciel-tools list; echo; read -p 'Enter to close'"</command></action></item>
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

    cat > "$CHROOT/usr/local/bin/eiciel-dashboard" <<'LAUNCH'
#!/bin/bash
exec /opt/eiciel-dashboard/EicielDashboard "$@"
LAUNCH
    chmod 755 "$CHROOT/usr/local/bin/eiciel-dashboard"
  fi

  if [ "$LICENSE_GATE_MODE" = "hard" ]; then HARD="systemctl enable eiciel-license-hard-lock.service"; else HARD=":"; fi
  if [ "$LICENSE_GATE_MODE" != "none" ]; then GATE="systemctl enable eiciel-license-gate.service"; else GATE=":"; fi
  if [ "$ENABLE_GUI" = "1" ] && [ "$GUI_AUTOLOGIN" = "1" ]; then AUTO="systemctl enable getty@tty1.service"; else AUTO=":"; fi
  if [ "$ENABLE_METRICS" = "1" ]; then METRICS="systemctl enable eiciel-metrics.timer"; else METRICS=":"; fi

  cat > config/hooks/030-enable-services.hook.chroot <<EOF
#!/bin/bash
set -e
systemctl enable auditd
augenrules --load 2>/dev/null || true
systemctl enable fail2ban
systemctl enable nftables
systemctl enable ssh
systemctl enable eiciel-watch
systemctl enable eiciel-detect
systemctl enable eiciel-watchdog.timer
systemctl enable eiciel-heartbeat.timer
$METRICS
systemctl enable eicield.service
$GATE
$HARD
$AUTO
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
/usr/local/sbin/eiciel-persist-init
/usr/local/bin/eiciel-tools
/root/TOOLS.md
/etc/eiciel/config.env
/etc/audit/rules.d/eiciel.rules
/etc/fail2ban/jail.d/eiciel.local
/etc/fail2ban/action.d/eiciel-notify.conf
/etc/nftables.conf
/etc/pam.d/eiciel-service
/etc/systemd/system/eiciel-watch.service
/etc/systemd/system/eiciel-detect.service
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

[ -f /etc/eiciel/reauth.secret ] && FILES="$FILES
/usr/local/sbin/eiciel-reauth-show"

[ -x /usr/bin/startx ] && FILES="$FILES
/usr/local/bin/eiciel-gui
/etc/X11/Xwrapper.config
/home/admin/.xinitrc
/home/admin/.bash_profile
/etc/xdg/openbox/rc.xml
/etc/xdg/openbox/menu.xml"

[ "${ENABLE_MFA:-0}" = "1" ] && FILES="$FILES
/etc/pam.d/sshd"

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
[ -x /usr/local/sbin/eiciel-persist-init ] || { echo "  ❌ persist-init not executable"; fail=1; }
[ -x /usr/local/bin/eiciel-tools ]       || { echo "  ❌ eiciel-tools not executable";   fail=1; }
[ "$(stat -c '%a' /etc/eiciel/config.env)" = "600" ] || { echo "  ❌ config.env mode wrong"; fail=1; }

grep -rqE 'NOPASSWD:[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null && { echo "  ❌ NOPASSWD:ALL present"; fail=1; }

if [ -x /usr/bin/startx ]; then
  [ -x /usr/bin/openbox ] || echo "  ⚠️  openbox not installed (GUI will fail)"
  [ -f /etc/X11/Xwrapper.config ] || { echo "  ❌ Xwrapper.config missing"; fail=1; }
fi

if [ -f /etc/eiciel/reauth.secret ]; then
  [ -s /etc/eiciel/reauth.secret ] || { echo "  ❌ reauth.secret is empty"; fail=1; }
fi

if grep -q '/dev/tty\*|/dev/pts/\*' /usr/local/sbin/eiciel-contain.sh 2>/dev/null; then
  echo "  ❌ contain.sh still has the /dev/tty prefix bug (F5 regression)"; fail=1
fi

# A1: every eiciel unit must have PAMName=eiciel-service
for unit in eiciel-watch eiciel-detect eiciel-watchdog eiciel-heartbeat eicield; do
  f="/etc/systemd/system/$unit.service"
  if [ -f "$f" ]; then
    grep -q '^PAMName=eiciel-service' "$f" || { echo "  ❌ $unit.service missing PAMName=eiciel-service"; fail=1; }
  fi
done
[ -f /etc/systemd/system/eiciel-metrics.service ] && \
  grep -q '^PAMName=eiciel-service' /etc/systemd/system/eiciel-metrics.service || \
  { [ -f /etc/systemd/system/eiciel-metrics.service ] && echo "  ❌ eiciel-metrics.service missing PAMName" && fail=1; }

if [ "${ENABLE_METRICS:-0}" = "1" ]; then
  [ -x /usr/local/sbin/eiciel-metrics.sh ] || { echo "  ❌ metrics not executable"; fail=1; }
  grep -q 'table inet eiciel_metrics' /etc/nftables.conf || { echo "  ❌ eiciel_metrics nft table missing"; fail=1; }
fi

# A6: contain.sh must accept --triggered-by
grep -q -- '--triggered-by' /usr/local/sbin/eiciel-contain.sh || \
  { echo "  ❌ contain.sh missing --triggered-by"; fail=1; }

if [ "${ENABLE_TOOLS:-0}" = "1" ]; then
  for bin in nmap tcpdump tshark binwalk foremost fls sqlite3 yara ghex xxd parted; do
    command -v "$bin" >/dev/null 2>&1 || { echo "  ❌ IR tool missing: $bin"; fail=1; }
  done
fi

if [ "${ENABLE_TOOLS_HEAVY:-0}" = "1" ]; then
  for bin in firefox-esr wireshark gparted; do
    command -v "$bin" >/dev/null 2>&1 || { echo "  ❌ heavy tool missing: $bin"; fail=1; }
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
chmod 755 /usr/local/sbin/eiciel-contain.sh
chmod 755 /usr/local/sbin/eiciel-watch.sh
chmod 755 /usr/local/sbin/eiciel-detect.sh
chmod 755 /usr/local/sbin/eiciel-persist-init
chmod 755 /usr/local/bin/eiciel-tools
chmod 600 /etc/eiciel/config.env
[ -f /etc/eiciel/reauth.secret ] && chmod 600 /etc/eiciel/reauth.secret
[ -x /usr/local/sbin/eiciel-metrics.sh ] && chmod 755 /usr/local/sbin/eiciel-metrics.sh
chown -R root:root /var/lib/eiciel-metrics 2>/dev/null || true
chmod 700 /var/lib/eiciel-metrics 2>/dev/null || true
chown -R root:root /var/lib/eiciel-detections 2>/dev/null || true
chmod 700 /var/lib/eiciel-detections 2>/dev/null || true
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
acl
attr
rsyslog

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

menuentry "Eiciel IR Console" {
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
  ENABLE_MFA="$ENABLE_MFA" \
  MFA_SSH="$MFA_SSH" MFA_SUDO="$MFA_SUDO" \
  ENABLE_TOOLS="$ENABLE_TOOLS" \
  ENABLE_TOOLS_HEAVY="$ENABLE_TOOLS_HEAVY" \
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
    echo "✅  All done."
    echo "      Dashboard : $APP_DIST"
    echo "      Daemon    : $DAEMON_DIST"
    echo "      ISO       : $ROOT/eiciel-server.iso"
    echo "      BUILD_MODE   = $BUILD_MODE"
    echo "      GUI          = $ENABLE_GUI (autologin=$GUI_AUTOLOGIN)"
    echo "      Toolkit      = $ENABLE_TOOLS (heavy=$ENABLE_TOOLS_HEAVY)"
    echo "      Metrics      = $ENABLE_METRICS"
    echo "      Auto-trigger = $AUTO_TRIGGER (min_sev=$AUTO_TRIGGER_MIN_SEVERITY, dry_run=$DETECT_DRY_RUN)"
    echo "      Persistence  = $ENABLE_PERSISTENCE"
    echo "      License gate = $LICENSE_GATE_MODE"
    echo "      Re-auth TOTP = $([ -n "$REAUTH_TOTP_SECRET" ] && echo enabled || echo disabled)"
    echo "═══════════════════════════════════════════════════════════════"
    ;;
  *) echo "usage: $0 [app|iso|all]" >&2; exit 2 ;;
esac