import { expect, test } from "@playwright/test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { actionButton, key, keyButton, loadPlugin, propertyInspector, unloadPlugin } from "./emulator";

// Runs against a build of streamdeck-osascript (macOS only): set
// OSASCRIPT_PLUGIN to its .sdPlugin folder or .streamDeckPlugin package.
const plugin = process.env.OSASCRIPT_PLUGIN;
const ACTION = "com.gabrielperales.osascript.action";

test.skip(!plugin, "set OSASCRIPT_PLUGIN to a streamdeck-osascript build");

test.beforeEach(async ({ request }) => loadPlugin(request, plugin!));
test.afterAll(async ({ request }) => unloadPlugin(request));

for (const [language, script] of [
  ["AppleScript", (marker: string) => `do shell script "printf ok > " & quoted form of "${marker}"`],
  [
    "JavaScript",
    (marker: string) =>
      `var app = Application.currentApplication(); app.includeStandardAdditions = true; app.doShellScript("printf ok > '${marker}'");`,
  ],
] as const) {
  test(`${language} typed in the Property Inspector runs on key press`, async ({ page, request }) => {
    const marker = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "osascript-e2e-")), "marker");

    await page.goto("/");
    await keyButton(page, 0, 0).click();
    await actionButton(page, ACTION).click();

    const pi = propertyInspector(page);
    // sdpi.css hides the real radio input behind a styled label; click the label.
    const radio = language === "AppleScript" ? "applescriptLang" : "javascriptLang";
    await pi.locator(`label[for=${radio}]`).click();
    await expect(pi.locator(`#${radio}`)).toBeChecked();
    await pi.locator("#scriptText").fill(script(marker));
    await expect
      .poll(async () => (await key(request, 0, 0))?.settings)
      .toEqual({ language, scriptText: script(marker) });

    await keyButton(page, 0, 0).click();
    await expect.poll(() => fs.existsSync(marker) && fs.readFileSync(marker, "utf8"), { timeout: 15_000 }).toBe("ok");
  });
}
