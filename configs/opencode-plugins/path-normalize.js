// path-normalize.js — BlarAI fleet opencode plugin.
//
// PURPOSE: stop the local coder from mangling its own Windows paths in bash commands.
//
// WHY (#670, reproduced on-hardware 2026-06-30): opencode's bash tool runs git-bash
// (`fleet-lib.ps1` pins $env:SHELL to C:\Program Files\Git\bin\bash.exe). In git-bash/MSYS a
// backslash is an ESCAPE character, so an UNQUOTED Windows path on the command line has its
// backslashes eaten: the coder emitted
//     cd C:\Users\mrbla\projects\testproject1-create-webpage-c1 && npm test
// and git-bash ran
//     cd: C:Usersmrblaprojectstestproject1-create-webpage-c1: No such file or directory
// so the coder could never enter its own worktree, its tests never ran, it stalled, the idle
// breaker killed it before it committed, and the worktree sweep discarded the uncommitted work.
//
// FIX: in `tool.execute.before` for the bash/shell tool, rewrite ONLY Windows drive-path tokens
// (`C:\...`) by converting their backslashes to forward slashes (git-bash accepts `C:/Users/...`).
// The match is ANCHORED on a drive-letter+colon+backslash prefix, so it touches NOTHING else — a
// `\b`/`\w`/`\s` regex, a `sed 's/\\n/ /'`, or any command without a `X:\` token is byte-identical.
// This is the path-mangling pair to command-timeout.js's hung-command cap.
//
// Auto-discovered from ~/.config/opencode/plugin/*.js (01-install-opencode.ps1 / sync-harness.ps1
// deploy configs/opencode-plugins/*.js there); no opencode.json entry is needed.

// A Windows drive-path token: a drive letter + ':' + at least one backslash, then run on through
// any path characters (incl. further '\' and '/') until whitespace or a shell metacharacter ends it.
// The leading `[A-Za-z]:\\` is the scope guard: a bare backslash escape (no drive prefix) never matches.
export const WIN_DRIVE_PATH_RE = /[A-Za-z]:\\[^\s"'|&;<>(){}`]*/g;

/**
 * Convert the backslashes inside Windows drive-path tokens to forward slashes, leaving the rest of
 * the command (and any non-drive-path backslash) untouched. Pure + idempotent.
 * @param {string} command
 * @returns {string}
 */
export function normalizeWindowsDrivePaths(command) {
  if (typeof command !== "string" || command.length === 0) return command;
  return command.replace(WIN_DRIVE_PATH_RE, (token) => token.replace(/\\/g, "/"));
}

/** @type {import("@opencode-ai/plugin").Plugin} */
export const PathNormalizePlugin = async () => {
  console.error("[path-normalize] loaded: Windows drive-path backslashes in bash commands -> forward slashes");
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash" && input.tool !== "shell" && input.tool !== "run") return;
      const args = output && output.args;
      if (!args || typeof args !== "object") return;
      const cmd = String(args.command || "");
      if (!cmd) return;
      const fixed = normalizeWindowsDrivePaths(cmd);
      if (fixed !== cmd) args.command = fixed;
    },
  };
};

export default PathNormalizePlugin;
