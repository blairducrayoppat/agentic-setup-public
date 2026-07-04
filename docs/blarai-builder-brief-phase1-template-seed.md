# Builder Brief — Phase 1: dispatch CUSTOMIZES a complete template (not build from a demo)

**Audience:** a fleet/BlarAI builder session. **Author:** Dispatch LA. **Tracking:** Vikunja (LA opens).
Lead your report with a comprehension summary + plan; do NOT merge — leave it on a branch for the
LA's gate. Isolated worktree; NEVER `git checkout`/`switch` the main checkouts.

## Why (the constraint, researched)

A small local coder (the 30B) is reliable at **customizing a complete scaffold**, NOT at architecting
a whole app from scratch — this is the documented strength/weakness of small models (it excels at
filling boilerplate/structure; it fails at from-scratch architecture). The live proof: given a
minimal one-button demo seed + "build a rocket calculator," it produced a non-functional demo (a
keypad it never wired). The fix the research endorses (Retrieval-Augmented Code Generation): give the
model a **complete, working template** and have it CUSTOMIZE it. The operator will provide the
template per app (his stated, realistic workflow). [Phase 2, separate: the 14B *finds* the template
from a trusted GitHub allowlist via the dormant egress — NOT in scope here.]

## Scope (Phase 1, offline, operator-provided template)

1. **The mechanism — the dispatch seeds from an OPERATOR-PROVIDED complete template, then customizes
   it.** Investigate the dispatch→fleet seeding flow first (`scripts/fleet-lib.ps1`
   `Copy-ScaffoldInto`/`Resolve-TaskScaffold`/`Resolve-BuildProfile`, `scripts/run-fleet.ps1`,
   `scripts/new-agent-task.ps1`, and the BlarAI side that carries the goal). Then implement the
   LEAST-INVASIVE mechanism — pick ONE and justify it:
   - (a) **Detect a pre-seeded project:** if the dispatch target already contains a real app (the
     operator put a template there), SKIP the generic scaffold (don't overwrite it) and customize the
     existing app; or
   - (b) **An explicit `--template <path>` option** threaded through the dispatch → fleet that copies
     the operator's local template into the worktree instead of the generic scaffold.
   Whichever is cleaner. **Backward-compat is mandatory:** no template provided → today's generic
   scaffold path, byte-identical (lock it with a test).
2. **The CUSTOMIZE prompt (a new staged-prompt mode for the template path).** When the build starts
   from a complete template, the coder prompt must say: *"This project is a COMPLETE, WORKING app.
   Your job is to ADAPT it into: <goal>. Customize, restyle, rename, and extend it to match the
   goal, but KEEP all existing functionality working — every feature that works now must still work.
   Do NOT rebuild it from scratch and do NOT reduce it to a demo or a placeholder. Build on what runs."*
   Keep the existing no-second-project / no-test-framework / no-test-execution rules. Make this a pure
   function (like `Add-StagedHint`), gated on the template path; the non-template path is unchanged.
3. **A seeding guide** (`docs/`, operator-facing, plain-language): how to provide a GOOD template —
   it must actually run, be the right framework for the goal, have its tests already building, and
   ideally mark the parts to change. Local/operator-curated only (GitHub-fetch is Phase 2). Short and
   practical; the operator is a novice.
4. **One example complete template** under a new `build-infra/templates/` library — a small but
   **complete, working, NEUTRAL** app for one surface (a real winui app that runs and does something,
   NOT a calculator, NOT a one-button demo), as the reference + the library's first entry + proof the
   mechanism works end to end. Document the library layout so the operator can add more.

## Verification (off-dispatch)

- Unit tests (PowerShell verify-*.ps1 pattern and/or pytest): the template-selection logic (template
  present → customize path; absent → today's scaffold, byte-identical KILL-test), the customize-prompt
  pure function (template → the adapt instruction; non-template → unchanged), and an offline `dotnet
  build` proof that the example template + the seed-from-template both build 0/0.
- The full standing gates stay green (the PowerShell `verify-*.ps1` suite 406+/0 on PS 5.1 & 7; and if
  you touch BlarAI, the Python standing gate — LOCALAPPDATA-redirected, py3.11 `.venv`). Report counts.
- The LA runs the LIVE dispatch (customize a real template) — surface the exact command.

## Constraints

Primarily `agentic-setup` (the fleet); if a template field must ride the BlarAI dispatch flow, keep it
backward-compatible + minimal (absent → today). Ships dormant-safe (no template → today's behavior —
zero regression). Separate commits per part. Append a BUILD_JOURNAL fragment. Note: the LA has
uncommitted over-fit calculator edits in `build-infra/winui/reference/MainWindow.xaml*` — IGNORE them
(you branch off main, which is clean); the LA reconciles them at merge. Report: the diff, the gate
counts, the build proofs, the live-run command, the worktree + branch. The LA independently gates.
