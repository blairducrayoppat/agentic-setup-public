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

test("a trailing & (detached process) is refused outright (#1357)", async () => {
  for (const c of [
    // THE MEASURED COMMAND. battery-b9-pottery-site-create-piece-list-page-20260809-143821 ran this
    // with args.timeout correctly clamped to 10000 and it still hung 602 s.
    "cd C:/Users/mrbla/agentic-setup/state/worktrees/battery-b9-pottery-site-create-piece-list-page && node src/server.js &",
    "node src/server.js &",
    "npm start &",
    "python -m http.server 8000 &",
    "node app.js  &",          // trailing whitespace after the ampersand
    "./run-me.sh &",           // not server-shaped at all -- detaching is the defect, not the program
  ]) {
    const args = await run(c, 10000);
    assert.ok(
      args.command.startsWith('echo "[headless build] backgrounding'),
      `should be REFUSED (detached): ${c}`,
    );
  }
});

test("&& chains and redirects are NOT mistaken for backgrounding (#1357)", async () => {
  for (const c of [
    "cd app && npm test",                 // the overwhelmingly common shape -- must survive
    "npm run build && npm test",
    "node --test tests/ 2>&1",            // redirect, does not end on the ampersand
    "node --test tests/ >out.txt 2>&1",
    "grep -r 'R&D' src/",                 // an ampersand that is just data
    "npm test",
  ]) {
    const args = await run(c, 10000);
    assert.equal(args.command, c, `should NOT be refused: ${c}`);
  }
});

test("TOGGLE PROOF: the probe cap alone would have let the measured command through", async () => {
  // A green suite is worth nothing here unless the new check is what catches the real incident.
  // Before this fix the ONLY branch that could fire for this command was the probe cap -- which is
  // exactly what DID fire on 2026-08-09, and the command still ran 602 s.
  const measured =
    "cd C:/Users/mrbla/agentic-setup/state/worktrees/battery-b9-pottery-site-create-piece-list-page && node src/server.js &";
  const args = await run(measured, 600000);
  assert.notEqual(args.timeout, SERVER_PROBE_MS,
    "the detach refusal must fire INSTEAD of the probe cap -- if this command is merely probe-capped, the fix is inert and the 602 s hang can recur");
  assert.ok(args.command.startsWith('echo "[headless build] backgrounding'));
});

test("node app.js / index.js entry points get the probe cap -- the measured BLOCKING_RE gap (#1357)", async () => {
  for (const c of ["node app.js", "node src/app.js", "node index.js", "node src/index.js"]) {
    const args = await run(c, 600000);
    assert.equal(args.timeout, SERVER_PROBE_MS, `should probe-cap: ${c}`);
  }
});

test("ordinary node scripts are NOT probe-capped by the new entry-point pattern", async () => {
  for (const c of [
    "node --test tests/app.test.js",   // a TEST that mentions app.js
    "node scripts/migrate.js",
    "node cli.js --help",
    "cat src/app.js",                  // not even node
  ]) {
    const args = await run(c, 60000);
    assert.equal(args.timeout, 60000, `should keep its own timeout: ${c}`);
  }
});

test("non-bash tools are never touched", async () => {
  const output = { args: { command: "npm start", timeout: 999999 } };
  await before({ tool: "edit" }, output);
  assert.equal(output.args.timeout, 999999);
});
