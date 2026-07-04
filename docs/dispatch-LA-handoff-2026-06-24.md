# Dispatch Lead-Architect (LA) — Session Handoff Brief

*Written 2026-06-24 by the outgoing LA session, which had grown too long and lost continuity (see §9). You are its replacement. You are launched at the **BlarAI CWD** (`C:\Users\mrbla\BlarAI`) and — per the operator — you **WILL work on the BlarAI runtime directly** (see §5; this is a deliberate change from the prior model). This brief is self-contained — all paths are absolute.*

---

## 0. READ THESE FIRST, in order — do NOT act before you have

1. Your **auto-loaded memory**, especially `blarai-headless-coding-dispatch.md` (the full program history + the CURRENT state) and the index `MEMORY.md`.
2. `C:\Users\mrbla\agentic-setup\docs\LESSONS-LEARNED.md` — the LA's dated running journal.
3. `git -C C:\Users\mrbla\agentic-setup log --oneline -30` and `git -C C:\Users\mrbla\agentic-setup status` — the ground truth of what is built.
4. The memory `compaction-can-erase-own-recent-work.md` — and **live by it**.

> **The in-tool TaskList does NOT persist across compaction.** Plan-of-record = the memory files + LESSONS-LEARNED + git. An empty TaskList does **not** mean "nothing done." Trust the artifacts (git log, files, tests) over any narrative recall.

---

## 0.5 FIRST ACTION — post a comprehension gate, then wait

Before doing ANY work, post a short **comprehension gate** for the operator and wait for his go: restate (a) your role + the default model (briefs+gate), (b) the current verified state (per the memory + `git log`), (c) the immediate task you're about to do, (d) any ambiguities or questions. This mirrors the dispatch program's builder-comprehension-gate convention, and it guards a fresh session against misreading the situation — the prior session's continuity slip (§9) is exactly why this matters.

## 1. Your role(s)

You are the **Dispatch Lead-Architect** for the **BlarAI headless-coding-dispatch program (#670)** — simultaneously:
- the operator's **technical proxy** (translate his intent into technical work; resolve tech questions yourself and recommend — never bounce a feasibility question back to him), and
- the **quality-gate** (before anything merges: read the actual diff, re-run the suites, mutation-probe with your own inputs, confirm dormancy + the operator's flips preserved). Since you now also **author** BlarAI runtime changes, you can no longer be a fully *independent* gate of your own work — use an adversarial/ultracode review for security-relevant runtime changes.

Your DEFAULT operating mode is the **guide model**: write **builder briefs** -> builder agents build (each in its own session) -> **you + the operator review/gate** their output. That separation of duties gives an *independent* review, which matters most on a security-first codebase, and it keeps the operator in the loop. You also hold direct-edit clearance (always for `agentic-setup` + the agent layer; for BlarAI runtime when a change is small/safe/urgent), but for **substantive** BlarAI runtime work, PREFER briefs+gate over building it yourself.

---

## 2. The operator (who you serve)

- A **novice, non-developer** building **BlarAI** — a serious, air-gapped, security-first local-LLM assistant.
- He **cannot decompose a spec or drive a coder** himself. The **NL → 14B-decompose → 30B-coder pipeline IS the deliverable** — never offer him the raw coder (OpenCode) as a substitute.
- He writes **natural-language PRODUCT intent** (detailed on what it does / how it looks; **no** technical direction). The **SYSTEM supplies all tech** (versions, TFM, RID) via the agent-layer `AGENTS.md` — never bake tech into his prompt.
- Standing preferences: **prose + a recommendation, not menus**; **mature-not-minimal** (Intel-grade bar; verify, don't assert); **mutation-resistant verification** (prove the tests can't false-pass: green → mutate → red); **always finish ALL cleanup before reporting back** (gate, durable commit, journal, memory); **drive autonomously when mandated** ("keep proceeding / you're approved").

---

## 3. Current state — DONE + VERIFIED (do NOT rebuild)

The #670 pipeline is **complete and proven end-to-end on-hardware** (palindrome-demo merged unattended, ~6 min). On top of that, the full **scaffold library + multi-pass maturation** all landed this session, **dormant**, on `agentic-setup` main:

- **7 gate-proven scaffolds** in `C:\Users\mrbla\agentic-setup\build-infra\<name>\reference\`: `winui`, `dotnet-console`, `python`, `web`, `powershell`, `cpp`, `android`.
- **7-domain knowledge packs** + an on-demand reference index (`build-infra\knowledge\`).
- **Error-feedback** (feed the build error back so the coder FIXES it, vs. blind resample) + **verify-output logging**.
- **Review-feedback multi-pass loop** (`97857ab`): on a `FIX FIRST` verdict it keeps the work and feeds the findings back for another pass on a SEPARATE budget — does not park.
- **Complexity signal** (`380e1b2`): the 14B sends `simple|moderate|complex`; the system scales the build + review pass budgets and hints the coder.
- **Dual-mode seeding** (`d1efe57`): seed up front, OR the coder pulls a scaffold mid-task.
- **Toolchains installed**: .NET MAUI workload + Microsoft OpenJDK 17 + Android SDK (Android builds offline); prerelease VS BuildTools/MSVC for C++.
- **Standing unit gate ~282/0** across `verify-{scaffold,errorfeedback,retry,reviewfeedback,complexity,merge-decision,ecosystem}.ps1`. Re-verified green this session (6/6 suites exit 0). **Working tree clean.**

---

## 4. The architecture

- **DISPATCH, not embed.** Operator NL goal → BlarAI's embedded **14B decomposes** → step-aside (release the 14B) → **30B coder loads via OVMS** → the **agentic-setup "fleet"** builds in an isolated git worktree → **deterministic verify gate** (build/test/lint) → **error-feedback / resample / review-feedback** passes → **auto-merge-or-park** to the target repo's `main` → **swap the 14B back**.
- **The fleet** (`C:\Users\mrbla\agentic-setup\scripts`): `run-fleet.ps1` → `new-agent-task.ps1` (worktree + scaffold seeding + the build/verify/review loop) → `verify-project.ps1` (the deterministic gate). Reusable, unit-tested logic lives in **`fleet-lib.ps1`** (pure functions: `Test-ShouldResample`, `Format-VerifyError`/`Add-BuildErrorFeedback`, `Resolve-TaskScaffold`/`Copy-ScaffoldInto`, `Add-ReviewFeedback`/`Test-ShouldContinue`, `Resolve-PassBudget`, `Add-ComplexityHint`, …) — each with a `verify-*.ps1` mutation-resistant suite. **This is the pattern: testable logic in `fleet-lib.ps1`, a `verify-*.ps1` that drives the REAL function + wiring asserts + kill-tests.**
- **Scaffold seeding**: `Resolve-TaskScaffold` (goal + has-a-project? → scaffold name; no-clobber guard + web-guard; conservative — never guess a language on an ambiguous goal) → `Copy-ScaffoldInto` (recursive copy + offline `nuget.config`) → committed as the coder's BASELINE `$codeBase`; the coder EXTENDS it. `AGENTS.md` instructs the coder to extend a seeded skeleton, not re-scaffold.
- **The coder** = OpenCode (the 30B via OVMS), routed through the **qwen-proxy on :8099** (OVMS's qwen3coder tool-call parser is the reason). It reads **`C:\Users\mrbla\.config\opencode\AGENTS.md`** (the **agent layer** — your lane) for all build/env facts. `sync-harness.ps1` mirrors that live file ↔ `agentic-setup\configs\AGENTS.md`.
- **Ships DORMANT**: `[fleet_dispatch].enabled=false` in BlarAI's `default.toml`.

---

## 5. The FENCES — do NOT cross

- **Direct-edit clearance — use it as the EXCEPTION, not the default.** The prior hard "never edit BlarAI runtime" fence is **lifted**: you MAY edit BlarAI runtime directly for small/safe/urgent fixes (and always for `agentic-setup` + the agent layer `~/.config/opencode/AGENTS.md`). **But your DEFAULT for substantive BlarAI work is briefs+gate** (brief -> a builder agent builds -> you + the operator review) — it preserves the *independent* review that direct-build forfeits, and on an air-gapped, security-first runtime that review is worth the extra step. (This supersedes the absolute "never touch BlarAI" framing the memory/journal still describe.) When you DO edit BlarAI directly: honor the design constraints below, and run an **adversarial/ultracode** review before committing anything security-relevant — don't self-certify.
- **Never stage/commit the operator's uncommitted flips.** His BlarAI working tree has `default.toml` `enabled=true` + a `MainWindow.xaml.cs` edit on purpose. **Never `git add -A` in BlarAI**; preserve them through any operation.
- **BlarAI runtime = absolute air-gap** (no network, fail-closed). The 14B reaching the network (websearch / ingest) is a **dormant, governed egress decision** — don't casually wire it. Knowledge packs are grown by **dev-layer curation INTO the offline library**, never by the air-gapped runtime live-browsing.
- **Scope controls to the agent layer** — never harden the OS/firewall for the coder.
- The fleet ships **dormant**; don't flip the flag.
- **Security posture for OS/device packs** (Win11-admin, Bitdefender, Synology, infra/DevOps): the agent **writes** scripts; **destructive ops** (Disable-BitLocker, Clear-Tpm, scheduled tasks, firewall changes) are **operator-reviewed-and-run, never gate-executed**; OS-admin packs are parse-check only.

---

## 6. The genuine NEXT step (the only open item)

**The on-hardware end-to-end `/dispatch` PROOF of the matured pipeline** — scaffold-seed + error-feedback + review-feedback + complexity-scaling, exercised live. Best target: **`rocket-calc`** (WinUI). It now gets the seeded skeleton that already carries `using Microsoft.UI.Xaml;`, so the **CS0246 ceiling that kept parking it should be gone**. The unit gate is green; **the live round-trip is the remaining evidence.** This is operator-run: he dispatches; you **narrate from the state files** (`agentic-setup\state\fleet-runs\<id>\` + `state\fleet-swap\current.json`) and **gate the outcome**. This is NOT more building.

---

## 6.5 IMMEDIATE JOB — monitor + analyze the live dispatch (the operator has launched one)

The operator has launched a dispatch and wants you to **monitor it, analyze its outputs, run the Intel UT telemetry, and compare runs against each other** — pure guide/analyst work, no building:

1. **Monitor the live run** from the state files: `C:\Users\mrbla\agentic-setup\state\fleet-runs\<run-id>\` (`swap-progress.log`, `run-fleet-*.log`, `SUMMARY.txt`) and `...\state\fleet-swap\current.json` (the `phase`). A background poll-loop watching `phase` + the appearance of `SUMMARY.txt` works well; the operator likes live narration from these.
2. **Analyze outputs**: the verify-gate result + the captured build errors (the run log now carries them), the review verdict(s) + any review-feedback passes, the complexity label + the budgets it drove, and merge-vs-park WITH the reason. If it parked, read the `agent/<slug>` branch + the report.
3. **Intel UT telemetry — YOU run these; the operator explicitly does NOT ("please don't make me do any of that"), and you're in an elevated shell.** Toolkit = Intel Unified Telemetry 0.2.0-beta1.1: extract from `C:\Users\mrbla\Downloads\ut-tool-ext-v0.2.0-beta1.1.zip` (gives `ut.exe` + `bin2perfetto.exe`); needs admin (EMON driver). Useful metrics: `ddr-bw`, `npu-pwr`/`npu-bw`, `pkg-pwr`, `cpu-igpu-concurrency`. **Capture DURING the run** (the swap + 30B load + build is the interesting window). See `[[intel-unified-telemetry]]` and `C:\Users\mrbla\agentic-setup\docs\telemetry-profiling-plan.md`.
4. **Compare runs against each other**: time-to-first-artifact, total wall-clock, resample + review-pass counts, merge-vs-park, and the UT power/bandwidth/concurrency profile per run. Produce a side-by-side so the operator can see which run/approach performed best (e.g. seeded vs unseeded, error-feedback on/off, complexity budgets).

## 7. Hard-won gotchas (verified facts — honor them)

- **WinUI build**: hand-authored SDK-style csproj; **singular** `<RuntimeIdentifier>win-x64</RuntimeIdentifier>` + `<Platform>x64</Platform>` (plural defaults to AnyCPU → *"WindowsAppSDKSelfContained requires a supported Windows architecture"* false-fail → park); pinned `Microsoft.WindowsAppSDK 1.8.260508005` + `Microsoft.Windows.SDK.BuildTools 10.0.26100.8249`; **build under a SHORT path** (`C:\bw`) — the net472 `XamlCompiler.exe` hits MAX_PATH (`WMC1006`) on deep worktrees; offline NuGet feed at `C:\Users\mrbla\blarai-build\nuget-feed`.
- **The 30B's WinUI ceiling**: it writes `RoutedEventArgs` handlers but omits `using Microsoft.UI.Xaml;` → CS0246, on every blind resample. The **seed prevents** it; **error-feedback recovers** from it.
- **C++**: the box's only toolchain is a **prerelease VS BuildTools 17.14 / MSVC 14.44**; `vswhere` needs `-all -prerelease`; cmake's VS generators can't find it → `scripts\build-cpp.ps1` uses **vcvars + `cmake -G Ninja`**.
- **Android**: JDK17 (`JAVA_HOME`) + Android SDK (`%LOCALAPPDATA%\Android\Sdk`, `ANDROID_HOME`/`ANDROID_SDK_ROOT`) installed; a single-TFM `net8.0-android` csproj builds under the existing `dotnet:build` gate; detection is **build-signal-only** (ordered before winui so "MAUI android" → android).
- **Python gate**: `uv run --no-project --with pytest pytest` — the `--no-project` avoids the setuptools flat-layout "Multiple top-level modules" trap that once parked a run.
- **Detection over-match lesson**: `nuget` (also PSGallery/vcpkg), the `.net` TLD, and a `dotnet` CLI mention must NOT hijack powershell/cpp; `dotnet-console` is ordered LAST and the `.NET` token is anchored. An ultracode panel found this; a builder's own green suite missed it (never combined the tokens in one test). **When you gate, combine tokens adversarially.**

---

## 8. Standing duties + workflow

- **Maintain `agentic-setup\docs\LESSONS-LEARNED.md`** (dated running log; ✅/❌/🔬; "→ BlarAI:" notes) on every milestone/decision/lesson.
- **Keep the memory current**, especially `blarai-headless-coding-dispatch.md` — convert relative dates to absolute.
- **Vikunja** tracking (localhost:3456) per BlarAI conventions, wired at **`agentic-setup\.mcp.json`** — so for Vikunja/MCP, operate from `agentic-setup`. You may be starting at the BlarAI CWD, but the dispatch work itself is mostly `agentic-setup` + the agent layer: **`cd C:\Users\mrbla\agentic-setup` for fleet work.**
- **Commit** fleet/agent-layer work directly to `agentic-setup` main (house convention). End commit messages with the `Co-Authored-By:` / `Claude-Session:` trailers.
- **"ultracode"** = a multi-agent adversarial `Workflow` review (find → independently refute → synthesize). Use it for high-stakes gates.

---

## 9. Why this handoff exists (the lesson — internalize it)

The outgoing session grew too long and **context compaction erased its recall of its own recent commits**. It twice mistook its own committed work for "a parallel process" and nearly rebuilt a finished, gate-proven Python scaffold. The operator caught it: *"we only have what you built; if you don't think you built it then you forgot that you built it."* **The work was never harmed — the durable record held — but recall-based judgment became unreliable.** Your safeguard: **trust the artifacts over memory; run `git log` + the tests BEFORE building; the durable docs are the plan-of-record.**

---

*End of brief. The state is clean and green; nothing dangles. Read §0, confirm with `git log` + a gate run, then drive §6.*
