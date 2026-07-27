# OpenCode custom tool: `search_docs` — LOCAL offline doc lookup (#746, STAGED)

`search_docs.js` gives the 30B coder a **local, offline documentation lookup** it can
call on a concrete named gap — an unknown symbol, an exact error line, a specific
question — backed by BlarAI's hash-verified, air-gapped docset (`shared/research/`).
It shells out to `tools/search_docs.py` (the tested, zero-egress CLI that is the real
deliverable) and returns the result to the model.

It is **staged here, not active**, for the same reasons `opencode-plugins/` is staged:

- the live OpenCode config/tool dir lives under `~/.config/opencode` (deny-edit by
  fleet policy), so it must be installed deliberately, not by an unattended agent; and
- the exact custom-tool API (`tool` helper / arg schema) can differ across OpenCode
  versions — verify it against your install before trusting.

## Double-dormant / opt-in (by design, #746)

This tool does nothing until BOTH gates are opened:

1. **Not installed** into the live `~/.config/opencode/tool/` (do the deliberate
   install below), AND
2. the CLI is **dormant** unless the environment sets `BLARAI_RESEARCH_DOCS=1` — until
   then the tool returns a clean "dormant — no index consulted" note.

This is the deliberate "research arm switch" for the reliability campaign. Flip it on
only at an explicit night-boundary, once the docset corpus is staged (BlarAI
`scripts/stage_docsets.py`, LA-approved, hash-verified) and the before/after battery
has measured whether it moves the solve rate.

## Behavior (what the coder gets)

- **Deterministic-first + pull-not-push.** Exact symbol / error-symbol match first
  (no model, no fuzz), then floor-gated lexical BM25. A query the corpus cannot answer
  above the relevance floor returns *"no high-value match — proceed without it (do not
  invent an answer)"* — never noise, never a hallucinated citation.
- **Zero egress.** The CLI reads only the local index file (`shared.research` is locked
  incapable of egress); the wrapper spawns a local process and nothing else. No fetch,
  ever — the runtime privacy mandate is absolute.
- **Fail-closed.** If the docset index is not staged/built, the CLI refuses with a clear
  message naming BlarAI's `scripts/stage_docsets.py`; the wrapper reports it and the
  coder proceeds without local docs (it never throws / derails the build).

## Install (do this deliberately, then verify)

1. Confirm the CLI works standalone (dormant vs enabled):
   ```powershell
   python C:\Users\mrbla\agentic-setup\tools\search_docs.py --json "json.dumps"          # dormant note
   $env:BLARAI_RESEARCH_DOCS = "1"
   python C:\Users\mrbla\agentic-setup\tools\search_docs.py "json.dumps"                  # exact hit
   ```
2. Copy the tool into your OpenCode tool folder:
   ```powershell
   $dst = "$env:USERPROFILE\.config\opencode\tool"
   New-Item -ItemType Directory -Force $dst | Out-Null
   Copy-Item "C:\Users\mrbla\agentic-setup\configs\opencode-tools\search_docs.js" $dst
   ```
3. **Verify the API shape** (`~/.config/opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts`):
   confirm a custom-`tool` export with a `description` + `args` schema + `execute` is
   what your OpenCode loads from `tool/`. If the API differs, adjust the export at the
   bottom of `search_docs.js` (it already falls back to a plain `{ description, execute }`
   object when the `tool` helper import is unavailable).
4. Set the enable gate in the coder's environment (only at go-live):
   ```powershell
   $env:BLARAI_RESEARCH_DOCS = "1"     # unset = dormant
   # optional overrides: BLARAI_RESEARCH_PYTHON, BLARAI_RESEARCH_TOOL, BLARAI_REPO
   ```

## Verify it reaches the coder (REQUIRED before trusting)

Adding the tool is not proof the model calls it. Run a coding task whose prompt names a
concrete unknown symbol/error, and confirm the coder invokes `search_docs` and that the
returned excerpt is real local-doc text (not invented). If it never fires, the model may
need a nudge in `AGENTS.md` ("on an unknown symbol or an exact error, call `search_docs`
BEFORE guessing").

## Back out

Delete `~/.config/opencode/tool/search_docs.js` (or unset `BLARAI_RESEARCH_DOCS` to
re-dormant it without uninstalling). No other change is needed.
