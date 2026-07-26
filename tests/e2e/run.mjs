#!/usr/bin/env node
// E2E runner. Boots `vite` in mock mode, drives the browser via the Chrome
// DevTools Protocol (CDP) to evaluate each scenario body from scenarios.mjs,
// and exits non-zero on the first failure.
//
// Claude Code can run the same scenarios through the Claude Preview MCP
// (`preview_eval`) without a separate binary — point it at tests/e2e/scenarios.mjs
// and paste each scenario's `body` into `preview_eval`.

import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { createRequire } from "node:module";
import { scenarios } from "./scenarios.mjs";

const PORT = 1420;
const BASE = `http://localhost:${PORT}`;

async function waitFor(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) return true;
    } catch {}
    await sleep(200);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

async function launchChromium() {
  const require = createRequire(import.meta.url);
  let puppeteer;
  try {
    puppeteer = require("puppeteer");
  } catch {
    throw new Error(
      "puppeteer is not installed. Install it with `npm i -D puppeteer` or run scenarios via the Claude Preview MCP instead.",
    );
  }
  const browser = await puppeteer.launch({ headless: "new" });
  return { browser, page: await browser.newPage() };
}

async function runScenario(page, spec) {
  await page.reload({ waitUntil: "networkidle0" });
  const body = spec.body.trim();
  const result = await page.evaluate(`(() => ${body})()`);
  return result;
}

async function main() {
  // A stray dev server (e.g. one left behind by `tauri dev`) would keep port
  // 1420 and serve the *non-mock* build, making every scenario fail for a
  // reason that has nothing to do with the code under test. Refuse to guess.
  try {
    const res = await fetch(BASE, { signal: AbortSignal.timeout(1000) });
    if (res.ok) {
      console.error(
        `Something is already serving ${BASE}. Stop it first ` +
          `(\`lsof -ti:${PORT} | xargs kill\`) — the e2e run needs its own ` +
          `mock-mode dev server.`,
      );
      process.exitCode = 2;
      return;
    }
  } catch {
    // Nothing listening, which is what we want.
  }

  const vite = spawn("npm", ["run", "dev:mock"], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env },
  });
  const pending = [];
  vite.stdout.on("data", (b) => pending.push(`[vite] ${b}`));
  vite.stderr.on("data", (b) => pending.push(`[vite!] ${b}`));

  try {
    await waitFor(BASE, 15_000);
    const { browser, page } = await launchChromium();
    let failed = 0;
    const rows = [];
    for (const spec of scenarios) {
      try {
        await page.goto(BASE, { waitUntil: "networkidle0" });
        const result = await runScenario(page, spec);
        const mark = result.pass ? "PASS" : "FAIL";
        if (!result.pass) failed++;
        rows.push({ id: spec.id, mark, detail: result.detail });
      } catch (err) {
        failed++;
        rows.push({ id: spec.id, mark: "ERROR", detail: String(err) });
      }
    }
    await browser.close();
    console.log("\nScenario results:");
    for (const r of rows) console.log(`  [${r.mark}] ${r.id}  ${JSON.stringify(r.detail)}`);
    if (failed > 0) process.exitCode = 1;
  } catch (err) {
    console.error("Runner crashed:", err);
    console.error("vite output follows:\n" + pending.join(""));
    process.exitCode = 2;
  } finally {
    vite.kill("SIGINT");
  }
}

main();
