// node --test — patterns for the BlarAI fleet path-normalize plugin (#670).
// Focus: the plugin's bash hook must FIX the coder's mangled `cd C:\...` WITHOUT touching
// anything that is not a Windows drive-path token (bash escapes, regex backslashes, forward-slash paths).
// The tests drive the REAL hook through the plugin factory (the loader-safe seam — #759 recon:
// opencode's loader rejects any non-function named export, so helpers are no longer exported).
// Run: node --test path-normalize.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import PathNormalizePlugin from "./path-normalize.js";

const hooks = await PathNormalizePlugin();
const before = hooks["tool.execute.before"];

/** Run a command through the real bash hook; returns the (possibly rewritten) command. */
async function norm(command, tool = "bash") {
  const output = { args: { command } };
  await before({ tool }, output);
  return output.args.command;
}

test("plugin factory returns the tool.execute.before hook", () => {
  assert.equal(typeof before, "function");
});

test("normalizes the exact failing command (the #670 repro)", async () => {
  const input = "cd C:\\Users\\mrbla\\projects\\testproject1-create-webpage-c1 && npm test";
  const want = "cd C:/Users/mrbla/projects/testproject1-create-webpage-c1 && npm test";
  assert.equal(await norm(input), want);
});

test("handles MULTIPLE drive-path tokens in one command", async () => {
  assert.equal(await norm("cp C:\\a\\b.txt C:\\c\\d.txt"), "cp C:/a/b.txt C:/c/d.txt");
});

test("normalizes a drive path inside double quotes (still safe + correct)", async () => {
  const input = 'cd "C:\\Program Files\\node" && node -v';
  // The token stops at the space inside the quotes; the FIRST segment is normalized, which is enough
  // to make the path valid in git-bash. (Quoted paths with spaces are rare in the coder's worktree.)
  assert.equal(await norm(input), 'cd "C:/Program Files\\node" && node -v');
});

test("lowercase drive letter is handled", async () => {
  assert.equal(await norm("ls d:\\tmp\\x"), "ls d:/tmp/x");
});

test("idempotent: an already-forward-slash path is untouched", async () => {
  const input = "cd C:/Users/mrbla/projects/foo && npm test";
  assert.equal(await norm(input), input);
});

test("a mixed-slash drive path is fully forward-slashed", async () => {
  assert.equal(await norm("cat C:\\Users/mrbla\\file"), "cat C:/Users/mrbla/file");
});

test("DOES NOT touch bash escapes / regex backslashes (no drive prefix)", async () => {
  for (const c of [
    "grep -E '\\bword\\b' file.txt",         // regex word boundaries
    "sed 's/\\n/ /g' in.txt",                // escaped newline in sed
    "echo a\\tb",                             // a tab escape
    "printf '%s\\n' done",                    // escaped newline in printf
    "find . -name '*.js'",                    // forward-slash only
    "npm test",                               // no path at all
    "node --test",                            // no path
  ]) {
    assert.equal(await norm(c), c, `should be UNCHANGED: ${c}`);
  }
});

test("does not mangle a UNC path (no drive letter) — left alone, not corrupted", async () => {
  const input = "ls \\\\server\\share\\dir";   // \\server\share\dir
  assert.equal(await norm(input), input);
});

test("non-bash tools are never touched", async () => {
  const output = { args: { command: "cd C:\\Users\\mrbla" } };
  await before({ tool: "edit" }, output);
  assert.equal(output.args.command, "cd C:\\Users\\mrbla");
});

test("empty / missing args are returned untouched (no throw)", async () => {
  await before({ tool: "bash" }, { args: { command: "" } });
  await before({ tool: "bash" }, { args: {} });
  await before({ tool: "bash" }, {});
});
