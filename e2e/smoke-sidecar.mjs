#!/usr/bin/env node
// Smoke test for a packaged backend (the Burrito-wrapped sidecar the desktop
// app runs): starts it, loads the echo fixture as a Node.js plugin through the
// control API, presses a key and checks what the plugin drew. Runs the same on
// macOS, Linux and Windows.
//
//   node e2e/smoke-sidecar.mjs burrito_out/streamdeck_emulator_desktop-<triple>[.exe]

import { spawn, execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const sidecar = process.argv[2];
if (!sidecar || !fs.existsSync(sidecar)) {
  console.error("usage: node e2e/smoke-sidecar.mjs <path to the backend executable>");
  process.exit(2);
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const port = 4123;
const base = `http://127.0.0.1:${port}`;
const json = { "content-type": "application/json" };

// The echo fixture as a JavaScript plugin, so it runs on every OS.
function nodeEcho() {
  const dir = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sde-smoke-")), "echo.sdPlugin");
  fs.cpSync(path.join(root, "test/fixtures/echo.sdPlugin"), dir, { recursive: true });
  fs.renameSync(path.join(dir, "plugin"), path.join(dir, "plugin.js"));
  const manifestPath = path.join(dir, "manifest.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  manifest.CodePath = "plugin.js";
  fs.writeFileSync(manifestPath, JSON.stringify(manifest));
  return dir;
}

async function until(description, check, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try {
      last = await check();
      if (last) return last;
    } catch (error) {
      last = error;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`timed out waiting for ${description} (last: ${last})`);
}

const state = async () => (await fetch(`${base}/api/state`)).json();
const title = async () => (await state()).keys.find((k) => k.column === 0 && k.row === 0)?.title;

// --no-halt as the Tauri shell passes it: Burrito boots the BEAM through
// Elixir's CLI, which otherwise stops the VM once it has nothing left to run.
const backend = spawn(path.resolve(sidecar), ["--no-halt"], {
  // Its own process group, so stop() reaches the BEAM behind Burrito's launcher.
  detached: process.platform !== "win32",
  env: {
    ...process.env,
    // Unpack into a fresh directory instead of the one an installed app uses.
    STREAMDECK_EMULATOR_DESKTOP_INSTALL_DIR: fs.mkdtempSync(path.join(os.tmpdir(), "sde-burrito-")),
    PORT: String(port),
    PHX_SERVER: "true",
    PHX_HOST: "localhost",
    SECRET_KEY_BASE: randomBytes(48).toString("base64"),
  },
  stdio: ["ignore", "inherit", "inherit"],
});

function stop() {
  if (backend.exitCode !== null) return;
  if (process.platform === "win32") {
    try {
      execFileSync("taskkill", ["/PID", String(backend.pid), "/T", "/F"], { stdio: "ignore" });
    } catch {}
  } else {
    try {
      process.kill(-backend.pid, "SIGTERM");
    } catch {}
  }
}

try {
  // The first run unpacks the release, which takes a while.
  await until("the backend to answer", async () => (await fetch(`${base}/api/state`)).ok, 180_000);
  console.log("backend is up");

  const load = await fetch(`${base}/api/plugin`, {
    method: "POST",
    headers: json,
    body: JSON.stringify({
      path: nodeEcho(),
      layout: { keys: [{ column: 0, row: 0, action: "com.example.echo.action", settings: { title: "smoke" } }] },
    }),
  });
  if (!load.ok) throw new Error(`loading the plugin failed: ${load.status} ${await load.text()}`);

  await until("the plugin to connect", async () => (await state()).plugin?.connected);
  await until('the title "smoke"', async () => (await title()) === "smoke");
  console.log("plugin connected and drew its title");

  await fetch(`${base}/api/keys/0/0/press`, { method: "POST", headers: json, body: "{}" });
  await until('the title "pressed 1"', async () => (await title()) === "pressed 1");
  console.log("key press reached the plugin");

  await fetch(`${base}/api/plugin`, { method: "DELETE", headers: json });
  console.log("smoke test passed");
} catch (error) {
  console.error(`smoke test failed: ${error.message}`);
  process.exitCode = 1;
} finally {
  stop();
}
