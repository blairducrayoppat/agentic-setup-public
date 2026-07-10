// node --test — patterns for the BlarAI fleet command-timeout plugin.
// Focus: the #687 browser-open neutralization must fire WITHOUT over-matching ordinary commands,
// the #688 server probe must cap blocking servers, and the base 5-min clamp must hold.
// The tests drive the REAL hook through the plugin factory (the loader-safe seam — #759 recon:
// opencode's loader rejects any non-function named export, so the regexes are no longer exported).
// Run: node --test command-timeout.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import CommandTimeoutPlugin from "./command-timeout.js";

const MAX_COMMAND_MS = 300000;   // default cap (OPENCODE_BASH_MAX_MS unset in tests)
const SERVER_PROBE_MS = 10000;   // default probe (OPENCODE_SERVER_PROBE_MS unset in tests)

const hooks = await CommandTimeoutPlugin();
const before = hooks["tool.execute.before"];

/** Run a command through the real bash hook; returns the mutated args. */
async function run(command, timeout = undefined, tool = "bash") {
  const output = { args: timeout === undefined ? { command } : { command, timeout } };
  await before({ tool }, output);
  return output.args;
}

test("plugin factory returns the tool.execute.before hook", () => {
  assert.equal(typeof before, "function");
});

test("a foreground browser / URL open is rewritten to the harmless note (#687)", async () => {
  for (const c of [
    "start http://localhost:3000",          // the exact 30B command (#687)
    "open https://example.com",
    "xdg-open http://x",
    "explorer.exe http://y",
    "explorer http://y",
    "cmd /c start http://z",
    "sensible-browser https://q",
    "START HTTP://X",                        // case-insensitive
    "cd app && start http://localhost:8080", // mid-chain after &&
  ]) {
    const args = await run(c);
    assert.ok(args.command.startsWith('echo "[headless build]'), `should be REWRITTEN (browser open): ${c}`);
  }
});

test("non-open / non-URL commands are NOT rewritten", async () => {
  for (const c of [
    "start notepad",                 // start, but not a URL
    "start .",                        // open the folder, no URL
    "npm test",
    "curl http://localhost:3000",    // a HEADLESS check -- the sanctioned alternative, must stay
    "curl -I https://x",
    "git restart",                   // contains 'start' as a substring, not the verb
  ]) {
    const args = await run(c);
    assert.equal(args.command, c, `should NOT be rewritten: ${c}`);
  }
});

test("a blocking server/watcher gets the short probe cap (#688)", async () => {
  for (const c of [
    "npm start",
    "npm run dev",
    "node src/server.js",
    "python -m http.server",
  ]) {
    const args = await run(c, 600000);
    assert.equal(args.timeout, SERVER_PROBE_MS, `should probe-cap: ${c}`);
  }
});

test("a self-bounded server command (timeout N ...) is left alone", async () => {
  const args = await run("timeout 30 npm start", 45000);
  assert.equal(args.timeout, 45000);
});

test("unset / oversized timeouts clamp to the 5-min cap; smaller stays", async () => {
  assert.equal((await run("npm test")).timeout, MAX_COMMAND_MS);              // unset -> cap
  assert.equal((await run("npm test", 900000)).timeout, MAX_COMMAND_MS);      // above -> cap
  assert.equal((await run("npm test", -5)).timeout, MAX_COMMAND_MS);          // invalid -> cap
  assert.equal((await run("npm test", 20000)).timeout, 20000);                // tighter stays
});

test("non-bash tools are never touched", async () => {
  const output = { args: { command: "npm start", timeout: 999999 } };
  await before({ tool: "edit" }, output);
  assert.equal(output.args.timeout, 999999);
});
