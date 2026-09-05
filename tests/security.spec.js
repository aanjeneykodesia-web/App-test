const { test, expect, _electron } = require('@playwright/test');
const path = require('path');
const os = require('os');
const fs = require('fs');

// ─── Configuration ───────────────────────────────────────────────
const CONFIG = {
  // Dynamically resolve executable path based on OS
  exePath: process.env.EICIEL_EXE_PATH || getDefaultExePath(),
  testMode: process.env.EICIEL_TEST_MODE === '1',
  timeouts: {
    app: 180000,      // 3 minutes for app startup
    login: 30000,     // 30 seconds for login
    window: 15000,    // 15 seconds for window operations
    element: 30000,   // 30 seconds for element visibility
    screenshot: 2000, // 2 seconds for screenshot
  },
  screenshot: {
    enabled: process.env.SCREENSHOTS_ENABLED !== 'false',
    dir: process.env.SCREENSHOTS_DIR || './test-results/screenshots',
  },
  credentials: {
    loginPasskey: process.env.EICIEL_PASSKEY || 'EICIEL-2026',
    wipePassword: process.env.EICIEL_WIPE_PASSWORD || 'EICIEL-2026',
  },
  retry: {
    maxAttempts: 3,
    delay: 500,
  },
};

// ─── Utility Functions ───────────────────────────────────────────
function getDefaultExePath() {
  if (process.platform === 'win32') {
    return path.join('D:', 'data', 'EicielOS', 'EicielOS-win32-x64', 'EicielOS.exe');
  }
  // Add other platforms as needed
  return process.env.EICIEL_EXE_PATH || '';
}

function ensureScreenshotDir() {
  if (!fs.existsSync(CONFIG.screenshot.dir)) {
    fs.mkdirSync(CONFIG.screenshot.dir, { recursive: true });
  }
}

async function captureScreenshot(window, testName) {
  if (!CONFIG.screenshot.enabled || !window) {
    return null;
  }

  try {
    await window.evaluate(() => true);
  } catch (e) {
    console.warn('⚠️ Window unresponsive, skipping screenshot');
    return null;
  }

  try {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const screenshotPath = path.join(
      CONFIG.screenshot.dir,
      `${testName.replace(/\s+/g, '-')}-${timestamp}.png`
    );
    
    await window.screenshot({
      path: screenshotPath,
      timeout: CONFIG.timeouts.screenshot,
    });
    
    console.log(`📸 Screenshot saved: ${screenshotPath}`);
    return screenshotPath;
  } catch (e) {
    console.error('❌ Screenshot failed:', e.message);
    return null;
  }
}

async function retryAsync(fn, maxAttempts = CONFIG.retry.maxAttempts) {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt === maxAttempts) throw e;
      console.warn(`⚠️ Attempt ${attempt} failed, retrying in ${CONFIG.retry.delay}ms...`);
      await new Promise(resolve => setTimeout(resolve, CONFIG.retry.delay));
    }
  }
}

async function waitForElement(window, selector, timeout = CONFIG.timeouts.element) {
  return retryAsync(
    () => window.locator(selector).waitFor({ state: 'visible', timeout }),
    2
  );
}

// ─── Test State ──────────────────────────────────────────────────
let app = null;
let window = null;
let testContext = {};

// ─── Test Setup & Teardown ──────────────────────────────────────
test.beforeAll(async () => {
  test.setTimeout(CONFIG.timeouts.app);
  
  ensureScreenshotDir();

  // Validate executable path
  if (!CONFIG.exePath) {
    throw new Error('EICIEL_EXE_PATH not set and no default found for this platform');
  }
  
  if (!fs.existsSync(CONFIG.exePath)) {
    throw new Error(`Executable not found: ${CONFIG.exePath}`);
  }

  console.log('🚀 Launching Electron app...');
  console.log(`   Executable: ${CONFIG.exePath}`);
  console.log(`   Test Mode: ${CONFIG.testMode}`);

  try {
    app = await _electron.launch({
      executablePath: CONFIG.exePath,
      args: [
        '--disable-gpu',
        '--disable-software-rasterizer',
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--enable-logging',
        '--log-level=0',
        '--js-flags="--max-old-space-size=4096"',
      ],
      env: {
        ...process.env,
        EICIEL_TEST_MODE: CONFIG.testMode ? '1' : '0',
      },
    });

    console.log('✅ App launched');

    // Set up console log forwarding
    window = await app.firstWindow();
    window.on('console', msg => {
      console.log(`[Browser Console] ${msg.text()}`);
    });

    window.on('crash', () => {
      console.error('❌ Renderer process crashed');
    });

    console.log('⏳ Waiting for page to load...');
    await window.waitForLoadState('domcontentloaded', {
      timeout: CONFIG.timeouts.app,
    });

    console.log('✅ Page loaded');

    // Handle login if needed
    await handleLogin(window);

    // Enable test mode
    await retryAsync(
      () => window.evaluate(() => window.api.enableTestMode()),
      2
    );

    console.log('✅ Test mode enabled');
    console.log('✅ Test setup complete');
  } catch (e) {
    console.error('❌ Setup failed:', e.message);
    if (window) await captureScreenshot(window, 'setup-failure');
    throw e;
  }
});

async function handleLogin(window) {
  const loginOverlay = window.locator('#loginOverlay');
  const isVisible = await loginOverlay.isVisible().catch(() => false);

  if (!isVisible) {
    console.log('✓ Login overlay not visible (already logged in or test mode)');
    return;
  }

  console.log('🔑 Login overlay visible, authenticating...');

  try {
    await waitForElement(window, '#loginPasskeyInput');
    await window.locator('#loginPasskeyInput').fill(CONFIG.credentials.loginPasskey);
    await window.locator('#loginBtn').click();

    await window.locator('#desktopArea').waitFor({
      state: 'visible',
      timeout: CONFIG.timeouts.login,
    });

    console.log('✅ Login successful');
  } catch (e) {
    console.error('❌ Login failed:', e.message);
    await captureScreenshot(window, 'login-failure');
    throw e;
  }
}

test.afterAll(async () => {
  console.log('🧹 Cleaning up...');

  if (!app) {
    console.log('ℹ️ App was never started');
    return;
  }

  try {
    const closePromise = app.close();
    const timeoutPromise = new Promise((_, reject) =>
      setTimeout(() => reject(new Error('Close timeout')), 30000)
    );

    await Promise.race([closePromise, timeoutPromise]);
    console.log('✅ App closed gracefully');
  } catch (e) {
    console.warn(`⚠️ Graceful close failed: ${e.message}`);
    console.log('🔨 Force-killing process...');

    try {
      const proc = app.process?.();
      if (proc) {
        proc.kill('SIGTERM');
        console.log('✅ Process terminated');
      }
    } catch (killError) {
      console.error('❌ Force-kill failed:', killError.message);
    }
  }

  console.log('✅ Cleanup complete');
});

test.afterEach(async ({ title }) => {
  if (!window) {
    console.warn('⚠️ No window available for screenshot');
    return;
  }

  // Always capture screenshot on failure
  if (test.info().status === 'failed') {
    await captureScreenshot(window, `FAILED-${title}`);
  }
});

// ─── Shared Test Utilities ──────────────────────────────────────
async function getTestSpies() {
  try {
    return await window.evaluate(() => window.api.getTestSpies());
  } catch (e) {
    console.error('Failed to get test spies:', e.message);
    throw e;
  }
}

async function expectSpyIncremented(spyName, initialSpies) {
  const finalSpies = await getTestSpies();
  const initial = initialSpies[spyName];
  const final = finalSpies[spyName];

  expect(final).toBeGreaterThan(initial);
  console.log(
    `✓ Spy "${spyName}" incremented: ${initial} → ${final}`
  );
}

// ─── Test 1: DevTools ───────────────────────────────────────────
test('1️⃣ DevTools should be blocked', async () => {
  console.log('🧪 Test 1: Verifying DevTools is blocked...');

  try {
    const result = await window.evaluate(() => {
      try {
        window.openDevTools?.();
        return 'opened';
      } catch (e) {
        return 'blocked';
      }
    });

    expect(result).toBe('blocked');
    console.log('✅ DevTools properly blocked');
  } catch (e) {
    console.error('❌ Test 1 failed:', e.message);
    throw e;
  }
});

// ─── Test 2: Node.js APIs ───────────────────────────────────────
test('2️⃣ Node.js APIs should not be accessible', async () => {
  console.log('🧪 Test 2: Verifying Node.js APIs are isolated...');

  try {
    const result = await window.evaluate(() => {
      try {
        // Check for require
        if (typeof require !== 'undefined') {
          return 'require-found';
        }

        // Check for __dirname (Node.js global)
        if (typeof __dirname !== 'undefined') {
          return 'dirname-found';
        }

        return 'isolated';
      } catch (e) {
        return 'isolated';
      }
    });

    expect(result).toBe('isolated');
    console.log('✅ Node.js APIs properly isolated');
  } catch (e) {
    console.error('❌ Test 2 failed:', e.message);
    throw e;
  }
});

// ─── Test 3: IPC Restrictions ───────────────────────────────────
test('3️⃣ IPC calls should be restricted to exposed APIs', async () => {
  console.log('🧪 Test 3: Verifying IPC restrictions...');

  try {
    const result = await window.evaluate(() => {
      // Should have api object
      if (typeof window.api === 'undefined') {
        return 'api-missing';
      }

      // Should not have direct ipcRenderer
      if (typeof window.ipcRenderer !== 'undefined') {
        return 'ipc-exposed';
      }

      // Try calling undefined method
      try {
        window.api.nonExistentMethod?.();
        return 'unrestricted';
      } catch (e) {
        // Expected - method doesn't exist
        return 'restricted';
      }
    });

    expect(result).toBe('restricted');
    console.log('✅ IPC properly restricted');
  } catch (e) {
    console.error('❌ Test 3 failed:', e.message);
    throw e;
  }
});

// ─── Test 4: Breach Trigger (Mouse Score) ───────────────────────
test('4️⃣ Low mouse authenticity score should trigger breach', async () => {
  test.setTimeout(CONFIG.timeouts.window + 5000);
  console.log('🧪 Test 4: Triggering breach via mouse score...');

  try {
    const initialSpies = await getTestSpies();
    console.log('📊 Initial spy state:', initialSpies);

    await window.evaluate(() => window.api.mouseScore(0));
    console.log('→ Called mouseScore(0)');

    // Wait for breach sequence to complete
    await new Promise(resolve => setTimeout(resolve, 2500));

    await expectSpyIncremented('createBackupArchive', initialSpies);
    await expectSpyIncremented('backupToCloud', initialSpies);
    await expectSpyIncremented('onWipeRequest', initialSpies);
    await expectSpyIncremented('systemShutdown', initialSpies);

    console.log('✅ Breach sequence completed successfully');
  } catch (e) {
    console.error('❌ Test 4 failed:', e.message);
    throw e;
  }
});

// ─── Test 5: System & Internet Controls ──────────────────────────
test('5️⃣ System and internet controls should be callable', async () => {
  test.setTimeout(CONFIG.timeouts.window + 5000);
  console.log('🧪 Test 5: Testing system/internet controls...');

  try {
    const initialSpies = await getTestSpies();
    const controls = [
      { fn: 'disableSystemProcesses', spy: 'disableSystemProcesses' },
      { fn: 'blockInternet', spy: 'blockInternet' },
      { fn: 'enableSystemProcesses', spy: 'enableSystemProcesses' },
      { fn: 'allowInternet', spy: 'allowInternet' },
    ];

    for (const { fn, spy } of controls) {
      try {
        console.log(`  → Calling ${fn}...`);
        await window.evaluate((fname) => window.api[fname](), fn);
        await new Promise(resolve => setTimeout(resolve, 300));
        console.log(`  ✓ ${fn} executed`);
      } catch (e) {
        console.error(`  ✗ ${fn} failed:`, e.message);
        throw e;
      }
    }

    // Verify spies were incremented
    for (const { spy } of controls) {
      await expectSpyIncremented(spy, initialSpies);
    }

    console.log('✅ All controls executed successfully');
  } catch (e) {
    console.error('❌ Test 5 failed:', e.message);
    throw e;
  }
});

// ─── Test 6: Browser-Only Internet Access ────────────────────────
test('6️⃣ Internet access should be limited to browser window', async () => {
  test.setTimeout(CONFIG.timeouts.window + 10000);
  console.log('🧪 Test 6: Testing browser-only internet...');

  try {
    const initialSpies = await getTestSpies();

    // Open browser
    console.log('  → Opening browser...');
    const browserIcon = window.locator('.icon[data-app="browser"]');
    await browserIcon.waitFor({ state: 'visible', timeout: CONFIG.timeouts.element });
    await browserIcon.click();
    await new Promise(resolve => setTimeout(resolve, 500));

    console.log('  ✓ Browser window opened');
    await expectSpyIncremented('allowInternet', initialSpies);

    // Close browser
    console.log('  → Closing browser...');
    const closeBtnLocator = window.locator('#browserWindow .app-close');
    await closeBtnLocator.waitFor({ state: 'visible', timeout: CONFIG.timeouts.window });
    await closeBtnLocator.click();
    await new Promise(resolve => setTimeout(resolve, 500));

    console.log('  ✓ Browser window closed');
    await expectSpyIncremented('blockInternet', initialSpies);

    console.log('✅ Browser internet control working correctly');
  } catch (e) {
    console.error('❌ Test 6 failed:', e.message);
    throw e;
  }
});

// ─── Test 7: Self-Destruct on Exit ──────────────────────────────
test('7️⃣ Self-destruct should be scheduled on exit', async () => {
  console.log('🧪 Test 7: Testing self-destruct scheduler...');

  try {
    const initialSpies = await getTestSpies();

    console.log('  → Scheduling self-destruct...');
    await window.evaluate(() => window.api.selfDestructOnExit());
    await new Promise(resolve => setTimeout(resolve, 300));

    await expectSpyIncremented('selfDestructOnExit', initialSpies);

    console.log('✅ Self-destruct scheduler working correctly');
  } catch (e) {
    console.error('❌ Test 7 failed:', e.message);
    throw e;
  }
});

// ─── Test 8: System Shutdown on Breach ──────────────────────────
test('8️⃣ System shutdown should trigger on breach', async () => {
  test.setTimeout(CONFIG.timeouts.window + 5000);
  console.log('🧪 Test 8: Testing forced system shutdown...');

  try {
    const initialSpies = await getTestSpies();

    console.log('  → Forcing breach...');
    await window.evaluate(() => window.api.forceBreach());
    await new Promise(resolve => setTimeout(resolve, 2000));

    await expectSpyIncremented('systemShutdown', initialSpies);

    console.log('✅ System shutdown triggered correctly');
  } catch (e) {
    console.error('❌ Test 8 failed:', e.message);
    throw e;
  }
});

// ─── Test 9: API Isolation ──────────────────────────────────────
test('9️⃣ Preload API should be properly isolated', async () => {
  console.log('🧪 Test 9: Verifying preload API isolation...');

  try {
    const result = await window.evaluate(() => {
      const expectedMethods = [
        'readdir', 'readFile', 'writeFile', 'mkdir', 'unlink', 'rename',
        'execScript', 'openDialog', 'saveDialog', 'getCpu', 'getGpu',
        'enableTestMode', 'getTestSpies', 'disableTestMode',
        'blockInternet', 'allowInternet', 'shutdownSystem',
      ];

      const missing = expectedMethods.filter(
        method => typeof window.api[method] !== 'function'
      );

      if (missing.length > 0) {
        return { ok: false, missing };
      }

      // Verify we can't modify the API
      const original = window.api.getCpu;
      try {
        window.api.getCpu = () => 'hacked';
        if (window.api.getCpu !== original) {
          return { ok: false, reason: 'api-is-mutable' };
        }
      } catch (e) {
        // Expected - frozen object
      }

      return { ok: true };
    });

    if (!result.ok) {
      throw new Error(`API isolation failed: ${JSON.stringify(result)}`);
    }

    console.log('✅ API properly isolated and frozen');
  } catch (e) {
    console.error('❌ Test 9 failed:', e.message);
    throw e;
  }
});

// ─── Test 10: Configuration Management ───────────────────────────
test('🔟 Configuration should be retrievable and settable', async () => {
  console.log('🧪 Test 10: Testing config management...');

  try {
    const initialConfig = await window.evaluate(() => window.api.getConfig());
    console.log('  ✓ Retrieved initial config');

    expect(initialConfig).toHaveProperty('cloudUrl');
    expect(initialConfig).toHaveProperty('loginPasskey');
    expect(initialConfig).toHaveProperty('breachPasskey');
    expect(initialConfig).toHaveProperty('wipePassword');

    const newConfig = {
      cloudUrl: 'https://test.example.com/upload',
      loginPasskey: 'TEST-2026',
    };

    const updatedConfig = await window.evaluate(
      (cfg) => window.api.setConfig(cfg),
      newConfig
    );

    console.log('  ✓ Updated config');
    expect(updatedConfig.cloudUrl).toBe(newConfig.cloudUrl);
    expect(updatedConfig.loginPasskey).toBe(newConfig.loginPasskey);

    console.log('✅ Configuration management working correctly');
  } catch (e) {
    console.error('❌ Test 10 failed:', e.message);
    throw e;
  }
});
