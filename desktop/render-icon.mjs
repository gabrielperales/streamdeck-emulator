#!/usr/bin/env node
// Renders desktop/app-icon.svg to desktop/app-icon.png (1024×1024, transparent
// background) with the Chromium that the e2e tests use. Then regenerate the
// app icons with `mix ex_tauri.icon desktop/app-icon.png`.
//
//   (cd e2e && npm ci && npx playwright install chromium)
//   node desktop/render-icon.mjs

import { createRequire } from "node:module";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const require = createRequire(new URL("../e2e/package.json", import.meta.url));
const { chromium } = require("@playwright/test");

const svg = fileURLToPath(new URL("app-icon.svg", import.meta.url));
const png = fileURLToPath(new URL("app-icon.png", import.meta.url));
const size = 1024;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
await page.setContent(
  `<style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>` +
    fs.readFileSync(svg, "utf8"),
);
await page.locator("svg").screenshot({ path: png, omitBackground: true });
await browser.close();

console.log(`wrote ${png}`);
