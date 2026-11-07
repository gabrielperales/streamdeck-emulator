import { expect, test } from "@playwright/test";
import {
  actionButton,
  ECHO_ACTION,
  ECHO_PLUGIN,
  key,
  keyButton,
  keyTitle,
  loadPlugin,
  placeAction,
  propertyInspector,
  unloadPlugin,
} from "./emulator";

// The echo fixture plugin sets the key title from settings.title, shows
// "pressed <n>" on keyDown and answers sendToPlugin with sendToPropertyInspector.

test.beforeEach(async ({ request }) => loadPlugin(request, ECHO_PLUGIN));
test.afterAll(async ({ request }) => unloadPlugin(request));

test("pressing a key in the UI reaches the plugin", async ({ page }) => {
  await page.goto("/");
  await keyButton(page, 0, 0).click(); // selects the empty key
  await actionButton(page, ECHO_ACTION).click();

  await keyButton(page, 0, 0).click();
  await expect(keyTitle(page, 0, 0)).toHaveText("pressed 1");
  await expect(keyButton(page, 0, 0).locator("[data-feedback=ok]")).toBeVisible();
});

test("settings edited in the Property Inspector reach the plugin", async ({ page, request }) => {
  await placeAction(request, 2, 1, ECHO_ACTION, { title: "start" });

  await page.goto("/");
  await expect(keyTitle(page, 2, 1)).toHaveText("start");
  await keyButton(page, 2, 1).click();

  const pi = propertyInspector(page);
  await expect(pi.locator("#title")).toHaveValue("start");
  await pi.locator("#title").fill("from the PI");

  // setSettings → stored → didReceiveSettings → the plugin sets the title.
  await expect(keyTitle(page, 2, 1)).toHaveText("from the PI");
  await expect.poll(async () => (await key(request, 2, 1))?.settings).toEqual({ title: "from the PI" });
});

test("the plugin and its Property Inspector can message each other", async ({ page, request }) => {
  await placeAction(request, 4, 2, ECHO_ACTION);
  await page.goto("/");
  await keyButton(page, 4, 2).click();

  const pi = propertyInspector(page);
  await pi.getByRole("button", { name: "Ping plugin" }).click();
  await expect(pi.locator("#received")).toContainText('"event":"sendToPropertyInspector"');
  await expect(pi.locator("#received")).toContainText('"payload":{"echo":{"ping":true}}');
});

test("the plugin is relaunched after a crash and gets its keys back", async ({ page, request }) => {
  await placeAction(request, 1, 1, ECHO_ACTION, { title: "kept" });
  await page.goto("/");
  await expect(keyTitle(page, 1, 1)).toHaveText("kept");
  await keyButton(page, 1, 1).click();
  await expect(keyTitle(page, 1, 1)).toHaveText("pressed 1");

  const { plugin } = await (await request.get("/api/state")).json();
  process.kill(plugin.os_pid, "SIGKILL");

  await expect(page.locator("#plugin-status")).toContainText("1 restarts");
  await expect(keyTitle(page, 1, 1)).toHaveText("kept");
});
