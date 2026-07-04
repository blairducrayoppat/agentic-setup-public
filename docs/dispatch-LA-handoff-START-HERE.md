# Dispatch LA — START HERE (fresh-session handoff, 2026-06-23)

You are picking up as the operator's **Lead-Architect / technical-proxy / independent quality-gate** for
the BlarAI **headless-coding-dispatch** program. The prior LA session grew too large; this is your clean
start. Read this, then read the auto-loaded memory (it carries the deep state).

---

## 0. Who you are (role + how to work with the operator)

- The operator is a **non-developer novice**. You **investigate technical questions and recommend — never
  bounce them back to him**. Lead with **conversation + a clear recommendation**, not menus.
- You **scope briefs** for builder agents (who do the actual coding in BlarAI / agentic-setup), then
  **independently gate** their work before the operator approves a merge. You **never edit BlarAI runtime
  code yourself** and **never flip `[fleet_dispatch].enabled`**. (You MAY edit the fleet repo
  `agentic-setup` and the operator's throwaway target repos under `~/projects`, and you may run
  tests/probes for verification.)
- **VERIFY, don't assert.** The prior session twice stated pipeline behavior without tracing the code
  (the swap-back park cause; the repo-creation rule) and was wrong both times. Trace the actual code /
  reproduce before claiming behavior. Gating must be **mutation-resistant** (prove the tests can't
  false-pass).
- **Never offer the raw coder (OpenCode / a direct `new-agent-task.ps1`) as a substitute** for the
  NL `/dispatch` pipeline — the 14B decomposition IS the deliverable for this novice.
- Relevant memory files (auto-loaded): `novice-operator-resolve-tech-yourself`, `novice-needs-14b-decomposition`,
  `prefers-conversation-over-menus`, `demands-mutation-resistant-verification`, `drive-autonomously-when-mandated`,
  `scope-controls-to-agent`, `mature-not-minimal-oss`, and the program record `blarai-headless-coding-dispatch`.

## 1. Read first

- **`MEMORY.md` + `blarai-headless-coding-dispatch.md`** (auto-loaded) — the full running record: every fix,
  every merge, the on-hardware proofs, the WinUI readiness facts, the current state. This is your context.
- Builder briefs already written (this dir, `agentic-setup/docs/`): `fleet-builder-brief-ecosystem-adherence.md`,
  `fleet-builder-brief-merge-unblock.md`, `blarai-builder-brief-rightsizing-and-swapback-polish.md`.

## 2. Where the program stands — the pipeline WORKS (proven on-hardware)

The full `#670` arc is **complete and merged**: a natural-language goal → the embedded 14B decomposes it →
the box swaps in the 30B coder (OVMS) → the agentic-setup **fleet** builds in an isolated git worktree →
verify-gate → **auto-merges to the project's `main`** → swaps the 14B back. Proven 2026-06-23: a
`/dispatch palindrome-demo | write an is_palindrome function` produced correct Python with tests and
**merged to main unattended in ~6 min**. Merged fixes: BlarAI P1 right-sizing (`929ad21`), P2 swap-back
(`fe3604a`), P3 fold+poll (`12bfe44`); fleet eco-adherence A1+A2 (`6a3b30c`), merge-unblock `--no-project`
(`8fc4e29`). All ship **dormant** (`[fleet_dispatch].enabled=false`); the operator's **uncommitted
`enabled=true` flip in `default.toml` + a `MainWindow.xaml.cs` edit live in the BlarAI main working tree and
MUST be preserved** (never `git add -A`; commit surgically).

## 3. The operating loop (how every piece has been done)

scope a brief (here in `agentic-setup/docs/`) → operator opens a builder session and points it at the brief
→ builder returns a **comprehension gate** → operator pastes it to you → you review + confirm (or redirect)
→ builder builds on an isolated branch (dormant, surgical) → returns a **package** → **you independently
gate** (read the actual commit/diff, reproduce the proofs, mutation-resistance; when the operator says
**"ultracode"**, use multi-agent `Workflow`s for thorough adversarial review) → operator approves → builder
merges → **you post-merge-verify** (structure, dormancy, the operator's flips preserved). Keep the dispatch
memory current as you go.

Key facts: repos = BlarAI `C:\Users\mrbla\BlarAI` (don't edit), fleet `C:\Users\mrbla\agentic-setup`, targets
`C:\Users\mrbla\projects`. The fleet refuses repos under `~/BlarAI` / `~/.openclaw`. The `/dispatch` surface
(gateway `services/ui_gateway/src/dispatch_coordinator.py`): `/dispatch <repo> | <goal>` (PLAN, shows
criteria) → `/dispatch approve` (EXECUTE + swap) → `/dispatch status`. The **.NET/WinUI gate is BUILD-ONLY**
(`verify-project.ps1:118` `dotnet build`; it never launches a GUI) → the **operator must launch and eyeball**
any visual app.

## 4. Workstream A — build the ROCKET CALCULATOR (WinUI), staged

Operator's goal: a space-rocket-themed calculator for an 8-year-old; ultimately a window **shaped like a
rocket** when not maximized, **red cartoon rocket with flames**, resizable. Feasibility was assessed (3-agent
workflow). Plan:

**Decisions already made with the operator:**
- **PURE test — do NOT scaffold the WinUI project.** The pipeline must author it itself (that's the real
  test). The LA only creates an **empty `rocket-calc` git repo** as the target (like `palindrome-demo` was an
  empty target) and **bakes the environment constraints into the goal text** — those are facts a dev would be
  given, not doing the work.
- **Resize for the shaped rung** = BOTH a right-click "Resize" menu AND visible grow/shrink buttons on the
  rocket (operator chose both). Programmatic resize sidesteps the shape-vs-edge-resize conflict.

**Toolchain facts (verified) — bake these into every WinUI goal or it fails:**
- Pin EXACT cached versions or offline restore NU1101-fails: `Microsoft.WindowsAppSDK 1.8.260508005`,
  `Microsoft.Windows.SDK.BuildTools 10.0.26100.8249`, TFM `net8.0-windows10.0.19041.0`.
- The csproj MUST bake `<RuntimeIdentifier>win-x64</RuntimeIdentifier>` (+ `<Platform>x64</Platform>`) or the
  bare gate `dotnet build` false-fails on "WindowsAppSDKSelfContained requires a supported Windows architecture".
- NO `dotnet new winui` template + NO workloads installed → hand-author an SDK-style csproj (PackageReference,
  `UseWinUI=true`, `WindowsPackageType=None` unpackaged/self-contained). Template = `BlarAI/services/ui_winui/
  BlarAI.Desktop.csproj` is the known-good reference. WinUI builds clean OFFLINE on this box (proven).
- **Android is OUT for now** (no MAUI workload). Separate later assessment.

**Staged ladder (each rung = one tight dispatch; operator launches + eyeballs after each merge):**
- **Rung 0 (run now):** minimal WinUI window that adds two numbers (proves the fleet can build C#/WinUI through
  the gate). No rocket.
- **Rung 1:** working rectangular calculator (digits, + - x /, =, clear).
- **Rung 2:** rocket THEMING — red cartoon rocket + animated flames in XAML, kid-sized buttons, normal
  resizable window. *This is the deliverable that delights the 8-yo; it's well in range.*
- **Rung 3 (HARD STRETCH, flagged):** the rocket-SHAPED window (Win32 interop: GetWindowHandle + SetWindowRgn
  + WM_NCHITTEST) + the right-click-menu/buttons resize. Expect iteration; most likely to compile-but-look-wrong.

**EXACT Rung-0 dispatch command to give the operator (after creating an empty `rocket-calc` git repo under
`~/projects`):**
```
/dispatch rocket-calc | Create a minimal WinUI 3 desktop app in C# that opens one window and adds two numbers. Use an SDK-style .csproj (NOT a template) targeting net8.0-windows10.0.19041.0 with RuntimeIdentifier win-x64, UseWinUI=true, WindowsPackageType=None, and PackageReference Microsoft.WindowsAppSDK version 1.8.260508005 and Microsoft.Windows.SDK.BuildTools version 10.0.26100.8249. The window has two TextBox inputs, an Add button, and a TextBlock that shows the sum. Success = the project builds with `dotnet build -c Release` with zero errors. Do NOT add a rocket, theming, or a custom window shape.
```
Set expectation: WinUI is a real step up from a palindrome; the 30B may resample or park. A park is **signal,
not failure** (it tells us its WinUI ceiling). A green gate means it COMPILED — the operator launches the
produced `App.exe` to see the window.

## 5. Workstream B — MATURE the dispatch PROJECT-HANDLING (write the builder brief)

The operator flagged real immaturity in how `/dispatch` handles the project/target. **Verified current
behavior:** the PLAN step (`dispatch_coordinator._plan`, ~:141-182) does NOT check whether the repo exists —
it decomposes + previews criteria for ANY name, so it *looks* like it "just works"; the existence requirement
only bites at EXECUTE (`shared/fleet/dispatch.py::validate_repo` ~:108-129 errors "is not a git repository");
`_repo_path` (~:279-281) resolves `projects_dir/<name>` but does NOT create it. Same-name reuse works
(idempotent for the same task via `new-agent-task.ps1`; accumulates `agent/<slug>` branches for different
goals) — not an error, just silent.

**Scope a builder brief** (gateway + fleet) for a matured flow:
- At dispatch start, **pick an existing project OR create a new one** (empty git repo), with **clear
  confirmation of which folder** is being used.
- **Tell the operator immediately if a name doesn't exist yet** (don't silently PLAN against nothing).
- On **same-name reuse, say so** (and what's already there) instead of silently overwriting/accumulating.
- Fix the misleading `Open the app: python -m <repo>` status line (wrong for loose-module / non-package repos).
- Keep it dormant/surgical, same gated process; respect the `~/BlarAI` fence.

Run A and B in parallel (A unblocks the operator's visible goal; B removes the friction he keeps hitting).

## 6. First actions for you (the fresh LA)

1. Greet the operator briefly, confirm you've picked up both workstreams.
2. **Workstream A:** create an empty `rocket-calc` git repo under `~/projects`, hand the operator the Rung-0
   command above. When the dispatch runs, watch the state files (`agentic-setup/state/fleet-runs/<run>/`,
   `state/fleet-swap/current.json`) and narrate; the operator likes live reads.
3. **Workstream B:** draft the project-handling builder brief (Section 5) in `agentic-setup/docs/`.
4. Keep BOTH records current as you work — this is non-optional, the operator explicitly wants it:
   - the **memory** `blarai-headless-coding-dispatch.md` (durable facts), AND
   - the **LA journal** `agentic-setup/docs/LESSONS-LEARNED.md` — append a **dated narrative entry** in its
     "Running log" style (`## YYYY-MM-DD — title that names the lesson/arc`, ✅/❌/🔬 tags, `→ BlarAI` notes,
     failures-stay-in) whenever a workstream ships a milestone, a real decision is made (name the trade-off),
     or a lesson is learned. The **builders** keep BlarAI's `BUILD_JOURNAL.md` for the code they ship; **you**
     keep `LESSONS-LEARNED.md` for the orchestration arc + lessons. (The `#670` arc through 2026-06-23 is
     already backfilled there — continue from the bottom; bump the header "Last updated" date.)
