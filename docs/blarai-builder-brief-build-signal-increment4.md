# BlarAI Builder Brief — Increment 4: confidence-gated clarifying question (ask-when-ambiguous)

**Audience:** a BlarAI builder session/subagent (all work in `C:\Users\mrbla\blarai`).
**Author:** Dispatch LA. **Tracking:** Vikunja #677 (under #674 / #670). **Design SSOT:**
`C:\Users\mrbla\agentic-setup\docs\dispatch-build-signal-architecture.md` §6 Increment 4
(+ §7 backward-compat, §9 risks). This is the LAST increment of the build-signal architecture.

Lead your final report with a comprehension summary + plan; do NOT merge — leave it on a branch
for the LA's gate. Create your own isolated worktree off `blarai` main
(`git -C C:/Users/mrbla/blarai worktree add C:/Users/mrbla/blarai/.worktrees/677-clarify -b feat/677-clarifying-question main`);
NEVER `git checkout`/`switch` the main `blarai` checkout (the LA gates from it). Verify
`git branch --show-current == main` for the main checkout before assuming anything.

---

## The idea (scoped to avoid the rubber-stamp-quiz failure mode)

When the 14B decomposes a goal it classifies `surface` (Increment 1). For MOST goals the surface
is clear → guess + confirm in the preview (today's behavior, unchanged). ONLY when the surface is
genuinely **ambiguous** — the textbook case is *GUI-but-which-device: desktop vs web vs phone* —
the system asks ONE curated, product-level question. The 14B does NOT write the question (small
models write leading/irrelevant ones): **the 14B only FLAGS the ambiguity + candidates; the SYSTEM
owns a small curated DECISION MAP** that turns a candidate-set into the question and maps each
answer deterministically to a surface.

**Scope discipline — keep the map SMALL.** v1 ships the platform/device case ONLY. Ask only for a
decision that (a) materially forks the build, (b) the 14B genuinely can't assume, and (c) the
operator can answer (product-level, never tech). Everything else stays assume-and-show-in-preview.

## Part A — `shared/fleet/acceptance.py` (the logic; unit-testable, no model)

1. **Add an `ambiguous` surface sentinel** `SURFACE_AMBIGUOUS = "ambiguous"` — DISTINCT from
   `SURFACE_UNKNOWN`. Add it to `SURFACE_VALUES` so `_parse_build_plan` accepts it.
2. **Parse `candidates`** in `_parse_build_plan`: a new optional `candidates` list of surface
   strings, validated fail-closed (keep only members of the REAL surface enum — desktop-gui / web /
   mobile / command-line / automation / library; drop unknown/ambiguous/garbage; dedupe; cap small,
   e.g. 4). **Fail-closed coupling:** if `surface == "ambiguous"` but fewer than 2 valid candidates
   survive, coerce `surface -> unknown` and `candidates -> []` (an ambiguous flag with no real fork
   is meaningless → today's behavior). Non-ambiguous surface → `candidates` forced to `[]`.
3. **The curated DECISION MAP** — `_CLARIFY_DECISION_MAP`, keyed on the **sorted tuple** (or
   frozenset) of the candidate-set, value = `{question, options: [{label, surface}]}`. v1 entry —
   the platform case, for the candidate-set `{desktop-gui, web, mobile}` AND its 2-way subsets
   ({desktop-gui, web}, {desktop-gui, mobile}, {web, mobile}):
   `question="Where will you mainly use this?"`, options labelled `On this computer`→`desktop-gui`,
   `In a web browser`→`web`, `On a phone`→`mobile` (include only the options whose surface is in the
   candidate-set). Keep the labels product-level and novice-friendly.
4. **`resolve_clarifying_question(build_plan) -> dict | None`** — returns `{question, options}` ONLY
   when `surface == "ambiguous"` AND the candidate-set has a map entry; else `None` (no question →
   today's behavior). PURE, no model.
5. **`apply_clarification(build_plan, chosen_surface) -> build_plan`** — returns a NEW build_plan
   with `surface = chosen_surface` (validated: must be one of the build_plan's own candidates; an
   off-list answer is ignored → returns the plan unchanged so the caller can re-ask/fall back),
   `candidates` cleared. PURE.
6. **Update `_BUILD_PLAN_TEMPLATE`** — add, gated and explicit: *"Use surface = 'ambiguous' ONLY if
   the request genuinely does not say whether it runs on this computer, in a web browser, or on a
   phone — and then list the 2-3 candidate platforms in a 'candidates' array. If you can reasonably
   tell, classify normally. Do NOT use 'ambiguous' as a hedge — over-asking is worse than a wrong
   guess the operator corrects in the preview."* Keep the template SHORT (the small-model
   long-prompt-regression lesson).
7. **Backward-compat (lock it):** absent `candidates` / any non-ambiguous surface →
   `resolve_clarifying_question` returns `None` → **byte-identical to today**. A `surface == unknown`
   dispatch is unchanged.

## Part B — `services/ui_gateway/src/dispatch_coordinator.py` (the interactive sub-state)

Study the EXISTING PLAN-preview → operator-confirm flow first. Add ONE bounded interactive
sub-state, extending the existing pending-approval machinery (do NOT add a parallel flow):

- After the 14B decompose produces the `AcceptanceSpec`/`build_plan`, call
  `resolve_clarifying_question`. If it returns a question, the coordinator surfaces the question to
  the operator (the curated options) as a pending interactive turn BEFORE the normal PLAN preview;
  on the operator's choice, `apply_clarification`, then **re-resolve** anything derived from surface
  (the fleet BuildProfile is resolved fleet-side, so here it's enough to thread the chosen surface
  into the build_plan that rides the task), then proceed to the normal PLAN preview + confirm.
- If `resolve_clarifying_question` returns `None` → the flow is EXACTLY today's (no extra turn).
- Respect the #6 one-pending-slot concern: at most ONE clarifying turn per dispatch; a malformed /
  out-of-range answer falls back to proceeding with the un-refined plan (never a hang/loop).

If a new IPC field/verb is genuinely needed (`shared/ipc/protocol.py`) to carry the question +
answer, add it metadata-only + backward-compatible (older payloads without it → no question). Prefer
reusing the existing PLAN-preview channel if it can carry an interactive question.

## Verification bar (off-dispatch, the "green E2E" the LA will re-run)

- **Unit (acceptance.py):** the decision-map mapping (each candidate-set → the right question +
  options), `apply_clarification` (chosen → surface; off-list → unchanged), the fail-closed coupling
  (ambiguous + <2 candidates → unknown), and the GATING **kill-tests**: a CLEAR surface
  (desktop-gui) → `resolve_clarifying_question` is `None`; a non-ambiguous plan is byte-identical.
- **Integration (coordinator):** a wiring test that an ambiguous build_plan drives the clarifying
  sub-state and the chosen answer threads the surface into the task; and the **kill-test** that a
  clear surface drives NO extra turn (today's flow).
- The **full BlarAI standing gate stays green** (run it LOCALAPPDATA-redirected to a temp dir —
  `$env:LOCALAPPDATA = <temp>` — BlarAI tests can write the real store):
  `pytest shared/ services/ launcher/ tests/integration/ tests/security/ -m "not hardware and not winui and not slow"`.
  Report the pass count (the LA's baseline was 3884/0 before dispatch work; report your delta).
- **NOT your job (the LA runs it):** the live 14B ambiguity-detection probe (does the model flag
  ambiguity sensibly) — that needs a real decompose. Surface any ambiguity-quality concern in your
  report.

## Constraints

`blarai` ONLY; strictly additive + fail-closed (a wrong/absent signal → today's behavior); ships
under the EXISTING dispatch enablement (no go-live / enabled-flag change — do NOT flip anything);
Python strict type hints + PEP 8; separate commits per part; **append a `BUILD_JOURNAL.md` journal
FRAGMENT** under `docs/journal_fragments/2026-06-24_inc4-clarifying-question.md` (parallel-safe —
do NOT edit `BUILD_JOURNAL.md` directly), dated `###` header + narrative + `**Next:**`. Update
`docs/DECISION_REGISTER.md` + ADR-035 (the Acceptance Layer ADR) with the clarifying-question
amendment if you author one. Report: the diff, the gate pass count, the unit/integration evidence,
the worktree + branch. The LA independently gates (re-runs + reviews) before merge.
