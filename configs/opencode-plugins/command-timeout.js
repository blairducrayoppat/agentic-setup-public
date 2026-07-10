// command-timeout.js — BlarAI fleet opencode plugin.
//
// PURPOSE: hard-cap every bash command's timeout so a single hung command can NEVER
// eat the agent's 30-minute build budget. This is the robustness pair to "stop doomed
// runs fast."
//
// WHY: opencode's bash tool takes a `timeout` (milliseconds) argument, and the tool
// description tells the model to "retry with a larger timeout if the command is expected
// to take longer." In the #676 Inc-3 test dispatch the coder ran `dotnet run` on a
// console test-runner it should not have created; that process never exited, and because
// the model had given it a large timeout it stalled ~15 minutes (0 CPU) before the 30-min
// circuit breaker fired — eating most of the budget with no error-feedback recovery.
//
// FIX: in the `tool.execute.before` hook we clamp `args.timeout` for the bash/shell tool
// to OPENCODE_BASH_MAX_MS (default 5 min). Any command that hangs now dies in <=5 min,
// returns a real failure to the model, and the run keeps moving. A command that sets a
// SMALLER timeout is left alone (tighter is fine). This is strictly a CAP — it never
// loosens a model-chosen shorter timeout.
//
// Auto-discovered from ~/.config/opencode/plugin/*.js (01-install-opencode.ps1 / sync-harness.ps1
// deploy configs/opencode-plugins/*.js there); no opencode.json entry is needed.
//
// LOADER CONSTRAINT (#759 recon, 2026-07-07): opencode's plugin loader treats EVERY named export
// as a plugin factory and rejects the whole file if one is not a function ("Plugin export is not
// a function") — the regex exports added in the #687/#688 wave silently killed this plugin AND
// path-normalize.js from 2026-06-30 onward. Export functions-intended-as-plugins ONLY; the
// regexes stay module-private and the tests drive the hook through the factory.

const MAX_COMMAND_MS = Number(process.env.OPENCODE_BASH_MAX_MS) || 300000; // 5 min hard cap

// #688: a BLOCKING long-running process (a dev server, a file watcher) started in the FOREGROUND
// hangs to the cap and BURNS the whole build budget. AGENTS.md forbids it, but the 30B does it
// anyway -- the live tip-calc dispatch ran `node src/server.js` and stalled the FULL 5 min,
// repeatedly, so the review saw a "hanging" verification -> FIX FIRST -> park. The instruction was
// never ENFORCED. So: a server/watcher command not already bounded by its own `timeout` gets a
// short PROBE cap -- long enough to start + print its banner, then it is killed (no 5-min wait, no
// leaked port). A command the model already wrapped in `timeout N ...` is left alone (self-bounded).
const SERVER_PROBE_MS = Number(process.env.OPENCODE_SERVER_PROBE_MS) || 10000; // 10s confirm-then-kill
const BLOCKING_RE = /\b(npm\s+(start|run\s+(dev|serve|start|watch|preview))|nodemon|http-server|serve|vite|next\s+(dev|start)|uvicorn|gunicorn|flask\s+run|php\s+-S|python\d?\s+-m\s+(http\.server|flask))\b|\bnode\b[^|&;]*\bserver\b/i;
const SELF_BOUNDED_RE = /(^|[|&;]|\s)timeout\s+\d/i; // already wrapped in `timeout N ...`

// #687: opening a BROWSER / URL in a headless build (start|open|xdg-open|explorer a http(s) URL)
// pops a FOREGROUND window on the operator's screen and verifies NOTHING -- the page is judged by
// the design loop's headless screenshot, not by a window the run cannot see. The 30B did
// `start http://localhost:3000` mid-build (it stole the operator's focus). AGENTS.md forbids a
// foreground browser; this ENFORCES it. Matches only a real URL scheme, so `start notepad` / a
// bare `start .` / `npm start` are untouched (npm start is handled by BLOCKING_RE separately).
const BROWSER_OPEN_RE = /(^|[|&;]|\s)(start|open|xdg-open|explorer(\.exe)?|sensible-browser)\s+[^|&;\n]*\bhttps?:\/\//i;

/** @type {import("@opencode-ai/plugin").Plugin} */
export const CommandTimeoutPlugin = async () => {
  // Load-log (stderr) so the fleet can VERIFY the plugin actually wired in.
  console.error(`[command-timeout] loaded: bash/shell commands capped at ${MAX_COMMAND_MS}ms (server probe ${SERVER_PROBE_MS}ms)`);
  return {
    "tool.execute.before": async (input, output) => {
      // opencode's shell tool id is "bash"; guard a couple of plausible aliases too.
      if (input.tool !== "bash" && input.tool !== "shell" && input.tool !== "run") return;
      const args = output && output.args;
      if (!args || typeof args !== "object") return;
      // ENFORCE the no-foreground-server rule (#688): a blocking server/watcher that is not already
      // self-bounded gets the short probe cap so it can NEVER eat the budget.
      const cmd = String(args.command || "");
      // ENFORCE no foreground browser (#687): rewrite a URL-opening command to a harmless note so it
      // can NEVER pop a window on the operator's screen; the coder is told to move on (the design
      // loop does the headless screenshot). A rewrite, not a cap -- done first.
      if (cmd && BROWSER_OPEN_RE.test(cmd)) {
        args.command = 'echo "[headless build] opening a browser/URL is disabled here; the page is verified by the design-loop headless screenshot, not a foreground window. Skipping -- continue with your task."';
        return;
      }
      if (cmd && BLOCKING_RE.test(cmd) && !SELF_BOUNDED_RE.test(cmd)) {
        args.timeout = SERVER_PROBE_MS;
        return;
      }
      const t = Number(args.timeout);
      // Unset / invalid / above the cap -> clamp to the cap. A smaller positive timeout stays.
      if (!Number.isFinite(t) || t <= 0 || t > MAX_COMMAND_MS) {
        args.timeout = MAX_COMMAND_MS;
      }
    },
  };
};

export default CommandTimeoutPlugin;
