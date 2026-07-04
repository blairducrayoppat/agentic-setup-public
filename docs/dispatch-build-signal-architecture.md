# Dispatch Build-Signal Architecture

**Status:** DESIGN — direction approved by the operator 2026-06-24. Build all three
increments off-dispatch, then ONE consolidated on-hardware `/dispatch` at the end.
**Author:** Dispatch LA session (2026-06-24).
**Tracking:** Vikunja #670 (headless-coding-dispatch).

---

## 1. Context — why this exists

The matured-pipeline proof run `20260624-084153-bd` (`/dispatch rocket-calc`,
a pure-product WinUI goal) **parked** after a ~30-minute churn. Root cause, traced
from the coder transcript (not assumed):

- The **WinUI scaffold never seeded** — the coder's first `glob **` saw only
  `README.md` + `.gitignore`; it authored the whole project from scratch.
- `Resolve-TaskScaffold` is deliberately conservative (it refuses to guess a
  language from an ambiguous goal), and the goal text was *pure product intent*
  ("a calculator that looks like a rocket") with **zero tech signal** — so it
  no-op'd and nothing seeded.
- Authoring from zero, the 30B **proliferated**: the real WinUI app *plus* a
  Console-style `Program.cs` with its own `Main()`, a second test project, and
  ~7 loose `.cs` runner/validation files with top-level statements → `CS8803`
  + a XAML internal compiler error → 30-min circuit-breaker → park.
- The CS0246 (`RoutedEventArgs` / missing `using`) ceiling is **gone** — the coder
  wrote the usings correctly itself — but that was never the scaffold's doing.

**The lesson:** the scaffold library — last session's headline deliverable — does
not engage for the way the operator actually speaks, because the platform signal it
keys on is intentionally absent from his prompt. The smartest component that *does*
know the platform (the 14B at decompose time) throws that knowledge away.

## 2. Principle (corrected)

The earlier framing — "the operator writes pure product, so nothing technical may
appear" — was wrongly extended from *his prompt* to *the 14B's output*, which
starved the system. The sharper principle:

> **The operator owns product intent. The SYSTEM owns all tech. The 14B is the
> system's *bridge* — it translates product intent into a coarse platform
> classification, and the deterministic fleet maps that classification into
> concrete engineering.**

The 14B carrying technical understanding does not violate "the operator writes pure
product": the 14B *is* the system, not the operator.

## 3. Ownership model

| Layer | Owns | Grain |
|---|---|---|
| **Operator** | Product intent (what it does, how it looks/feels) | Natural language |
| **14B decompose** | product → platform classification + product decomposition | COARSE, fixed enums (like the existing `complexity` label) |
| **System / fleet** (deterministic + curated) | ALL concrete tech: scaffold, versions, TFM, RID, structural contract, gates, the label→profile map | Exact, version-pinned |
| **Operator (confirm)** | Sanity-check the resolved platform at the cheapest point | One line in the PLAN preview |
| **Gates** | Structural + build + behavioral enforcement | Fail-closed, mutation-resistant |

## 4. End-to-end data flow

```
OPERATOR (product intent: "a calculator that looks like a rocket")
 │
 ▼
14B DECOMPOSE ── classifies (coarse, fixed enums) ──▶ acceptance.json
 │   build_plan.surface:       desktop-gui            { spec + build_plan }
 │   build_plan.complexity:    moderate   (exists)
 │   build_plan.components:     [calculator-core(testable-logic), ui-shell(gui-shell)]
 │   build_plan.language_hint:  null   (set only when product implies it)
 ▼
SYSTEM MAP (deterministic, curated)  Resolve-BuildProfile(surface, language_hint, repo)
 │   → { scaffold, language, tfm, rid, packages[], structural_contract, staged }
 ▼
PLAN PREVIEW: "Building this as: a Windows desktop app (WinUI 3)."
 │   ◀── operator confirms here, for free, BEFORE any GPU time  (reuses #6 preview)
 ▼
approve → step-aside → load 30B
 ▼
SEED: scaffold + version pins + structural contract (+ optional knowledge pack)
 ▼
CODE (staged prompt: implement+test the CORE first, THEN theme the SHELL; fill slots)
 ▼
VERIFY:  struct:contract (fail-FAST, seconds) → build → run core tests
 │            └─ a violation feeds back through the existing error-feedback channel
 ▼
error / review feedback loops → merge or park → swap 14B back
```

## 5. Contracts (the schemas — system source of truth)

### 5.1 `build_plan` — 14B decompose output (added to `acceptance.json` spec)

```jsonc
"build_plan": {
  "surface":       "desktop-gui",   // enum, REQUIRED; the primary signal
  "language_hint": null,            // enum|null; set ONLY when product implies it
  "complexity":    "moderate",      // existing label, relocated under build_plan
  "components": [                    // optional; scales with complexity
    { "name": "calculator-core", "kind": "testable-logic" },
    { "name": "ui-shell",        "kind": "gui-shell" }
  ]
}
```

The 14B emits this from a tightly-constrained, enum-valued prompt (the exact
mechanism already proven for `complexity`, commit `380e1b2`). Anything it can't
classify → `surface: "unknown"`.

### 5.2 `surface` enum — the primary, reliably-inferrable signal

`surface` answers "what kind of thing does the product have?" — the most
product-meaningful dimension a small model can infer from intent alone:

| `surface` | Means | Default scaffold |
|---|---|---|
| `desktop-gui` | a window, buttons, a visual app | `winui` |
| `web` | a web page / browser app / REST service | `web` |
| `mobile` | a phone app | `android` |
| `command-line` | a terminal tool, no GUI | `dotnet-console` (or `language_hint`) |
| `automation` | OS / system scripting & admin | `powershell` |
| `library` | reusable logic / a script, no UI | `python` (or `language_hint`) |
| `unknown` | could not classify | NONE → today's conservative no-seed |

`language_hint` ∈ `{ python, dotnet, node, cpp, powershell, null }` — set only when
the product *explicitly* implies a language; it refines the ambiguous surfaces
(`command-line`, `library`). The system never guesses a language the 14B didn't
signal — the `unknown`/no-hint path is exactly today's behavior.

### 5.3 `BuildProfile` — system mapping output (deterministic, curated)

`Resolve-BuildProfile(surface, language_hint, repo)` →

```jsonc
{
  "scaffold":   "winui",
  "language":   "csharp",
  "tfm":        "net8.0-windows10.0.19041.0",
  "rid":        "win-x64",
  "packages":   [ "Microsoft.WindowsAppSDK 1.8.260508005",
                  "Microsoft.Windows.SDK.BuildTools 10.0.26100.8249" ],
  "structural_contract": { /* §5.4 */ },
  "staged":     true                 // this surface has a testable-core/shell split
}
```

This is the curated knowledge — the system supplying tech. It is the SINGLE place
a version/TFM/RID lives (today they're scattered across the AGENTS.md note + each
scaffold's csproj). `Resolve-TaskScaffold` is changed to **prefer the profile's
scaffold**, falling back to today's keyword/manifest heuristic only when
`surface == unknown` — strictly additive, never worse than now.

### 5.4 `structural_contract` — what the fail-fast gate enforces (per profile)

```jsonc
{
  "max_projects":      1,                       // exactly one csproj/pyproject…
  "project_globs":     [ "*.csproj" ],
  "entry_points":      [ "App.xaml.cs" ],       // the only allowed entry
  "forbid_extra_entry_points": true,            // no rogue Program.cs / 2nd Main
  "forbid_top_level_statements_outside": [ "App.xaml.cs" ],
  "test_dir":          "Tests/"                 // where tests belong
}
```

When no profile resolved (`unknown`), the contract is **absent** and the struct
gate is a no-op — so it can never false-fail a path we didn't define.

### 5.5 `components` / `kind` — drives within-task staging

`kind` ∈ `{ testable-logic, gui-shell, web-endpoint, cli-command, … }`. The fleet
uses it to STAGE the coder prompt without spawning extra fleet tasks (§6.3).

## 6. The three increments

### Increment 1 — platform signal flow + preview confirm  *(the headline fix)*

- **BlarAI (runtime):** the 14B decompose emits `build_plan.surface` (+ optional
  `language_hint`, + relocate `complexity` under `build_plan`) from an enum-
  constrained prompt; validate against the enum, fail-closed to `unknown`. Surface
  the resolved platform in the PLAN preview ("Building this as: …").
- **Fleet (agentic-setup):** add `Resolve-BuildProfile`; change `Resolve-TaskScaffold`
  to prefer the profile, fall back to the heuristic on `unknown`; thread the
  profile's language pin from the profile (not from a manifest that doesn't exist
  in an empty repo).
- **Why first:** alone, this would very likely have *merged* this run — the scaffold
  would have seeded and the proliferation would not have started from zero.
- **Verify off-dispatch:** a live decompose (does the 14B emit `surface: desktop-gui`?)
  + the fleet unit gate (`Resolve-BuildProfile`/`Resolve-TaskScaffold` mutation tests)
  + a scaffold seed-then-`dotnet build` (seconds).

### Increment 2 — structural fail-fast gate  *(cheap, high-leverage guardrail)*

- **Fleet only:** a pure `Test-ProjectStructure` in `fleet-lib.ps1` enforcing the
  profile's `structural_contract`, run as an EARLY `struct:contract` verify check
  (before the expensive build). A violation routes through the EXISTING error-feedback
  channel ("this is a WinUI app — the entry is App.xaml.cs; put tests in Tests/").
- **Why:** converts the exact 30-min-churn-to-park we watched into a seconds-fast,
  recoverable loop. Independent of Increment 1; fail-closed; no contract → no-op.
- **Verify off-dispatch:** a new `verify-struct.ps1` mutation suite (a proliferated
  tree goes RED; a clean tree passes).

### Increment 3 — core/shell scaffold + staged prompt + slot-filling  *(the real unlock)*

- The master lesson is decomposition into small verifiable units — but doing that as
  *separate fleet tasks* caused the over-decomposition tax (a worktree + swap per
  task). The move: **decompose the WORK without decomposing the INFRASTRUCTURE.**
- **Fleet:** for a `staged` surface, the scaffold ships the **core/shell split**
  pre-wired — a `Calculator.cs` with TODO slots + a REAL test project the gate runs,
  plus an `App`/`MainWindow` shell with named hooks. The coder prompt is *staged*:
  "(1) implement the core and make its tests pass — real behavior, gate-enforced,
  retry-on-test-failure converges it; (2) THEN theme the shell — build-only + the
  operator's eyeball." The model fills known slots in a known-good structure instead
  of inventing architecture from zero.
- Composes with the existing right-sizing (this is the *within-task* structure, not
  more tasks) and with Increment 2 (the slots ARE the structural contract).
- **Verify off-dispatch:** seed the core/shell scaffold, run the gate's `dotnet build`
  + the core unit tests (seconds); confirm the staged prompt reaches the coder (a
  wiring test, the established `verify-*.ps1` pattern).

### Increment 4 — confidence-gated clarifying question (ask-when-ambiguous)  *(after the 1–3 dispatch proof)*

The operator's idea, scoped to avoid the rubber-stamp-quiz failure mode. The 14B does
NOT quiz the operator on every goal — it asks ONE targeted question ONLY when the
surface is genuinely ambiguous. A confidence-gated ladder:

- The 14B classifies `surface`. **Clear** (most goals: "a calculator with buttons" →
  GUI; "a script that renames files" → script) → guess + confirm in the preview
  (Increment 1). **Ambiguous** (e.g. GUI-but-which-device: desktop vs web vs phone) →
  ask one curated question.
- **The system owns the question; the 14B only flags the ambiguity.** Do NOT have the
  small model write the question (small models write irrelevant/leading ones). The 14B
  emits only the ambiguity + candidates (e.g. `surface: ambiguous`, `candidates:
  [desktop-gui, web, mobile]`); the SYSTEM holds a small curated DECISION MAP keyed on
  the candidate set ("Where will you use it? ① On this computer ② In a web browser
  ③ On a phone"), each answer mapping deterministically to a surface.
- **Scope discipline — keep the map SMALL.** Ask only for a decision that (a) materially
  forks the build, (b) the 14B genuinely can't assume, AND (c) the operator can answer
  (product-level, never tech). Platform/device is the textbook case. Everything else
  stays assume-and-show-in-the-preview (#6). A novice quizzed per-detail rubber-stamps —
  worse than not asking. Same principle as routing consent to the coarsest meaningful
  grain: ask the human only what they can actually judge.
- **Builds on Increment 1** — `surface: unknown`/ambiguous is the trigger hook (no Inc-1
  rework). Cost: one interactive disambiguation sub-state in the dispatch flow (the #6
  one-pending-slot concern — bounded; the flow already has a pending-approval state).
- **Sequenced AFTER the 1–3 dispatch proof** because Increment 1 IS the experiment that
  tells us whether the 14B classifies `surface` reliably enough for ambiguity-detection
  to be meaningful. Shaky classifier → lean on guess+confirm; solid → the ask-ladder is
  realistic.
- **Verify off-dispatch:** the interactive turn + the decision-map mapping are
  unit-testable; the 14B's ambiguity-detection quality needs a live decompose (not a
  full dispatch).

## 7. Backward-compatibility & fail-closed properties (the safety case)

Every increment is **strictly additive**:

- Absent/`unknown` `surface` → no profile → no seed → **exactly today's behavior**.
- No profile → no `structural_contract` → the struct gate is a no-op (can't false-fail).
- No scaffold → no staging → today's single-pass prompt.
- A wrong 14B classification is caught at the **cheapest** point (the operator
  confirms the resolved platform in the preview, before any GPU time), and downstream
  by the build/criteria gates (a console scaffold can't satisfy a `visual` criterion).

So the change can never make a currently-working dispatch worse; the worst case is
"no improvement, behaves as today."

## 8. Build order & verification strategy

1. **Increment 1** (BlarAI label + preview ∥ fleet profile map) — the headline fix.
2. **Increment 2** (struct fail-fast gate) — cheap guardrail.
3. **Increment 3** (core/shell scaffold + staged prompt) — the deep capability.
4. **Increment 4** (confidence-gated clarifying question) — AFTER the 1–3 dispatch proof; gated on the live decompose showing a reliable `surface` classifier.

Each is builder-built (BlarAI runtime) or LA-built + adversarially gated (fleet),
verified **off-dispatch** by the unit gate / scaffold builds / a live decompose.
**One** consolidated `/dispatch rocket-calc` at the very end proves the whole chain
on-hardware (the operator's velocity constraint: pay the 30-min GPU cost once). NOTE: the seed has NEVER engaged in a live dispatch
(`verify-scaffold` is unit-only), so the gate on that run must prove TWO things, not one
— (a) the label routed AND the scaffold actually copied in (the `seed:` baseline commit
+ the skeleton on the branch), and (b) the seed delivered: one project the coder
extended, no proliferation, clean build. SCHEDULE (operator, 2026-06-24, clarified): a TEST DISPATCH runs after EACH of
Increments 2, 3, and 4 — one per increment, NOT one combined run — so each increment is
validated on-hardware as it merges. Increment 4 is additionally de-risked BEFORE its build
by an off-dispatch live decompose (the PLAN step with the loaded 14B, seconds) that checks
the 14B classifies surface/ambiguity sensibly.

## 9. Risks / open questions

- **14B mis-classification.** Mitigated by the enum constraint, the preview confirm,
  and the downstream gates. Watch the first live decompose.
- **`command-line` / `library` language ambiguity** (python vs dotnet vs powershell).
  Resolved by `language_hint` when the product implies it; otherwise a house default
  per surface, refined as we see real goals. Not on the critical path for the WinUI
  proof.
- **Scaffold staleness.** The BuildProfile becomes the single home for version pins;
  the scaffolds' csprojs should read as the profile's mirror, not a second source of
  truth (a follow-up consolidation, not a blocker).

- **The 30-min circuit-breaker pre-empts the feedback loops.** A wall-clock timeout is
  NEVER resampled and skips error-feedback/review entirely — so a single long churn parks
  with no recovery. The seed (one project, not ten files) + Increment 3's staging are the
  cure. Operational fallback for the proof dispatch: the themed rocket calculator is
  XAML-heavy and may still time out; if it does, drop to a PLAIN calculator rung first to
  isolate the signal-flow fix, THEN add theming (the staged ladder). Capture Intel UT
  start-to-finish on that run.

*Implementation map (exact file:line insertion points) lives in the per-increment
builder briefs, derived after the BlarAI + fleet path traces.*

---

## 10. Iteration-budget policy (build/review passes)

**Mechanism.** The 14B's `complexity` label scales the loop via `Resolve-PassBudget`:
simple → 2 build / 1 review, moderate → 3/2, complex → 5/3. The label rides the same
build-signal channel as `surface` (the 14B classifies; the system maps).

**The budget is variance insurance, not a capability multiplier.** Error-feedback and
resample reliably converge a small model on a *random, specific* slip (a one-off compile
error, a transient logic miss — the journal's ~1-random-slip-per-implementation floor,
retryable). They do NOT converge a *consistent* problem (a capability gap or a spec
ambiguity) — it fails the same way every pass, so an Nth pass is the 1st pass again.

**Practical ceiling ≈ 3 build passes**, bounded by three limits (not the mechanism):
1. **Convergence kind, not count** — random slips converge in ~2–4 passes (a Python
   classifier converged in 4 auto-retries); a consistent problem never does.
2. **Context bloat turns extra passes negative** — error-feedback appends the failure to
   the prompt; a long prompt *regresses* a small model (measured: the lean prompt beat the
   heavy one). Passes 5–6 can do worse than pass 2.
3. **Wall-clock** — each pass can run to the 30-min circuit breaker, so 5 passes is up to
   ~2.5 h of GPU time for one task — impractical to run consistently.

**Decision (LA 2026-06-24, operator-endorsed reasoning):** keep the build budget modest —
cap around **3 even for "complex."** The leverage for hard builds is **prevention** (a
richer seed/scaffold shipping a working test project — Increment 3) and **decomposition**
(sizing units the model one-shots), NOT more retries. Raising the budget does not solve a
consistent failure — live proof: the Inc-2 `rocket-calc` run would fail the same
offline-test-framework problem on pass 5 as on pass 2. Path not taken: bumping
complex→8/10 to "force" hard builds through (rejected — pays 30 min/pass to re-confirm a
consistent failure, and bloats the prompt against the model).

**Open measurement (set the cap empirically, don't trust the estimate):** the **pass-N
convergence rate** — across a batch, the fraction of tasks that fail pass N and go green on
pass N+1. Prior: it falls off a cliff after ~3. Measure once the pipeline is proven and set
the budget map from the data, not the estimate.
