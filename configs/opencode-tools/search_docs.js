// search_docs.js — BlarAI fleet OpenCode CUSTOM TOOL (#746). STAGED — verify the
// plugin/tool API against your installed OpenCode before trusting (see README.md,
// mirrors the qwen-sampling.js staging precedent).
//
// PURPOSE: give the 30B coder a LOCAL, offline documentation lookup it can CALL on a
// concrete named gap — an unknown symbol, an exact error line, a specific question —
// backed by BlarAI's hash-verified, air-gapped docset (shared/research/). It shells
// out to `tools/search_docs.py` (the tested, zero-egress CLI that is the real
// deliverable) and returns its result to the model.
//
// DETERMINISTIC-FIRST + PULL-not-PUSH: the CLI matches EXACTLY first (symbol / the
// exception name inside an error line), then floor-gated lexical search; a query the
// corpus cannot answer above the relevance floor returns "no high-value match —
// proceed" instead of noise. The coder should call this ONLY on a real gap, never
// speculatively.
//
// ZERO EGRESS: the CLI reads only the local index file; no network, ever. This wrapper
// spawns a local process and nothing else.
//
// DORMANT BY DEFAULT (#1206): this wrapper passes every query through to the CLI, and the
// CLI decides for itself whether it is armed by reading `research_docs` in
// configs/fleet-driver.json at the point of use — not from anything this wrapper or
// opencode exports. That is deliberate: a capability carried by process-environment
// inheritance is armed only for whoever was spawned by the right parent, and silently
// dormant after a reboot, a crash relaunch, or in an already-running session. When the
// manifest says false the CLI returns a clean "dormant" note, which renders as-is below.
//
// Environment (all optional; NONE of them can arm the tool):
//   BLARAI_RESEARCH_PYTHON   python executable (default "python")
//   BLARAI_RESEARCH_TOOL     absolute path to tools/search_docs.py
//                            (default resolved relative to this file's repo)
//   BLARAI_RESEARCH_DOCS     emergency stop ONLY: a falsy value (0/false/no/off) forces
//                            dormant. A truthy value has no effect — see the manifest.
//   BLARAI_REPO              BlarAI repo root (default C:\Users\mrbla\blarai)

import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// configs/opencode-tools/ -> repo root -> tools/search_docs.py
const DEFAULT_TOOL = path.resolve(__dirname, "..", "..", "tools", "search_docs.py");
const PYTHON = process.env.BLARAI_RESEARCH_PYTHON || "python";
const TOOL = process.env.BLARAI_RESEARCH_TOOL || DEFAULT_TOOL;
const TIMEOUT_MS = Number(process.env.BLARAI_RESEARCH_TIMEOUT_MS) || 20000;

/** Run the local CLI and return its parsed JSON result (fail-soft). */
function runSearchDocs(query, k) {
  return new Promise((resolve) => {
    const args = [TOOL, "--json", "-k", String(k || 4), String(query || "")];
    execFile(
      PYTHON,
      args,
      { timeout: TIMEOUT_MS, windowsHide: true, maxBuffer: 1 << 20 },
      (err, stdout) => {
        const text = (stdout || "").trim();
        if (text) {
          try {
            resolve(JSON.parse(text));
            return;
          } catch {
            /* fall through to the fail-soft note */
          }
        }
        // A spawn failure / non-JSON output must NEVER derail the coder — return a
        // clear, honest "unavailable" note (the coder proceeds without local docs).
        resolve({
          available: false,
          reason: "tool_error",
          message: `local doc lookup unavailable (${err ? err.message : "no output"}).`,
        });
      }
    );
  });
}

/** Render the CLI result into a compact string for the model. */
function render(result) {
  if (!result || result.available === false) {
    return `[research: ${result?.reason || "unavailable"}] ${result?.message || ""}`.trim();
  }
  if (!result.hits_found) {
    return `[research] ${result.message}`;
  }
  const lines = [`[research] ${result.message}`];
  for (const [label, hits] of [["EXACT", result.exact || []], ["SEARCH", result.search || []]]) {
    for (const h of hits) {
      lines.push(`(${label} ${Number(h.score).toFixed(2)}) [${h.source}] ${h.title} — ${h.path}`);
      if (h.excerpt) lines.push(`    ${h.excerpt}`);
    }
  }
  return lines.join("\n");
}

const DESCRIPTION =
  "Look up LOCAL, offline documentation for a CONCRETE gap — an unknown symbol " +
  "(e.g. `json.dumps`), an exact error line (paste it whole; the exception name is " +
  "resolved deterministically), or a specific question. Deterministic-first + " +
  "relevance-gated: returns real local docs, or an honest 'no high-value match — " +
  "proceed without it' (never invents). Call ONLY on a real gap, never speculatively. " +
  "Zero egress: reads BlarAI's local air-gapped docset only.";

async function execute(args) {
  const query = typeof args === "string" ? args : (args && (args.query || args.q)) || "";
  const k = (args && Number(args.k)) || 4;
  if (!String(query).trim()) {
    return "[research] provide a `query`: a concrete symbol, error line, or question.";
  }
  return render(await runSearchDocs(query, k));
}

// EXPORT SHAPE — STAGED, verify before install (README.md §Verify).
// The default export is the portable, always-loadable shape: a plain object with a
// `description` + an async `execute(args)`. This never fails to load (no dependency on
// `@opencode-ai/plugin` being resolvable at stage time).
//
// If your installed OpenCode requires the schema-typed `tool()` helper for custom
// tools, wrap it at install time (the `execute` here is reused verbatim):
//
//   import { tool } from "@opencode-ai/plugin";
//   import { execute } from "./search_docs.js";   // or inline this file's execute
//   export default tool({
//     description: "...",                          // reuse DESCRIPTION
//     args: { query: tool.schema.string(), k: tool.schema.number().optional() },
//     execute: async (args) => execute(args),
//   });
export default { description: DESCRIPTION, execute };

// Exported for the wrapper's own unit checks + the install-time `tool()` wrap.
export { DESCRIPTION, execute, render, runSearchDocs };
