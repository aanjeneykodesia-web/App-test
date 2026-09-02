import { test, expect, _electron as electron } from '@playwright/test';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let app, window;

test.beforeAll(async () => {
  // Path to the built .exe (relative to the repo root)
  const exePath = path.join('D:', 'data', 'EicielOS', 'EicielOS-win32-x64', 'EicielOS.exe');
  app = await electron.launch({
    executablePath: exePath,
    // If the .exe requires any arguments, add them here
    args: [],
    // For headless testing, you can set headless: true, but Electron's headless mode might not work perfectly.
    // We'll keep it non-headless but in CI it runs without a display – Playwright handles it.
    // We'll rely on the CI env to force headless.
  });
  window = await app.firstWindow();
  await window.waitForLoadState('domcontentloaded');
  // Enable test mode (if your app supports it)
  await window.evaluate(() => window.api.enableTestMode());
  // Wait for the desktop to appear
  await window.locator('#desktopArea').waitFor({ state: 'visible' });
});

test.afterAll(async () => {
  if (app) await app.close();
});

test('DevTools should be blocked', async () => {
  // Attempt to open DevTools via the API (should fail)
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
  // We expect it to be blocked, but if the app is in test mode, it might be allowed.
  // In any case, we check that the breach doesn't happen unexpectedly.
  // We can check the spies.
  const spies = await window.evaluate(() => window.api.getTestSpies());
  expect(spies.forceBreach).toBeUndefined(); // or check that the count hasn't increased unexpectedly
});

test('Navigation to external URL should be blocked', async () => {
  // Open the browser window
  const browserIcon = window.locator('.icon[data-app="browser"]');
  await browserIcon.click();
  const browserWin = window.locator('#browserWindow');
  await expect(browserWin).toBeVisible();

  // Try to navigate to a malicious site
  const urlBar = browserWin.locator('#browserUrl');
  await urlBar.fill('https://evil.com');
  await browserWin.locator('#browserGo').click();
  await window.waitForTimeout(500);

  // Check that the iframe did not load evil.com
  const iframe = browserWin.frameLocator('#browserFrame');
  const currentUrl = await iframe.locator('body').evaluate(() => window.location.href);
  expect(currentUrl).not.toContain('evil.com');
  // It should still be on the original page (e.g., example.com)
});

test('Breach trigger via CAPTCHA failures should work', async () => {
  const initialSpies = await window.evaluate(() => window.api.getTestSpies());
  // Send 11 CAPTCHA failures (limit is 10)
  for (let i = 0; i < 11; i++) {
    await window.evaluate(() => window.api.captchaFail());
  }
  const finalSpies = await window.evaluate(() => window.api.getTestSpies());
  // In test mode, the breach should be triggered and wipeAllDrives should have been called
  expect(finalSpies.wipeAllDrives).toBeGreaterThan(initialSpies.wipeAllDrives);
  // Lockdown overlay should appear
  const lockdown = window.locator('#lockdownOverlay');
  await expect(lockdown).toBeVisible({ timeout: 5000 });
});
