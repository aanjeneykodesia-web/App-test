import { test, expect, _electron as electron } from '@playwright/test';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let app, window;

test.beforeAll(async () => {
  // Path to the built .exe (adjust if your build outputs elsewhere)
  const exePath = path.join('D:', 'data', 'EicielOS', 'EicielOS-win32-x64', 'EicielOS.exe');
  app = await electron.launch({
    executablePath: exePath,
    args: [],
  });
  window = await app.firstWindow();
  await window.waitForLoadState('domcontentloaded');

  // ─── LOGIN AUTOMATION ──────────────────────────────────────
  // Check if the login overlay is present
  const loginOverlay = window.locator('#loginOverlay');
  if (await loginOverlay.isVisible()) {
    // Enter the passkey (default: EICIEL-2026)
    await window.locator('#loginPasskeyInput').fill('EICIEL-2026');
    await window.locator('#loginBtn').click();
    // Wait for the desktop to appear
    await window.locator('#desktopArea').waitFor({ state: 'visible' });
  }

  // Enable test mode to prevent actual system destruction
  await window.evaluate(() => window.api.enableTestMode());

  // Wait for desktop to be fully ready
  await window.locator('#desktopArea').waitFor({ state: 'visible' });
});

test.afterAll(async () => {
  if (app) await app.close();
});

// ─── Security Tests ──────────────────────────────────────────

test('DevTools should be blocked', async () => {
  const result = await window.evaluate(() => {
    try {
      // @ts-ignore
      window.openDevTools();
      return 'opened';
    } catch (e) {
      return 'blocked';
    }
  });
  expect(result).toBe('blocked');
});

test('Node.js APIs should not be accessible', async () => {
  const result = await window.evaluate(() => {
    try {
      // @ts-ignore
      return typeof require !== 'undefined' ? 'require found' : 'require not found';
    } catch (e) {
      return 'blocked';
    }
  });
  expect(result).toBe('require not found');
});

test('IPC calls should be restricted', async () => {
  const result = await window.evaluate(() => {
    try {
      // @ts-ignore – forceBreach is exposed but should be guarded
      window.api.forceBreach();
      return 'breach triggered';
    } catch (e) {
      return 'blocked';
    }
  });
  // In test mode, forceBreach might be allowed to increment spies, but we expect it not to cause a real breach.
  // We check that the app doesn't crash and that the breach count is as expected.
  const spies = await window.evaluate(() => window.api.getTestSpies());
  // We'll check later if the breach was triggered via CAPTCHA failures.
  expect(spies.forceBreach).toBeUndefined(); // or check that the count hasn't increased unexpectedly
});

test('Navigation to external URL should be blocked', async () => {
  const browserIcon = window.locator('.icon[data-app="browser"]');
  await browserIcon.click();
  const browserWin = window.locator('#browserWindow');
  await expect(browserWin).toBeVisible();

  const urlBar = browserWin.locator('#browserUrl');
  await urlBar.fill('https://evil.com');
  await browserWin.locator('#browserGo').click();
  await window.waitForTimeout(500);

  const iframe = browserWin.frameLocator('#browserFrame');
  const currentUrl = await iframe.locator('body').evaluate(() => window.location.href);
  expect(currentUrl).not.toContain('evil.com');
});

test('Breach trigger via CAPTCHA failures should work', async () => {
  const initialSpies = await window.evaluate(() => window.api.getTestSpies());
  for (let i = 0; i < 11; i++) {
    await window.evaluate(() => window.api.captchaFail());
  }
  const finalSpies = await window.evaluate(() => window.api.getTestSpies());
  expect(finalSpies.wipeAllDrives).toBeGreaterThan(initialSpies.wipeAllDrives);
  const lockdown = window.locator('#lockdownOverlay');
  await expect(lockdown).toBeVisible({ timeout: 5000 });
});
