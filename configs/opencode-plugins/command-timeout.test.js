// node --test — patterns for the BlarAI fleet command-timeout plugin.
// Focus: the #687 BROWSER_OPEN_RE must neutralize a foreground-browser open WITHOUT over-matching
// ordinary commands. Run: node --test command-timeout.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { BROWSER_OPEN_RE } from "./command-timeout.js";

test("BROWSER_OPEN_RE matches a foreground browser / URL open", () => {
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
    assert.ok(BROWSER_OPEN_RE.test(c), `should MATCH (browser open): ${c}`);
  }
});

test("BROWSER_OPEN_RE does NOT over-match non-open or non-URL commands", () => {
  for (const c of [
    "start notepad",                 // start, but not a URL
    "start .",                        // open the folder, no URL
    "npm start",                      // a dev server (BLOCKING_RE's job, not this)
    "node src/server.js",            // a server (BLOCKING_RE's job)
    "curl http://localhost:3000",    // a HEADLESS check -- the sanctioned alternative, must stay
    "curl -I https://x",
    "python -m http.server",         // a server start, no open verb
    "git restart",                   // contains 'start' as a substring, not the verb
  ]) {
    assert.ok(!BROWSER_OPEN_RE.test(c), `should NOT match: ${c}`);
  }
});
