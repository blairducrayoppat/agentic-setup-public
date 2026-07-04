# Fleet Builder Brief — Increment 2: build-profile mapping + structural fail-fast gate

**Audience:** a fleet builder session/subagent (all work in `C:\Users\mrbla\agentic-setup`).
**Author:** Dispatch LA. **Tracking:** Vikunja #675 (under #674). **Design SSOT:**
`agentic-setup/docs/dispatch-build-signal-architecture.md` §5–§6 (read first).

Lead your final report with a short **comprehension summary + plan** (there is no
interactive LA to gate mid-run; your report is the handoff to the LA's gate). Do NOT
merge — leave it on a branch for the LA to gate.

---

## Why this exists

A pure-product `/dispatch` goal ("a calculator that looks like a rocket") carries no tech
signal, so the fleet's conservative `Resolve-TaskScaffold` no-ops, the 30B authors from
scratch, proliferates, and parks. Increment 1 (already merged on the BlarAI side) makes the
14B emit a coarse `surface` label onto each fleet queue task. This ticket builds the FLEET
side: consume `surface` → seed the right scaffold, and add a cheap structural guardrail.

## The cross-repo seam (already LIVE — do not change it)

Each task object in `task-queue.json` (the file `run-fleet.ps1` reads) now carries three
extra fields beside `repo`/`task`/`prompt`:
`surface` (`desktop-gui|web|mobile|command-line|automation|library|unknown`),
`complexity` (`simple|moderate|complex`), `language_hint` (`python|dotnet|node|cpp|powershell|null`).
`surface == unknown` (or absent) MUST reproduce today's behavior exactly.

## Part A — the Increment-1 fleet consumer (the headline park-fix)

1. **`Resolve-BuildProfile` (new pure fn in `scripts/fleet-lib.ps1`).** Input: `surface`,
   `language_hint`. Output: a hashtable `@{ scaffold=<name|''>; structural_contract=<hashtable|$null>; staged=<bool> }`.
   Mapping:
   - `desktop-gui` → `winui` (staged=$true)
   - `web` → `web`
   - `mobile` → `android`
   - `command-line` → `language_hint`-refined (`python`→python, `dotnet`→dotnet-console,
     `node`→web, `cpp`→cpp, `powershell`→powershell), default `dotnet-console`
   - `automation` → `powershell`
   - `library` → `language_hint`-refined, default `python`
   - `unknown` / anything else → `scaffold=''`, `structural_contract=$null` (the fall-back path)
2. **`Resolve-TaskScaffold` (`fleet-lib.ps1:377-421`) prefers the profile.** Add a
   `-Surface`/`-LanguageHint` path: when `surface` is set+known, return the profile's
   scaffold; on `unknown`/absent, fall through to TODAY'S existing keyword/`-HasProject`
   heuristic UNCHANGED (strictly additive — never worse than now). Keep the existing
   signature working for callers that pass no surface.
3. **Thread `surface`/`language_hint` through the run path** the SAME way `complexity`
   already travels: `run-fleet.ps1:101-103` (forward `$t.surface`/`$t.language_hint` into
   the `new-agent-task.ps1` param splat), `new-agent-task.ps1` params (~:17), and the seed
   call site (`new-agent-task.ps1:77` — pass surface into `Resolve-TaskScaffold`). Add a
   validated `-Surface` to `add-fleet-task.ps1` (mirror the `-Complexity` ValidateSet at :10,26).

## Part B — the structural fail-fast gate

4. **`Test-ProjectStructure` (new pure fn in `fleet-lib.ps1`).** Input: a worktree path + a
   `structural_contract`. Returns a violation string (or `''` if clean). The WinUI contract
   (the proliferation case) enforces: exactly one `*.csproj`; for a `WinExe` no extra entry
   point (no `Program.cs`/`static … Main`); no loose top-level-statement `.cs` outside the
   allowed entry; no 2nd project. `structural_contract=$null` → return `''` (NO-OP — never
   false-fail an undefined contract).
5. **Wire it as an EARLY `struct:contract` check in `verify-project.ps1`** (checks are
   assembled `:31-34`; add this BEFORE the build checks at `:53`). On a violation: `Add-Result
   'struct:contract' 'fail' … <violation>` so it appears first and BEFORE the expensive build.
6. **Route a struct violation through the EXISTING error-feedback channel** (the runner
   already feeds a verify-fail back via `Format-VerifyError`/`Add-BuildErrorFeedback`,
   `fleet-lib.ps1:271-297`, called at `new-agent-task.ps1:139`). The coder gets "this is a
   WinUI app — the entry is App.xaml.cs; put tests in Tests/; one project" in seconds, not
   after a 30-min churn. No new feedback machinery — reuse the build-error path.

## Verification bar (off-dispatch, mutation-resistant — the standing pattern)

- **`verify-buildprofile.ps1`** + **`verify-struct.ps1`** suites driving the REAL functions
  + WIRING asserts (the surface reaches `Resolve-TaskScaffold`; a violation reaches the
  feedback prompt) + KILL-tests (each mutant flips an assertion). A proliferated tree (a 2nd
  csproj / a `Program.cs` with `Main` / a loose top-level `.cs`) goes RED; a clean seeded
  tree passes; `unknown`/no-contract is a proven NO-OP.
- **A real seed proof** (the seed has NEVER engaged in a live dispatch — `verify-scaffold`
  is unit-only): `Copy-ScaffoldInto` the winui scaffold into a temp worktree, then run the
  gate's exact `dotnet build` → 0/0, and `Test-ProjectStructure` → clean.
- The existing standing unit gate (`verify-{scaffold,errorfeedback,retry,reviewfeedback,complexity,merge-decision,ecosystem}.ps1`, ~282/0) must stay green.

## The over-match lesson (HONOR IT — it bit this exact area before)

An adversarial panel found the detection logic over-matches (`\bnuget\b` hijacking
powershell, the `.net` TLD, a `dotnet` CLI mention) where a builder's own green suite never
combined the tokens. When you test `Resolve-BuildProfile`/`Resolve-TaskScaffold`, COMBINE
TOKENS ADVERSARIALLY: prove a `surface=automation` + a "nuget"/".net"-mentioning prompt
still resolves to powershell, not a C# scaffold; prove `surface` PREEMPTS the keyword
heuristic only when known. Do not let the new surface path resurrect the over-match class.

## Constraints

- `agentic-setup` ONLY. Ships dormant (the fleet flag is BlarAI-side; don't touch it).
- No OS/firewall changes; scope every control to the agent layer.
- PowerShell 5.1 AND 7 safe (cache `$proc.Handle` before `.ExitCode`; UTF-8 BOM on `.ps1`;
  `$ErrorActionPreference=Continue` for native stderr). Separate commits for Part A vs Part B.
- Report: the diff summary, the new + existing gate numbers, the wiring/kill-test evidence,
  the real seed-build proof. The LA independently gates (re-runs + adversarial-combines
  tokens) before merge to agentic-setup main.
