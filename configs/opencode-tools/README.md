# OpenCode custom tool: `search_docs` — LOCAL offline doc lookup (#746, INSTALLED + DORMANT)

`search_docs.js` gives the 30B coder a **local, offline documentation lookup** it can
call on a concrete named gap — an unknown symbol, an exact error line, a specific
question — backed by BlarAI's hash-verified, air-gapped docset (`shared/research/`).
It shells out to `tools/search_docs.py` (the tested, zero-egress CLI that is the real
deliverable) and returns the result to the model.

This file is the **implementation**. It was installed into the live tool dir on
2026-07-24 as `~/.config/opencode/tool/search_docs.js`, a thin `tool()` wrapper that
imports `execute`/`DESCRIPTION` from this file by absolute path — so edits here are live
edits, and the API-shape caveat below still applies whenever OpenCode is upgraded.

## Where the arming actually lives (#1206)

Installation is gate one and it is **open**. Gate two used to be the environment variable
`BLARAI_RESEARCH_DOCS`, and until #1206 that variable was set **nowhere** — not in any
dispatch script, launcher, task-spawn or config. The tool answered *"I am dormant"* to
every request the coder ever made, and `state/research-usage.jsonl` shows it: 212
lookups recorded, every one from BlarAI's `plan_grounding` planner, not one from
`search_docs_cli`.

An environment variable was the wrong home for it anyway. A setting that arrives by
process inheritance is armed for whoever happened to be spawned by the right parent and
silently dormant for everyone else — an already-running session, a crash relaunch, a
hand-started process, anything after a reboot. **A setting you have to re-export to
survive a restart is not a setting.**

So the answer lives in one committed line, and the tool reads it **itself**, on every
call, resolved relative to its own file location:

```jsonc
// configs/fleet-driver.json
"research_docs": false        // <- the ONLY switch. true arms the next coder run.
```

`tools/search_docs.py` (`resolve_arming`) consults that file at the point of use. Nothing
has to be exported and nothing is lost across a reboot, because there is no ambient state
to lose. Three properties matter:

- **Only the JSON boolean `true` arms it.** A string `"true"`, a `1`, a typo or a missing
  key all mean OFF.
- **`BLARAI_RESEARCH_DOCS` can only ever DISARM.** A truthy value does nothing; a falsy one
  (`0`/`false`/`no`/`off`) forces dormant even against an armed manifest, so a running
  process can be killed without editing a committed file. This is toggle-tested.
  **This bullet used to say "the environment can only ever disarm", full stop. That was
  false**, and it had reached a ticket record and two review messages as settled fact before
  an adversarial check caught it on 2026-07-30. `BLARAI_FLEET_DRIVER_CONFIG` overrides which
  manifest is read, so aimed at an armed one it **arms the tool from any parent process** —
  and it redirects the PowerShell launcher too, so both halves stay in agreement while both
  point somewhere unintended. Production leaves it unset; nothing enforces that. Whether it
  should be gated is an operator posture decision, tracked on #1206.
  The general lesson, since this is the second time it has bitten this file: a variable that
  was never *tried* is not a variable that *cannot*. Only the toggle-tested claim is a claim.
- **"Off" and "cannot tell" are different answers.** An unreadable or missing manifest
  reports `unresolved` with a non-zero exit — refused fail-closed, but never dressed up as
  a deliberate "switched off".

`Set-CoderResearchEnv` (`scripts/fleet-lib.ps1`) still runs before every coder spawn on
both driver paths, but it does not grant the capability. It does the part the child cannot
do for itself: bank the per-spawn arming record, pin `BLARAI_REPO` /
`BLARAI_RESEARCH_PYTHON` from the manifest, clear a stale truthy value, and propagate a
deliberate stop.

Flipping it on is a build-time capability change: it belongs at an explicit
night-boundary with a battery-attribution window (#740 one-change-per-run), once the
docset corpus is staged (BlarAI `scripts/stage_docsets.py`, LA-approved, hash-verified),
so the before/after battery can say whether it moves the solve rate. Never mid-campaign.

Regression locks: `scripts/verify-research-arming.ps1` (launcher side, plus a check that
both implementations of the predicate agree) and `tools/tests/test_search_docs.py` (tool
side, including clean-process tests that carry no inherited state at all).

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
4. Arm it for the next run — **edit the manifest, never the shell**:
   ```jsonc
   // configs/fleet-driver.json
   "research_docs": true
   ```
   `BLARAI_REPO` and `BLARAI_RESEARCH_PYTHON` are pinned from `acp.blarai_root` /
   `acp.python` in the same manifest, so an armed run resolves the same substrate and
   the same interpreter every time instead of whatever is on `PATH`.
   Setting `$env:BLARAI_RESEARCH_DOCS = "1"` by hand does nothing at all — the tool reads
   the manifest, not the environment. That is deliberate, and it is what makes the state
   survive a reboot. To kill the capability without editing a committed file, set it to
   `"0"` instead; that direction is honoured everywhere, including in a running process.

## What has been verified, and what has NOT (read this before believing a commit message)

**This capability has never been armed.** `research_docs` ships `false`, no dispatch has
ever run with it on, and `state/research-usage.jsonl` contains zero `search_docs_cli`
records produced by a real coder run.

What *was* verified, on 2026-07-30, is the **wiring**: with a **temporary** manifest
setting `research_docs: true`, a process carrying no inherited environment at all (`env -i`,
harsher than a reboot, which preserves user-level variables) resolved `armed`, queried the
staged corpus, returned `json.dumps()` as an exact hit, and wrote its `search_docs_cli`
usage record. The dormant half was verified the same way. Both are permanent regression
tests in `tools/tests/test_search_docs.py`.

> **Correction.** Commit `c794b21`'s message reads *"Live-verified armed against the real
> staged corpus"*. That describes the temporary-manifest run above — **not** a live
> capability, and not a go-live. Nothing about the local corpus is live. The history is
> left intact rather than rewritten; this note is the correction of record.

### The two rungs are blocked on different things — and #746 is not one of them

**#746 is a GRANTED approval, not a pending one.** Its description records the design as
*LA-APPROVED 2026-07-05*, naming the two research points and the deterministic-first
lookups specifically. Its one gated item was the docset **download** — an operator-approved
build-time internet action — and that happened on 2026-07-06: 15 artifacts, 134.6 MB,
13,803 indexed pages, hash-verified, `models/docsets/MANIFEST.sha256.json` on disk. Citing
#746 as a blocker cites a decision the operator already made. (Authority: #746's own
description plus `docs/DECISION_REGISTER.md`'s 2026-07-30 research-grounding row — read
those, not this paragraph, if they ever disagree.)

**Plan-time rung** (BlarAI's `research_grounding`) — NOT live. Stood back down 2026-07-30
(`48f63cff`) after review measured it leading with the wrong documentation page on 5 of 9
goals. This rung IS blocked, on a real predicate: the #1204 relevance fix **plus a fresh
measurement on the operator's own goal shapes**. That is an LA direction, not a pending
approval, and time passing does not satisfy it.

**Build/fix-time rung** (`research_docs` — this file, #1206) — NOT armed, and **not blocked
on an approval either**. The bar is the ordinary one for already-approved work: proven, then
live. Proving it means measuring what the tool returns for the questions a **coder** asks,
which is a different question from what a **planner** asks and cannot be inherited from the
plan-time measurement above.

## Verify it reaches the coder (REQUIRED before trusting)

Adding the tool is not proof the model calls it, and arming it is not proof it fired.
Three questions, three durable answers:

| question | where the answer is |
|---|---|
| was the lookup armed for this run? | `state/research-arming.jsonl` — one record per coder spawn, both driver paths, with the reason and worktree; and a `[research-docs] armed=...` line in the run transcript |
| did the coder actually call it? | `state/research-usage.jsonl` — one `search_docs_cli` record per lookup, with the query and outcome (`hit` / `no_match` / `unavailable`) |
| was the answer real? | the transcript excerpt is verbatim local-doc text; the CLI never invents |

If the arming records say `armed=true` but no `search_docs_cli` records appear, the tool
is reachable and the model is not choosing to call it — nudge it in `AGENTS.md` ("on an
unknown symbol or an exact error, call `search_docs` BEFORE guessing") rather than
re-checking the wiring.

## Back out

Set `"research_docs": false` in `configs/fleet-driver.json` — the next spawn is dormant
and actively clears the variable. Delete `~/.config/opencode/tool/search_docs.js` to
remove the tool from the model's menu entirely. No other change is needed.
