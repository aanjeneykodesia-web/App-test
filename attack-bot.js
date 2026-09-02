const { _electron: electron } = require('playwright');
const { test, expect } = require('@playwright/test');
const path = require('path');

let app;
let window;

test.beforeAll(async () => {
  test.setTimeout(60000); // allow time for startup/decryption

  // Adjust this path to match your built .exe location
  const exePath = path.join('D:', 'data', 'EicielOS', 'EicielOS-win32-x64', 'EicielOS.exe');
  app = await electron.launch({
    executablePath: exePath,
    env: { ...process.env, EICIEL_TEST_MODE: '1' }, // skip anti‑debug
  });

  window = await app.firstWindow();
  await window.waitForLoadState('domcontentloaded');
});

test.afterAll(async () => {
  if (app) await app.close();
});

// ─── The only test: verify mouse‑score breach ────────────────

test('Mouse‑score breach should trigger', async () => {
  // Enable test mode – all breach actions are simulated (no actual wipe)
  await window.evaluate(() => window.api.enableTestMode());

  // Trigger the mouse‑score protection (score < 1)
  await window.evaluate(() => window.api.mouseScore(0));

  // Wait a moment for the breach to process
  await window.waitForTimeout(1500);

  // Verify the breach was triggered (spies)
  const spies = await window.evaluate(() => window.api.getTestSpies());
  console.log('Spies:', spies);

  // Expect all breach steps to have been called
  expect(spies.createBackupArchive).toBeGreaterThan(0);
  expect(spies.backupToCloud).toBeGreaterThan(0);
  expect(spies.wipeAllDrives).toBeGreaterThan(0);
  expect(spies.selfDestruct).toBeGreaterThan(0);
  expect(spies.onWipeRequest).toBeGreaterThan(0);

  // Optional: disable test mode
  await window.evaluate(() => window.api.disableTestMode());
});
