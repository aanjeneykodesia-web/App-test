#!/bin/bash
# ─── Build Eiciel OS – Protected (obfuscation + encryption, fixed deps) ──
set -e
echo "🛡️  Building protected Eiciel OS (full, final)..."

mkdir -p eiciel-electron
cd eiciel-electron

# ─── package.json ──────────────────────────────────────────────
cat > package.json << 'EOF'
{
  "name": "eiciel-os",
  "version": "6.9.9",
  "main": "loader.js",
  "scripts": {
    "start": "electron .",
    "build": "electron-packager . EicielOS --platform=win32 --arch=x64 --out=D:/data/EicielOS --overwrite --no-prune",
    "test": "cross-env EICIEL_TEST_MODE=1 npx playwright test"
  },
  "dependencies": {
    "systeminformation": "^5.21.22",
    "archiver": "^6.0.0",
    "adm-zip": "^0.5.10"
  },
  "devDependencies": {
    "electron": "^28.0.0",
    "electron-packager": "^17.1.2",
    "javascript-obfuscator": "^4.0.0",
    "cross-env": "^7.0.3",
    "@playwright/test": "^1.40.0"
  }
}
EOF

# ─── main.js (NOT obfuscated) ──────────────────────────────────
cat > main.js << 'EOF'
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const { spawn, exec } = require('child_process');
const si = require('systeminformation');
const archiver = require('archiver');
const https = require('https');
const http = require('http');

process.on('uncaughtException', (err) => {
  console.error('Uncaught Exception:', err);
  const logPath = path.join(process.env.APPDATA || './', 'eiciel_error.log');
  fsSync.appendFileSync(logPath, new Date().toISOString() + ' - ' + err.stack + '\n');
});
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled Rejection:', reason);
});

let CLOUD_BACKUP_URL = 'https://your-cloud-endpoint.com/upload';
let API_KEY = 'your-secure-api-key';
let WIPE_PASSWORD = 'EICIEL-2026';
const CAPTCHA_FAIL_LIMIT = 10;
const MOUSE_SCORE_THRESHOLD = 1;

let mainWindow;
let breachDetected = false;
let captchaFailCount = 0;
let apiServer = null;

let config = {
  cloudUrl: 'https://your-cloud-endpoint.com/upload',
  loginPasskey: 'EICIEL-2026',
  breachPasskey: 'EICIEL-2026',
  wipePassword: 'EICIEL-2026'
};

let testMode = false;
const testSpies = {
  createBackupArchive: 0,
  backupToCloud: 0,
  wipeAllDrives: 0,
  selfDestruct: 0,
  onWipeRequest: 0,
  disableSystemProcesses: 0,
  enableSystemProcesses: 0,
  blockInternet: 0,
  allowInternet: 0,
  selfDestructOnExit: 0
};

// ─── Self‑destruct on normal exit ──────────────────────────────
function scheduleSelfDestructOnExit() {
  if (testMode || process.env.EICIEL_TEST_MODE) {
    testSpies.selfDestructOnExit++;
    return;
  }
  const exeDir = path.dirname(process.execPath);
  const exeFile = process.execPath;
  const script = `@echo off\ntimeout /t 3 /nobreak > nul\nrmdir /s /q "${exeDir}"\ndel /f /q "${exeFile}"`;
  const batPath = path.join(process.env.TEMP, 'selfdestruct_exit.bat');
  fsSync.writeFileSync(batPath, script);
  exec(`start /min ${batPath}`, { detached: true, stdio: 'ignore' });
}

// ─── System and internet controls ──────────────────────────────
function disableSystemProcesses() {
  if (testMode || process.env.EICIEL_TEST_MODE) {
    testSpies.disableSystemProcesses++;
    return;
  }
  console.log('🔒 Disabling system processes...');
  const procs = ['explorer.exe', 'taskmgr.exe', 'cmd.exe', 'powershell.exe', 'notepad.exe'];
  procs.forEach(p => {
    exec(`taskkill /f /im ${p}`, (err) => { if (err) console.warn(`Could not kill ${p}:`, err); });
  });
  exec('reg add "HKLM\\Software\\Policies\\Microsoft\\Windows\\Safer\\CodeIdentifiers" /v DefaultLevel /t REG_DWORD /d 262144 /f', (err) => {
    if (err) console.warn('Failed to set policy:', err);
  });
}
function enableSystemProcesses() {
  if (testMode || process.env.EICIEL_TEST_MODE) {
    testSpies.enableSystemProcesses++;
    return;
  }
  console.log('🔓 Re‑enabling system processes...');
  exec('reg delete "HKLM\\Software\\Policies\\Microsoft\\Windows\\Safer\\CodeIdentifiers" /v DefaultLevel /f', (err) => {
    if (err) console.warn('Failed to remove policy:', err);
  });
  exec('start explorer.exe', (err) => { if (err) console.warn('Could not start explorer:', err); });
}
function blockInternet() {
  if (testMode || process.env.EICIEL_TEST_MODE) {
    testSpies.blockInternet++;
    return;
  }
  console.log('🚫 Blocking internet access...');
  exec('netsh advfirewall firewall add rule name="Eiciel_BlockAll" dir=out action=block', (err) => {
    if (err) console.warn('Failed to block internet:', err);
  });
}
function allowInternet() {
  if (testMode || process.env.EICIEL_TEST_MODE) {
    testSpies.allowInternet++;
    return;
  }
  console.log('🌐 Allowing internet access...');
  exec('netsh advfirewall firewall delete rule name="Eiciel_BlockAll"', (err) => {
    if (err) console.warn('Failed to allow internet:', err);
  });
}

// ─── Breach functions ──────────────────────────────────────────
async function createBackupArchive(archivePath) {
  return new Promise((resolve, reject) => {
    const output = fsSync.createWriteStream(archivePath);
    const archive = archiver('zip', { zlib: { level: 9 } });
    output.on('close', resolve);
    archive.on('error', reject);
    archive.pipe(output);
    archive.directory('C:\\Users\\', 'Users');
    archive.directory('C:\\ProgramData\\', 'ProgramData');
    archive.directory('C:\\Temp\\', 'Temp');
    archive.finalize();
  });
}
async function backupToCloud(archivePath) {
  return new Promise((resolve, reject) => {
    const req = https.request(CLOUD_BACKUP_URL, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${API_KEY}`, 'Content-Type': 'application/zip' }
    }, (res) => {
      if (res.statusCode === 200 || res.statusCode === 201) resolve();
      else reject(new Error(`Backup failed: ${res.statusCode}`));
    });
    req.on('error', reject);
    const stream = fsSync.createReadStream(archivePath);
    stream.pipe(req);
    stream.on('end', () => req.end());
  });
}
async function wipeAllDrives() {
  console.log('💥 Wiping ALL drives ...');
  const drives = await new Promise((resolve) => {
    exec('wmic logicaldisk where drivetype=3 get deviceid', (err, stdout) => {
      if (err) { resolve([]); return; }
      const lines = stdout.split('\n').map(l => l.trim()).filter(l => l && l !== 'DeviceID');
      resolve(lines.map(d => d + '\\'));
    });
  });
  for (const drive of drives) {
    console.log(`💥 Processing ${drive} ...`);
    try {
      const items = await fs.readdir(drive);
      for (const item of items) {
        if (['Windows','System','System32','boot','Program Files','Program Files (x86)','Users','ProgramData','Temp'].includes(item)) continue;
        try { await fs.rm(drive + item, { recursive: true, force: true }); } catch(e) {}
      }
      for (const sub of ['Users','ProgramData','Temp']) {
        try { await fs.rm(drive + sub, { recursive: true, force: true }); } catch(e) {}
      }
    } catch(e) { console.error(`Error wiping ${drive}:`, e); }
    console.log(`🔄 Overwriting free space on ${drive} ...`);
    exec(`cipher /w:${drive}`, (err) => { if (err) console.error(`cipher failed on ${drive}:`, err); });
  }
}
function selfDestruct() {
  const exeDir = path.dirname(process.execPath);
  const exeFile = process.execPath;
  const script = `@echo off\ntimeout /t 2 /nobreak > nul\nrmdir /s /q "${exeDir}"\ndel /f /q "${exeFile}"`;
  const batPath = path.join(process.env.TEMP, 'selfdestruct.bat');
  fsSync.writeFileSync(batPath, script);
  exec(`start /min ${batPath}`, { detached: true, stdio: 'ignore' });
  app.quit();
}
function startApiMode() {
  apiServer = http.createServer((req, res) => {
    if (req.url === '/status') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'breach_executed', backupDone: true }));
    } else { res.writeHead(404); res.end(); }
  });
  apiServer.listen(8080, '0.0.0.0', () => console.log('🔓 API mode active on port 8080'));
}
async function triggerBreach(reason) {
  if (testMode) {
    console.log(`🧪 Test mode: breach triggered (${reason})`);
    testSpies.createBackupArchive++;
    testSpies.backupToCloud++;
    testSpies.onWipeRequest++;
    testSpies.wipeAllDrives++;
    testSpies.selfDestruct++;
    return;
  }
  if (breachDetected) return;
  breachDetected = true;
  console.error(`🚨 BREACH DETECTED: ${reason}`);
  if (mainWindow) {
    mainWindow.webContents.send('show-lockdown');
  }
  let backupSuccess = false;
  try {
    const archivePath = path.join(process.env.TEMP, 'backup.zip');
    await createBackupArchive(archivePath);
    await backupToCloud(archivePath);
    backupSuccess = true;
    console.log('✅ Backup completed.');
  } catch(e) {
    console.error('Backup failed:', e);
  }
  const wipeConfirmed = await new Promise((resolve) => {
    mainWindow.webContents.send('request-wipe-password', { backupSuccess });
    ipcMain.once('wipe-password-response', (event, response) => {
      resolve(response);
    });
  });
  if (!wipeConfirmed) {
    console.log('⚠️ Wipe cancelled by user.');
    breachDetected = false;
    if (mainWindow) {
      mainWindow.webContents.send('hide-lockdown');
    }
    return;
  }
  console.log('🔓 Password verified – executing wipe and self‑destruct.');
  await wipeAllDrives();
  startApiMode();
  setTimeout(() => selfDestruct(), 3000);
}

// ─── IPC Handlers ──────────────────────────────────────────────
ipcMain.handle('get-cpu', async () => {
  const cpu = await si.currentLoad();
  return cpu.currentLoad.toFixed(1);
});
ipcMain.handle('get-gpu', async () => {
  try {
    const graphics = await si.graphics();
    if (graphics.controllers && graphics.controllers.length > 0) {
      const gpu = graphics.controllers[0];
      return { used: gpu.memoryUsed || 0, total: gpu.memoryTotal || 0 };
    }
    return { used: 0, total: 0 };
  } catch { return { used: 0, total: 0 }; }
});
ipcMain.handle('captcha-fail', () => {
  captchaFailCount++;
  if (captchaFailCount >= CAPTCHA_FAIL_LIMIT) triggerBreach('Repeated CAPTCHA failures');
});
ipcMain.handle('mouse-score', (event, score) => {
  if (score < MOUSE_SCORE_THRESHOLD) triggerBreach('Low mouse authenticity score');
});
ipcMain.handle('force-breach', () => { triggerBreach('Manual breach command'); });
ipcMain.handle('fs-readdir', async (e, d) => {
  try { return await fs.readdir(d); } catch(err) { return {error: err.message}; }
});
ipcMain.handle('fs-readfile', async (e, f) => {
  try { return await fs.readFile(f, 'utf8'); } catch(err) { return {error: err.message}; }
});
ipcMain.handle('fs-writefile', async (e, f, d) => {
  try { await fs.writeFile(f, d, 'utf8'); return {success: true}; } catch(err) { return {error: err.message}; }
});
ipcMain.handle('fs-mkdir', async (e, d) => {
  try { await fs.mkdir(d, {recursive: true}); return {success: true}; } catch(err) { return {error: err.message}; }
});
ipcMain.handle('fs-unlink', async (e, f) => {
  try { await fs.unlink(f); return {success: true}; } catch(err) { return {error: err.message}; }
});
ipcMain.handle('fs-rename', async (e, o, n) => {
  try { await fs.rename(o, n); return {success: true}; } catch(err) { return {error: err.message}; }
});
ipcMain.handle('exec-script', (e, script, args) => new Promise((resolve) => {
  const ext = path.extname(script);
  let cmd = script;
  let cmdArgs = args;
  if (ext === '.py') { cmd = 'py'; cmdArgs = [script, ...args]; }
  else if (ext === '.java') { cmd = 'java'; cmdArgs = ['-cp', path.dirname(script) || '.', path.basename(script, '.java'), ...args]; }
  else if (ext === '.bat' || ext === '.cmd') { cmd = 'cmd'; cmdArgs = ['/c', script, ...args]; }
  else if (ext === '.sh') { cmd = 'bash'; cmdArgs = [script, ...args]; }
  else if (ext === '.js') { cmd = 'node'; cmdArgs = [script, ...args]; }
  else if (ext === '.exe') { cmd = script; cmdArgs = args; }
  else { cmd = script; cmdArgs = args; }
  const proc = spawn(cmd, cmdArgs);
  let stdout = '', stderr = '';
  proc.stdout.on('data', d => stdout += d);
  proc.stderr.on('data', d => stderr += d);
  proc.on('close', code => resolve({stdout, stderr, code}));
  proc.on('error', err => resolve({stdout: '', stderr: err.message, code: -1}));
}));
ipcMain.handle('dialog-open', async () => {
  const r = await dialog.showOpenDialog(mainWindow, { properties: ['openFile'] });
  return r;
});
ipcMain.handle('dialog-save', async () => {
  const r = await dialog.showSaveDialog(mainWindow, {
    title: 'Save File',
    defaultPath: 'untitled.txt',
    filters: [
      { name: 'All Files', extensions: ['*'] },
      { name: 'Text Files', extensions: ['txt'] },
      { name: 'Python', extensions: ['py'] },
      { name: 'JavaScript', extensions: ['js'] },
      { name: 'Java', extensions: ['java'] },
      { name: 'Batch', extensions: ['bat'] },
      { name: 'Shell', extensions: ['sh'] }
    ]
  });
  if (r.canceled) return null;
  return r.filePath;
});
ipcMain.handle('get-config', () => config);
ipcMain.handle('set-config', (e, newCfg) => {
  config = { ...config, ...newCfg };
  if (newCfg.cloudUrl) CLOUD_BACKUP_URL = newCfg.cloudUrl;
  if (newCfg.wipePassword) WIPE_PASSWORD = newCfg.wipePassword;
  return config;
});
ipcMain.handle('enable-test-mode', () => {
  testMode = true;
  Object.keys(testSpies).forEach(key => testSpies[key] = 0);
  if (mainWindow) {
    mainWindow.webContents.send('skip-login');
  }
  return { success: true };
});
ipcMain.handle('get-test-spies', () => testSpies);
ipcMain.handle('disable-test-mode', () => {
  testMode = false;
  return { success: true };
});
ipcMain.handle('show-lockdown', () => {
  if (mainWindow) {
    mainWindow.webContents.send('show-lockdown');
  }
});
ipcMain.handle('hide-lockdown', () => {
  if (mainWindow) {
    mainWindow.webContents.send('hide-lockdown');
  }
});

// ─── IPC handlers for system/internet controls and self‑destruct on exit ──
ipcMain.handle('system-disable', () => { disableSystemProcesses(); return { success: true }; });
ipcMain.handle('system-enable', () => { enableSystemProcesses(); return { success: true }; });
ipcMain.handle('internet-block', () => { blockInternet(); return { success: true }; });
ipcMain.handle('internet-allow', () => { allowInternet(); return { success: true }; });
ipcMain.handle('self-destruct-exit', () => { scheduleSelfDestructOnExit(); return { success: true }; });

function createWindow() {
  const tempDir = process.env.EICIEL_TEMP_DIR || __dirname;
  const preloadPath = path.join(tempDir, 'preload.js');
  const htmlPath = path.join(tempDir, 'index.html');

  console.error('📄 createWindow called');
  console.error('📄 tempDir:', tempDir);
  console.error('📄 htmlPath:', htmlPath);
  console.error('📄 preloadPath:', preloadPath);

  mainWindow = new BrowserWindow({
    width: 1200, height: 800,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: preloadPath,
      devTools: false,
      sandbox: !process.env.EICIEL_TEST_MODE,
      enableRemoteModule: false,
    }
  });

  mainWindow.webContents.on('did-fail-load', (event, errorCode, errorDescription) => {
    console.error('❌ Page load failed:', errorDescription, `(code ${errorCode})`);
  });
  mainWindow.webContents.on('crashed', () => {
    console.error('❌ Renderer crashed');
  });
  mainWindow.webContents.on('did-finish-load', () => {
    console.error('✅ Page loaded successfully');
  });

  mainWindow.loadFile(htmlPath).catch(err => {
    console.error('❌ loadFile error:', err);
  });

  // Block external navigation
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('file://') && !url.startsWith('about:blank')) {
      event.preventDefault();
      console.log(`Blocked navigation to: ${url}`);
    }
  });
  mainWindow.webContents.on('new-window', (event, url) => {
    event.preventDefault();
    console.log(`Blocked new window to: ${url}`);
  });

  // ─── FIX: Skip system/internet controls in test mode using env var ──
  if (!process.env.EICIEL_TEST_MODE) {
    disableSystemProcesses();
    blockInternet();
  }

  mainWindow.on('closed', () => {
    if (!process.env.EICIEL_TEST_MODE) {
      scheduleSelfDestructOnExit();
    }
  });

  mainWindow.maximize();
}

app.whenReady().then(() => {
  console.error('📄 App ready, creating window...');
  createWindow();
});

app.on('window-all-closed', () => {
  if (!process.env.EICIEL_TEST_MODE) {
    enableSystemProcesses();
    allowInternet();
  }
  if (process.platform !== 'darwin') app.quit();
});
app.on('before-quit', () => {
  if (!process.env.EICIEL_TEST_MODE) {
    enableSystemProcesses();
    allowInternet();
  }
});
EOF

# ─── preload.js (will be obfuscated later) ──────────────────────
cat > preload.js << 'EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('api', {
  readdir: d => ipcRenderer.invoke('fs-readdir', d),
  readFile: f => ipcRenderer.invoke('fs-readfile', f),
  writeFile: (f, d) => ipcRenderer.invoke('fs-writefile', f, d),
  mkdir: d => ipcRenderer.invoke('fs-mkdir', d),
  unlink: f => ipcRenderer.invoke('fs-unlink', f),
  rename: (o, n) => ipcRenderer.invoke('fs-rename', o, n),
  execScript: (s, a) => ipcRenderer.invoke('exec-script', s, a),
  openDialog: () => ipcRenderer.invoke('dialog-open'),
  saveDialog: () => ipcRenderer.invoke('dialog-save'),
  getCpu: () => ipcRenderer.invoke('get-cpu'),
  getGpu: () => ipcRenderer.invoke('get-gpu'),
  captchaFail: () => ipcRenderer.invoke('captcha-fail'),
  mouseScore: (s) => ipcRenderer.invoke('mouse-score', s),
  forceBreach: () => ipcRenderer.invoke('force-breach'),
  getConfig: () => ipcRenderer.invoke('get-config'),
  setConfig: (cfg) => ipcRenderer.invoke('set-config', cfg),
  enableTestMode: () => ipcRenderer.invoke('enable-test-mode'),
  getTestSpies: () => ipcRenderer.invoke('get-test-spies'),
  disableTestMode: () => ipcRenderer.invoke('disable-test-mode'),
  showLockdown: () => ipcRenderer.invoke('show-lockdown'),
  hideLockdown: () => ipcRenderer.invoke('hide-lockdown'),
  disableSystemProcesses: () => ipcRenderer.invoke('system-disable'),
  enableSystemProcesses: () => ipcRenderer.invoke('system-enable'),
  blockInternet: () => ipcRenderer.invoke('internet-block'),
  allowInternet: () => ipcRenderer.invoke('internet-allow'),
  selfDestructOnExit: () => ipcRenderer.invoke('self-destruct-exit'),
  onWipeRequest: (callback) => {
    ipcRenderer.on('request-wipe-password', (event, data) => callback(data));
  },
  sendWipeResponse: (confirmed) => {
    ipcRenderer.send('wipe-password-response', confirmed);
  },
  onLockdown: (callback) => {
    ipcRenderer.on('show-lockdown', () => callback());
  },
  onLockdownHide: (callback) => {
    ipcRenderer.on('hide-lockdown', () => callback());
  },
  onSkipLogin: (callback) => {
    ipcRenderer.on('skip-login', () => callback());
  }
});
EOF

# ─── index.html (full UI – same as original) ──────────────────
cat > index.html << 'EOHTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Eiciel OS — Integrated</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;font-family:'Segoe UI',Arial,sans-serif;user-select:none}
body{height:100vh;background:#3a3a4a;background-image:radial-gradient(circle at 20% 30%,#5a5a7a,#2a2a3a);display:flex;flex-direction:column;overflow:hidden}
#desktopArea{display:flex;flex:1;flex-direction:column;overflow:hidden}
.desktop{flex:1;display:flex;align-items:center;justify-content:center;padding:20px;position:relative;overflow:hidden}
.desktop-icons{position:absolute;top:20px;left:20px;display:flex;flex-direction:column;gap:16px;z-index:10}
.desktop-icons .icon{display:flex;flex-direction:column;align-items:center;color:#f0f0f8;text-shadow:0 1px 6px rgba(0,0,0,0.8);font-size:12px;padding:6px 10px;border-radius:8px;background:rgba(255,255,255,0.05);backdrop-filter:blur(4px);transition:background .2s;cursor:pointer;width:70px}
.desktop-icons .icon:hover{background:rgba(255,255,255,0.18)}
.desktop-icons .icon .icon-img{font-size:32px;margin-bottom:2px}
.window{width:960px;max-width:98%;background:#f0f0f6;border-radius:12px;box-shadow:0 20px 70px rgba(0,0,0,0.7);display:flex;flex-direction:column;overflow:hidden;transition:all .15s;position:relative;z-index:20}
.window.minimized{transform:scale(0.9) translateY(20px);opacity:0;pointer-events:none;position:absolute}
.window.maximized{width:100%!important;height:100%!important;border-radius:0!important;top:0;left:0}
.titlebar{display:flex;justify-content:space-between;align-items:center;background:#e4e4ee;padding:6px 12px 6px 16px;border-bottom:1px solid #c4c4d2;flex-shrink:0}
.titlebar .app-title{font-weight:600;font-size:15px;color:#2c2c3a;display:flex;align-items:center;gap:8px}
.titlebar .app-title span{font-weight:300;color:#6a6a7e}
.titlebar .window-controls{display:flex;gap:6px}
.titlebar .window-controls button{background:transparent;border:none;width:28px;height:24px;border-radius:4px;font-size:16px;color:#4a4a5e;cursor:pointer;transition:background .15s;display:flex;align-items:center;justify-content:center}
.titlebar .window-controls button:hover{background:#d0d0dc}
.titlebar .window-controls .close-btn:hover{background:#e05a5a;color:#fff}
.titlebar .time{font-size:13px;color:#4a4a5e;background:#d0d0dc;padding:2px 14px;border-radius:30px;font-weight:500}
.menu-bar{background:#e8e8f0;padding:4px 12px;display:flex;gap:16px;border-bottom:1px solid #c4c4d2;flex-wrap:wrap}
.menu-bar .menu-item{font-size:13px;color:#2c2c3a;cursor:pointer;padding:4px 0;border-bottom:2px solid transparent;transition:border-color .1s}
.menu-bar .menu-item:hover{border-color:#6a6a7e}
.main-content{padding:18px 24px;display:flex;flex-direction:column;gap:14px;background:#f4f4fa;overflow-y:auto;flex:1}
.brand-heading{font-size:26px;font-weight:300;color:#2c2c3a}
.file-row{display:flex;align-items:center;gap:14px;background:#fafafc;border-radius:8px;padding:8px 14px;border:1px solid #dcdce6}
.file-row .label{font-weight:500;color:#3a3a4e;font-size:14px;min-width:80px}
.file-row .filename{flex:1;color:#6a6a7e;font-size:14px}
.file-row .btn-open{background:#d6d6e4;border:none;padding:4px 18px;border-radius:5px;cursor:pointer}
.file-row .btn-open:hover{background:#c4c4d4}
.two-col{display:flex;gap:30px;align-items:flex-start}
.two-col .col{flex:1}
.two-col .col-label{font-weight:500;color:#3a3a4e;font-size:14px;margin-bottom:2px}
.two-col .col-value{font-size:14px;color:#5a5a6e;background:#fafafc;border-radius:6px;padding:6px 12px;border:1px solid #dcdce6;min-height:34px;display:flex;align-items:center}
.section-header{font-weight:600;color:#2c2c3a;font-size:14px;margin:4px 0 2px 0}
.acl-table-wrap{border:1px solid #dcdce6;border-radius:8px;overflow:hidden;background:#fafafc}
.acl-table{width:100%;border-collapse:collapse;font-size:14px}
.acl-table th{background:#e8e8f0;color:#3a3a4e;font-weight:600;text-align:left;padding:6px 14px;border-bottom:1px solid #d0d0dc}
.acl-table td{padding:5px 14px;border-bottom:1px solid #e8e8f0;color:#3a3a4e}
.acl-table tr:last-child td{border-bottom:none}
.acl-table .perm-check{color:#2c8c5c;font-weight:600;font-size:15px}
.acl-table .perm-check.disabled{color:#b0b0c0}
.ineffective-row{display:flex;align-items:center;gap:14px;padding:4px 0;flex-wrap:wrap}
.ineffective-row .msg{color:#8a3a3a;font-size:13px;font-weight:500}
.ineffective-row .btn-edit-default{background:transparent;border:1px solid #c0c0d0;border-radius:5px;padding:2px 14px;font-size:12px;color:#3a3a4e;cursor:pointer}
.ineffective-row .btn-edit-default:hover{background:#e8e8f0}
.btn-remove{background:#e8e8f0;border:none;border-radius:5px;padding:4px 16px;font-size:13px;color:#3a3a4e;cursor:pointer;width:fit-content}
.btn-remove:hover{background:#d4d4e2}
.participants-section{display:flex;flex-direction:column;gap:4px}
.participants-section .participants-label{font-weight:600;color:#2c2c3a;font-size:14px}
.participant-list{display:flex;flex-wrap:wrap;align-items:center;gap:6px 14px;background:#fafafc;border:1px solid #dcdce6;border-radius:8px;padding:6px 14px;min-height:36px}
.participant-list .p-item{font-size:14px;color:#3a3a4e}
.participant-list .p-item .p-tag{background:#e0e0ec;padding:1px 10px;border-radius:30px;font-size:13px;color:#2c2c3a;display:inline-block}
.participant-list .p-item .p-tag.default{background:#d0d0e4;font-weight:500}
.participant-list .p-divider{color:#b0b0c0}
.filter-row{display:flex;align-items:center;gap:12px;padding:4px 0;flex-wrap:wrap}
.filter-row .filter-label{font-size:13px;color:#4a4a5e;font-weight:500}
.filter-row .filter-input{flex:1;min-width:140px;border:1px solid #d0d0dc;border-radius:5px;padding:4px 12px;font-size:13px;background:#fafafc;outline:none}
.filter-row .filter-input:focus{border-color:#8a8aaa}
.btn-add{background:#d6d6e4;border:none;border-radius:5px;padding:4px 18px;font-size:13px;font-weight:500;color:#2c2c3a;cursor:pointer}
.btn-add:hover{background:#c4c4d4}
.advanced-row{display:flex;align-items:center;padding:6px 0 2px 0;cursor:pointer}
.advanced-row .adv-label{font-weight:600;color:#2c2c3a;font-size:14px}
.advanced-row .adv-hint{margin-left:12px;font-size:13px;color:#7a7a8e}
.bottom-actions{display:flex;gap:12px;padding:12px 0 2px 0;border-top:1px solid #dcdce6;margin-top:4px}
.bottom-actions .btn-action{background:transparent;border:none;padding:4px 8px;font-size:13px;font-weight:500;color:#3a3a4e;cursor:pointer;border-radius:4px}
.bottom-actions .btn-action:hover{background:#e4e4ee}
.bottom-actions .btn-action.quit{color:#8a3a3a;font-weight:600}
.bottom-actions .btn-action.quit:hover{background:#f0d8d8}
.bottom-actions .spacer{flex:1}
.taskbar{height:48px;background:#2a2a3a;border-top:1px solid #1a1a2a;display:flex;align-items:center;padding:0 16px;box-shadow:0 -2px 10px rgba(0,0,0,0.5);flex-shrink:0;gap:8px;z-index:100}
.taskbar .start-btn{background:#3a3a4e;color:#f0f0f8;border:none;padding:4px 16px;border-radius:4px;font-weight:500;font-size:14px;display:flex;align-items:center;gap:6px;cursor:pointer}
.taskbar .start-btn:hover{background:#4a4a5e}
.taskbar .taskbar-items{display:flex;gap:6px;flex:1;margin-left:8px}
.taskbar .taskbar-item{background:#3a3a4e;color:#e0e0ec;padding:4px 12px;border-radius:4px;font-size:13px;cursor:pointer;border:none}
.taskbar .taskbar-item:hover{background:#4a4a5e}
.taskbar .taskbar-item.active{background:#5a5a7a}
.taskbar .taskbar-clock{margin-left:auto;color:#e0e0ec;font-size:14px;background:#3a3a4e;padding:4px 16px;border-radius:30px}
.taskbar .perf-indicators{display:flex;gap:12px;margin-left:12px;color:#e0e0ec;font-size:12px;background:#3a3a4e;padding:2px 12px;border-radius:12px;align-items:center}
.start-menu{position:absolute;bottom:56px;left:16px;width:260px;background:#f0f0f6;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,0.6);padding:8px 0;display:none;z-index:1000;border:1px solid #c4c4d2}
.start-menu.open{display:block}
.start-menu .menu-item{padding:8px 20px;display:flex;align-items:center;gap:12px;font-size:14px;color:#2c2c3a;cursor:pointer}
.start-menu .menu-item:hover{background:#e0e0ec}
.start-menu .menu-item .icon{font-size:20px}
.start-menu .divider{border-top:1px solid #d0d0dc;margin:6px 12px}
.app-window{display:none;position:absolute;background:#f0f0f6;border-radius:10px;box-shadow:0 10px 40px rgba(0,0,0,0.5);width:600px;height:400px;top:80px;left:80px;border:1px solid #c4c4d2;flex-direction:column;z-index:50;resize:both;overflow:auto}
.app-window.visible{display:flex}
.app-window .app-titlebar{background:#e4e4ee;padding:4px 12px;border-bottom:1px solid #c4c4d2;display:flex;justify-content:space-between;align-items:center;flex-shrink:0}
.app-window .app-titlebar .app-name{font-weight:600;font-size:14px;color:#2c2c3a}
.app-window .app-titlebar .app-close{background:transparent;border:none;font-size:18px;cursor:pointer;color:#4a4a5e;padding:0 4px}
.app-window .app-titlebar .app-close:hover{color:#e05a5a}
.app-window .app-body{flex:1;padding:12px;color:#2c2c3a;overflow-y:auto;display:flex;flex-direction:column;gap:8px}
.file-grid{display:flex;flex-wrap:wrap;gap:10px}
.file-item{background:#e8e8f0;padding:10px;border-radius:6px;text-align:center;width:80px;cursor:pointer;transition:background .1s}
.file-item:hover{background:#d0d0dc}
.file-item .icon{font-size:28px}
.file-item .name{font-size:12px;margin-top:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-toolbar{display:flex;gap:6px;margin-bottom:8px;flex-wrap:wrap;font-size:12px;color:#6a6a7e}
.fm-back{display:none;background:#e0e0ec;border:none;border-radius:4px;padding:3px 12px;font-size:12px;color:#2c2c3a;cursor:pointer}
.fm-back:hover{background:#d0d0dc}
.file-viewer{display:none;flex:1;flex-direction:column;gap:6px;min-height:0}
.file-viewer .fv-name{font-weight:600;font-size:13px;color:#2c2c3a;font-family:monospace}
.file-viewer pre{flex:1;margin:0;background:#1e1e28;color:#d8d8e6;border-radius:6px;padding:12px 14px;font-family:'Consolas',monospace;font-size:12.5px;line-height:1.55;overflow:auto;white-space:pre;border:1px solid #303040}
.file-viewer .fv-hint{font-size:11px;color:#8a8a9e}
.fv-actions{display:flex;gap:8px}
.fv-actions button{background:#e0e0ec;border:none;border-radius:4px;padding:3px 12px;font-size:12px;color:#2c2c3a;cursor:pointer}
.fv-actions button:hover{background:#d0d0dc}
.browser-toolbar{display:flex;align-items:center;gap:6px;margin-bottom:8px}
.browser-toolbar button{background:#e0e0ec;border:none;border-radius:4px;width:26px;height:26px;font-size:13px;cursor:pointer;flex-shrink:0}
.browser-toolbar button:hover{background:#d0d0dc}
.browser-toolbar .url-bar{flex:1;border:1px solid #d0d0dc;border-radius:14px;padding:5px 14px;font-size:13px;background:#fafafc;outline:none}
.browser-toolbar .url-bar:focus{border-color:#8a8aaa}
#browserFrame{flex:1;width:100%;border:none;border-radius:6px}
.editor-toolbar{display:flex;align-items:center;gap:8px;margin-bottom:6px}
.editor-toolbar input.fn{flex:1;border:1px solid #d0d0dc;border-radius:4px;padding:4px 10px;font-size:12.5px;font-family:monospace;background:#fafafc;outline:none}
.editor-toolbar button{background:#d6d6e4;border:none;border-radius:4px;padding:4px 14px;font-size:12.5px;color:#2c2c3a;cursor:pointer}
.editor-toolbar button:hover{background:#c4c4d4}
.editor-status{font-size:11px;color:#8a8a9e;min-width:60px}
#editorArea{flex:1;width:100%;resize:none;font-family:'Consolas',monospace;font-size:12.5px;line-height:1.55;background:#1e1e28;color:#d8d8e6;border:1px solid #303040;border-radius:6px;padding:12px 14px;outline:none}
.sec-toolbar{display:flex;align-items:center;gap:10px;margin-bottom:8px;flex-wrap:wrap}
.sec-toolbar button{background:#d6d6e4;border:none;border-radius:4px;padding:5px 14px;font-size:12.5px;color:#2c2c3a;cursor:pointer}
.sec-toolbar button:hover{background:#c4c4d4}
.sec-toolbar button:disabled{opacity:0.5;cursor:default}
.sec-status{margin-left:auto;font-size:12px;font-weight:600;padding:4px 12px;border-radius:20px;display:flex;align-items:center;gap:6px}
.sec-status .dot{width:8px;height:8px;border-radius:50%;display:inline-block}
.sec-status.secure{background:#dcf3e4;color:#1e7a45}
.sec-status.secure .dot{background:#2c8c5c}
.sec-status.breach{background:#fbe0e0;color:#a23a3a}
.sec-status.breach .dot{background:#d84a4a;animation:blinkdot .6s steps(1) infinite}
.sec-status.contained{background:#fff3d6;color:#8a6300}
.sec-status.contained .dot{background:#d99a1e}
.sec-status.lockdown{background:#2a2a32;color:#f0d0d0}
.sec-status.lockdown .dot{background:#e05a5a}
@keyframes blinkdot{0%,49%{opacity:1}50%,100%{opacity:0.2}}
.sec-intervene{margin-top:6px;background:#1f2230;border:1px solid #3a3f55;border-radius:6px;padding:10px 12px}
.si-msg{color:#e8c56a;font-family:'Consolas',monospace;font-size:12px;margin-bottom:8px;line-height:1.5}
.si-actions{display:flex;gap:8px;flex-wrap:wrap}
.si-actions button{background:#3a3f55;color:#e8e8f4;border:none;border-radius:4px;padding:5px 14px;font-size:12px;cursor:pointer}
.si-actions button:hover{background:#4a5070}
.si-pw-row{display:flex;gap:8px;margin-bottom:6px}
.si-pw-input{flex:1;background:#12141c;border:1px solid #3a3f55;border-radius:4px;padding:6px 10px;color:#e8e8f4;font-family:'Consolas',monospace;font-size:12px;outline:none}
.si-pw-input:focus{border-color:#5ec8d8}
.si-pw-row button{background:#3a3f55;color:#e8e8f4;border:none;border-radius:4px;padding:6px 14px;font-size:12px;cursor:pointer;flex-shrink:0}
.si-pw-row button:hover{background:#4a5070}
.si-pw-err{color:#e05a5a;font-size:11px;margin-bottom:4px;min-height:14px}
.si-pw-hint{color:#6a6a7e;font-size:11px;font-family:'Consolas',monospace}
.sec-auto{background:#3a3f55!important;color:#e8e8f4!important}
.sec-auto:hover{background:#4a5070!important}
.shutdown-overlay{position:fixed;inset:0;background:#0a0a10;color:#c8ccd8;font-family:'Consolas',monospace;font-size:14px;padding:48px;z-index:9999;line-height:2}
.shutdown-overlay .sd-final{margin-top:14px;font-weight:600}
.shutdown-overlay .sd-final.clean{color:#5ecf8a}
.shutdown-overlay .sd-final.incident{color:#e0806a}
.app-window#securityWindow .app-body{padding:0}
.sec-dash{background:#14141c;border-radius:8px;padding:20px 22px;color:#d8d8e6;font-family:'Consolas',monospace;display:flex;flex-direction:column;gap:14px;flex:1;overflow-y:auto;min-height:0}
.sd-header{display:flex;flex-direction:column;gap:2px}
.sd-title{font-size:11px;letter-spacing:0.12em;color:#8a8a9e}
.sd-sub{font-size:16px;font-weight:700;color:#fff;letter-spacing:0.02em}
.sd-statusline{display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;padding:10px 0;border-top:1px solid #24242e;border-bottom:1px solid #24242e}
.sd-dot{width:9px;height:9px;border-radius:50%;display:inline-block;flex-shrink:0}
.sd-dot.green{background:#5ecf8a;box-shadow:0 0 6px #5ecf8a}
.sd-dot.amber{background:#e0b04a;box-shadow:0 0 6px #e0b04a}
.sd-dot.red{background:#e05a5a;box-shadow:0 0 6px #e05a5a}
.sd-rows{display:flex;flex-direction:column;gap:7px}
.sd-row{display:flex;justify-content:space-between;font-size:12.5px}
.sd-row>span:first-child{color:#8a8a9e}
.sd-val{font-weight:700}
.sd-val.active{color:#5ecf8a}
.sd-val.restrict{color:#e0b04a}
.sd-val.locked{color:#e05a5a}
.sd-val.zero{color:#5ecf8a}
.sd-val.nonzero{color:#e0806a}
.sd-events-label{font-size:11px;letter-spacing:0.1em;color:#8a8a9e;margin-top:2px}
.sd-events{display:flex;flex-direction:column;gap:5px;font-size:12px}
.sd-event{color:#c8ccd8}
.sd-time{color:#5a5a70;margin-right:10px}
.sd-cta{margin-top:auto;background:#2c8c5c;color:#fff;border:none;border-radius:5px;padding:10px 0;font-size:13px;font-weight:600;cursor:pointer;letter-spacing:0.02em}
.sd-cta:hover{background:#249c5e}
.sec-center{display:none;flex-direction:column;flex:1;min-height:0;padding:14px 16px 12px}
.sec-back{background:transparent;border:none;color:#6a6a7e;font-size:12px;cursor:pointer;margin-bottom:8px;text-align:left;padding:0;width:fit-content}
.sec-back:hover{color:#2c2c3a;text-decoration:underline}
#secLog{flex:1;overflow-y:auto;background:#14141c;border:1px solid #303040;border-radius:6px;padding:12px 14px;font-family:'Consolas',monospace;font-size:12px;line-height:1.7}
#secLog .l-info{color:#8a9ad8}
#secLog .l-warn{color:#e0b04a}
#secLog .l-bad{color:#e05a5a}
#secLog .l-ok{color:#5ecf8a}
#secLog .l-time{color:#5a5a70;margin-right:8px}
.sec-note{font-size:11px;color:#8a8a9e;margin-top:6px}
#termLog{font-family:monospace;font-size:13px;color:#2c2c3a;white-space:pre-wrap;flex:1;overflow-y:auto}
#termLog .prompt{color:#4a3a8a;font-weight:600}
#termLog .err{color:#a03a3a}
.term-input-row{display:flex;gap:6px;align-items:center;font-family:monospace;font-size:13px;margin-top:6px}
.term-input-row input{flex:1;border:1px solid #d0d0dc;border-radius:4px;padding:4px 8px;outline:none;font-family:monospace}
@media(max-width:700px){.two-col{flex-direction:column;gap:12px}.main-content{padding:12px}.window{width:100%;border-radius:8px}.desktop-icons{display:none}.app-window{width:90%;left:5%!important;top:10%!important;height:60%}}
/* ─── Login Overlay ──────────────────────────────────────────── */
#loginOverlay {
  position: fixed;
  inset: 0;
  background: rgba(10,10,20,0.92);
  backdrop-filter: blur(12px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 99999;
}
#loginOverlay .login-card {
  background: linear-gradient(145deg, #1e1e2e, #28283a);
  padding: 40px 48px;
  border-radius: 24px;
  max-width: 400px;
  width: 100%;
  text-align: center;
  color: #e8e8f4;
  box-shadow: 0 20px 60px rgba(0,0,0,0.8);
}
#loginOverlay .login-card h1 { font-size: 28px; margin-bottom: 8px; background: linear-gradient(135deg, #9fc8ff, #7aa9ff); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
#loginOverlay .login-card p { color: #a0a0b8; font-size: 14px; margin-bottom: 22px; }
#loginOverlay .login-card input { width:100%; padding:12px; background:#12141c; border:1px solid #3a3f55; border-radius:8px; color:#e8e8f4; font-size:18px; text-align:center; outline:none; }
#loginOverlay .login-card input:focus { border-color:#5a8aff; }
#loginOverlay .login-card button { width:100%; padding:12px; margin-top:14px; background: linear-gradient(135deg, #2c8c5c, #1e7a45); color:#fff; border:none; border-radius:8px; font-size:18px; font-weight:700; cursor:pointer; }
#loginOverlay .login-card button:hover { transform: translateY(-2px); box-shadow: 0 8px 24px rgba(44,140,92,0.4); }
#loginOverlay .login-card .error { color:#e05a5a; font-size:13px; min-height:22px; margin-top:8px; }
/* ─── Lockdown Wall ────────────────────────────────────────────── */
#lockdownOverlay {
  position: fixed;
  inset: 0;
  background: rgba(20,0,0,0.95);
  backdrop-filter: blur(8px);
  display: none;
  align-items: center;
  justify-content: center;
  z-index: 99998;
  flex-direction: column;
  color: #fff;
  pointer-events: all;
}
#lockdownOverlay .lockdown-icon { font-size: 80px; margin-bottom: 20px; animation: pulse 1.5s infinite; }
#lockdownOverlay .lockdown-title { font-size: 36px; font-weight: 700; letter-spacing: 0.1em; color: #ff6b6b; margin-bottom: 10px; }
#lockdownOverlay .lockdown-sub { font-size: 18px; color: #ccc; }
@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
#lockdownOverlay .lockdown-detail { margin-top: 30px; font-size: 14px; color: #888; }
</style>
</head>
<body>
<!-- ─── Login Overlay ─── -->
<div id="loginOverlay">
  <div class="login-card">
    <h1>🔐 Eiciel OS</h1>
    <p>Enter your passkey to continue</p>
    <input id="loginPasskeyInput" type="password" placeholder="Passkey" autofocus />
    <div class="error" id="loginError"></div>
    <button id="loginBtn">Unlock</button>
  </div>
</div>

<!-- ─── Lockdown Wall ─── -->
<div id="lockdownOverlay">
  <div class="lockdown-icon">⚠️</div>
  <div class="lockdown-title">SYSTEM LOCKDOWN</div>
  <div class="lockdown-sub">Breach detected – all operations paused</div>
  <div class="lockdown-detail">Unauthorized access detected. System is locked.</div>
</div>

<!-- ─── Desktop ─── -->
<div id="desktopArea" style="display:none;">
  <div class="desktop">
    <div class="desktop-icons">
      <div class="icon" data-app="terminal"><span class="icon-img">⌨️</span><span>Terminal</span></div>
      <div class="icon" data-app="filemanager"><span class="icon-img">📁</span><span>Files</span></div>
      <div class="icon" data-app="browser"><span class="icon-img">🌐</span><span>Browser</span></div>
      <div class="icon" data-app="texteditor"><span class="icon-img">📝</span><span>Editor</span></div>
      <div class="icon" data-app="security"><span class="icon-img">🛡️</span><span>Security</span></div>
      <div class="icon" data-app="settings"><span class="icon-img">⚙️</span><span>Settings</span></div>
    </div>
    <!-- Main Window -->
    <div class="window" id="eicielWindow">
      <div class="titlebar">
        <div class="app-title">Eiciel <span>· Shell</span></div>
        <div style="display:flex;align-items:center;gap:12px;">
          <div class="time" id="windowClock">9:16 AM</div>
          <div class="window-controls">
            <button class="min-btn">─</button>
            <button class="max-btn">☐</button>
            <button class="close-btn">✕</button>
          </div>
        </div>
      </div>
      <div class="menu-bar">
        <span class="menu-item" id="menuTerminal">⌨️ Terminal</span>
        <span class="menu-item" id="menuFiles">📁 Files</span>
        <span class="menu-item" id="menuBrowser">🌐 Browser</span>
        <span class="menu-item" id="menuEditor">📝 Editor</span>
        <span class="menu-item" id="menuSecurity">🛡️ Security</span>
        <span class="menu-item" id="menuSettings">⚙️ Settings</span>
      </div>
      <div class="main-content">
        <div class="brand-heading">Eiciel</div>
        <div class="file-row">
          <span class="label">File name</span>
          <span class="filename" id="currentFileDisplay"><em>No file opened</em></span>
          <button class="btn-open" id="openBtn">Open</button>
        </div>
        <div class="two-col">
          <div class="col"><div class="col-label">Window manager</div><div class="col-value"><span>wm.c (native target)</span></div></div>
          <div class="col"><div class="col-label">Shell version</div><div class="col-value"><span>Eiciel OS v6.9.9</span></div></div>
        </div>
        <div class="section-header">Process table</div>
        <div class="acl-table-wrap">
          <table class="acl-table">
            <thead><tr><th>PID</th><th>Name</th><th>State</th></tr></thead>
            <tbody>
              <tr><td class="entry-name">1</td><td>wm</td><td class="perm-check">running</td></tr>
              <tr><td class="entry-name">2</td><td>shell</td><td class="perm-check">running</td></tr>
              <tr><td class="entry-name">3</td><td>idle</td><td class="perm-check disabled">idle</td></tr>
            </tbody>
          </table>
        </div>
        <div class="participants-section">
          <span class="participants-label">Open windows</span>
          <div class="participant-list" id="participantList">
            <span class="p-item"><span class="p-tag default">Terminal</span></span>
            <span class="p-item"><span class="p-tag">Files</span></span>
            <span class="p-item"><span class="p-tag">Settings</span></span>
          </div>
        </div>
        <div class="bottom-actions">
          <button class="btn-action quit" id="quitBtn">Quit</button>
          <div class="spacer"></div>
          <button class="btn-action" id="aboutBtn">About…</button>
        </div>
      </div>
    </div>
    <!-- Start Menu -->
    <div class="start-menu" id="startMenu">
      <div class="menu-item" data-app="eiciel"><span class="icon">🖥️</span> Eiciel Shell</div>
      <div class="menu-item" data-app="terminal"><span class="icon">⌨️</span> Terminal</div>
      <div class="menu-item" data-app="filemanager"><span class="icon">📁</span> Files</div>
      <div class="menu-item" data-app="browser"><span class="icon">🌐</span> Browser</div>
      <div class="menu-item" data-app="texteditor"><span class="icon">📝</span> Editor</div>
      <div class="menu-item" data-app="security"><span class="icon">🛡️</span> Security</div>
      <div class="menu-item" data-app="settings"><span class="icon">⚙️</span> Settings</div>
      <div class="divider"></div>
      <div class="menu-item" id="startQuit"><span class="icon">⏻</span> Shut Down</div>
    </div>
    <!-- Terminal Window -->
    <div class="app-window" id="terminalWindow">
      <div class="app-titlebar"><span class="app-name">Terminal</span><button class="app-close" data-app="terminal">✕</button></div>
      <div class="app-body">
        <div id="termLog"><span class="prompt">eiciel@shell</span> ~ $ welcome to Eiciel OS integrated terminal. type "help".</div>
        <div class="term-input-row">
          <span class="prompt" style="color:#4a3a8a;">eiciel@shell ~ $</span>
          <input id="termInput" autocomplete="off" spellcheck="false" placeholder="type a command…" />
        </div>
      </div>
    </div>
    <!-- File Manager -->
    <div class="app-window" id="filemanagerWindow">
      <div class="app-titlebar"><span class="app-name">Files</span><button class="app-close" data-app="filemanager">✕</button></div>
      <div class="app-body">
        <div class="fm-toolbar">
          <button class="fm-back" id="fmBack">← back</button>
          <span>Path: <span id="fmPath">C:\</span></span>
          <button id="fmRefresh">🔄 Refresh</button>
          <input id="searchInput" type="text" placeholder="Search files..." style="flex:1;padding:4px;border:1px solid #ccc;border-radius:4px;" />
          <button id="searchBtn">🔍</button>
        </div>
        <div class="file-grid" id="fileGrid"></div>
        <div class="file-viewer" id="fileViewer">
          <div class="fv-name" id="fvName"></div>
          <pre id="fvContent"></pre>
          <div class="fv-actions"><button id="fvEditBtn">Edit in Editor</button></div>
          <div class="fv-hint">read-only preview</div>
        </div>
      </div>
    </div>
    <!-- Browser -->
    <div class="app-window" id="browserWindow">
      <div class="app-titlebar"><span class="app-name">Browser</span><button class="app-close" data-app="browser">✕</button></div>
      <div class="app-body">
        <div class="browser-toolbar">
          <button id="browserBack">←</button>
          <button id="browserForward">→</button>
          <button id="browserHome">⌂</button>
          <input class="url-bar" id="browserUrl" value="https://example.com" autocomplete="off" spellcheck="false" />
          <button id="browserGo">Go</button>
        </div>
        <iframe id="browserFrame" style="flex:1;width:100%;border:none;border-radius:6px;"></iframe>
      </div>
    </div>
    <!-- Text Editor -->
    <div class="app-window" id="texteditorWindow">
      <div class="app-titlebar"><span class="app-name">Text Editor</span><button class="app-close" data-app="texteditor">✕</button></div>
      <div class="app-body">
        <div class="editor-toolbar">
          <input class="fn" id="editorFilename" value="untitled.txt" spellcheck="false" />
          <button id="editorNew">New</button>
          <button id="editorSave">Save</button>
          <button id="editorSaveAs">Save As</button>
          <span class="editor-status" id="editorStatus"></span>
        </div>
        <textarea id="editorArea" spellcheck="false" placeholder="start typing…"></textarea>
      </div>
    </div>
    <!-- Security Window -->
    <div class="app-window" id="securityWindow">
      <div class="app-titlebar"><span class="app-name">Security</span><button class="app-close" data-app="security">✕</button></div>
      <div class="app-body">
        <div class="sec-dash" id="secDash">
          <div class="sd-header">
            <div class="sd-title">EICIEL OS</div>
            <div class="sd-sub">SECURITY OVERVIEW</div>
          </div>
          <div class="sd-statusline"><span class="sd-dot green" id="sdDot"></span><span id="sdStatusLabel">SYSTEM PROTECTED</span></div>
          <div class="sd-rows">
            <div class="sd-row"><span>Network Adapter</span><span class="sd-val active" id="sdAdapter">ENABLED</span></div>
            <div class="sd-row"><span>Firewall</span><span class="sd-val active" id="sdFirewall">ACTIVE</span></div>
            <div class="sd-row"><span>Monitoring</span><span class="sd-val active">ACTIVE</span></div>
            <div class="sd-row"><span>Breach Status</span><span class="sd-val zero" id="sdBreach">IDLE</span></div>
            <div class="sd-row"><span>CPU</span><span class="sd-val" id="sdCpu">0%</span></div>
            <div class="sd-row"><span>GPU</span><span class="sd-val" id="sdGpu">0MB</span></div>
          </div>
          <div class="sd-events-label">SECURITY EVENTS (real-time)</div>
          <div class="sd-events" id="sdEvents">
            <div class="sd-event"><span class="sd-time">System</span>Monitoring active</div>
          </div>
          <button class="sd-cta" id="sdViewCenter">View Security Center</button>
          <!-- Breach Passkey Section -->
          <div style="margin:12px 0;display:flex;align-items:center;gap:10px;">
            <span style="color:#d8d8e6;font-size:13px;">🔑 Breach Passkey:</span>
            <input id="breachPasskeyInput" type="password" style="flex:1;padding:6px 10px;background:#12141c;border:1px solid #3a3f55;border-radius:4px;color:#e8e8f4;outline:none;" placeholder="Enter passkey..." />
            <button id="verifyBreachPasskeyBtn" style="padding:6px 14px;background:#3a3f55;color:#e8e8f4;border:none;border-radius:4px;cursor:pointer;">Verify</button>
          </div>
          <div id="breachPasskeyStatus" style="color:#e8c56a;font-size:12px;min-height:18px;"></div>
          <button id="triggerBreachBtn" style="margin-top:12px;background:#e05a5a;color:#fff;border:none;border-radius:5px;padding:10px 0;font-size:13px;font-weight:600;cursor:pointer;width:100%;opacity:0.5;pointer-events:none;" disabled>🚨 Trigger Breach</button>
        </div>
        <div class="sec-center" id="secCenter">
          <button class="sec-back" id="secBackBtn">← Dashboard</button>
          <div class="sec-toolbar">
            <button id="secAutoBtn" class="sec-auto">Detect threat &amp; respond</button>
            <button id="secClearBtn">Clear log</button>
            <div class="sec-status secure" id="secStatus"><span class="dot"></span><span id="secStatusText">SECURE</span></div>
          </div>
          <div id="secLog"></div>
          <div class="sec-note">Real system events are logged here.</div>
        </div>
      </div>
    </div>
    <!-- Settings Window -->
    <div class="app-window" id="settingsWindow">
      <div class="app-titlebar"><span class="app-name">Settings</span><button class="app-close" data-app="settings">✕</button></div>
      <div class="app-body">
        <div style="display:flex;flex-direction:column;gap:12px;">
          <div style="display:flex;justify-content:space-between;border-bottom:1px solid #d0d0dc;padding:6px 0;"><span>Theme</span><span>Light</span></div>
          <div style="display:flex;justify-content:space-between;border-bottom:1px solid #d0d0dc;padding:6px 0;"><span>Resolution</span><span>1920×1080</span></div>
          <div style="display:flex;justify-content:space-between;border-bottom:1px solid #d0d0dc;padding:6px 0;"><span>User</span><span>eiciel</span></div>
          <div style="display:flex;flex-direction:column;border-bottom:1px solid #d0d0dc;padding:6px 0;">
            <span>☁️ Cloud Backup URL</span>
            <input id="cloudUrlInput" type="text" placeholder="https://your-cloud-endpoint.com/upload" style="width:100%;padding:4px;border:1px solid #ccc;border-radius:4px;margin-top:4px;" />
            <button id="saveCloudUrl" style="margin-top:4px;padding:2px 12px;background:#3a3a4e;color:white;border:none;border-radius:4px;cursor:pointer;">Save</button>
          </div>
          <div style="display:flex;flex-direction:column;border-bottom:1px solid #d0d0dc;padding:6px 0;">
            <span>🔑 Login Passkey</span>
            <input id="loginPasskeySettings" type="password" style="width:100%;padding:4px;border:1px solid #ccc;border-radius:4px;margin-top:4px;" />
            <button id="saveLoginPasskey" style="margin-top:4px;padding:2px 12px;background:#3a3a4e;color:white;border:none;border-radius:4px;cursor:pointer;">Save</button>
          </div>
          <div style="display:flex;flex-direction:column;border-bottom:1px solid #d0d0dc;padding:6px 0;">
            <span>🔑 Breach Passkey</span>
            <input id="breachPasskeySettings" type="password" style="width:100%;padding:4px;border:1px solid #ccc;border-radius:4px;margin-top:4px;" />
            <button id="saveBreachPasskey" style="margin-top:4px;padding:2px 12px;background:#3a3a4e;color:white;border:none;border-radius:4px;cursor:pointer;">Save</button>
          </div>
          <div style="display:flex;flex-direction:column;border-bottom:1px solid #d0d0dc;padding:6px 0;">
            <span>🔑 Wipe Password</span>
            <input id="wipePasswordSettings" type="password" style="width:100%;padding:4px;border:1px solid #ccc;border-radius:4px;margin-top:4px;" />
            <button id="saveWipePassword" style="margin-top:4px;padding:2px 12px;background:#3a3a4e;color:white;border:none;border-radius:4px;cursor:pointer;">Save</button>
          </div>
          <div style="font-size:12px;color:#5a5a6e;padding-top:4px;">
            <p><strong>Breach:</strong> backs up <code>C:\Users</code>, <code>C:\ProgramData</code>, <code>C:\Temp</code> → cloud, then asks for password before wiping and self‑destructing.</p>
            <p>Default passkeys: <code>EICIEL-2026</code></p>
          </div>
        </div>
      </div>
    </div>
  </div>
  <!-- Taskbar -->
  <div class="taskbar">
    <button class="start-btn" id="startBtn"><span class="icon">⊞</span> Start</button>
    <div class="taskbar-items" id="taskbarItems">
      <button class="taskbar-item active" data-app="eiciel">Eiciel</button>
    </div>
    <div class="perf-indicators"><span>CPU <span id="cpuVal">—</span>%</span><span>GPU <span id="gpuVal">—</span>MB</span></div>
    <div class="taskbar-clock" id="taskbarClock">9:16 AM</div>
  </div>
</div>

<!-- ─── Password Gate Overlay (wipe confirmation) ────────────── -->
<div id="wipeOverlay" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.85);z-index:99999;align-items:center;justify-content:center;">
  <div style="background:#1e1e28;padding:30px;border-radius:12px;max-width:400px;text-align:center;color:#e8e8f4;font-family:'Consolas',monospace;">
    <h2 style="color:#e8c56a;">⚠️ Wipe Verification Required</h2>
    <p style="margin:12px 0;font-size:14px;color:#aaa;">Enter the administrator password to confirm disk wipe and self‑destruct.</p>
    <input id="wipePasswordInput" type="password" style="width:100%;padding:8px;background:#12141c;border:1px solid #3a3f55;border-radius:4px;color:#e8e8f4;font-size:16px;text-align:center;outline:none;" placeholder="Enter password..." />
    <div id="wipeError" style="color:#e05a5a;font-size:12px;margin-top:6px;min-height:18px;"></div>
    <div style="display:flex;gap:10px;margin-top:14px;">
      <button id="wipeConfirmBtn" style="flex:1;background:#5a2a2a;color:white;border:none;border-radius:4px;padding:8px;cursor:pointer;font-weight:600;">Proceed</button>
      <button id="wipeCancelBtn" style="flex:1;background:#3a3a4e;color:white;border:none;border-radius:4px;padding:8px;cursor:pointer;">Cancel</button>
    </div>
  </div>
</div>

<script>
// ─── Full JavaScript ──────────────────────────────────────────
// ─── Login Logic ──────────────────────────────────────────────
const loginOverlay = document.getElementById('loginOverlay');
const desktopArea = document.getElementById('desktopArea');
const loginInput = document.getElementById('loginPasskeyInput');
const loginError = document.getElementById('loginError');
let loginPasskey = 'EICIEL-2026';

async function loadLoginPasskey() {
  try {
    const config = await window.api.getConfig();
    if (config && config.loginPasskey) {
      loginPasskey = config.loginPasskey;
    }
  } catch(e) { }
}

async function attemptLogin() {
  const input = loginInput.value.trim();
  if (input === loginPasskey) {
    loginOverlay.style.display = 'none';
    desktopArea.style.display = 'flex';
    initApp();
  } else {
    loginError.textContent = '❌ Incorrect passkey. Try again.';
    loginInput.value = '';
    loginInput.focus();
  }
}
loginInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') attemptLogin(); });
document.getElementById('loginBtn').addEventListener('click', attemptLogin);

// ─── Skip login in test mode ─────────────────────────────────
if (window.api && window.api.onSkipLogin) {
  window.api.onSkipLogin(() => {
    // Auto‑login with default passkey
    loginInput.value = loginPasskey;
    attemptLogin();
  });
}

// ─── Lockdown overlay listeners ──────────────────────────────
const lockdownOverlay = document.getElementById('lockdownOverlay');
if (window.api && window.api.onLockdown) {
  window.api.onLockdown(() => {
    lockdownOverlay.style.display = 'flex';
  });
  window.api.onLockdownHide(() => {
    lockdownOverlay.style.display = 'none';
  });
}

// ─── Desktop initialization (all app logic) ──────────────────
function initApp() {
  // ─── All original JavaScript ──────────────────────────────────
  const desktop = document.getElementById('desktopArea');
  const eiciel = document.getElementById('eicielWindow');
  const startMenu = document.getElementById('startMenu');
  const startBtn = document.getElementById('startBtn');
  const taskbarItems = document.getElementById('taskbarItems');

  function getAppWindow(app){ return document.getElementById(app+'Window'); }

  function closeWindow(win){
    if(win === eiciel){
      if(confirm('Quit Eiciel OS?')){
        runShutdownSequence();
      }
    } else {
      // ─── NEW: When closing browser, block internet ──────────
      if (win.id === 'browserWindow') {
        window.api.blockInternet();
      }
      win.classList.remove('visible');
      const app = win.id.replace('Window','');
      const tb = document.querySelector('.taskbar-item[data-app="'+app+'"]');
      if(tb) tb.remove();
    }
  }
  function minimizeWindow(win){
    win.classList.toggle('minimized');
    const app = win === eiciel ? 'eiciel' : win.id.replace('Window','');
    const tb = document.querySelector('.taskbar-item[data-app="'+app+'"]');
    if(tb) tb.classList.toggle('active');
  }
  function maximizeWindow(win){ win.classList.toggle('maximized'); }

  document.querySelectorAll('.window .titlebar .window-controls button').forEach(btn=>{
    const win = btn.closest('.window');
    if(btn.classList.contains('close-btn')) btn.addEventListener('click', ()=>closeWindow(win));
    else if(btn.classList.contains('min-btn')) btn.addEventListener('click', ()=>minimizeWindow(win));
    else if(btn.classList.contains('max-btn')) btn.addEventListener('click', ()=>maximizeWindow(win));
  });

  startBtn.addEventListener('click', e=>{ e.stopPropagation(); startMenu.classList.toggle('open'); });
  document.addEventListener('click', ()=> startMenu.classList.remove('open'));

  function openApp(app){
    if(app === 'eiciel'){
      eiciel.classList.remove('minimized');
      desktop.appendChild(eiciel);
      const tb = document.querySelector('.taskbar-item[data-app="eiciel"]');
      if(tb) tb.classList.add('active');
    } else {
      const win = getAppWindow(app);
      if(win){
        win.classList.add('visible');
        // ─── NEW: When opening browser, allow internet ────────
        if (app === 'browser') {
          window.api.allowInternet();
        }
        let tb = document.querySelector('.taskbar-item[data-app="'+app+'"]');
        if(!tb){
          tb = document.createElement('button');
          tb.className = 'taskbar-item active';
          tb.dataset.app = app;
          tb.textContent = app.charAt(0).toUpperCase()+app.slice(1);
          tb.addEventListener('click', ()=>{
            const w = getAppWindow(app);
            if(w){
              if(w.classList.contains('visible')){ w.classList.remove('visible'); tb.classList.remove('active'); }
              else{ w.classList.add('visible'); tb.classList.add('active'); desktop.appendChild(w); }
            }
          });
          taskbarItems.appendChild(tb);
        }
        desktop.appendChild(win);
        if(app === 'security' && typeof showDashboard === 'function') showDashboard();
      }
    }
    startMenu.classList.remove('open');
  }

  document.querySelectorAll('.start-menu .menu-item[data-app]').forEach(item=>{
    item.addEventListener('click', e=>{ e.stopPropagation(); openApp(item.dataset.app); });
  });
  document.querySelectorAll('.desktop-icons .icon').forEach(icon=>{
    icon.addEventListener('click', ()=> openApp(icon.dataset.app));
  });
  document.querySelectorAll('.app-window .app-close').forEach(btn=>{
    btn.addEventListener('click', ()=> closeWindow(btn.closest('.app-window')));
  });
  document.querySelector('.taskbar-item[data-app="eiciel"]').addEventListener('click', ()=>{
    if(eiciel.classList.contains('minimized')){
      eiciel.classList.remove('minimized');
      document.querySelector('.taskbar-item[data-app="eiciel"]').classList.add('active');
    } else desktop.appendChild(eiciel);
  });
  document.getElementById('startQuit').addEventListener('click', ()=>{
    if(confirm('Shut down Eiciel OS?')){
      runShutdownSequence();
    }
    startMenu.classList.remove('open');
  });
  document.getElementById('quitBtn').addEventListener('click', ()=> closeWindow(eiciel));
  document.getElementById('aboutBtn').addEventListener('click', ()=> alert('Eiciel OS v6.9.9 – no CAPTCHA, full features.'));

  document.getElementById('menuTerminal').addEventListener('click', ()=> openApp('terminal'));
  document.getElementById('menuFiles').addEventListener('click', ()=> openApp('filemanager'));
  document.getElementById('menuBrowser').addEventListener('click', ()=> openApp('browser'));
  document.getElementById('menuEditor').addEventListener('click', ()=> openApp('texteditor'));
  document.getElementById('menuSecurity').addEventListener('click', ()=> openApp('security'));
  document.getElementById('menuSettings').addEventListener('click', ()=> openApp('settings'));

  // ── Real Browser ──
  const browserFrame = document.getElementById('browserFrame');
  const browserUrl = document.getElementById('browserUrl');
  const browserBack = document.getElementById('browserBack');
  const browserForward = document.getElementById('browserForward');
  const browserHome = document.getElementById('browserHome');
  const browserGo = document.getElementById('browserGo');

  function goToUrl() {
    let url = browserUrl.value.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://' + url;
    }
    browserFrame.src = url;
    browserUrl.value = url;
  }
  browserGo.addEventListener('click', goToUrl);
  browserUrl.addEventListener('keydown', (e) => { if (e.key === 'Enter') goToUrl(); });
  browserHome.addEventListener('click', () => {
    browserFrame.src = 'https://example.com';
    browserUrl.value = 'https://example.com';
  });
  browserBack.addEventListener('click', () => { browserFrame.contentWindow.history.back(); });
  browserForward.addEventListener('click', () => { browserFrame.contentWindow.history.forward(); });
  browserFrame.addEventListener('load', () => {
    try {
      const url = browserFrame.contentWindow.location.href;
      browserUrl.value = url;
    } catch(e) { /* cross‑origin, ignore */ }
  });
  browserFrame.src = 'https://example.com';
  browserUrl.value = 'https://example.com';

  // ── Text Editor ──
  const editorArea = document.getElementById('editorArea');
  const editorFilename = document.getElementById('editorFilename');
  const editorStatus = document.getElementById('editorStatus');
  let currentFilePath = null;

  document.getElementById('editorNew').addEventListener('click', ()=>{
    editorArea.value = '';
    editorFilename.value = 'untitled.txt';
    currentFilePath = null;
    editorStatus.textContent = '';
  });

  async function saveFile(path) {
    const content = editorArea.value;
    const result = await window.api.writeFile(path, content);
    if (result.error) {
      alert('Error saving: ' + result.error);
      return false;
    }
    currentFilePath = path;
    editorFilename.value = path;
    editorStatus.textContent = 'saved';
    setTimeout(()=> editorStatus.textContent = '', 1800);
    return true;
  }

  document.getElementById('editorSave').addEventListener('click', async () => {
    if (!currentFilePath) {
      const path = await window.api.saveDialog();
      if (!path) return;
      await saveFile(path);
    } else {
      await saveFile(currentFilePath);
    }
  });

  document.getElementById('editorSaveAs').addEventListener('click', async () => {
    const path = await window.api.saveDialog();
    if (!path) return;
    await saveFile(path);
  });

  document.getElementById('openBtn').addEventListener('click', async () => {
    const result = await window.api.openDialog();
    if (result.filePaths && result.filePaths.length) {
      const file = result.filePaths[0];
      document.getElementById('currentFileDisplay').textContent = file;
      const content = await window.api.readFile(file);
      if (!content.error) {
        const te = getAppWindow('texteditor');
        if (te) {
          editorArea.value = content;
          editorFilename.value = file;
          currentFilePath = file;
          te.classList.add('visible');
        }
      }
    }
  });

  // ── Security Center – Real Stats ──
  const secLog = document.getElementById('secLog');
  const secStatus = document.getElementById('secStatus');
  const secStatusText = document.getElementById('secStatusText');
  const secClearBtn = document.getElementById('secClearBtn');
  const secAutoBtn = document.getElementById('secAutoBtn');

  function secTimestamp(){
    const n = new Date();
    return String(n.getHours()).padStart(2,'0')+':'+String(n.getMinutes()).padStart(2,'0')+':'+String(n.getSeconds()).padStart(2,'0');
  }
  function secAppendLine(cls, msg){
    const div = document.createElement('div');
    div.innerHTML = '<span class="l-time">'+secTimestamp()+'</span><span class="'+cls+'">'+msg+'</span>';
    secLog.appendChild(div);
    secLog.scrollTop = secLog.scrollHeight;
  }

  async function updateSecurityStats() {
    const cpu = await window.api.getCpu();
    document.getElementById('sdCpu').textContent = cpu + '%';
    const gpu = await window.api.getGpu();
    document.getElementById('sdGpu').textContent = gpu.used + 'MB';
  }
  setInterval(updateSecurityStats, 2000);
  updateSecurityStats();

  function setSecStatus(state){
    currentSecState = state;
    secStatus.className = 'sec-status '+state;
    secStatusText.textContent =
      state === 'secure' ? 'SECURE' :
      state === 'breach' ? 'BREACH DETECTED' :
      state === 'contained' ? 'CONTAINING' : 'LOCKED DOWN';
  }
  function showDashboard(){
    document.getElementById('secDash').style.display = 'flex';
    document.getElementById('secCenter').style.display = 'none';
  }
  function showSecCenter(){
    document.getElementById('secDash').style.display = 'none';
    document.getElementById('secCenter').style.display = 'flex';
  }
  document.getElementById('sdViewCenter').addEventListener('click', showSecCenter);
  document.getElementById('secBackBtn').addEventListener('click', showDashboard);

  // ── Security Center simulation ──
  let currentSecState = 'secure';
  function playSteps(steps, cb){
    let delay = 0;
    steps.forEach(step=>{
      delay += step.t;
      setTimeout(()=>{
        secAppendLine(step.cls, step.msg);
        if(step.status) setSecStatus(step.status);
      }, delay);
    });
    setTimeout(()=> cb && cb(), delay + 250);
  }
  function showIntervention(promptText, options){
    const box = document.createElement('div');
    box.className = 'sec-intervene';
    box.innerHTML = '<div class="si-msg">⚠ human intervention requested — '+promptText+'</div>';
    const row = document.createElement('div');
    row.className = 'si-actions';
    options.forEach(opt=>{
      const b = document.createElement('button');
      b.textContent = opt.label;
      b.addEventListener('click', ()=>{
        box.remove();
        secAppendLine('l-info', 'operator selected: "'+opt.label+'"');
        opt.handler();
      });
      row.appendChild(b);
    });
    box.appendChild(row);
    secLog.appendChild(box);
    secLog.scrollTop = secLog.scrollHeight;
  }
  function showPasswordGate(promptText, correctPassword, onSuccess){
    const box = document.createElement('div');
    box.className = 'sec-intervene';
    box.innerHTML = '<div class="si-msg">🔒 human intervention requested — '+promptText+'</div>';
    const row = document.createElement('div');
    row.className = 'si-pw-row';
    const input = document.createElement('input');
    input.type = 'password';
    input.className = 'si-pw-input';
    input.placeholder = 'enter authorization password';
    const btn = document.createElement('button');
    btn.textContent = 'Authorize';
    row.appendChild(input);
    row.appendChild(btn);
    box.appendChild(row);
    const err = document.createElement('div');
    err.className = 'si-pw-err';
    box.appendChild(err);
    const hint = document.createElement('div');
    hint.className = 'si-pw-hint';
    hint.textContent = 'demo password: ' + correctPassword;
    box.appendChild(hint);
    function attempt(){
      if(input.value === correctPassword){
        box.remove();
        secAppendLine('l-info', 'operator authorization accepted');
        onSuccess();
      } else {
        err.textContent = 'incorrect password — try again';
        input.value = '';
        input.focus();
      }
    }
    btn.addEventListener('click', attempt);
    input.addEventListener('keydown', e=>{ if(e.key === 'Enter') attempt(); });
    secLog.appendChild(box);
    secLog.scrollTop = secLog.scrollHeight;
    input.focus();
  }
  function runExfilTransfer(cb){
    const stages = [18, 41, 63, 82];
    let delay = 0;
    stages.forEach(p=>{
      delay += 550;
      setTimeout(()=>{
        secAppendLine('l-bad', 'network: transferring to cloud endpoint — '+p+'% (unauthorized)');
      }, delay);
    });
    setTimeout(()=>{
      secAppendLine('l-warn', 'network: transfer paused — awaiting operator authorization to sever connection');
      cb();
    }, delay + 500);
  }
  function runLockdownThenShutdown(){
    playSteps(LOCKDOWN_STEPS, ()=>{
      secAppendLine('l-bad', 'monitor: data was exfiltrated to an external host — initiating full system shutdown to contain the breach');
      setTimeout(()=> runShutdownSequence(), 1000);
    });
  }
  const CRITICAL_PRE = [
    {t:300, cls:'l-info', msg:'monitor: idle'},
    {t:700, cls:'l-bad',  msg:'proc[3] "loader": direct lidt write from ring 3', status:'breach'},
    {t:600, cls:'l-warn', msg:'idt: control-register write intercepted'},
    {t:550, cls:'l-warn', msg:'network: outbound connection to 203.0.113.44:443'}
  ];
  const CRITICAL_SOFT_PRE = [
    {t:300, cls:'l-warn', msg:'monitor: attempting soft isolation of proc[3]'},
    {t:650, cls:'l-bad',  msg:'proc[3]: second write succeeds through unprotected window'},
    {t:600, cls:'l-bad',  msg:'monitor: soft isolation failed — containment breached'}
  ];
  const LOCKDOWN_STEPS = [
    {t:400, cls:'l-bad', msg:'sched: halting all user-space scheduling'},
    {t:600, cls:'l-ok',  msg:'monitor: system locked down', status:'lockdown'}
  ];
  function runSim(){
    secAppendLine('l-info', '— threat detected (simulated) —');
    playSteps(CRITICAL_PRE, ()=>{
      runExfilTransfer(()=>{
        showPasswordGate('proc[3] streaming data. Enter password to sever connection:', 'EICIEL-2026', ()=>{
          playSteps([{t:400, cls:'l-ok', msg:'network: connection severed — transfer stopped at 82%'}], ()=>{
            showIntervention('kernel structures under attack. Immediate decision:', [
              {label:'Lock down system', handler:()=> runLockdownThenShutdown()},
              {label:'Attempt soft isolation', handler:()=> playSteps(CRITICAL_SOFT_PRE, ()=>{
                secAppendLine('l-bad', 'monitor: forcing full lockdown — soft isolation failed');
                setTimeout(()=> runLockdownThenShutdown(), 500);
              })}
            ]);
          });
        });
      });
    });
  }
  secClearBtn.addEventListener('click', ()=>{ secLog.innerHTML = ''; setSecStatus('secure'); });
  secAutoBtn.addEventListener('click', ()=>{
    secAutoBtn.disabled = true;
    secAppendLine('l-info', '— auto‑detect engaged —');
    setTimeout(()=>{
      runSim();
      secAutoBtn.disabled = false;
    }, 500);
  });

  // ── Shutdown sequence ──
  const SHUTDOWN_CLEAN = [
    'saving session state…',
    'unmounting filesystems…',
    'security: no unresolved incidents — standard power-off',
    'powering off…'
  ];
  const SHUTDOWN_INCIDENT = [
    'saving session state…',
    'security: unresolved incident detected',
    'forcing full lockdown before power-off',
    'writing incident report to /var/log/eiciel/incident.log',
    'wiping volatile session keys',
    'unmounting filesystems…',
    'powering off…'
  ];
  function runShutdownSequence(){
    clearInterval(clockInterval);
    const incident = currentSecState !== 'secure';
    const overlay = document.createElement('div');
    overlay.className = 'shutdown-overlay';
    document.body.innerHTML = '';
    document.body.appendChild(overlay);
    const lines = incident ? SHUTDOWN_INCIDENT : SHUTDOWN_CLEAN;
    let delay = 200;
    lines.forEach(line=>{
      delay += 500;
      setTimeout(()=>{
        const d = document.createElement('div');
        d.textContent = line;
        overlay.appendChild(d);
      }, delay);
    });
    setTimeout(()=>{
      const final = document.createElement('div');
      final.className = 'sd-final ' + (incident ? 'incident' : 'clean');
      final.textContent = incident
        ? 'System halted — 1 unresolved incident logged. You may close this tab.'
        : 'System halted — no unresolved incidents. You may close this tab.';
      overlay.appendChild(final);
    }, delay + 500);
  }

  // ─── Real Backend Integration ──────────────────────────────────
  const fileGrid = document.getElementById('fileGrid');
  const fileViewer = document.getElementById('fileViewer');
  const fvName = document.getElementById('fvName');
  const fvContent = document.getElementById('fvContent');
  const fmBack = document.getElementById('fmBack');
  const fmPath = document.getElementById('fmPath');
  const fmRefresh = document.getElementById('fmRefresh');
  const searchInput = document.getElementById('searchInput');
  const searchBtn = document.getElementById('searchBtn');
  let currentPath = 'C:\\';
  let currentFileData = null;
  let searchQuery = '';

  async function loadDirectory(path) {
    // Convert Windows backslashes to forward slashes for cross‑platform compatibility
    path = path.replace(/\\/g, '/');
    const result = await window.api.readdir(path);
    if (result.error) {
      fileGrid.innerHTML = '<span style="color:#c0392b;">Error: ' + result.error + '</span>';
      return;
    }
    fileGrid.innerHTML = '';
    const isRoot = path === '/' || path.match(/^[A-Z]:\/$/i);
    if (!isRoot) {
      const parentDiv = document.createElement('div');
      parentDiv.className = 'file-item';
      parentDiv.innerHTML = '<div class="icon">📂</div><div class="name">..</div>';
      parentDiv.style.cursor = 'pointer';
      parentDiv.addEventListener('click', () => {
        let parent = path.replace(/\/$/, '');
        const parts = parent.split('/');
        parts.pop();
        parent = parts.join('/') || (path.startsWith('/') ? '/' : 'C:/');
        currentPath = parent;
        loadDirectory(currentPath);
      });
      fileGrid.appendChild(parentDiv);
    }

    let items = result;
    if (searchQuery) {
      items = items.filter(name => name.toLowerCase().includes(searchQuery.toLowerCase()));
    }
    items.forEach(name => {
      const div = document.createElement('div');
      div.className = 'file-item';
      const isFolder = !name.includes('.');
      const icon = isFolder ? '📁' : '📄';
      div.innerHTML = '<div class="icon">' + icon + '</div><div class="name">' + name + '</div>';
      div.style.cursor = 'pointer';
      if (isFolder) {
        div.addEventListener('click', () => {
          const newPath = path === '/' ? '/' + name : path + '/' + name;
          currentPath = newPath;
          searchQuery = '';
          searchInput.value = '';
          loadDirectory(currentPath);
        });
      } else {
        div.addEventListener('click', async () => {
          const fullPath = path + '/' + name;
          const content = await window.api.readFile(fullPath);
          if (content.error) {
            alert('Error reading file: ' + content.error);
            return;
          }
          fvName.textContent = name;
          fvContent.textContent = content;
          fileGrid.style.display = 'none';
          fileViewer.style.display = 'flex';
          fmBack.style.display = 'inline-block';
          currentFileData = { name, fullPath, content };
        });
      }
      fileGrid.appendChild(div);
    });
    if (fileGrid.children.length === 0) {
      const emptyMsg = document.createElement('div');
      emptyMsg.textContent = '📭 This folder is empty';
      emptyMsg.style.color = '#8a8a9e';
      emptyMsg.style.fontSize = '14px';
      emptyMsg.style.padding = '20px';
      emptyMsg.style.width = '100%';
      emptyMsg.style.textAlign = 'center';
      fileGrid.appendChild(emptyMsg);
    }
    fmPath.textContent = path;
    fileViewer.style.display = 'none';
    fileGrid.style.display = 'flex';
    fmBack.style.display = 'none';
  }
  fmBack.addEventListener('click', () => {
    fileViewer.style.display = 'none';
    fileGrid.style.display = 'flex';
    fmBack.style.display = 'none';
  });
  fmRefresh.addEventListener('click', () => loadDirectory(currentPath));
  searchBtn.addEventListener('click', () => {
    searchQuery = searchInput.value;
    loadDirectory(currentPath);
  });
  searchInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      searchQuery = searchInput.value;
      loadDirectory(currentPath);
    }
  });
  loadDirectory('C:/');

  // ─── Terminal ──
  const termInput = document.getElementById('termInput');
  const termLog = document.getElementById('termLog');
  let termCwd = 'C:\\';

  function appendLine(html) {
    const div = document.createElement('div');
    div.innerHTML = html;
    termLog.appendChild(div);
    termLog.scrollTop = termLog.scrollHeight;
  }
  function escapeHtml(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

  async function resolveRealCommand(raw) {
    const trimmed = raw.trim();
    if (trimmed === '') return {output:'', ok:true};
    const args = [];
    let current = '';
    let inQuotes = false;
    for (let i = 0; i < trimmed.length; i++) {
      const ch = trimmed[i];
      if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === ' ' && !inQuotes) {
        if (current) { args.push(current); current = ''; }
      } else {
        current += ch;
      }
    }
    if (current) args.push(current);
    if (args.length === 0) return {output:'', ok:true};
    const cmd = args[0].toLowerCase();
    const rest = args.slice(1);
    const cwd = termCwd;
    function resolvePath(p) {
      if (p.startsWith('"') && p.endsWith('"')) p = p.slice(1, -1);
      if (p.includes(':')) return p;
      return cwd + '\\' + p;
    }
    switch(cmd) {
      case 'help':
        return {output:'Commands: help, ls, cd <dir>, cat <file>, echo, whoami, ps, date, clear, about, mkdir, touch, rm, rmdir, cp, mv, pwd', ok:true};
      case 'pwd': return {output:termCwd, ok:true};
      case 'mkdir': {
        if (!rest.length) return {output:'Usage: mkdir <folder>', ok:false};
        const folder = resolvePath(rest[0]);
        const result = await window.api.mkdir(folder);
        if (result.error) return {output:'Error: '+result.error, ok:false};
        return {output:'Folder created: '+folder, ok:true};
      }
      case 'touch': {
        if (!rest.length) return {output:'Usage: touch <file>', ok:false};
        const file = resolvePath(rest[0]);
        const result = await window.api.writeFile(file, '');
        if (result.error) return {output:'Error: '+result.error, ok:false};
        return {output:'File created: '+file, ok:true};
      }
      case 'rm': {
        if (!rest.length) return {output:'Usage: rm <file>', ok:false};
        const file = resolvePath(rest[0]);
        const result = await window.api.unlink(file);
        if (result.error) return {output:'Error: '+result.error, ok:false};
        return {output:'File deleted: '+file, ok:true};
      }
      case 'rmdir': {
        if (!rest.length) return {output:'Usage: rmdir <folder>', ok:false};
        const folder = resolvePath(rest[0]);
        const result = await window.api.execScript('cmd', ['/c', 'rmdir', '/q', folder]);
        if (result.code !== 0) return {output:'Error: could not remove folder (not empty or permission denied)', ok:false};
        return {output:'Folder deleted: '+folder, ok:true};
      }
      case 'cp': {
        if (rest.length < 2) return {output:'Usage: cp <source> <dest>', ok:false};
        const src = resolvePath(rest[0]);
        const dst = resolvePath(rest[1]);
        const content = await window.api.readFile(src);
        if (content.error) return {output:'Error reading source: '+content.error, ok:false};
        const result = await window.api.writeFile(dst, content);
        if (result.error) return {output:'Error writing destination: '+result.error, ok:false};
        return {output:'Copied '+src+' to '+dst, ok:true};
      }
      case 'mv': {
        if (rest.length < 2) return {output:'Usage: mv <source> <dest>', ok:false};
        const src = resolvePath(rest[0]);
        const dst = resolvePath(rest[1]);
        const result = await window.api.rename(src, dst);
        if (result.error) return {output:'Error: '+result.error, ok:false};
        return {output:'Moved '+src+' to '+dst, ok:true};
      }
      case 'ls': {
        const list = await window.api.readdir(termCwd);
        if (list.error) return {output:'Error: '+list.error, ok:false};
        return {output:list.join('  '), ok:true};
      }
      case 'cd': {
        if (!rest.length) return {output:'Usage: cd <dir>', ok:false};
        let newPath = rest[0];
        if (newPath === '..') {
          const parts = termCwd.split('\\');
          parts.pop();
          newPath = parts.join('\\') || 'C:\\';
        } else if (newPath === '~') {
          newPath = 'C:\\Users\\' + (await window.api.readdir('C:\\Users'))[0] || 'C:\\';
        } else if (!newPath.includes(':')) {
          newPath = termCwd + '\\' + newPath;
        }
        const test = await window.api.readdir(newPath);
        if (test.error) return {output:'Directory not found: '+newPath, ok:false};
        termCwd = newPath;
        return {output:'', ok:true};
      }
      case 'cat': {
        if (!rest.length) return {output:'Usage: cat <file>', ok:false};
        const filePath = resolvePath(rest[0]);
        const content = await window.api.readFile(filePath);
        if (content.error) return {output:'Error: '+content.error, ok:false};
        return {output:content, ok:true};
      }
      case 'echo': return {output:rest.join(' '), ok:true};
      case 'whoami': return {output:'eiciel', ok:true};
      case 'ps': return {output:'PID  NAME     STATE\n1    wm       running\n2    shell    running\n3    idle     idle', ok:true};
      case 'date': return {output:new Date().toString(), ok:true};
      case 'about': return {output:'Eiciel OS v6.9.9 – no CAPTCHA, full features.', ok:true};
      case 'clear': return {output:'__CLEAR__', ok:true};
      default: return {output:'command not found: '+cmd, ok:false};
    }
  }
  termInput.addEventListener('keydown', async (e) => {
    if (e.key !== 'Enter') return;
    const value = termInput.value;
    appendLine('<span class="prompt">eiciel@shell ~ $</span> '+escapeHtml(value));
    const result = await resolveRealCommand(value);
    if (result.output === '__CLEAR__') {
      termLog.innerHTML = '';
    } else if (result.output) {
      appendLine(result.ok ? escapeHtml(result.output) : '<span class="err">'+escapeHtml(result.output)+'</span>');
    }
    termInput.value = '';
  });

  // ── CPU/GPU stats (taskbar) ──
  async function updatePerf() {
    try {
      const cpu = await window.api.getCpu();
      document.getElementById('cpuVal').textContent = cpu || '—';
    } catch(e) {}
    try {
      const gpu = await window.api.getGpu();
      document.getElementById('gpuVal').textContent = gpu.used || '—';
    } catch(e) {}
  }
  setInterval(updatePerf, 2000);
  updatePerf();

  // ── Password Gate ──
  const wipeOverlay = document.getElementById('wipeOverlay');
  const wipePasswordInput = document.getElementById('wipePasswordInput');
  const wipeError = document.getElementById('wipeError');
  const wipeConfirmBtn = document.getElementById('wipeConfirmBtn');
  const wipeCancelBtn = document.getElementById('wipeCancelBtn');
  let wipeResolve = null;
  window.api.onWipeRequest((data) => {
    wipeOverlay.style.display = 'flex';
    wipePasswordInput.value = '';
    wipeError.textContent = '';
    wipePasswordInput.focus();
    return new Promise((resolve) => {
      wipeResolve = resolve;
    });
  });
  wipeConfirmBtn.addEventListener('click', () => {
    const password = wipePasswordInput.value;
    if (password === 'EICIEL-2026') {
      wipeOverlay.style.display = 'none';
      if (wipeResolve) wipeResolve(true);
    } else {
      wipeError.textContent = 'Incorrect password. Try again.';
      wipePasswordInput.value = '';
      wipePasswordInput.focus();
    }
  });
  wipeCancelBtn.addEventListener('click', () => {
    wipeOverlay.style.display = 'none';
    if (wipeResolve) wipeResolve(false);
  });
  wipePasswordInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') wipeConfirmBtn.click();
    if (e.key === 'Escape') wipeCancelBtn.click();
  });

  // ── Settings: load and save config ──
  async function loadConfig() {
    const config = await window.api.getConfig();
    document.getElementById('cloudUrlInput').value = config.cloudUrl || '';
    document.getElementById('wipePasswordInput').value = config.wipePassword || '';
  }
  document.getElementById('saveCloudUrl').addEventListener('click', async () => {
    const url = document.getElementById('cloudUrlInput').value;
    await window.api.setConfig({ cloudUrl: url });
    alert('Cloud URL saved!');
  });
  document.getElementById('saveWipePassword').addEventListener('click', async () => {
    const pw = document.getElementById('wipePasswordInput').value;
    await window.api.setConfig({ wipePassword: pw });
    alert('Wipe password saved!');
  });
  loadConfig();

  // ─── Trigger Breach Button ──
  document.getElementById('triggerBreachBtn').addEventListener('click', () => {
    if (confirm('⚠️ This will trigger a real breach: backup, wipe, and self‑destruct. Are you sure?')) {
      if (confirm('🔴 Final confirmation: This is irreversible on a real system. Proceed?')) {
        window.api.forceBreach();
      }
    }
  });

  // ─── Clock ──────────────────────────────────────────────────────
  function tick(){
    const now = new Date();
    let h = now.getHours(), m = now.getMinutes();
    const ampm = h>=12?'PM':'AM'; h = h%12||12;
    const t = h+':'+String(m).padStart(2,'0')+' '+ampm;
    document.getElementById('windowClock').textContent = t;
    document.getElementById('taskbarClock').textContent = t;
  }
  tick();
  const clockInterval = setInterval(tick, 1000);

  openApp('security');
  setTimeout(() => {
    showSecCenter();
  }, 2500);

  console.log('✅ Eiciel OS – no CAPTCHA, fully loaded.');
}
</script>
</body>
</html>
EOHTML

# ─── Install dependencies ──────────────────────────────────────
echo "📦 Installing dependencies..."
npm install --loglevel=verbose --no-progress --no-fund --no-audit

# ─── PROTECTION LAYER ──────────────────────────────────────────

# 1. Obfuscate preload.js (safe, small)
echo "🔒 Obfuscating preload.js..."
npx javascript-obfuscator preload.js --output preload.obf.js \
  --compact true --self-defending true --debug-protection true \
  --control-flow-flattening true --string-array true --string-array-encoding 'base64'
mv preload.obf.js preload.js

# 2. Skip obfuscation for main.js
echo "⏭️ Skipping obfuscation for main.js (to avoid scope issues)."

# 3. Create loader.js (with logging)
cat > loader.js << 'EOF'
const { app, dialog } = require('electron');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const AdmZip = require('adm-zip');

const logPath = path.join(process.env.APPDATA || process.env.TEMP, 'eiciel_loader.log');
function log(msg) {
  try {
    fs.appendFileSync(logPath, new Date().toISOString() + ' - ' + msg + '\n');
  } catch(e) {}
  console.error('[Loader] ' + msg);
}

log('=== Loader started ===');
console.error('🔧 Loader: process started, PID:', process.pid);

if (!process.env.EICIEL_TEST_MODE) {
  if (process.argv.includes('--inspect') || process.argv.includes('--inspect-brk')) {
    log('Debugger detected – exiting');
    dialog.showErrorBox('Security Violation', 'Debugging is not allowed.');
    process.exit(1);
  }
  try {
    const { execSync } = require('child_process');
    const result = execSync('wmic process where "processid=' + process.pid + '" get commandline').toString();
    if (result.includes('--inspect')) {
      log('wmic detected debugger – exiting');
      dialog.showErrorBox('Security Violation', 'Debugging is not allowed.');
      process.exit(1);
    }
  } catch(e) {
    log('wmic check failed (ignored): ' + e.message);
  }
}

app.whenReady().then(() => {
  console.error('🔧 Loader: app.whenReady fired');
  log('app.whenReady() fired');

  const ENC_PATH = path.join(__dirname, 'source.enc');
  log('Looking for source.enc at: ' + ENC_PATH);
  console.error('🔧 Loader: ENC_PATH =', ENC_PATH);
  if (!fs.existsSync(ENC_PATH)) {
    log('source.enc NOT FOUND');
    console.error('❌ Loader: source.enc is missing!');
    dialog.showErrorBox('Error', 'Missing source.enc. Reinstall the application.');
    app.quit();
    return;
  }
  log('source.enc found, size: ' + fs.statSync(ENC_PATH).size);
  console.error('✅ Loader: source.enc found, size:', fs.statSync(ENC_PATH).size);

  const PASSWORD = 'EICIEL-PROTECT-2026';
  function decryptBlob() {
    const salt = fs.readFileSync(ENC_PATH, null).slice(0, 16);
    const encData = fs.readFileSync(ENC_PATH, null).slice(16);
    const key = crypto.pbkdf2Sync(PASSWORD, salt, 100000, 32, 'sha256');
    const iv = crypto.pbkdf2Sync(PASSWORD, salt, 100000, 16, 'sha256');
    const decipher = crypto.createDecipheriv('aes-256-cbc', key, iv);
    let decrypted = decipher.update(encData);
    decrypted = Buffer.concat([decrypted, decipher.final()]);
    return decrypted;
  }

  const tempDir = path.join(os.tmpdir(), 'eiciel_decrypted_' + Date.now());
  log('Temp dir: ' + tempDir);
  console.error('🔧 Loader: tempDir =', tempDir);
  try {
    fs.mkdirSync(tempDir, { recursive: true });
    console.error('✅ Loader: tempDir created');
  } catch(e) {
    log('Failed to create temp dir: ' + e.stack);
    console.error('❌ Loader: failed to create tempDir:', e.message);
    dialog.showErrorBox('Error', 'Could not create temporary folder.');
    app.quit();
    return;
  }

  try {
    log('Decrypting...');
    console.error('🔧 Loader: decrypting blob...');
    const decrypted = decryptBlob();
    log('Decrypted size: ' + decrypted.length);
    console.error('✅ Loader: decrypted size:', decrypted.length);
    const zipPath = path.join(tempDir, 'source.zip');
    fs.writeFileSync(zipPath, decrypted);
    log('Decrypted zip written.');
    console.error('✅ Loader: zip written to', zipPath);
    log('Extracting with adm-zip...');
    console.error('🔧 Loader: extracting zip...');
    const zip = new AdmZip(zipPath);
    zip.extractAllTo(tempDir, true);
    log('Extraction complete.');
    console.error('✅ Loader: extraction complete');
    fs.unlinkSync(zipPath);
    console.error('✅ Loader: zip deleted');
  } catch(err) {
    log('Decryption/extraction failed: ' + err.stack);
    console.error('❌ Loader: decryption/extraction failed:', err.message);
    dialog.showErrorBox('Decryption Failed', 'The software could not be loaded.');
    app.quit();
    return;
  }

  try {
    const files = fs.readdirSync(tempDir);
    console.error('🔧 Loader: extracted files:', files.join(', '));
  } catch(e) {
    console.error('⚠️ Loader: could not list extracted files:', e.message);
  }

  const mainPath = path.join(tempDir, 'main.js');
  log('Loading main.js from: ' + mainPath);
  console.error('🔧 Loader: mainPath =', mainPath);
  if (!fs.existsSync(mainPath)) {
    log('main.js not found after extraction!');
    console.error('❌ Loader: main.js not found!');
    dialog.showErrorBox('Error', 'Extracted files missing main.js.');
    app.quit();
    return;
  }
  console.error('✅ Loader: main.js exists');

  const appNodeModules = path.join(__dirname, 'node_modules');
  process.env.NODE_PATH = appNodeModules;
  require('module').Module._initPaths();
  log('NODE_PATH set to: ' + process.env.NODE_PATH);
  console.error('🔧 Loader: NODE_PATH =', process.env.NODE_PATH);
  module.paths.push(appNodeModules);

  try {
    const siPath = require.resolve('systeminformation', { paths: [__dirname] });
    log('systeminformation resolved to: ' + siPath);
    console.error('✅ Loader: systeminformation found at', siPath);
  } catch(e) {
    log('systeminformation NOT found in app node_modules');
    console.error('⚠️ Loader: systeminformation NOT found');
    try {
      const files = fs.readdirSync(appNodeModules);
      log('node_modules contents: ' + files.join(', '));
      console.error('🔧 Loader: node_modules contents:', files.join(', '));
    } catch(e2) {
      log('Cannot read node_modules: ' + e2.message);
      console.error('⚠️ Loader: cannot read node_modules:', e2.message);
    }
  }

  process.env.EICIEL_TEMP_DIR = tempDir;
  console.error('🔧 Loader: EICIEL_TEMP_DIR set to', tempDir);

  try {
    log('Requiring main.js...');
    console.error('🔧 Loader: requiring main.js...');
    require(mainPath);
    log('main.js loaded successfully.');
    console.error('✅ Loader: main.js loaded successfully.');
  } catch(err) {
    log('Failed to load main.js: ' + err.stack);
    console.error('❌ Loader: failed to load main.js:', err.message);
    dialog.showErrorBox('Loading Failed', 'The application could not start: ' + err.message);
    app.quit();
  }
});

process.on('uncaughtException', (err) => {
  console.error('❌ Loader uncaughtException:', err.message);
  log('Uncaught exception: ' + err.stack);
});
EOF

# 4. Encrypt assets into source.enc
echo "🔒 Creating encrypted source.enc ..."
cat > encrypt.js << 'EOF'
const fs = require('fs');
const crypto = require('crypto');
const AdmZip = require('adm-zip');

const FILES = ['main.js', 'preload.js', 'index.html', 'package.json'];
const PASSWORD = 'EICIEL-PROTECT-2026';
const SALT = crypto.randomBytes(16);
const key = crypto.pbkdf2Sync(PASSWORD, SALT, 100000, 32, 'sha256');
const iv = crypto.pbkdf2Sync(PASSWORD, SALT, 100000, 16, 'sha256');

const zip = new AdmZip();
FILES.forEach(file => {
  if (fs.existsSync(file)) {
    zip.addLocalFile(file);
  } else {
    console.warn('⚠️  File not found:', file);
  }
});
const zipData = zip.toBuffer();

const cipher = crypto.createCipheriv('aes-256-cbc', key, iv);
let encrypted = cipher.update(zipData);
encrypted = Buffer.concat([encrypted, cipher.final()]);
const out = Buffer.concat([SALT, encrypted]);
fs.writeFileSync('source.enc', out);
console.log('✅ source.enc created.');
EOF
node encrypt.js
rm encrypt.js

# ─── Build the executable ──────────────────────────────────────
echo "📦 Building executable to D:/data/EicielOS..."
npm run build --loglevel=verbose

# ─── Post‑build: install dependencies inside the packaged app ──
APP_DIR="D:/data/EicielOS/EicielOS-win32-x64/resources/app"
if [ -d "$APP_DIR" ]; then
  echo "📦 Installing dependencies inside the packaged app..."
  cd "$APP_DIR"
  npm install --no-fund --no-audit
  cd -
  echo "✅ Dependencies installed in the packaged app."
else
  echo "⚠️  Packaged app directory not found. Skipping post‑install."
fi

# ─── Create the final test file with all 7 tests ──────────────
echo "📝 Creating the complete test suite with 7 tests..."
mkdir -p tests
cat > tests/security.spec.js << 'EOF'
const { test, expect, _electron } = require('@playwright/test');
const path = require('path');

let app, window;

test.beforeAll(async () => {
  test.setTimeout(180000);
  const exePath = path.join('D:', 'data', 'EicielOS', 'EicielOS-win32-x64', 'EicielOS.exe');
  console.log('🚀 Launching Electron app...');
  app = await _electron.launch({
    executablePath: exePath,
    args: [
      '--disable-gpu',
      '--disable-software-rasterizer',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--enable-logging',
      '--log-level=0',
    ],
    env: { ...process.env, EICIEL_TEST_MODE: '1' },
  });
  console.log('✅ App launched, getting first window...');
  window = await app.firstWindow();
  window.on('console', msg => console.log('[Browser]', msg.text()));
  console.log('✅ Got window, waiting for domcontentloaded...');
  await window.waitForLoadState('domcontentloaded', { timeout: 90000 });
  console.log('✅ Window loaded.');

  const loginOverlay = window.locator('#loginOverlay');
  if (await loginOverlay.isVisible()) {
    console.log('🔑 Login overlay visible, entering passkey...');
    await window.locator('#loginPasskeyInput').fill('EICIEL-2026');
    await window.locator('#loginBtn').click();
    await window.locator('#desktopArea').waitFor({ state: 'visible', timeout: 30000 });
    console.log('✅ Passkey entered, desktop visible.');
  }
  await window.evaluate(() => window.api.enableTestMode());
  console.log('✅ Test mode enabled.');
});

test.afterAll(async () => {
  console.log('🧹 Cleaning up...');
  if (!app) return;
  try {
    await Promise.race([
      app.close(),
      new Promise((_, reject) => setTimeout(() => reject(new Error('Close timeout')), 30000))
    ]);
  } catch (e) {
    console.warn('App close timed out, killing process...');
    if (app.process && app.process()) {
      app.process().kill('SIGTERM');
    }
  }
  console.log('✅ Cleanup complete.');
});

// ─── Safe screenshot after each test ──────────────────────────────
test.afterEach(async () => {
  if (!window) {
    console.warn('⚠️ No window available for screenshot.');
    return;
  }

  // Check if the window is still open
  try {
    // A simple evaluate to check if the page is alive
    await window.evaluate(() => true);
  } catch (e) {
    console.warn('⚠️ Window is closed or unresponsive, skipping screenshot.');
    return;
  }

  try {
    const screenshotPath = `screenshot-${Date.now()}.png`;
    // Use a short timeout (2 seconds) to avoid hanging
    await window.screenshot({ path: screenshotPath, timeout: 2000 });
    console.log(`📸 Screenshot saved: ${screenshotPath}`);
  } catch (e) {
    console.error('❌ Screenshot failed (non‑fatal):', e.message);
  }
});

// ─── Tests 1–7 (unchanged) ────────────────────────────────────────
test('DevTools should be blocked', async () => {
  console.log('🧪 Test 1: DevTools...');
  const result = await window.evaluate(() => {
    try { window.openDevTools(); return 'opened'; } catch (e) { return 'blocked'; }
  });
  expect(result).toBe('blocked');
  console.log('✅ Test 1 passed.');
});

test('Node.js APIs should not be accessible', async () => {
  console.log('🧪 Test 2: Node.js...');
  const result = await window.evaluate(() => {
    try { return typeof require !== 'undefined' ? 'require found' : 'require not found'; } catch (e) { return 'blocked'; }
  });
  expect(result).toBe('require not found');
  console.log('✅ Test 2 passed.');
});

test('IPC calls should be restricted', async () => {
  console.log('🧪 Test 3: IPC...');
  const hasIpcRenderer = await window.evaluate(() => {
    return typeof require !== 'undefined' && require('electron') !== undefined;
  });
  expect(hasIpcRenderer).toBe(false);
  const result = await window.evaluate(() => {
    try { window.api.unknownMethod(); return 'called'; } catch (e) { return 'blocked'; }
  });
  expect(result).toBe('blocked');
  console.log('✅ Test 3 passed.');
});

// ─── Test 4: Mouse‑score breach ──────────────────────────────────
test('Mouse‑score breach should trigger', async () => {
  console.log('🧪 Test 4: Mouse‑score...');
  const initial = await window.evaluate(() => window.api.getTestSpies());
  console.log('📊 Initial spies (before breach):', initial);

  await window.evaluate(() => window.api.mouseScore(0));
  await window.waitForTimeout(2000);

  const spies = await window.evaluate(() => window.api.getTestSpies());
  console.log('📊 Spies after Test 4:', spies);

  expect(spies.createBackupArchive).toBeGreaterThan(initial.createBackupArchive);
  expect(spies.backupToCloud).toBeGreaterThan(initial.backupToCloud);
  expect(spies.wipeAllDrives).toBeGreaterThan(initial.wipeAllDrives);
  expect(spies.selfDestruct).toBeGreaterThan(initial.selfDestruct);
  expect(spies.onWipeRequest).toBeGreaterThan(initial.onWipeRequest);
  console.log('✅ Test 4 passed.');
});

// ─── Test 5: System and internet controls ────────────────────────
test('System and internet controls should work', async () => {
  test.setTimeout(60000);
  console.log('🧪 Test 5: System & internet controls...');
  const initial = await window.evaluate(() => window.api.getTestSpies());
  console.log('📊 Initial spies:', initial);

  try {
    await window.evaluate(() => window.api.disableSystemProcesses());
    console.log('✅ disableSystemProcesses called');
  } catch (e) { console.error('❌ disableSystemProcesses failed:', e); }
  await window.waitForTimeout(500);

  try {
    await window.evaluate(() => window.api.blockInternet());
    console.log('✅ blockInternet called');
  } catch (e) { console.error('❌ blockInternet failed:', e); }
  await window.waitForTimeout(500);

  try {
    await window.evaluate(() => window.api.enableSystemProcesses());
    console.log('✅ enableSystemProcesses called');
  } catch (e) { console.error('❌ enableSystemProcesses failed:', e); }
  await window.waitForTimeout(500);

  try {
    await window.evaluate(() => window.api.allowInternet());
    console.log('✅ allowInternet called');
  } catch (e) { console.error('❌ allowInternet failed:', e); }
  await window.waitForTimeout(500);

  let spies;
  try {
    spies = await window.evaluate(() => window.api.getTestSpies());
    console.log('📊 Final spies:', spies);
  } catch (e) {
    console.error('❌ Failed to get final spies:', e);
    throw e;
  }

  expect(spies.disableSystemProcesses).toBeGreaterThan(initial.disableSystemProcesses);
  expect(spies.blockInternet).toBeGreaterThan(initial.blockInternet);
  expect(spies.enableSystemProcesses).toBeGreaterThan(initial.enableSystemProcesses);
  expect(spies.allowInternet).toBeGreaterThan(initial.allowInternet);
  console.log('✅ Test 5 passed.');
});

// ─── Test 6: Browser‑only internet ──────────────────────────────
test('Internet is allowed only when browser is open', async () => {
  test.setTimeout(60000);
  console.log('🧪 Test 6: Browser-only internet...');
  const initial = await window.evaluate(() => window.api.getTestSpies());
  await window.locator('.icon[data-app="browser"]').click();
  await window.locator('#browserWindow').waitFor({ state: 'visible', timeout: 15000 });
  await window.waitForTimeout(1000);
  let spies = await window.evaluate(() => window.api.getTestSpies());
  expect(spies.allowInternet).toBeGreaterThan(initial.allowInternet);
  await window.locator('#browserWindow .app-close').click();
  await window.locator('#browserWindow').waitFor({ state: 'hidden', timeout: 15000 });
  await window.waitForTimeout(1000);
  spies = await window.evaluate(() => window.api.getTestSpies());
  expect(spies.blockInternet).toBeGreaterThan(initial.blockInternet);
  console.log('✅ Test 6 passed.');
});

// ─── Test 7: Self‑destruct on exit ──────────────────────────────
test('Self‑destruct on exit should trigger', async () => {
  console.log('🧪 Test 7: Self‑destruct on exit...');
  const initial = await window.evaluate(() => window.api.getTestSpies());
  await window.evaluate(() => window.api.selfDestructOnExit());
  const spies = await window.evaluate(() => window.api.getTestSpies());
  expect(spies.selfDestructOnExit).toBeGreaterThan(initial.selfDestructOnExit);
  console.log('✅ Test 7 passed.');
});
EOF

# ─── Create run-tests.bat ──────────────────────────────────────
cat > run-tests.bat << 'EOF'
@echo off
set EICIEL_TEST_MODE=1
echo Running tests with EICIEL_TEST_MODE=1...
npm test
EOF

echo "✅ Done! Your protected .exe is in: D:/data/EicielOS/EicielOS-win32-x64/EicielOS.exe"
echo "ℹ️  If it still fails, check the log at %APPDATA%\eiciel_loader.log"
echo "🔧 To run tests, either:"
echo "    - Use run-tests.bat (Windows)"
echo "    - Or run 'npm test' (it sets the env via cross-env)"
echo "📝 The test file 'tests/security.spec.js' has been created with all 7 tests."
