# Fleet Builder Brief — Increment 3: core/shell WinUI scaffold + staged build

**Audience:** a fleet builder session/subagent (all work in `C:\Users\mrbla\agentic-setup`).
**Author:** Dispatch LA. **Tracking:** Vikunja #676 (under #674). **Design SSOT:**
`agentic-setup/docs/dispatch-build-signal-architecture.md` §6 Increment 3 + §10.

Lead your final report with a comprehension summary + plan; do NOT merge — leave it on a
branch for the LA's gate. Create your own isolated worktree off `agentic-setup` main
(`git -C C:/Users/mrbla/agentic-setup worktree add C:/Users/mrbla/agentic-setup/.worktrees/676-core-shell -b feat/676-core-shell main`);
NEVER `git checkout`/`switch` the main `agentic-setup` checkout (the LA gates from it).

---

## Why this exists — proven live, not theorized

The Inc-2 on-hardware test dispatch (`rocket-calc`, run `20260624-120231-bd`) PARKED for a
SPECIFIC, now-known reason: the seed gave the coder a compiling WinUI shell, and it extended
it correctly — but when it went to write tests, it **invented MSTest** (`[TestMethod]` /
`[TestCategory]`) with no package reference → `CS0246`, and spun up a **second project** to
hold them. The struct gate caught the 2nd project and error-feedback fed it back, but the
coder couldn't get a test framework working **offline** within its budget → pass-2 breaker →
park. **Inc 3 removes that failure at the root: the scaffold ships a test setup that already
builds offline, so the coder EXTENDS working tests instead of inventing a framework.**

## Scope

1. Restructure `build-infra/winui/reference/` into a **core + shell + offline-building tests**
   shape, kept as **ONE project** (max_projects stays 1 — see §Structural-contract).
2. A **staged core-then-shell** coder prompt.
3. **Extend** the existing single-project rule in the agent-layer `AGENTS.md` (do NOT add a
   parallel rule) with the exact anti-patterns this run exposed.

## Part A — the scaffold (`build-infra/winui/reference/`)

Keep the single `MinimalWinUI.csproj` (WinExe, the verified pins) and add, inside that one
project:
- **`Calculator.cs`** — a platform-free core class with the four ops + divide-by-zero
  handling, written with clearly-marked `// TODO:` slots the coder fills/extends. It must
  compile as-is (stub returns are fine) so the seed builds 0/0.
- **`Tests/CalculatorTests.cs`** — tests that **BUILD OFFLINE with no external package**.
  THE KEY CONSTRAINT (the live failure): do NOT seed MSTest/xUnit/NUnit unless you VERIFY the
  package is in the offline feed (`C:\Users\mrbla\blarai-build\nuget-feed`) and restores
  offline. The robust default is a **dependency-free assert harness** — a small `static`
  test class with `[Conditional]`-free plain methods that throw on failure (or a trivial
  `Assert` helper in the same folder) — so it needs ZERO NuGet and always builds offline. The
  coder EXTENDS these with real cases. (Rationale: the WinUI gate is `dotnet:build` only — it
  does NOT run C# tests, ADR-035 §116 — so the test project's job is to BUILD cleanly so the
  coder never re-hits the MSTest CS0246; the operator runs the tests by eye/hand.)
- The existing `App.xaml`/`App.xaml.cs`/`MainWindow.xaml`/`MainWindow.xaml.cs` shell, with the
  `MainWindow` carrying **named hooks** (e.g. a `Display` TextBlock + `Calculator _calc` field
  already wired) so the coder themes/extends rather than re-authors the wiring.

**Verify-don't-assert (mandatory):** `Copy-ScaffoldInto` the new scaffold into a temp worktree
and run the gate's EXACT `dotnet build --nologo -v q` → **0 warning / 0 error, fully offline**
(restore from the cache/feed only). A scaffold that doesn't build offline is worse than none.

## Part B — the staged core-then-shell prompt

In `new-agent-task.ps1`, for a `staged` surface (the BuildProfile's `staged=$true`, set for
`winui` in Inc 2's `Resolve-BuildProfile`), inject a staged instruction AFTER the complexity
hint: **"(1) First implement the Calculator core in `Calculator.cs` and extend the tests in
`Tests/` — keep it building. (2) THEN theme the `MainWindow` shell (colors, flames, chunky
buttons). Do NOT add a second project and do NOT add a test framework package — the tests in
`Tests/` already build; just add cases to them."** Pure-function the staging text in
`fleet-lib.ps1` (e.g. `Add-StagedHint`) so it unit-tests without a model; gate it on the
`staged` flag so non-staged surfaces are untouched (strictly additive).

## Part C — extend AGENTS.md (do NOT parallel it)

Extend the existing single-project rule in BOTH the repo master and the live
`~/.config/opencode/AGENTS.md` (sync via `sync-harness.ps1`) with the exact anti-patterns:
for a WinUI `WinExe` — **one `.csproj`**; **no `Program.cs`/`Main`** (the SDK generates the
entry; the entry is `App.xaml.cs`); **no second/test project**; **no test-framework package**
(MSTest/xUnit/NUnit are NOT in the offline feed — extend the dependency-free tests already in
`Tests/`); put logic in `Calculator.cs`, tests in `Tests/`.

## Structural-contract consistency (the Inc-2 coupling)

The Inc-2 winui `structural_contract` enforces `max_projects=1` + `forbid_extra_entry_points`
+ `test_dir='Tests/'`. Your single-project scaffold (tests inside the one project's `Tests/`)
MUST stay consistent with it — keep ONE `.csproj`, no second project. Re-run
`verify-struct.ps1` against the new seed to prove `Test-ProjectStructure` returns CLEAN on it
(a regression here = the gate would false-fail the seed). If you find a genuine reason the
scaffold needs >1 project, STOP and flag it (it's a contract change, an LA decision — don't
silently raise `max_projects`).

## Verification bar (off-dispatch, mutation-resistant)

- The seed builds offline 0/0 (Part A proof) AND `verify-struct.ps1` shows it CLEAN (the
  struct gate passes the new seed) AND `verify-scaffold.ps1` stays green (extend it: the
  seeded `Calculator.cs` + `Tests/` are present + the tree builds).
- A WIRING test that the staged hint REACHES the coder prompt only for a `staged` surface
  (kill-test: a non-staged surface gets no staged hint).
- The full standing unit gate (now 406/0 with Inc 2) must stay green.

## Constraints

`agentic-setup` ONLY; ships dormant; no OS changes; PS 5.1 + 7 safe; separate commits per
part; do NOT edit `LESSONS-LEARNED.md` (surface lessons in your report). Report: the diff, the
offline-build proof, the struct/scaffold gate numbers, the wiring evidence, the worktree +
branch. The LA independently gates (re-runs + a real seed build) before merge.
