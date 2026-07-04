# BlarAI Builder Brief — Increment 1: the 14B emits the build-signal (BlarAI side)

**Audience:** a BlarAI builder session/subagent. **Author:** Dispatch LA.
**Tracking:** Vikunja #674 (under #670). **Design SSOT:**
`agentic-setup/docs/dispatch-build-signal-architecture.md` — read §2–§5 first.

**Start with a comprehension gate** (restate the task + your plan, wait for the
LA's go) before writing code, per BlarAI convention.

---

## Why this exists (one paragraph)

A pure-product `/dispatch` goal ("a calculator that looks like a rocket") carries no
tech signal, so the fleet's conservative scaffold picker no-ops, the 30B authors a
WinUI project from scratch, proliferates files/projects, and parks on a build error
after a 30-minute churn (run `20260624-084153-bd`). The fix is to stop throwing away
the one component that DOES understand the platform — the 14B at decompose time. The
14B will emit a coarse, enum-constrained **build-signal**; the deterministic fleet
(the LA's separate work) maps it to a scaffold + tech. This brief is the **BlarAI
side only**: emit the signal, thread it to the fleet queue, show it in the preview.

**Verified finding you can rely on:** the coarse-signal *producer* channel does not
exist yet. `complexity` is *consumed* by the fleet but the 14B never emits it (the
BlarAI dispatch path has zero `complexity` references). You are building the producer
for the first time, carrying `surface` + `complexity` + `language_hint` together.

## The cross-repo seam (the contract — do not break it)

> **The fleet queue task object gains three fields: `surface`, `complexity`,
> `language_hint`.** BlarAI writes them onto each task; the fleet (LA's lane) reads
> them. That JSON contract is the entire interface. Do not build the fleet consumer.

## Scope

**In scope (BlarAI runtime):**
1. The 14B emits a `build_plan` object during PLAN, validated + fail-closed.
2. `build_plan` rides on the `AcceptanceSpec` (so `acceptance.json` + the PLAN_RESULT
   carry it) AND its per-task fields are threaded onto each `PlanResult` task object
   (so they reach the fleet queue write).
3. The PLAN preview shows a friendly "Building this as: …" line (display-only).

**Out of scope (do NOT touch):** the fleet (`agentic-setup/scripts/*`, `build-infra/*`),
`Resolve-BuildProfile`, `Resolve-TaskScaffold`, any scaffold. The flag stays
`enabled=false`. Never stage/commit the operator's uncommitted working-tree flips
(`default.toml enabled=true`, `services/ui_winui/MainWindow.xaml.cs`).

## The schema

Add to the `AcceptanceSpec` (frozen dataclass, `shared/fleet/acceptance.py:116-164`):

```python
build_plan: dict | None = None   # None when unclassified — preserves today's behavior
```

`build_plan` shape (all values from fixed enums; the 14B fills it):

```jsonc
{
  "surface":       "desktop-gui",   // REQUIRED enum (below). primary signal.
  "language_hint": null,            // enum|null — set ONLY when the product implies it
  "complexity":    "moderate",      // "simple"|"moderate"|"complex" (matches the fleet ValidateSet)
  "components": [                    // optional; [] is fine
    { "name": "calculator-core", "kind": "testable-logic" },
    { "name": "ui-shell",        "kind": "gui-shell" }
  ]
}
```

- `surface` ∈ `{ desktop-gui, web, mobile, command-line, automation, library, unknown }`
- `language_hint` ∈ `{ python, dotnet, node, cpp, powershell }` or `null`
- `complexity` ∈ `{ simple, moderate, complex }` (must match the fleet's
  `add-fleet-task.ps1 -Complexity` ValidateSet exactly)
- `kind` ∈ `{ testable-logic, gui-shell, web-endpoint, cli-command, data, other }`

**Fail-closed rule:** any parse/validation failure, missing field, or unknown enum
value → set that field to `null`/`unknown` (never raise, never block PLAN/EXECUTE).
`surface == unknown` must reproduce today's behavior exactly (no scaffold downstream).

## Tasks

### Task 1 — the 14B emits `build_plan`

Mirror the **assumptions** pattern (a SEPARATE small model call — do NOT fold into the
criteria call; the criteria JSON contract must stay byte-identical so existing tests
don't break):
- `_ASSUMPTIONS_TEMPLATE` at `acceptance.py:229-246`, parsed by `_parse_assumptions`
  (\~`acceptance.py:255`), called inside `generate_plan` (\~`acceptance.py:801-804`).
- Add a `_BUILD_PLAN_TEMPLATE` (enum-constrained prompt — copy the `tier` enum
  discipline from `_CRITERIA_TEMPLATE` at `acceptance.py:197-208`) + a
  `_parse_build_plan` (validate against the enums above; fail-closed). Call it in
  `generate_plan` after assumptions; attach the result to the spec.
- Update `AcceptanceSpec.to_dict()` / `from_dict()` (`acceptance.py:143-164`) to
  round-trip `build_plan` (None-safe).

The 14B prompt must ask it to classify from PRODUCT intent (does it have a window?
a web page? a phone screen? a terminal? is it just logic?) — keep it lean (the
journal's "over-long prompts regress a small model" lesson).

### Task 2 — thread the per-task fields onto the queue task objects

The fleet reads per-task data from the queue task object (it already reads
`$t.complexity`). So `surface`/`complexity`/`language_hint` (goal-level values, copied
to every task in this dispatch) must land on each `PlanResult` task object that
reaches the queue write.
- `generate_plan` builds tasks via `compile_prompts` (`acceptance.py:807`) and returns
  `PlanResult.tasks` (`acceptance.py:808-814`). Add the three fields to each task dict.
- **Trace the EXECUTE→queue-write yourself** and confirm the fields survive to the
  written queue. Candidate sites: `shared/fleet/dispatch.py::enqueue_task` (219-253,
  shells `add-fleet-task.ps1` — the deterministic path) and the swap path that the
  real `/dispatch` uses (`shared/fleet/swap_ops.py` / `swap_driver.py`, which writes
  `state/fleet-swap/task-queue.json`; and the EXECUTE handler in
  `services/assistant_orchestrator/src/entrypoint.py`). Thread the fields as far as
  BlarAI owns the write. If a path shells `add-fleet-task.ps1`, STOP at the boundary
  and note it in your report — the LA adds the `-Surface` parameter on the fleet side;
  do not edit `add-fleet-task.ps1`.

### Task 3 — the PLAN preview line (display-only)

- `render_criteria_preview` (`acceptance.py:628-690`; the task list renders \~652-656,
  called from `dispatch_coordinator.py:178`). Add a "Building this as: <friendly>"
  line driven by `spec.build_plan.surface`, via a small BlarAI-side surface→friendly
  map: `desktop-gui→"a Windows desktop app"`, `web→"a web app"`,
  `mobile→"an Android app"`, `command-line→"a command-line tool"`,
  `automation→"a system-automation script"`, `library→"a code library / script"`,
  `unknown→ (omit the line)`. Display-only, fail-closed, no state machine — same
  posture as the #6 assumptions block. No IPC change needed (`build_plan` rides inside
  the spec dict, which `encode_plan_result` already passes as arbitrary keys —
  confirm at `protocol.py:786-830`).

## Verification (mutation-resistant; the BlarAI bar)

You CANNOT load the 14B (that's the LA's on-hardware live-decompose at integration).
Verify the PLUMBING with injected fake `generate_fn` (the existing decompose/
acceptance tests already do this):
- A fake `generate_fn` returning a valid `build_plan` → assert it lands on
  `spec.build_plan`, threads onto every task object, and renders the preview line.
- **Fail-closed tests:** the 14B returns malformed JSON / a bad enum / no build_plan →
  `surface == unknown`, `build_plan` None-safe, PLAN still succeeds, the preview omits
  the line, and an `unknown` dispatch is byte-identical to today (add a regression
  asserting the existing no-build_plan path is unchanged).
- **Mutation-resistance:** for each new assertion, show it goes RED under a deliberate
  mutation (e.g. accept-a-bad-enum, or drop the threading) — don't just show green.
- **Do not weaken or rewrite existing decompose/criteria/assumptions tests.** The
  criteria + assumptions JSON contracts stay byte-identical (that's why build_plan is
  a separate call). Run the dispatch-relevant suite + the full standing gate; report
  the pass count (must not regress).

## BlarAI conventions (non-negotiable)

- Comprehension gate first; wait for the LA.
- Feature branch (e.g. `feat/674-build-signal-i1`); never commit to `main`.
- Ships **dormant** — do not flip `[fleet_dispatch].enabled`. Preserve the operator's
  uncommitted `default.toml`/`MainWindow.xaml.cs` flips (never `git add -A`).
- Journal fragment under `docs/journal_fragments/YYYY-MM-DD_<slug>.md` (parallel-safe).
- Report back: the diff summary, the new test count + the standing-gate number, the
  EXECUTE→queue-write trace result, and the exact boundary where you handed to the
  fleet. The LA independently gates (reads the diff, re-runs the suite, mutation-probes
  with its own inputs) before any merge.
