# Fleet builder brief — coder produces NO usable output (Windows-path + stall + offline-deps)

**Audience:** a Claude session in `C:\Users\mrbla\agentic-setup` (fleet PowerShell + the opencode plugins/config). FLEET-side; do NOT touch `~/BlarAI` runtime and NEVER flip `[fleet_dispatch].enabled`. You MAY edit `agentic-setup` and use throwaway `~/projects` targets.
**Tracking:** #670 (fleet limb — coder output-reliability; surfaced by the first real New-Project dispatch).
**Authored:** 2026-06-30, by the BlarAI session that shipped the `#712` New Project UX, from its first end-to-end on-hardware dispatch.
**Severity:** operator-blocking — a CORRECT, fully-working dispatch (New Project button → plan → approve → 14B⇄30B swap → build → honest status) currently produces `RESULT: Nothing to merge`. The UX is done; the **coder** is the wall. Three linked faults; **F1 is one opencode plugin**.

Lead your report with a comprehension summary + plan; do NOT merge — leave it on a branch for the LA's gate. Isolated worktree; NEVER `git checkout`/`switch` the main checkouts. Read `docs/dispatch-LA-handoff-START-HERE.md` + the program memory `blarai-headless-coding-dispatch.md` + `docs/LESSONS-LEARNED.md` first; **VERIFY, don't assert** — the file:line anchors below are from a 2026-06-30 read; confirm them before you change anything.

---

## 0. Why — the live failure (reproduced on-hardware 2026-06-30)

- **Dispatch:** `/dispatch new TestProject1 | a webpage with a cartoon elephant saying hello.` (the operator clicked the new BlarAI **New Project** button; everything up to the coder worked — create real repo, 14B PLAN + criteria, approve, swap in the 30B, run the fleet, swap the 14B back, honest `/dispatch status`).
- **Outcome:** `C:\Users\mrbla\projects\testproject1` has ONLY `README.md` + `.gitignore`. The parked branch `agent/create-webpage-c2` is just the empty `seed: web skeleton` commit. **Nothing the coder wrote survived.**
- **Evidence (re-read these):**
  - Run dir `C:\Users\mrbla\agentic-setup\state\fleet-runs\20260630-121256-bd\` — `SUMMARY.txt` (`create-webpage: processed → RESULT: Nothing to merge.`) + `run-fleet-create-webpage.log` (the test failures, the circuit-breaker lines, the `BUILD: STOPPED by circuit breaker after 60 min (… the local model no-op'd the earlier ones)` verdict).
  - Coder transcripts (opencode JSONL): `state\reports\testproject1-create-webpage-20260630-121539.c1.agent.log` (wrote the elephant, hit the path bug, stalled) and `…c2.agent.log` (no changes). Per-task report `…20260630-121539.txt`.
- **What actually happened (traced in c1):** candidate c1 wrote `public/index.html` (`<h1>Hello</h1>` + a cartoon-elephant `<img>`) and `test/webpage.test.js`, then tried to run the tests, hit **F1** (the `cd` failed), got stuck trying to recover, the idle breaker (**F2**) killed it **before it ever committed**, and the worktree sweep discarded the uncommitted work. c2 produced nothing. Best-of-N kept the empty seed → "Nothing to merge." The work it did write also depended on the network (**F3**), so it could not have passed offline anyway.

---

## 1. F1 — Windows path mangling in the coder's bash tool  *(fix FIRST; one plugin)*

- **Evidence (c1 log):** `cd C:\Users\mrbla\projects\testproject1-create-webpage-c1 && npm test` → `/usr/bin/bash: line 1: cd: C:Usersmrblaprojectstestproject1-create-webpage-c1: No such file or directory`. Git Bash/MSYS ate the backslashes (`\` is an escape), collapsing `C:\Users\…` → `C:Users…`; the coder could never enter its own worktree, so its tests never ran.
- **Root cause:** opencode's `bash` tool runs through `/usr/bin/bash`; a Windows **backslash** path passed to it is escape-mangled. (`fleet-lib.ps1:~165` already notes opencode's Windows shell detection prefers WSL when `wsl.exe` exists — **confirm which shell is actually in play** before fixing.)
- **The fix (recommended):** a new opencode **`tool.execute.before`** plugin that **normalizes Windows paths in bash commands** — convert `C:\…` backslashes to forward slashes (Git Bash accepts `C:/Users/…`) and/or strip a redundant leading `cd <worktree>` (the bash tool already runs in the worktree cwd, so the coder need not `cd` at all). Mirror the EXISTING proven pattern in `configs/opencode-plugins/command-timeout.js` (it already rewrites `args.command` in `tool.execute.before`). ALSO add a coder instruction (`configs/AGENTS.md`): "use forward slashes; never `cd` into an absolute Windows path; you are already in the project dir."
- **Boundaries / do-NOT:** do not loosen `command-timeout.js`'s caps; do not switch the whole fleet to WSL/pwsh blindly (verify the shell first). Backward-compat: a command with no Windows path is untouched (lock with a test).
- **Where:** `configs/opencode-plugins/` (+ the `plugin` array in `opencode.json`), `scripts/fleet-lib.ps1` (~131–260 the `opencode run` invocation + ~165 shell selection), `configs/AGENTS.md` / `PROMPTS.md`.

## 2. F2 — the local 30B coder STALLS (circuit-breaker idle-240s)

- **Evidence:** `run-fleet-create-webpage.log` — `CIRCUIT BREAKER: agent went idle (no new step/edit for 240s) -- genuinely stuck and was stopped` (both candidates) + `BUILD: STOPPED by circuit breaker after 60 min`.
- **Root cause:** the breaker is **working** — it correctly caught a genuinely-stuck model. The 30B went idle, **triggered here by F1** (stuck recovering from the mangled `cd`), on top of the known local-model ceiling.
- **The fix:** **do F1 first and re-measure** — removing the confusing failure may remove this stall. Residual: tool-call robustness (`docs/qwen3coder-toolcall-fix.md`), retry-from-clean-worktree tuning, and *fail-faster* (a shorter idle timeout — "stop doomed runs fast" — never longer).
- **Boundaries / do-NOT:** do NOT loosen the breaker; do NOT raise the idle/ceiling timeouts (that bleeds budget). This is the genuinely-hard residual — F1+F3 may make it rare; quantify before investing.
- **Where:** `scripts/run-fleet.ps1:~23` + `scripts/new-agent-task.ps1:~18` (`$IdleTimeoutSec=240`), `scripts/fleet-lib.ps1` (~314–342 idle Should-Stop; ~131–260 the run loop), `docs/qwen3coder-toolcall-fix.md`.

## 3. F3 — the coder writes NETWORK-DEPENDENT code + tests (can't pass offline)

- **Evidence:** the elephant `<img>` was `https://placehold.co/300x300?text=Cartoon+Elephant` (external CDN); the auto-written tests fetched that URL **and** `http://localhost:8081` (a server port it never started) → all 4 acceptance tests `fetch failed`. This box is **offline** (`fleet-lib.ps1:~74-75` even treats "No such host is known" as a hard fail).
- **Root cause:** the coder isn't constrained to **offline** assets/tests. A CDN-dependent page is wrong for an air-gapped system, and tests that hit the network / an unstarted server can't pass.
- **The fix:** bake **offline-only** into the coder instructions **and** the `web` build-profile seed — never fetch an external URL; use inline SVG / a data-URI / a bundled local asset for images; test the **static files** (or the seed server's *actual* port via a seeded offline-test pattern), never a live external fetch. The `dotnet`/`winui` profiles already ship an "extend this offline test harness" seed (`fleet-lib.ps1:~521-526`); the **`web` profile needs the equivalent**.
- **Boundaries / do-NOT:** keep the non-web profiles byte-identical (lock with a test). Don't add a network-dependent test framework.
- **Where:** `build-infra/web/` (the `web` seed the coder EXTENDS — its `index.html`, `src/server.js`, port, test pattern), the acceptance-test prompt assembly in `scripts/new-agent-task.ps1` / `scripts/run-fleet.ps1` (the "Write automated tests…" block), `configs/AGENTS.md`.

## 4. Sequencing

1. **F1** (Windows path) — concrete, low-risk, highest-leverage; likely removes this run's stall trigger.
2. **F3** (offline assets/tests) — prompt + `web`-seed; makes a web dispatch *passable* offline.
3. **Re-run the exact case** and measure: does it now produce **and auto-merge** a working offline page?
4. **F2** (residual stall) — only after F1/F3; measure how often it still stalls, then tune. The hard one.

## 5. Verification (mutation-resistant + the live proof — the real deliverable)

1. **Reproduce first:** confirm F1 (a `cd C:\…` bash command fails; the normalized form succeeds) and F3 (a test that fetches an external URL fails offline) BEFORE fixing — capture the real terminal output.
2. **Regression / gate-not-weakened:** prove the offline-test change still FAILS a genuinely-broken page (not a mirror of whatever the coder wrote); prove the non-web / non-template profiles stay byte-identical (KILL-test). Run the PowerShell `verify-*.ps1` suite (the standing fleet gates; e.g. `verify-ecosystem.ps1`, `verify-retry.ps1`, `verify-bestofn*.ps1`) on **PS 5.1 AND 7** — report counts, stay green.
3. **THE LIVE PROOF ("fixed and working"):** re-run the exact failing case — an empty `~/projects/<repo>` + "a webpage with a cartoon elephant saying hello." Fast iteration path: queue + `scripts/run-fleet.ps1` with OVMS already up (skips the swap; see `scripts/demo-fleet.ps1` + `add-fleet-task.ps1`). FINAL proof: the operator runs it through BlarAI (New Project / `/dispatch new`). **Fixed = the project's `main` gets a real offline `index.html` (no external URL), the acceptance tests run + pass offline, and the run AUTO-MERGES** (`SUMMARY.txt` = merged, not "Nothing to merge").
4. **No regression:** the BlarAI Python standing gate is out of scope (no BlarAI edits expected); if you do touch BlarAI, run it LOCALAPPDATA-redirected (py3.11 `.venv`) and report counts.

## 6. Process / scope / fences

- Feature branch off `main` (never commit to main). Open with a **comprehension gate**. **Separate commits per fault** (F1 / F3 / any F2 work). One self-contained package before merge: the diff, the reproduce→fixed terminal output, the regression/KILL-test proofs, the `verify-*.ps1` counts, and the live re-dispatch result (MERGED, work on the target's `main`). The **LA independently gates** before any merge; on "ultracode," expect adversarial multi-agent review.
- Records: append a dated narrative entry to **`docs/LESSONS-LEARNED.md`** (the program's running log) when a fault ships or a real decision/lesson lands; keep the program memory `blarai-headless-coding-dispatch.md` current.
- **NOT this brief — the BlarAI `#712` New Project UX is done and works** (branch `feat/712-create-project-and-command-ui`, commit `47a3454`, standing gate 4679/0, WinUI build 0/0, C# headless 59/0; awaiting the operator's live-confirm + merge). It already delivers the old START-HERE *Workstream B* "create a new project, clear confirmation" — so that friction is largely retired on the BlarAI side; THIS is the coder-output-reliability workstream it exposed. Two BlarAI-side items are a **separate BlarAI follow-up** (not this brief): live-confirming the **image Edit/Save** + **dispatch Approve/Reject** buttons render, and the deferred typed-`/dispatch <missing>`-offers-create decision.
