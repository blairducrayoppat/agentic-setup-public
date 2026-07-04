// node --test — patterns for the BlarAI fleet path-normalize plugin (#670).
// Focus: normalizeWindowsDrivePaths must FIX the coder's mangled `cd C:\...` WITHOUT touching
// anything that is not a Windows drive-path token (bash escapes, regex backslashes, forward-slash paths).
// Run: node --test path-normalize.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeWindowsDrivePaths } from "./path-normalize.js";

test("normalizes the exact failing command (the #670 repro)", () => {
  const input = "cd C:\\Users\\mrbla\\projects\\testproject1-create-webpage-c1 && npm test";
  const want = "cd C:/Users/mrbla/projects/testproject1-create-webpage-c1 && npm test";
  assert.equal(normalizeWindowsDrivePaths(input), want);
});

test("handles MULTIPLE drive-path tokens in one command", () => {
  const input = "cp C:\\a\\b.txt C:\\c\\d.txt";
  assert.equal(normalizeWindowsDrivePaths(input), "cp C:/a/b.txt C:/c/d.txt");
});

test("normalizes a drive path inside double quotes (still safe + correct)", () => {
  const input = 'cd "C:\\Program Files\\node" && node -v';
  // The token stops at the space inside the quotes; the FIRST segment is normalized, which is enough
  // to make the path valid in git-bash. (Quoted paths with spaces are rare in the coder's worktree.)
  assert.equal(normalizeWindowsDrivePaths(input), 'cd "C:/Program Files\\node" && node -v');
});

test("lowercase drive letter is handled", () => {
  assert.equal(normalizeWindowsDrivePaths("ls d:\\tmp\\x"), "ls d:/tmp/x");
});

test("idempotent: an already-forward-slash path is untouched", () => {
  const input = "cd C:/Users/mrbla/projects/foo && npm test";
  assert.equal(normalizeWindowsDrivePaths(input), input);
});

test("a mixed-slash drive path is fully forward-slashed", () => {
  assert.equal(normalizeWindowsDrivePaths("cat C:\\Users/mrbla\\file"), "cat C:/Users/mrbla/file");
});

test("DOES NOT touch bash escapes / regex backslashes (no drive prefix)", () => {
  for (const c of [
    "grep -E '\\bword\\b' file.txt",         // regex word boundaries
    "sed 's/\\n/ /g' in.txt",                // escaped newline in sed
    "echo a\\tb",                             // a tab escape
    "printf '%s\\n' done",                    // escaped newline in printf
    "find . -name '*.js'",                    // forward-slash only
    "npm test",                               // no path at all
    "node --test",                            // no path
  ]) {
    assert.equal(normalizeWindowsDrivePaths(c), c, `should be UNCHANGED: ${c}`);
  }
});

test("does not mangle a UNC path (no drive letter) — left alone, not corrupted", () => {
  const input = "ls \\\\server\\share\\dir";   // \\server\share\dir
  assert.equal(normalizeWindowsDrivePaths(input), input);
});

test("non-string / empty inputs are returned as-is", () => {
  assert.equal(normalizeWindowsDrivePaths(""), "");
  assert.equal(normalizeWindowsDrivePaths(undefined), undefined);
  assert.equal(normalizeWindowsDrivePaths(null), null);
});
