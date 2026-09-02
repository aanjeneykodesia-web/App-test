// attack-bot.js – external bot that triggers mouse‑score breach
import { _electron as electron } from '@playwright/test';
import { expect } from '@playwright/test';

async function run() {
  // Launch the Electron app – either from source or built .exe
  const app = await electron.launch({
    args: ['.'],               // uses main.js from current folder
    // Or point to the built executable:
    // executablePath: './EicielOS-win32-x64/EicielOS.exe',
  });

  const window = await app.firstWindow();
  await window.waitForLoadState('domcontentloaded');

  // Enable test mode – all breach actions are simulated
 // await window.evaluate(() => window.api.enableTestMode());

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

  // Clean up
  await app.close();
  console.log('✅ Mouse‑score breach triggered and verified.');
}

run().catch(err => {
  console.error('❌ Attack failed:', err);
  process.exit(1);
});
