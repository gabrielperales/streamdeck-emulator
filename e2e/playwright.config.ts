import { defineConfig } from "@playwright/test";

// The emulator runs once for the whole suite with no plugin; each test file
// loads the plugin it needs through the control API. One plugin runs at a
// time, so tests run serially.
const port = Number(process.env.EMULATOR_HTTP_PORT ?? 4100);

export default defineConfig({
  testDir: "./tests",
  workers: 1,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
  },
  webServer: {
    command: `mix streamdeck.run --http-port ${port}`,
    cwd: "..",
    url: `http://127.0.0.1:${port}/api/state`,
    reuseExistingServer: !process.env.CI,
    // The first run may compile the app and build its assets.
    timeout: 180_000,
  },
});
