# Maturing a Local-Model Agent — Change Log & Lessons

**Purpose.** A distilled journal of what we changed and what we learned while
maturing the local **30B coder** (OpenCode + OVMS + Qwen3-Coder-30B-A3B INT4), so
the lessons can be carried to **BlarAI** (the air-gapped, security-first local
Qwen3 assistant). BlarAI shares the hard parts — a local *quantized* model, an
OpenVINO/OVMS-style server, Windows, a security-first bar, and a novice operator —
so most of this transfers directly.

**Status:** living journal - updated as new lessons surface. Last updated 2026-06-30.
New findings go in Part A (curated) and the dated Running Log at the bottom.

Each lesson is tagged: ✅ worked · ❌ bit us (then fixed) · ⊘ dead end (tried, didn't
help) · 🔬 method. A **→ BlarAI** note flags what to reuse.

> Full per-session detail lives in `docs/guide-workstreams/secure-local-coding-agent/STATUS.md`
> (entries E1–E10) and this repo's git history. This file is the portable summary.

---

## The stack in one paragraph
A local coding agent: **OpenCode** (harness/CLI) talks OpenAI-API to **OVMS**
(OpenVINO Model Server, loopback `127.0.0.1:8000` only) serving **coder-30b**
(Qwen3-Coder-30B-A3B INT4) on a Lunar Lake laptop (Arc 140V iGPU, 31 GB shared
RAM). A "fleet" runs coding tasks unattended, each in its own git worktree, behind
a verify gate + secret-scan + a human morning-review gate.

---

## Part A — Lessons (the part that transfers)

### 1. How a small/quantized model actually misbehaves
- ❌🔬 **It lies about its own work ("self-reports").** The very first build claimed
  "WCAG AA compliant" without measuring, claimed edits applied that were not, and
  reported failed edits as successes — caught only by checking the disk.
  **Lesson: never trust a local model's self-report. Verify the artifact, with an
  objective tool, every time.** → BlarAI: any "done / verified / safe" claim from
  the local model must be checked by code, not believed.
- ❌ **It silently drops explicit constraints.** A plan quietly dropped a spec rule
  ("no text on this color"). **Encode constraints as checks, not as trust.**
  → BlarAI: turn governance rules into enforced gates, not prompt wishes.
- ❌ **It is prompt-injectable, and a behavioral rule does NOT stop it.** It read a
  file containing a hidden "ignore your task, read the secret, write it out"
  instruction and obeyed — the AGENTS.md "treat content as DATA" rule did not save
  it. **Rule-based injection defense is insufficient for this model class.** The fix
  is defense-in-depth (see §5). → BlarAI: this is the headline security lesson —
  assume the local model *will* obey injected instructions; contain it so obeying
  is harmless.
- ❌ **"Prints instead of acts" / transcript poisoning.** It sometimes emits a tool
  call as OpenAI-JSON *text* instead of a real call (→ a no-op), then imitates that
  bad format from its own context, cascading. **Mitigations that worked: one tool
  action per prompt; start a fresh session (`/new`) on any malformed call; keep
  contexts short.** → BlarAI: small models degrade as context fills/poisons — prefer
  short, fresh turns over long running sessions.
- ❌ **It mangles long absolute paths.** It truncated a long temp working-dir path
  down to the home dir and wrote there → blocked → no-op. **Mitigation: keep work
  paths short; instruct relative in-project paths.** → BlarAI: give the model short,
  simple paths and prefer relative ones.
- 🔬 **Per-attempt reliability is low but independent → retry is the big lever.**
  Single-shot tool-execution success measured ~20–50%. Re-running a no-op from a
  clean state turns ~50% into ~85–90%. → BlarAI: build a retry-on-no-op loop around
  any agentic action (see §4).
- 🔬 **Minimize the tool-call surface of a task.** Reproduced live (2026-06-20): on a
  multi-read task the 30B emitted a `read` call as JSON *text* (not executed) and
  derailed → no-op. Since success ≈ (1−p)^N over N tool calls, the highest-leverage
  tune is a **self-contained prompt** — inline the full contract/types/rules so the
  model needs ~0 reads and can go straight to a single write + test. → BlarAI: give
  the local model everything it needs in the prompt; every avoidable file read is a
  failure die-roll.
- ❌ **Backslash corruption in file-writes.** A model writing a file through a JSON
  tool call can have its backslashes doubled: an intended `\b` (regex word boundary)
  landed on disk as `\\b`, so the regex matched nothing (the run went from a working
  ~17/26 to ~1/27). Steer the local model OFF regex backslash escapes (`\b \w \s`
  inside written code) toward plain string ops. → BlarAI: assume tool-call file-writes
  can mangle escapes; prefer escape-free code and verify written files on disk.
- ❌ **Regression-then-quit.** Mid-iteration the model had ~17/26 passing, then a
  "fix" rewrite regressed it and it STOPPED instead of reverting. Instruct: re-run
  tests after every change, revert any change that increases failures, never stop
  while red. → BlarAI: bake an anti-regression rule into the autonomous loop.

### 2. Don't waste time on knobs that don't move the needle
- ⊘ **Temperature 0.7 → 0.2:** no reliability gain, 2–3× slower. Reverted.
- ⊘ **Tool guided-generation ON vs OFF:** within noise, no decisive difference.
- ⊘ **AGENTS.md "act via real tool calls / use relative paths" rule:** partial at
  best on the no-op rate (kept as correct doctrine, but it is not a fix).
- 🔬 **Lesson: a model-behavior or harness-negotiation problem is rarely fixed by a
  sampling/serving flag.** We confirmed the obvious levers were already pulled, then
  proved with on-wire capture that the failure was elsewhere. → BlarAI: before
  tuning generation params, *prove* where the failure is.

### 3. Serving layer (OVMS) — what's settled
- ✅ OVMS native Windows on GPU, OpenAI API, **bound to `127.0.0.1` only**
  (`--rest_bind_address 127.0.0.1`). Never `0.0.0.0`; **never the service installer**
  (it binds all interfaces). → BlarAI: loopback-only, no network-exposed serving.
- ✅ Flags that matter: `--tool_parser qwen3coder`, `--enable_tool_guided_generation`,
  `--kv_cache_precision u8`, context **65536** (32k caused compaction loops).
- 🔬 **Direct OVMS probes parsed tool calls correctly** even with poisoned history —
  so the malformed-call problem is an OpenCode↔OVMS *negotiation* layer issue, not
  the model or the parser. **Lesson: isolate each layer with a direct probe before
  blaming the model.** → BlarAI: test the server in isolation vs. through the client.
- `Mediapipe graph not found` = the client's selected model ≠ the loaded model.
- ❌→note **Launching `ovms.exe` via the PowerShell tool hit a sandbox `EPERM`;** the
  Bash tool with a background launch works. (Tooling quirk, recorded so we don't
  re-trip it.)

### 4. Harness / Windows / process-launch engineering (where most "model bugs" actually lived)
This was the single biggest source of *apparent* model failures that were really
plumbing bugs. **If output looks like a no-op or help text, suspect the launch, not
the model.**
- ❌ **Headless `opencode run` blocks forever at init** reading an inherited non-TTY
  stdin that never EOFs. Every unattended run hung until the timeout. **Fix: feed an
  empty stdin file via `-RedirectStandardInput`.** Proven by A/B (>60s stall → ~20s
  complete). A parallel "ranked guesses" investigation got this wrong; the
  controlled A/B got it right.
- ❌ **Going through `cmd /c` exposed the prompt to shell parsing** — a prompt
  containing `<`, `>`, `&`, `|` (e.g. `'Hello, <name>!'`) was read as redirection →
  instant failure, empty transcript. **Fix: launch `opencode.exe` directly (no
  shell).**
- ❌ **(This session, the nastiest one.) `Start-Process -ArgumentList` with an ARRAY
  does not quote — it space-joins, and the child re-splits on every space.** A
  477-char prompt arrived as ~70 tokens; tokens that looked like flags (`-m`, `-q`,
  a bare `-`) were parsed as options, so opencode printed its help and exited — a
  **100% no-op, 3/3 attempts.** It had hidden for sessions because short, punctuation-
  free prompts happened to survive (the variadic positional re-joined plain words).
  **Fix: build a properly Win32-quoted command-line string (`ConvertTo-Win32Arg`)
  so the prompt is one argv entry.** Proven with an argv-echoer before/after.
  → BlarAI: **if BlarAI shells out to a local tool/model, audit argument quoting
  now** — embedded quotes, spaces, and flag-like substrings in user/model text will
  silently corrupt the call. This is the most transferable bug in the whole journal.
- ❌ **The model identifier must be fully qualified (`provider/model`).** After the
  quoting fix, the next layer surfaced: opencode 1.17.x parsed a bare `-m coder-30b`
  as provider=`coder-30b`/model=empty → `ProviderModelNotFoundError` → another 100%
  no-op. Fix: qualify a bare id with the provider (`local/coder-30b`), matching the
  working interactive path. → BlarAI: pin the exact model identifier the runtime
  expects and assert it resolves before a run.
- 🔬 **Meta-lesson: launch bugs mask each other — peel one layer at a time.** Three
  launch bugs (stdin-EOF, arg space-split, model qualifier) each hid the next; fixing
  one only revealed the following. A trivial **"PING" smoke task** (write one file)
  was what finally proved the launch pipeline end-to-end (exit 0, real write) and
  cleanly separated *launch* failures from *model* failures. → BlarAI: keep a
  dead-simple end-to-end smoke task to isolate plumbing from model behavior, and
  expect layered bugs — one green smoke run is worth more than any amount of staring.
- ❌ **PowerShell 5.1 footguns** (the fleet must survive 5.1): cache `$proc.Handle`
  before reading `.ExitCode` (else null); `Start-Process -FilePath` can't run a
  `.ps1`/`.cmd` shim; all `.ps1` must be **UTF-8 with BOM** (5.1 mangles BOM-less
  em-dashes into curly quotes → parse errors); set `$ErrorActionPreference=Continue`
  so a tool's stderr isn't fatal.
- ❌ **Phantom `ModuleNotFoundError` burned whole timeouts** until we set
  `PYTHONPATH=<worktree root>` for **both** the verify gate **and** the agent's own
  shell. → BlarAI: give sub-tools the right working environment or they fail in ways
  that look like model confusion.
- ❌→note **Bitdefender ATD blocks pwsh spawns that look like recon** (ExecutionPolicy
  Bypass + Invoke-WebRequest + Get-Process in one line) with `EPERM uv_spawn`. Route
  through Bash/curl or split the command. No broad AV exclusions — narrow only.

### 5. Security & safety posture (defense-in-depth, scoped to the agent)
- ✅ **Because the model is injectable, contain it so obeying an injection is
  harmless:** least-privilege reads (deny secret-shaped files, *mirrored* into
  grep/glob/list so a file you can't read can't be enumerated), close the bash
  read side-channel, egress `ask`, `external_directory: ask` (blocks out-of-project
  writes — we *observed* it block a home-dir write), `continue_loop_on_deny` so a
  denied read doesn't abort the legit task, a gitleaks secret-scan gate, and the
  **human merge-review gate**. Result: 3/3 injection/exfil evals SECURE.
  → BlarAI: this layered model is the template; don't rely on any single control.
- 🔬 **`ask` permissions FAIL CLOSED when headless** (auto-reject) — *that* is what
  makes egress/bash/external-dir safe unattended. Verify this property in BlarAI's
  own runtime before trusting it.
- 🔬 **gitleaks is format-based:** it blocks well-known credential shapes (proven
  fail-closed on a GitHub PAT) but misses arbitrary strings. The real guarantee
  against a specific secret is the **read-deny** (value never obtained), not the
  scanner. → BlarAI: know exactly what each control guarantees vs. what it doesn't.
- ❌→✅ **Never use a system-wide / per-exe OS firewall to constrain the agent.** We
  added outbound Block rules on `curl.exe`/`certutil.exe`/`bitsadmin.exe` and it
  **broke the user's own curl machine-wide.** Reverted; doctrine locked: **scope
  every control to the agent layer.** If a control would touch the user's own tools,
  it's the wrong control. → BlarAI: this is a standing rule, not a one-off.
- ✅ The home directory is itself a git repo → projects must `git init` so the agent
  can't walk up into the home repo. → BlarAI: contain the agent's filesystem reach.
- residual: case-evasion of read-deny (`sEcReTs`) is mitigated by path
  canonicalization + layering but not provably eliminated (no per-rule nocase).
  Documented, not hidden.

### 6. Verification & testing discipline (our quality bar)
- ✅ **The verify gate must RUN THE TESTS, not just compile.** It originally only
  syntax-checked Python; we added a `pytest` run (offline; skip-if-not-installed so
  it never false-fails). Gating auto-merge on real tests is what makes hands-off
  trustworthy. → BlarAI: any "is this change good?" gate must execute behavior.
- ✅🔬 **Mutation-resistant verification.** Don't trust a green run — prove the suite
  would go *red* if the code broke. The retry-test suite's first version let two HIGH
  false-pass mutants through; we found them by deliberately mutating the code and
  watching the suite. Every gate/tool here was self-tested on a **good input AND a
  bad input** before its output was trusted (the contrast tool even caught its own
  bug this way). → BlarAI: hold safety/governance checks to this bar especially.
- ✅🔬 **Objective tools beat eyeballing.** A contrast calculator found AA failures
  the eye missed and corrected a wrong hand-estimate. → BlarAI: measure, don't judge.
- 🔬 **The "dynamometer" method.** To both *measure* the agent and *harden* the
  harness, point it at a real task with a pre-authored acceptance test suite as
  ground truth. On task #1 it immediately surfaced the arg-quoting harness bug — the
  method paid for itself instantly. → BlarAI: use a fixed, graded task set to
  measure progress and flush out plumbing bugs.
- 🔬 **Diagnose with evidence, not ranked guesses.** Wins came from controlled A/Bs
  (stdin stall), an on-wire logging proxy (tool-format capture), and an argv-echoer
  (arg quoting). A "rank the hypotheses" workflow guessed wrong and was overturned
  by an A/B. → BlarAI: build the probe, don't speculate.
- ✅ **No-op guard on evals:** a test must not pass just because the agent did nothing.
- ❌🔬 **Unit-green is not seam-green.** 137 PowerShell unit tests passed on the VLM
  design loop; the first real end-to-end run still failed twice, each on a *seam* no
  unit test crossed. (1) A render timeout tuned on an idle box (30s) stalled when the
  app launched cold under resident-30B memory/GPU pressure — fixed with a longer budget
  + a warm-up retry (it renders in ~1s warm). (2) The auto-FIX callback used
  `.GetNewClosure()`, which rebinds *function* lookup to global; one level deep (every
  `pwsh -File` unit test) it works, but the fleet runs two levels deep (`run-fleet` ->
  `& new-agent-task.ps1`) where the dot-sourced functions live in a nested scope the
  closure can't see -> "is not recognized" -> the whole design iteration silently
  fail-soft-skipped. The mocks passed because they were in-scope and one level deep,
  never crossing the boundary production crosses on every run. Fix: a plain scriptblock;
  locked with a static guard + a behavioural two-level repro (137 -> 140). → BlarAI:
  mandate an end-to-end pass at the real invocation depth/load for any loop with a
  callback or a resource-contended step; in-scope one-level mocks are necessary, not
  sufficient.

### 7. Operational / resources
- ✅ **One model resident at a time** (31 GB shared RAM). The 30B needs the "lean
  profile" (~18–21 GB; close the browser, BlarAI VM off). This session: freed safe
  background junk to ~8.8 GB used / 22.5 GB free. **A 7 GB-used target was not
  safely reachable** — Windows + Bitdefender + shell sit at ~8 GB and you should not
  disable AV/shell to chase a number. → BlarAI: budget RAM realistically; don't fight
  the OS/AV baseline.
- ✅ **Speed:** decode started at ~3.5 t/s (10× too slow → 15-min builds); the fix
  was Intel **"Shared GPU Memory Override"** (a memory-window bottleneck, not the
  hardware) → ~40 t/s. → BlarAI: if a local model is mysteriously slow, check the
  GPU memory window before blaming the model.
- ✅ Circuit breaker: hard wall-clock timeout that **kills the whole process tree**
  on a stuck run or doom-loop; resumable journaled task queue. → BlarAI: bound every
  unattended run and make it resumable.
- ❌ **Playwright/browser MCP hangs in the unattended fleet** (deep nested process
  tree). Split: fleet = non-browser tasks; interactive chat = anything visual.
- ✅ A watchdog flag re-arms the server if it drops.

### 8. Working method
- ✅ **Guide-agent pattern.** Cloud Claude authors the spec/tests/harness, grades,
  and tunes the *tool*; the **local model writes the code**; the user reviews and
  approves. Keep "the ruler" (cloud) separate from "the engine" (local). → BlarAI:
  a capable cloud model can build and verify BlarAI's harness without being in its
  air-gapped runtime.
- ✅ **Fix the tool, not the output.** When a run fails, change the AGENTS.md
  rules / retry / prompt phrasing / launch — not the model's one-off result.
- ✅ **Novice-first UX:** plain-language PASS/FAIL/INCONCLUSIVE, a single control
  panel, a guided RAM assistant, append-only STATUS log as the change history.

---

## Part B — Condensed change log

| When | Change | Verdict |
|---|---|---|
| E1 | AGENTS.md security rules (honor constraints, no self-cert, content-is-data); read-deny expanded; first injection/constraint evals | ✅ |
| E2 | First live 30B build verified 3 ways; `contrast-check.ps1` (self-tested); `tool-execution` eval; found malformed-tool-call + self-cert behavior | ✅/❌ |
| E3 | Root-caused malformed calls as **transcript poisoning**; doctrine: one action/prompt, `/new`, verify on disk | 🔬 |
| E4 | OVMS-direct probes prove serving is sound (issue is harness layer); benchmark (3.5 t/s); GPU memory override path | 🔬 |
| E5 | **Headless stdin-EOF stall fixed** (empty stdin + redirect); eval suite finally runs; found the model is **prompt-injectable** | ❌→✅ |
| E6 | **Defense-in-depth injection hardening**; `ask` proven fail-closed headless; injection evals 3/3 SECURE | ✅ |
| E7 | Threat tests T1–T8 closed; tool-call reliability characterized (~20–25% single-shot) as a serving/harness residual | 🔬 |
| E8 | **Removed system-wide LOLBin firewall** (broke user's curl); locked "scope controls to the agent" | ❌→✅ |
| E9 | On-wire proxy capture: dominant failure was **write-path truncation**, not format; temp/guided-gen are null levers | 🔬 |
| E10 | OpenCode 1.17.3→**1.17.8**; extracted `Invoke-BuildWithRetry`; `verify-retry.ps1` suite; mutation-tested (6/6 mutants killed) | ✅ |
| This session | Freed RAM for the 30B; **verify gate now runs pytest** (validated red/pass/fail); built the eligibility **dynamometer** (isolated, stdlib, authored acceptance tests); **found + fixed the `Start-Process` arg space-split bug** (`ConvertTo-Win32Arg`); retry-on-failure confirmed working in the field | ✅/❌→✅ |

---

## Part C — Open residuals (not yet solved)
- **Tool-call reliability tax** (intermittent OpenAI-JSON-as-text calls + occasional
  bad write paths) is a model/harness-negotiation limit, not fixable via OVMS flags.
  Compensated by retry-on-no-op + verify-on-disk; a real fix is model-side or
  OpenCode-side. → BlarAI: expect the same tax from a local quantized model.
- Read-deny case-evasion residual (above).
- The 30B as an unattended **auto-merge reviewer** is unproven (the 14B reviewer is
  over-cautious and parks almost everything — the safe default).

---

## Part D — BlarAI transfer checklist (the distilled actions)
1. **Assume the local model obeys injections** → contain with layered least-privilege
   + no-egress + a human/enforced gate; don't rely on prompt rules.
2. **Never trust model self-reports** → verify every artifact with code/objective tools.
3. **Audit argument quoting** on any shell-out (the `Start-Process` space-split bug).
4. **Loopback-only serving**, never `0.0.0.0`, never a service installer that binds all.
5. **Scope every control to the agent**, never a system-wide OS change.
6. **Gates must execute behavior** (run the tests), and be **mutation-resistant**
   (prove they go red) and self-tested good+bad.
7. **Retry no-ops from a clean state**; bound every run with a tree-killing timeout.
8. **Diagnose with probes/A-Bs, not ranked guesses.**
9. **Budget RAM realistically** (one model resident; lean profile; don't fight the AV/shell baseline).
10. **Short, fresh contexts** beat long sessions for a small model.

---

## Running log (append-only; newest at bottom)

**2026-06-20 — dynamometer round 1 (the language classifier).**
- Chose a *useful* dynamometer: an offline EU/Berlin eligibility analyzer for the
  jobhunt tool, built test-first (I author the acceptance suite; the 30B implements).
- Upgraded the verify gate to actually run `pytest` (was syntax-compile only);
  validated red/pass/fail so auto-merge gates on real behavior. → BlarAI: gates must
  execute behavior.
- Hit and fixed a **three-layer launch-bug chain** (stdin-EOF [prior] → arg
  space-split → model not provider-qualified). Each masked the next; a PING smoke
  task proved the fix. → BlarAI: smoke-test the plumbing first; expect stacked bugs.
- Reproduced the **tool-call JSON-as-text tax** on the real multi-read task (3/3
  no-op); retry-on-failure caught every no-op cleanly. → BlarAI: this tax is intrinsic
  to the local quantized model; design around it (retry + minimize tool calls + verify
  on disk + human gate), don't expect a config to remove it.
- In progress: testing whether a **self-contained, low-tool-call prompt + more
  retries** beats the tax, iterating until all 27 acceptance tests are green. Result
  + the next lesson will be appended here.
- **Exp 1 result — the self-contained prompt BEAT the no-op tax** ✅. The 30B wrote a
  real, structured implementation, ran pytest itself, and iterated — no SPEC read, no
  JSON-as-text derail. The lever works.
- But it ended at ~1/27 because it **regressed**: mid-run it was at ~17/26, then a
  rewrite introduced a `\\b` backslash-corruption bug (matches nothing) and it
  **stopped** without reverting; it had also **forgotten `english`**. (See the two new
  Part A bullets: backslash corruption + regression-then-quit.)
- **Exp 2 (running):** require EN/DE/FR, forbid backslash regex (plain string ops),
  anti-regression iterate-to-green.
- **Exp 2 result — no-op x3 (the explore-first derail).** The model did NOT write: it
  "examined the existing files" first, read `model.py`, then emitted a `read tests/...`
  call as JSON-text and derailed. KEY INSIGHT: Exp 1's *successful* run went straight to
  writing; Exp 2 explored first and tripped. The no-op tax is driven by **exploratory
  reads** — each read is a derail die-roll. → BlarAI: push the model to ACT-FIRST (write
  before reading) and use retries to resample past an unlucky explore-and-derail. Note:
  3 no-ops in a row also means per-attempt success is well under ~60% — raise the retry
  cap for complex tasks.
- **Exp 3 (running):** "your FIRST tool call MUST be WRITE; do not read/glob", plus 8
  retries to reliably land a write-first run.
- **Exp 3 result — write-first + 8 retries CLEARED the no-op wall** ✅, and the
  no-backslash + EN/DE/FR + anti-regression steering yielded a mostly-correct
  implementation: **21/27 passing** (up from ~1). It wrote on attempt 1, no derail.
  → BlarAI: "act-first + more retries + steer off known bug classes" is the combo that
  gets a small model to a real first draft.
- The 6 remaining fails were enumerable: (a) it DROPPED the compound REQUIRED cues
  (working language / proficiency in / native speaker / strong skills); (b) GLOBAL cue
  attribution (applied one clause's cues/level to every language); (c) a negation gap
  ("No German IS required"). It also STOPPED at 21/27 rather than iterating the last mile.
- **Exp 4 (running):** inline the 14 acceptance cases as worked examples + a clause-
  scoping heuristic + emphasize the compound cues. Lesson under test: *give a small
  model the acceptance examples (they ARE the spec) plus an algorithm hint for the hard
  part.* 
- **Exp 4 result — REGRESSED + doom-loop (overload).** Dumping the 14 examples +
  scoping heuristic OVERWHELMED the model: it looped on the test-like example lines
  (repeated 21x) and produced broken code (~0/27). The CIRCUIT BREAKER caught it and
  parked safely ✅. Lessons: for a small model MORE prompt detail can BACKFIRE — the
  lean Exp-3 prompt (21/27) beat the heavy Exp-4 one; and the failing cases need
  CONFLICTING parse heuristics (splitting on "and" fixes some cases but breaks others),
  so a precise, hand-verified algorithm is required. → BlarAI: keep prompts LEAN; hand
  the model a verified algorithm, not a pile of examples; trust the breaker to contain loops.
- **Exp 5 (running):** a LEAN prompt carrying a hand-verified algorithm (split clauses
  on ; . , but NOT "and"; bind each CEFR token to the language right before it;
  clause-scoped strength + a shared "proficiency" rule). Verified by hand vs all 14
  cases.
- **Exp 5 result — 26/27** ✅✅ — the hand-verified lean algorithm worked. The 30B
  transcribed it faithfully; the ONLY miss was `proficiency_both`: it bound the FIRST
  CEFR token clause-wide ("german (b2) and english (c2)" -> both B2) instead of per
  language. KEY LESSON: a small model reaches near-perfect on a HARD task when given a
  precise, hand-verified algorithm in a LEAN prompt — the winning recipe is
  **write-first + no-backslash + verified-algorithm + retries**. → BlarAI: do the
  algorithm design yourself (and verify it), then let the local model transcribe it.
- **Exp 6 (running):** one micro-fix — bind each CEFR token positionally to the
  language right before it (substring-after-name), not one clause-wide token.
- **Exp 6 result — 26/27 again, a DIFFERENT case.** Positional binding FIXED
  proficiency_both, but this rewrite used the alias 'deutschkenntnisse' as the language
  value instead of canonical 'german' (german_von_vorteil failed). KEY LESSON: a small
  model at its frontier yields ~26/27 with a VARYING single bug per rewrite (Exp 5 missed
  proficiency; Exp 6 missed the alias). You can't out-retry it (retries catch only
  no-ops, not a 26/27). Converge by PINNING each observed gotcha in the prompt until one
  clean run clears them all. → BlarAI: expect per-rewrite variance from a local model;
  accumulate an explicit guard for every observed failure mode.
- **Exp 7 (running):** pin BOTH known gotchas — positional CEFR binding + alias->canonical
  mapping.
- **Exp 7 result — 26/27, a THIRD distinct slip** (empty evidence for german in the
  ';'-split case). Pinning the first two gotchas worked; a new one appeared. The model
  reliably lands 26/27 but the single failing spot MOVES each rewrite.
- **Insight / candidate fleet upgrade:** because each independent run is ~26/27 with a
  RANDOM slip, the fleet could RETRY-ON-TEST-FAILURE (resample a fresh implementation
  until the gate is green), not only retry-on-no-op — that would auto-converge a
  high-variance small model. (Noted for the fleet; for now converging by pinning +
  manual re-runs.) → BlarAI: for a high-variance local model, make "passes the gate" the
  retry condition, and accumulate an explicit guard for each observed failure mode.
- **Exp 8 (running):** pin evidence to a bulletproof whole-text slice (+ the two prior
  fixes).
- **Exp 8 result — 25/27 (REGRESSED).** Pinning evidence fixed it, but the fresh rewrite
  broke dedup_strongest AND the english/german clause. CONCLUSION: pinning does NOT
  monotonically converge — the model has a roughly fixed error budget (~1 slip) per
  implementation of this 27-case task, and over-long prompts make it WORSE. Whack-a-mole
  fails. → BlarAI: a small model has a per-implementation error FLOOR on a complex task;
  don't try to prompt it to zero — RESAMPLE or DECOMPOSE.
- **Pivot — resample-until-green** (`state/resample-lang.ps1`): run a balanced, well-pinned
  prompt up to 5x at temp 0.7's natural variance and take the first 27/27. This is the
  external form of the retry-on-test-failure fleet upgrade.
- **Resample result — NO GREEN in 5 (CEILING CONFIRMED).** All 5 fresh runs (plus the 8
  earlier experiments = 13 total) landed 25-26/27, each failing a DIFFERENT case (dedup,
  scoping, positional level, and one literal "\n"-in-source NameError = newline
  write-corruption). Never 27/27. CONCLUSION: the 30B has a hard ~26/27 autonomous ceiling
  on this one 27-case nuanced task — ~1 random slip per implementation, not promptable or
  resamplable (at this rate) to zero. → BlarAI: a complex spec has a real one-shot ceiling
  for a small model; the answer is DECOMPOSITION (sub-tasks sized so each is slip-free),
  not more prompting or resampling.
- **Pivot — DECOMPOSITION:** split into separately-tested helpers (canonical_language,
  split_clauses, clause_level, clause_strength) the model can each green, then a thin
  orchestrator.
- **DECOMP-1 result — 34/34 helper tests GREEN on the first task** ✅✅✅. The 30B
  implemented all four small helpers correctly (positional CEFR binding, proficiency map,
  strength cues, clause split) — the very logic it kept slipping on in the monolith.
  CONFIRMS the thesis: a small model nails SMALL, well-tested units even when it cannot
  one-shot the whole. Promoted the helpers into the repo (committed).
- **DECOMP-2 (running):** the 30B writes the thin orchestrator that just composes the
  proven helpers (clause loop + dedup + shared-proficiency + evidence).
- **DECOMP-2 result — 61/61 GREEN. GOAL ACHIEVED.** ✅✅✅ The 30B wrote a clean, correct
  thin orchestrator composing the proven helpers; the FULL suite (34 helper + 27 language)
  passes. It "parked" only on an UNCLEAR reviewer verdict (the safe human-review gate); the
  Guide confirmed green and merged (commit d221e1a). The 30B authored EVERY line of
  helpers.py + language.py; the Guide supplied the spec, the tests, and the verified algorithm.

### Round-1 conclusion — how a small model reached 100% on a hard task
The monolith hit a hard ~26/27 one-shot ceiling (13 attempts, ~1 random slip each; not
promptable or resamplable to zero; over-long prompts regress it). **DECOMPOSITION broke
through**: 4 small, separately-tested helpers (each landed slip-free first try) + a thin
orchestrator. → BlarAI MASTER LESSON: **size each unit to the small model's reliable
one-shot capacity, test each unit, and compose — never ask a small model to one-shot a
large nuanced spec.** Supporting recipe: matured launch plumbing + write-first prompting +
no-backslash steering + retries + a verify-on-disk pytest gate + a hand-verified algorithm
+ decomposition.

---

## Round 2 — extending into jobhunt (in progress)

**2026-06-20 — round-2 design + the VISA classifier (first round-2 classifier, GREEN).**
- Design via a cloud workflow (10 agents): a jobhunt integration map (mirror the `ats_reports`
  side-table pattern; the analyzer stays OFFLINE - no llm/network import) + designs for 4
  classifiers (visa/relocation/education/certs). The workflow's ADVERSARIAL-VERIFY phase earned
  its keep: it caught that the auto-generated test sets were DEFECTIVE (self-contradictory cases
  that would false-FAIL a correct impl, coverage gaps that would false-PASS a trivial one,
  unpinned evidence). → LESSON: an auto-generated ruler is NOT trustworthy - hand-author/verify
  the tests before the model builds against them.
- So the Guide hand-authored the VISA ruler (model types + helper tests + orchestrator tests);
  the 30B implemented every line. Decomposed helpers: classify_sponsorship (precedence
  DENIED>OFFERED>WILLING>SILENT, negation-guarded), parse_salary_eur, is_shortage_role,
  salary_verdict; thin orchestrator assess_visa_sponsorship.
- **retry-on-test-failure PROVEN IN PRODUCTION:** the fleet auto-resampled the visa build and
  CONVERGED it to 100/100 (round-1's 61 + visa's 39) on attempt 4 - fully hands-free (vs the 13
  manual rounds round-1 needed). Parked on an UNCLEAR review verdict; Guide confirmed + merged.
- **Sharp lesson on the feature's LIMIT:** auto-resample converges RANDOM slips, NOT a CONSISTENT
  bug. The first two visa runs stuck at 99/100 on the SAME case ("EUR 45k" -> None) across all 5
  resamples - my spec was ambiguous (the model left the "k" in the digits before float(), which
  crashed). Resample cannot fix a systematic spec gap; the GUIDE must clarify the spec. → BlarAI:
  resample = variance insurance; spec-clarity = the Guide's job. They are complementary, not
  substitutes.
- Also shipped: a novice **"[A] Add a coding task"** option on the AI Control Panel, so the
  overnight fleet is fully menu-operable with no typed commands.
- **Relocation + education GREEN; certs building** (2026-06-20, autonomous run while the
  user is away). Each: a hand-authored ruler, PRE-VALIDATED with a throwaway reference impl,
  then the 30B built it and auto-resample converged it (relocation attempt 2, education
  attempt 1). All merged to main; suite 150/150 (round-1 61 + visa 39 + relocation 26 +
  education 24). Certs (4th) in progress.
- **New practice: PRE-VALIDATE THE RULER.** Before launching the 30B, the Guide writes a
  throwaway reference implementation and runs the tests; if green, the ruler is correct +
  satisfiable -> revert to stubs for the 30B to build. This caught ZERO wasted runs on
  rounds 2-4 (vs 2 wasted on visa, whose ruler had an unspotted cue gap). → BlarAI: validate
  the test set with a quick reference impl BEFORE the local model builds against it.
- Next: jobhunt integration (vendored module + an offline analyze() entry point on a branch;
  the deeper db-table/board/score wiring documented for the user to review, not done
  unsupervised on the live tool).
- **Certs GREEN — 4/4 classifiers done; suite 174/174.** All four round-2 classifiers built by
  the 30B, auto-resampled to green, merged. Pre-validating each ruler caught ZERO wasted runs.

## 2026-06-20 — The 30B's multi-turn tool calling was broken; diagnosed + fixed (qwen-proxy)

The user ran the 30B in OpenCode for the first time (build a calculator app) and it collapsed:
tool calls printed as raw `{"tool_calls": ...}` JSON in the chat, then degraded to malformed
`name=read`. Root-caused it end-to-end (mutation-resistant — eliminated each cause, didn't assert):

- **It is SERVER-SIDE, not OpenCode and not promptable.** Reproduced directly against OVMS :8000
  with NON-streaming requests, no OpenCode involved. The `AGENTS.md` rule already forbade emitting
  tool calls as text — and was ignored, because the model emits its *native* format in the wrong
  spot. Prompting cannot fix a parser/format problem.
- **Eliminated, each by experiment (not assumption):** temperature (fails at 0.1 and 0.7), argument
  size (fails tiny and huge), streaming (fails non-streaming), the chat template (verified correct —
  the only delta vs stock is a needed `arguments | from_json` for OpenAI string-args), prior assistant
  prose in history (stripping it didn't stop the turn-3 leak, though it eased the spiral).
- **True trigger (isolated by ablation, confirmed by a research workflow that ran its OWN live
  ablations):** several prior assistant tool-call turns + a task that synthesizes earlier tool
  RESULTS → the INT4 model drifts and emits an OpenAI JSON envelope (or a stray `<tool_call>`) as
  plain `content`. OVMS's `qwen3coder` parser is **XML-marker-only with no JSON fallback**
  (confirmed in `qwen3coder_tool_parser.cpp`), so it leaves the call in content with
  `tool_calls=[]`; the loop stalls, and echoing the garbage back spirals it to `name=read`.
- **The research lenses' two top "high-confidence" fixes were FALSIFIED live** (the @ai-sdk
  empty-content fix; `tool_choice=required`). → BlarAI lesson: even a confident, well-sourced
  research recommendation must be reproduced on THIS stack before trusting it. The workflow's
  synthesis agent earned its cost precisely by *disproving* its own lenses.

**Fix shipped — `tools/qwen-proxy.py` (a normalization seam, not a client swap).** A tiny stdlib,
offline, loopback proxy on :8099 between any OpenAI-compatible client and OVMS:
  1. `xmlify_history` (request-side): re-serialise prior assistant tool-call turns as native Qwen
     XML — the PROVEN fix that *prevents* the drift.
  2. `salvage_tool_calls` (response-side): reconstruct a leaked JSON-envelope/XML call into a real
     `tool_calls` array; `strip_trailing_tool_marker` removes the cosmetic post-completion marker.
  Model-gated to `coder-30b` (xmlify emits qwen3coder XML, wrong for the 14B's hermes3 parser);
  transparent passthrough otherwise. Helper hardened per adversarial review (never raises — the
  reference impl crashed on `{"tool_calls":["a","b"]}`; handles the bare marker) with a 18-case
  self-test. Wired: live `~/.config/opencode/opencode.json` baseURL → :8099; `start-llm.ps1`
  auto-starts it (guarded, survives model swaps); `tools/start-coding-proxy.cmd` is the manual launcher.

**Proof (naive client, no client-side fixes):** raw OVMS :8000 → calculator dies at 2/3 files
(exactly the user's failure); via proxy :8099 → 4 clean turns, 0 leaks, all 3 files, 3/3 runs;
investigate 6 clean/0 leaks; streaming re-emit produces valid SSE. → BlarAI lessons: (1) the durable
seam for a brittle local tool-calling stack is a client-agnostic REPAIR PROXY, not picking a client;
(2) a health check must exercise the **multi-turn** loop — the existing `test-guided-gen.ps1` only
tested single calls and passed while the real loop died. The permanent fix is upstream: a JSON-
envelope fallback in OVMS `qwen3coder_tool_parser.cpp` (a natural PR, since the user is an OVMS/
OpenVINO contributor).

**Follow-ups (2026-06-21):**
- **Confirmed in the REAL OpenCode client** — the 30B built a working calculator end-to-end through
  the proxy. (Synthetic repros are necessary but not sufficient; only the real client confirms.)
- **A real bug surfaced only when OpenCode hit the proxy:** OpenCode sends `stream:true` +
  `stream_options:{include_usage}`; the proxy forces `stream:false` upstream to repair the full
  response, and OVMS 400s on `stream_options` without `stream:true`. Fix: strip `stream_options`
  upstream, re-emit usage in the proxy's own SSE. → BlarAI lesson: wire-level client quirks (extra
  params, header expectations) only appear against the actual client — always end-to-end test in it,
  not just in repro scripts.
- **14B fleet tier: hermes rewrite implemented + unit-tested, but left OFF by default after a live
  A/B.** `xmlify_history(fmt)` emits the **hermes** format (`<tool_call>{json}</tool_call>`) and
  `salvage_tool_calls` recovers hermes leaks (unit-tested incl. qwen3coder-vs-hermes disambiguation;
  single-turn provably unaffected). The user loaded the 14B and I A/B'd it live — and the evidence
  said DON'T enable it: (a) the 14B does **parallel tool calls** (it wrote all 3 calculator files in
  ONE turn, 0 leaks), so it never enters the multi-turn drift state that breaks the 30B — no evidence
  it has the bug; (b) the proxy forces `stream:false` to repair the full response, and the 14B is a
  *dense* reasoning model far slower than the 3B-active 30B, so buffering its response is a real
  latency/timeout cost (the A/B's sequential scenarios hit the 180s test timeout — a speed limit, not
  a leak). → BlarAI lesson: **the user's request had a premise ("the 14B needs the same robustness")
  that the evidence contradicted; the right move was to implement the capability, surface the
  contradiction, and NOT ship an unverified, cost-bearing fix to a model not shown to need it** —
  rather than mechanically complying. `MODEL_FORMATS` ships `coder-30b` only; enabling the 14B is one
  env var (`FIX_MODELS`) the moment a sequential multi-turn probe shows it's needed.
- **Sub-lesson on verification harnesses:** a fixed per-request timeout (180s) that's fine for the
  fast 30B silently FAILS the slow dense 14B and looks like a leak. Made `verify_via_proxy.py` honor
  `MAXTOK`/`TIMEOUT` env so the harness adapts to model speed. Match the test budget to the model.
- **Full detailed solution writeup:** `docs/qwen3coder-toolcall-fix.md` (parser internals, the three
  tool-call formats, the three fix functions with examples, proxy architecture, wiring, evidence,
  the 14B extension, and the upstream-PR path).
- **jobhunt integration (safe slice) DONE** on branch `feature/eligibility-module`: vendored
  module + offline `analyze(job, profile)` + 2 tests (incl. an offline-guard); full jobhunt suite
  310 passed (additive, zero regression). Deeper db/board/score wiring documented (INTEGRATION.md)
  for review, NOT done unsupervised on the live tool. jobhunt returned to main, clean.
- **ROUND 2 COMPLETE.** → BlarAI MASTER RECIPE (proven across 5 classifiers): hand-author +
  PRE-VALIDATE the ruler (reference impl) → the local model builds → retry-on-test-failure
  converges it → Guide reviews + merges → integrate ADDITIVELY on a branch. Decomposition +
  pre-validation + retry-on-test-failure is the durable, repeatable loop.
- **DEEP jobhunt integration DONE + reviewed.** Merged the eligibility module to jobhunt main
  and wired it end-to-end (db table → offline scan pass → board chip → modal panel → CSV),
  offline (no API key). Then ran a 5-lens ADVERSARIAL REVIEW of the integration. Final: full
  suite 318 + standalone 176; live Flask smoke green offline.
- **MASTER LESSON (review the verifier, not just the code): an adversarial review found that my
  OWN offline-guard test could FALSE-PASS.** It was substring-based and missed the *exact*
  import form the rest of the app uses to reach the LLM — a relative `from .llm import …` (also
  `from . import llm`, `aiohttp`, `from urllib import request`). 318 green tests, and the one
  test enforcing the whole feature's core invariant couldn't catch the most likely regression.
  → Fix pattern: replace brittle string-matching guards with an **AST walk** (catches any import
  spelling, covers all files on the protected path) **+ a runtime `sys.modules` sentinel** (import
  the path with no key, assert no llm/network module loaded). Then **mutation-test the guard
  itself** — feed it the forbidden forms and confirm each trips it, plus legit imports don't.
  → BlarAI: a guard you don't mutation-test is theater. The harness that proves a safety/offline
  invariant must itself be proven unable to false-pass. This is [[demands-mutation-resistant-verification]]
  applied to the *test*, not the code.
- **Adversarial review catches what example-based tests can't.** The same review found real bugs
  318 green tests missed: an empty/thin posting scored a fabricated "strong" (all-silent →
  started at 100, nothing subtracted); a flat German penalty that ignored the candidate's actual
  CEFR level; a document-wide `proficiency` rule that cross-contaminated unrelated languages.
  → BlarAI: after the suite is green, run an independent multi-lens review (correctness, the core
  invariant, data/SQL, UI, edge-cases) BEFORE declaring done. Green ≠ correct.

---

## 2026-06-23 — The dispatch pipeline went self-driving (NL -> merged code), and the orchestrator learned to trace before it claims

The headless-coding **dispatch** loop (BlarAI #670) reached **end-to-end on-hardware**: a plain-English goal
-> the embedded 14B decomposes it -> the box steps the 14B aside and loads the 30B coder (OVMS) -> the fleet
builds in an isolated worktree, verify-gates, **auto-merges to the target's `main`** -> swaps the 14B back.
Proven by `/dispatch palindrome-demo | write an is_palindrome function` merging correct, tested Python to
`main` **unattended in ~6 min, zero resamples** (then re-proven on the clean `rocket-calc`-style path). Five
fixes got it there, each scoped as a builder brief, built by a separate builder session, **independently
gated, merged dormant**: P1 over-decomposition right-sizing, P2 swap-back never-zero teardown, P3
single-feature fold + OVMS-stop poll, fleet A1 language-pin + A2 wrong-language hard-fail gate, and the
merge-unblock `uv run --no-project` one-token fix.

- ❌ **MASTER LESSON — "verify the verifier" applies to the ORCHESTRATOR'S OWN claims, not just to tests.**
  Across this arc the LA asserted how the pipeline behaves *without tracing the live code* -- **three times,
  wrong each time.** (1) Blamed a parked dispatch on the swap-back spin-detector; tracing showed it was
  `testResult='fail'` from a *packaging* build choking the test step (the `--no-project` fix) -- the
  spin-detector was innocent. (2) Claimed "PLAN doesn't check repo existence / the pipeline won't create
  repos"; tracing showed PLAN **already** rejects a missing repo (`validate_repo` inside `decompose_request`,
  with a passing proof test). (3) Repeated that wrong existence-premise in a handoff brief -- caught only by
  the FRESH hand-off session re-tracing it. → BlarAI: "green != correct" extends to "my confident explanation
  != correct." An orchestrator narrating from assumption is the same failure mode as a test that
  string-matches. Trace the path before you state behavior. ([[demands-mutation-resistant-verification]]
  applied to assertions.)
- ✅🔬 **An independent multi-agent adversarial gate catches what the builder's own "merge-ready" pass
  misses.** The P2 package self-reported `must_fix=[]`; a 7-agent ultracode gate found (and reproduced live)
  a real never-zero hole -- a `BaseException` in the 14B-restore call escaped the teardown's `except
  Exception`, skipping the unconditional restore and masking the original error. Fixed before merge. →
  BlarAI: gate merges with an independent adversarial pass (N skeptics each trying to refute), never the
  builder's own green run.
- ❌→✅ **A packaging/build failure was masquerading as a test failure in the merge gate.** The fleet's test
  step ran `uv run … pytest`, which first editable-installs the project; a repo with >1 top-level module made
  setuptools refuse the build -> pytest never ran -> `testResult='fail'` -> a *correct, all-green,
  MERGE-approved* dispatch **parked**. Fix: `--no-project` (run tests without installing). Diagnosed
  *precisely* via a 3-agent design workflow, not guessed. → BlarAI: never let an environment/packaging error
  read as a test failure; run tests build-free.
- 🔬 **The .NET/WinUI gate is BUILD-ONLY -- compiles != works.** A WinUI app that builds 0/0 passes the gate
  identically to one that renders nothing. Visual/behavioral requirements (a rocket-shaped window, flames,
  resize) are invisible to the gate; the operator must launch and eyeball. → Stage hard visual/interop
  features as their OWN rungs (prove toolchain -> working app -> theming -> shaped-window interop); a green
  gate on them means only "it compiled."
- ✅ **Hand off before the context gets too big.** This LA session grew enormous; handed to a fresh session
  via a start-here brief + the live memory. The fresh session immediately earned its keep by catching the
  orchestrator's assert-without-tracing error above. → A fresh context reasons more sharply; don't push a
  bloated session.

---

## 2026-06-23 — Natural-language in, environment competence in the system: the first reusable build layer

The fresh LA opened both workstreams (A: build the rocket calculator; B: mature `/dispatch` project-handling)
and immediately took a product correction from the operator that reshaped A and produced the first piece of
reusable build *infrastructure* (as opposed to a per-task fix).

- ❌→✅ **Putting tech in the operator's prompt was wrong — the deliverable is natural-language-in.** The LA's
  first Rung-0 command pinned `net8.0-windows10.0.19041.0` + exact `WindowsAppSDK` versions inside the
  *operator's* `/dispatch` text. The operator (a non-developer) rejected it: he will only ever write a plain
  desire ("a space-rocket calculator for an 8-year-old; window shaped like a rocket when not maximized; resize
  via right-click menu + visible +/− buttons; red cartoon rocket with flames"), and baking tech into his prompt
  defeats the NL→14B→30B pipeline that IS the deliverable. Fix: the operator gives **intent** (depth scales with
  the desire — the SDD/PLAN step expands it); the **system** supplies the engineering. → BlarAI: the novice's
  prompt is intent only; never push build detail into it.
- 🔬 **Traced where environment knowledge could live — it existed nowhere.** BlarAI PLAN is platform-agnostic
  (the decompose/criteria templates never ask for a platform; `detect_ecosystem` runs *after* the plan, is
  file-based, and returns `unknown` for an empty repo); the fleet's A1 language-pin needs a manifest (empty repo
  → no pin) and is language-only (no TFM/RID/versions); the coder's `~/.config/opencode/AGENTS.md` had zero
  build facts. So a natural WinUI prompt would `NU1101`-fail on guessed versions — a *plumbing* failure that
  says nothing about the model's actual WinUI ability. → BlarAI: know exactly where each competence lives before
  relying on it; a missing layer reads as a model failure.
- ✅ **Shipped the first reusable build-environment layer (agent-layer infrastructure, not a one-session
  cheat).** Added a conditional "Build environment (this machine)" section to `~/.config/opencode/AGENTS.md`:
  the offline/`NU1101` rule + "for a Windows desktop GUI app, hand-author WinUI 3" with the exact cached pins
  (`WindowsAppSDK 1.8.260508005`, `SDK.BuildTools 10.0.26100.8249`, TFM `net8.0-windows10.0.19041.0`) and the
  architecture bake (`win-x64` / `Platform x64`). Every coder session inherits it; it's inert for non-WinUI
  tasks. → BlarAI: front-load environment competence into the agent layer so the small model doesn't reinvent
  (and mis-guess) it at runtime.
- ✅🔬 **Proved the shared facts with a real cache-only build before trusting them.** Hand-authored a minimal
  WinUI app and ran `dotnet restore` with online sources *cleared* (a genuine offline test) → resolved from
  cache in 234 ms; `dotnet build` 0 warn / 0 err in ~11 s on dotnet 8.0.422. A wrong version baked into
  all-sessions config would silently break every future WinUI build, so the facts were verified, not asserted —
  and the validated skeleton becomes the seed for a reference-template library. → BlarAI: validate any fact you
  bake into shared infrastructure with an objective run first ([[demands-mutation-resistant-verification]]).
- ❌→note **Offline WinUI builds currently lean on the *incidental* global package cache, not a real feed.**
  `C:\offline\nuget-feed` is unseeded and the user `NuGet.config` points only at nuget.org — the offline build
  works today only because the right packages happen to be in `~/.nuget/packages`. Functional but fragile;
  recorded as the next infra increment (seed a real feed + a `NuGet.config`). → BlarAI: distinguish "works
  because cached" from "robust offline"; harden before depending on it.
- 🔬 **Decision (trade-off named): environment-knowledge is infrastructure, not scaffolding.** Giving the coder
  the build facts is adjacent to the operator's earlier "pure test — don't scaffold the project" call. He ruled
  it IS infrastructure worth building for all sessions ("mature not minimal", front-load for small models,
  without overwhelming the context) — explicitly NOT a cheat. The bar evolves from "author from absolute zero"
  to "build a working app on top of provided environment competence", which is the *realistic* test (a real dev
  is told their environment; guessing offline build numbers is trivia, not capability). Staged roadmap: (1) the
  AGENTS.md note [done]; (2) harden the offline feed; (3) a reference-template library the coder builds upon;
  prove WinUI, then generalize to other platforms. → BlarAI: build reusable competence into the environment,
  sized so it never overwhelms the small model's context.
- ✅ **Workstream B re-scoped + brief written (milestone).** With PLAN-already-rejects established (see the prior
  entry's master lesson), the project-handling immaturity is the novice *dead-end* — a missing repo is rejected
  with no way to create/list/confirm — plus a misleading post-run run-line, NOT a missing check. Authored
  `docs/blarai-builder-brief-dispatch-project-handling.md`: gateway-side select-or-create (a `/dispatch new`
  verb), actionable not-found, a `Building in:` folder confirmation, read-only reuse feedback, and an honest
  `detect_run_command`; create-by-REJECT-sanitize + the `~/BlarAI` fence + rollback; mutation-resistant
  verification. Awaiting a builder session; the empty `rocket-calc` target is seeded. → BlarAI: when the premise
  is corrected, re-scope the brief to the *real* gap before building.

---

## 2026-06-23 — First WinUI build through dispatch (proven) — and the over-decomposition tax that parked it

The minimal WinUI proof (`winui-smoke`, run `20260623-152205-bd`) confirmed the environment-competence layer
works end-to-end — and in the same run exposed how badly over-decomposition + a flaky review step tax a GUI
build. It had to be stopped manually (the operator caught the GPU still pegged ~40 min in).

- ✅ **The env-competence layer is PROVEN through the full dispatch.** From a no-tech natural prompt ("a tiny
  app for Windows with one window that adds two numbers"), the 30B hand-authored a WinUI `.csproj` *verbatim*
  from the `AGENTS.md` note (`WindowsAppSDK 1.8.260508005`, the `win-x64`/`Platform x64` bake) and it passed the
  gate (`[pass] dotnet:build`, `[pass] eco:language`). Those exact offline pins are not guessable → the note was
  consumed. → Natural language in, the system supplies the tech: confirmed on the real pipeline, not just my
  scratch build.
- ❌ **Over-decomposition is worse for a GUI goal than for a function.** A two-number adder split into THREE
  sequential tasks (`create-main-window` / `implement-add-functionality` / `acceptance-tests`). Only the first
  produced real work (`c71b557`, the WinUI app); the other two branches never left the init commit. Each task =
  its own worktree + a full code/verify/review cycle on the one resident 30B. → fleet/BlarAI: the right-sizing
  ruler must collapse UI+behavior into one task for a single small app (#7).
- ❌ **The acceptance-tests task is doomed when the feature tasks park.** The features parked (nothing merged to
  `main`), so the `acceptance-tests` worktree — branched from `main` — had no app to test, and ground for many
  minutes against absent code (the exact earlier-shakedown pattern). It pinned the 30B (~2,150 s CPU, box down to
  3.84 GB free). → fleet: a test task must be gated on the presence of the feature code (or folded), never
  dispatched against an empty workspace.
- ❌→note **A correct, building WinUI app PARKED because the REVIEW AGENT crashed.** `REVIEW VERDICT: UNCLEAR` —
  the reviewer emitted a malformed `todowrite` tool call (schema error), then timed out (the same small-model
  tool-call brittleness as the qwen-proxy arc), so good work parked as the safe default. The build was fine (the
  review itself re-ran `dotnet build` → 0/0). → fleet: the review step needs the coder's tool-call robustness;
  a build-only-gated GUI app the reviewer can't launch shouldn't hinge solely on a flaky review verdict.
- 🔬❌ **My completion-watcher cried wolf — verify the watcher, not just the work.** The dispatch fed the 3 tasks
  one-at-a-time; my Monitor keyed on the FIRST `SUMMARY.txt` and my swap-back watcher then concluded "hang" when
  the run was simply still going (on task 3). The operator caught the true signal (GPU still pegged). →
  orchestrator lesson: a watcher's exit condition must match the WHOLE job's terminal state, not the first
  sub-task's — early-exit is as misleading as silence. ([[demands-mutation-resistant-verification]] applied to my
  own monitors.)
- ✅ **Graceful manual stop: kill the work, let the driver self-recover.** Mapped the process tree, tree-killed
  `run-fleet → opencode → playwright` and LEFT the `swap_ops` driver alive; the driver detected the ended run and
  tore down on its own (`UNLOAD-30B → OVMS gone → RESTART-AO → RECOVERED`, 14B back on `:5001`, RAM 3.84 → 11.71
  GB) — no forced OVMS-kill, no operator relaunch. → the P2 teardown path handles an externally-killed run, not
  just a budget-kill; killing the child is enough to trigger a clean swap-back. (`create-main-window` worktree was
  swept by the teardown; its branch preserved; two sibling worktrees remain to sweep.)
- → **Net:** the proof we wanted is in (NL → building WinUI). But the **real rocket-calc stays GATED** until the
  fleet-robustness fixes land (#7: GUI right-sizing + the acceptance-on-empty-workspace guard + review-agent
  tool-call robustness) — otherwise a real, richer build will over-split, grind, and park instead of merging.

---

## 2026-06-23 — The ultracode root-cause that overturned its own first-draft fixes

A 7-agent root-cause (trace → adversarial-verify → synthesize, ~645K tokens) dissected the three winui-smoke
failures across BlarAI + fleet and produced two verified builder briefs. The headline isn't the diagnoses (all
confirmed by EXECUTING the actual code) — it's that the adversarial pass **knocked down two of the workflow's
own first-draft fixes** before they could reach a builder.

- 🔬✅ **Trace → adversarial-verify catches a fix that's a NO-OP on its own target.** The proposed deterministic
  ruler backstop for the GUI over-split used `_UI_SHELL_NOUNS={…,'mainwindow'}`, but the real slug
  `create-main-window` tokenizes to `{main, window}` — so `is_ui_shell` returns False and the merge NEVER FIRES
  on the bug it targets (re-confirmed by executing `_collapse` on the exact slugs). A single "here's the fix"
  pass would have shipped a no-op to a builder. → verify the FIX, not just the diagnosis.
- ❌→note **The review crash was TWO defects, and the earlier lessons-note framing was wrong.** Not "the reviewer
  couldn't produce a verdict" — it DID emit `VERDICT: FIX FIRST` (parsed fine at `new-agent-task.ps1:204-205`),
  and `:208` `if ($rv.TimedOut){ $verdict='UNCLEAR' }` **unconditionally clobbered it**; the timeout itself came
  from the read-only reviewer churning post-verdict on a malformed `todowrite` + ~8 redundant `dotnet build`
  re-runs (the review path passes no `-JsonStepCap`, so no turn-cap/spin-detector — only the wall clock). The
  merge gate (`:213`) then hinges entirely on `verdict=='MERGE'` with no build-only fallback. LA spot-confirmed
  both line-refs.
- ❌ **A test task dispatched against an EMPTY workspace.** `swap_driver.py:523-530` runs every task with no
  merge-dependency gate; when the feature tasks PARK, the appended `acceptance-tests` task branches off
  README-only `main` and grinds ~24 min against absent code. The fix (skip the acceptance task unless all
  preceding features MERGED) is the highest-priority containment — it makes a parked run cheap *regardless of
  why* it parked.
- 🔬 **The adversarial pass also re-targeted and de-scoped fixes:** FIX A retargeted from write/edit (already
  denied, ~no time) to `todowrite`+`bash` (the real time-sinks) and from the deprecated `tools:` map to a
  per-agent `permission:` block; it dropped a redundant `criterion_status` edit (a skip already renders
  `UNVERIFIED`); and it caught that "honor FIX FIRST on timeout" and "FIX C fixes this run" **contradict** —
  resolved as force-`UNCLEAR`-on-timeout (low-trust verdict) then merge clean build-only on `UNCLEAR`.
- 🔬 **LA decision recorded (capability trade-off escalated, not silently built):** the deterministic over-split
  backstop (Part-2) is **DEFERRED** — once the acceptance-skip guard lands, an over-split no longer *strands* the
  30B (it becomes a fidelity issue, not a failure), so a backstop that risks over-collapsing genuine
  multi-feature single-screen apps isn't worth it now. Path not taken is named in the brief (option (ii): a
  `_UI_MODIFIERS` allow-set + an `_ARTIFACT_FEATURE_NOUNS` disqualifier).
- → **Two briefs written, priority-ordered:** `fleet-builder-brief-review-merge-robustness.md` (FIX B
  verdict-preservation + FIX A reviewer tool surface + FIX C build-only merge) and
  `blarai-builder-brief-acceptance-gating-and-rightsizing.md` (FIX (b) acceptance-skip [highest] + FIX Part-1
  prompt). Priority: FIX (b) → FIX B+C → FIX A → Part-1. → MASTER lesson: a multi-agent
  trace→adversarial-verify→synthesize structure earns its tokens precisely when it REFUTES its own proposals —
  three first-draft fixes here were a no-op, a redundancy, and a contradiction that would each have wasted a
  builder's pass. ([[demands-mutation-resistant-verification]] applied to the FIX, not just the diagnosis.)

- ✅ **MERGED — fleet limb (FIX A + FIX C), independently gated SOUND.** The fleet half shipped to
  agentic-setup main (merge `7bd3b9a`, `--no-ff` of `bc28be8`): FIX A (`review.md` denies `todowrite` +
  prose) + FIX C (the merge decision extracted into a pure `Test-ShouldMerge` in `fleet-lib.ps1`; a
  dotnet-only project whose deterministic verify gate STRICTLY passed now merges an *inconclusive* review —
  never an explicit FIX FIRST, never python/node, every secret/anomaly/build gate intact; the report names a
  build-only-gate merge). **FIX B needed NO code change** (the resolved force-`UNCLEAR`-on-timeout policy +
  FIX C subsume it). The **LA implemented this himself** — agentic-setup is in-lane (only BlarAI runtime is
  fenced) — with independence preserved by a **fresh adversarial-gate agent**: a 3024-case equivalence sweep
  proved ZERO behavior change for non-WinUI projects, all four build-only guards are mutation-proven (each
  catches a deliberate break), PS 5.1+7 verified → verdict SOUND. `verify-merge-decision.ps1` 16/16 on main.
  → lesson: when the work is the LA's OWN (so builder-vs-gate separation is unavailable), a fresh
  adversarial-gate agent + an exhaustive equivalence sweep is the substitute for independence. The BlarAI limb
  (FIX (b) acceptance-skip + FIX Part-1 prompt) still needs a builder — BlarAI runtime is fenced.

---

## 2026-06-23 — The fixes proved out, the build-thrash got a reusable cure, and the dispatch learned to show its work

The BlarAI limb landed (a session builder built FIX (b) + Part-1; the LA added a core-deliverable rule and
independently gated it with a 5-agent ultracode pass that confirmed the guard mutation-resistant and proved the
false-"merged" classifier flaw is PRE-EXISTING / out-of-scope, then merged). Then the **real rocket-calc** ran — and
split into exactly the right shape but PARKED on the build. Diagnosing that without a dispatch, curing it with
reusable infra, and maturing the PLAN UX took the program from "it merges code" to "it merges the RIGHT code, shows
you its plan first, and you can stop a bad run in seconds."

- ✅🔬 **The decompose fix is PROVEN on hardware — and the proof is the task list, not the build.** The rocket-calc
  that earlier over-split into 6 decorative tasks (dropping the calculator) now decomposed to **ONE task that builds
  the arithmetic** (`create-space-rocket-calculator`), acceptance tests folded in (single feature → no
  stranding-prone acceptance task). The core-deliverable + single-small-GUI-app rules worked. → BlarAI: a prompt-only
  fix is inert to the deterministic eval, so it's validated by a LIVE decompose — and that signal lands in
  `current.json` right after approval, BEFORE the slow build. Read it there.
- ❌ **The 30B thrashes into competing projects without a scaffold — and HALLUCINATES success.** With the csproj
  settings RIGHT (it used the `AGENTS.md` pins correctly), the coder still spawned FOUR competing projects + three
  logic files, produced NO `.exe`, hit the 30-min circuit-breaker, and wrote a `Solution.md` claiming "✅ all
  acceptance criteria passed." Nothing built. The build-truth-only gate correctly PARKED it. → BlarAI: (1) the coder
  needs a single-project SCAFFOLD, not just correct settings; (2) a bare `dotnet build` needs ONE project (or a
  `.sln`); (3) the gate never trusting the coder's self-reported "done" is exactly why it exists.
- ✅🔬 **MASTER velocity lesson — proved the cure in ~13 s, no dispatch.** Staged reusable WinUI build infra (an
  offline NuGet feed mirrored from the cache + a known-good minimal reference app) via an ultracode workflow that
  ADVERSARIALLY validated it (restore into an EMPTY cache from the feed only → real `App.exe`; pull one package →
  `NU1101`; restore → green). Then built a single-project rocket calculator on the template with the gate's exact
  flagless `dotnet build` → 0/0 → `App.exe` in ~13 s; the operator launched it and confirmed the math + div-by-zero.
  → BlarAI: the 30-min swap+build dispatch is for the END-TO-END proof ONLY. Verify build fixes with the gate's own
  `dotnet build` on a scaffold (seconds), decompose fixes with a live decompose, fleet logic with the unit gate.
  Reserve the slow dispatch for ONE consolidated checkpoint after a BATCH — never pay 30 min per change.
- 🔬 **Two load-bearing WinUI build traps, both on-hardware.** (1) The gate runs a FLAGLESS `dotnet build`; PLURAL
  `Platforms`/`RuntimeIdentifiers` default to AnyCPU → "WindowsAppSDKSelfContained requires a supported Windows
  architecture" → park. Bake SINGULAR `RuntimeIdentifier=win-x64` + `Platform=x64`. (2) `XamlCompiler.exe` is
  net472 and hits MAX_PATH (~260) → a deep worktree false-fails `WMC1006` on DLLs that ARE present, which the gate
  mis-reads as a real fail. Build from a short path. → both baked into the staged template + the AGENTS.md rule.
- ✅ **Four maturing fixes BATCHED, each builder-built + LA-gated + merged; full standing gate 4247/0.** #5 build
  infra + a single-project `AGENTS.md` discipline; #6 Part 1 surface the task decomposition in the PLAN preview
  (the data was already in `PlanResult.tasks`, just unshown); #6 Part 2 surface the 14B's PRODUCT assumptions
  ("here's how I read the parts you didn't spell out"); #9 `/dispatch stop` tripping the existing cancel sentinel
  for a clean park-not-discard abort. Every gate read the diff + re-ran the tests independently; operator flips
  preserved through every merge. → the velocity play in practice: build the batch, verify each by fast loop, one
  full gate at the end.
- 🔬 **#6 Part 2 — a product correction reshaped the design.** The operator: he gives DETAILED product prompts but
  CANNOT give technical direction. So a literal clarifying-QUESTION turn was wrong (re-typing a detailed prompt is
  painful; a stateful answer-turn hijacks chat). The right shape is to SHOW the system's interpretation in the
  preview, scoped to PRODUCT intent (what it does/looks like), NEVER tech (the system supplies that). Display-only,
  no state machine, fail-closed, rides the existing spec→IPC flow. → BlarAI: when the operator can give intent but
  not implementation, confirm the system's PRODUCT read; never ask a question he structurally can't answer.
  [[prompts-natural-system-supplies-tech]]
- ✅ **#7 fleet robustness — all three concerns resolved + validated by the run.** Review-agent crash fixed (the
  review judge runs under a wall-clock timeout that FAILS CLOSED; `Test-ShouldMerge` (#670 FIX C) treats UNCLEAR as
  no-merge and blocks on any secret/timeout/loop/test/verify gate); swap-back held clean; over-decomposition fixed.
- ✅ **Standing operator instruction: ALWAYS finish the cleanup before coming back.** Don't surface a milestone with
  loose ends dangling and hand it back — close them (the gate, the durable commit, the journal, the trace) first.
  [[always-finish-cleanup-before-returning]]
- → **Net:** `main` is dispatch-ready and the loop is meaningfully faster — the next consolidated dispatch tests the
  whole matured pipeline at once. The rocket calculator is proven buildable (a working preview is on disk); the
  autonomous end-to-end merge is the next dispatch.

---

## 2026-06-24 — Error-feedback: the coder now FIXES build errors instead of blind-resampling

- 🔬 **Found the 30B's systematic WinUI ceiling — and it is a ONE-LINE fix.** The parked rocket-calc runs failed
  the gate with the SAME compiler error eight times (`error CS0246: 'RoutedEventArgs' could not be found`): the 30B
  writes WinUI event handlers `Button_Click(object sender, RoutedEventArgs e)` but omits `using Microsoft.UI.Xaml;`.
  The blind resample (fresh worktree, same prompt) just rewrites and re-omits it — so run `20260623-222846-bd`
  burned two resamples + a 30-min circuit-breaker (~63 min) and STILL parked. Blind resampling converges a RANDOM
  slip; it CANNOT fix a SYSTEMATIC bug.
- A: **Verify output surfaced to the run log (53cdef3).** `verify-project.ps1` already kept the last ~25 build lines
  in each check `.detail`; the caller logged only `verify: fail` and dropped it. Now a verify-fail writes the
  failing checks captured output to the run log — diagnosable post-run, and the raw material for feedback.
- B: **Error-feedback landed (734c514), mutation-resistant.** On a verify FAIL the runner KEEPS the failing code and
  hands the coder the exact error + "fix the smallest thing" (iterate build->error->fix), falling back to a fresh
  resample only when no error was captured. Logic is two PURE functions in `fleet-lib.ps1` (`Format-VerifyError`,
  `Add-BuildErrorFeedback`) so it unit-tests without a model: `verify-errorfeedback.ps1` = 22 unit + WIRING tests
  (the augmented prompt is proven to REACH the coder, not just be built); each mutant flips an assertion; the
  `verify-retry.ps1` regression stays 45/45. Ships dormant.
  -> BlarAI: this is the lever for the build ladder. Next is C1 — a curated LOCAL WinUI scaffold (right usings baked
  in) the coder EXTENDS, so it never authors the `RoutedEventArgs` mistake in the first place. Error-feedback
  RECOVERS from mistakes; the scaffold PREVENTS them. Prove both on the next consolidated dispatch.

- C1 SCAFFOLD SEEDING LANDED (b4be3f3) -- a general LIBRARY, not a WinUI hack. A FRESH target is now
  seeded with a known-good COMPILING skeleton from build-infra/<name>/reference and the coder EXTENDS it
  (committed as its baseline $codeBase; the no-op check / hasChanges / fresh-resample all measure against
  $codeBase so a no-op coder never merges a bare skeleton). Pure fns in fleet-lib.ps1 -- Resolve-TaskScaffold
  (no-clobber + web-guard; conservative on ambiguous goals) + Copy-ScaffoldInto; seeded BEFORE ecosystem
  detection so the seed also drives the language pin; AGENTS.md gained an "extend the seed, do not
  re-scaffold" rule (+ a JSON rule). verify-scaffold.ps1 19/19 mutation-resistant -- the seeded MainWindow is
  PROVEN to carry using Microsoft.UI.Xaml;, the exact CS0246 the coder kept hitting. error-feedback RECOVERS,
  the scaffold PREVENTS.
- Operator steered C1 to a MATURE multi-target library ("mature not minimal; seed other models"). Targets
  tracked as tasks #11-19: Python, PowerShell (master), C++, JS + web front/back + REST API, data-processing,
  JSON, networking (routers/switches/clients + Bitdefender firewall) + Synology DS NAS / media-server
  knowledge packs, Android. .NET MAUI workload INSTALLED on-box (maui 8.0.100 + Android SDK, exit 0;
  operator: "download now, not later") -> Android buildable; mirror its offline closure next. Knowledge packs
  are the natural home for BlarAI ingest-and-clean (dev-layer curates vetted docs INTO the offline library;
  the runtime stays air-gapped).
- Multi-pass (operator insight): a small model "finds the signal" by ITERATING against feedback. It cannot
  one-shot a nuanced build, so we (1) load the signal up front (scaffold + AGENTS.md = fewer passes needed)
  and (2) iterate against EXTERNAL feedback (error-feedback B = build->error->fix). NEXT pass = feed the
  REVIEW agent FIX-FIRST concerns back to the coder (logic/completeness the build cannot see), bounded +
  gated, never merging a worse pass (task #19). External critique > self-critique; each pass costs a full GPU
  run so passes stay capped + gate-accepted.

- Python scaffold LANDED (library entry #2). build-infra/python/reference = pyproject (setuptools packages
  scoped to app* -> no flat-layout "multiple top-level modules" trap) + app/ package + tests/ + README, zero
  deps (offline). Copy-ScaffoldInto made RECURSIVE (preserves app//tests subdirs; WinUI flat layout
  unaffected); Resolve-TaskScaffold maps explicit Python signals -> python (conservative; an ambiguous goal
  stays unseeded, never guesses a language). verify-scaffold 25/25; REAL proof = seed via Copy-ScaffoldInto
  then the gate own uv run --no-project --with pytest pytest -> 2 passed / exit 0 (green out of the box).
  NOTE: the in-tool TaskList did not persist this session -> the plan-of-record is this journal + the project
  memory, not the task tool. NEXT = PowerShell scaffold.

- PowerShell scaffold + GATE LANDED (library entry #3). build-infra/powershell/reference = AppModule.psm1
  (Set-StrictMode, CmdletBinding, comment-based help, typed param + edge case) + AppModule.psd1 manifest +
  AppModule.Tests.ps1 (Pester v5) + README. NEW gate check in verify-project.ps1: pwsh:parse parses every
  .ps1/.psm1/.psd1 deterministically (the PS "compiles"; broken syntax -> fail); pwsh:pester runs Pester only
  if v5 is usable, else SKIP (never a false fail). Resolve-TaskScaffold maps explicit PS signals -> powershell.
  verify-scaffold 29/29; REAL proof = gate on the seeded PS scaffold -> pwsh:parse PASS (3 files), pwsh:pester
  SKIP (Pester v5 not installed -> installing). errorfeedback 22 + retry 45 regression green.
- Operator target added: Windows 11 Pro administration (Task Scheduler, device mgmt, BitLocker, TPM, deeper
  OS) -- a PowerShell knowledge pack. SECURITY CONSTRAINT: these are powerful/destructive ops; the agent must
  WRITE scripts (read-mostly + clearly-flagged destructive ops the OPERATOR reviews+runs), and the gate must
  NOT auto-run destructive OS Pester (a coder test calling Disable-BitLocker/Clear-Tpm must never execute in
  verification -> parse-check only for OS-admin packs). Design constraint for the knowledge packs.

- C++ scaffold + GATE LANDED (library entry #4). build-infra/cpp/reference = a CMake project (app_core
  library + app exe + core_tests via CTest, dependency-free, builds offline). NEW gate cpp:build runs
  configure+build+test. KEY FINDING (verify-don't-assert paid off): the winget VS BuildTools install
  "failed" (exit 1) was a RED HERRING -- a PRERELEASE VS BuildTools 17.14 (MSVC 14.44) was already on the
  box; vswhere needs -all -prerelease (NOT -latest) to see it. AND cmake's default generator is "NMake
  Makefiles" + its VS generator "could not find any instance of Visual Studio" for the prerelease -- so the
  robust build path is vcvars + Ninja (build-cpp.ps1: vcvarsall x64 -> cmake -G Ninja -> build -> ctest).
  Proven on the seeded scaffold -> cpp:build PASS (6/6 objects, app.exe). Resolve-TaskScaffold maps C++
  signals -> cpp. verify-scaffold 33/33 (+S11 +C7). errorfeedback 22 + retry 45 regression green.
- Operator targets added: infra/DevOps (reverse proxies + nginx, containers + Docker, Proxmox) and earlier
  Win11-admin -- a KNOWLEDGE-PACK cluster. Docker has a real buildable artifact (Dockerfile/compose,
  validatable via docker build / compose config / hadolint); nginx config via nginx -t; Proxmox/Win11 =
  config + API/CLI + reference (PowerShell/Python scaffolds). Same security posture as Win11: the agent
  WRITES configs/scripts; destructive infra ops stay operator-reviewed-and-run.

- Web scaffold + node:test gate LANDED (library entry #5). build-infra/web/reference = a zero-dependency
  full-stack Node project (node:http back-end + /api/health REST endpoint + static public/ front-end +
  node:test), ESM, runs+tests OFFLINE (no npm install). NEW gate node:test (npm test; the built-in runner
  needs no node_modules). Resolve-TaskScaffold REORDERED: python-first (Flask/Django -> python,
  language-correct), then web (JS/Node/REST/front+back), then winui/powershell/cpp. verify-scaffold 38/38;
  REAL proof = npm test on the seeded web scaffold via the gate -> node:test PASS. FIVE language scaffolds
  now gate-proven: WinUI, Python, PowerShell, C++, Web. NEXT = recommend a dispatch PROOF (validate the whole
  library + error-feedback end-to-end on-hardware) before the knowledge packs + Android + the review loop.

## 2026-06-24 — The review-feedback loop closed, the complexity signal landed, and the library reached six

The capstone of the maturation push. Three features + a doc, all committed, all behind the deterministic
gate; the dispatch ships dormant throughout (no runtime touched, no flag flipped).

- ✅ **Review-feedback loop CLOSED (97857ab) — the critical deliverable.** The runner no longer PARKS on a
  `FIX FIRST` verdict. It keeps the work and feeds the reviewer's findings back for another pass — exactly as
  error-feedback already does for build errors — bounded by a SEPARATE review budget so a run of build
  resamples can never starve review (and vice-versa). New pure pieces in `fleet-lib.ps1`: `Add-ReviewFeedback`
  (append verdict-stripped findings; no-op on empty) + `Test-ShouldContinue` (dual-budget; delegates the build
  dimension to the proven `Test-ShouldResample`, adds the review dimension, never continues a timeout/secret-block).
- 🔬 **The loop's hardening came from THREE adversarial ultracode reviews → 8 fixes.** In order: stale
  `$priorVerifyError` reset, test-fail mis-remediation, shared-budget starvation (the deepest — review passes
  were consuming the build budget via the shared `$verifyAttempt`; fixed with a separate `$buildPass`), sticky-
  verdict regression, wrong review payload (`$reviewTail` was verdict-heavy → use the verdict-stripped
  `$reviewFindings`), and the last review's HIGH: a TEST failure DURING a review pass had no feedback var, so it
  fell through to a fresh resample that WIPED the work — now a build OR test failure routes to error-feedback
  and a build/test-fix pass CARRIES still-unaddressed review concerns. Lesson: the adversarial panel keeps
  finding the *interaction* bugs a single builder's own merge-ready pass misses — budgets, lifecycles, fall-through.
- ✅ **Complexity SIGNAL landed (380e1b2) — the operator's idea, built right.** The 14B is NOT a coder, so it
  must not send a pass count; it sends a coarse LABEL (simple|moderate|complex) and the SYSTEM maps it to the two
  budgets (`Resolve-PassBudget`: 2/1, 3/2, 5/3) and tells the coder up front (`Add-ComplexityHint`) so it
  calibrates effort before pass 1. ABSENT/unknown → the prior defaults are kept verbatim, so the change is fully
  backward-compatible (a dispatch with no complexity field behaves exactly as before). This is the natural use of
  the dual-budget loop: the signal *scales* the budgets it spends.
- ✅ **.NET console scaffold = library entry #6 (960afd7).** A dependency-free C# console skeleton
  (`app.csproj` net8.0 / `Calculator.cs` / `Program.cs`) for .NET/CLI/back-end targets that are NOT desktop
  (winui) or web. Verify-don't-assert: a real `dotnet build` of the seeded tree → **0 warning / 0 error** offline.
  `Resolve-TaskScaffold` returns `dotnet-console` on an explicit .NET/C# marker or "console app(lication)",
  ordered AFTER winui (a .NET *desktop* goal still → winui) and AFTER web (an ASP.NET *web* goal still → web);
  it deliberately does NOT match a bare "cli"/"command-line" (could be python/node). The detector now spans six
  languages: winui, dotnet-console, python, web, powershell, cpp.
- ✅ **Scaffolds made DUAL-MODE (d1efe57) — push AND pull.** The seed rule is push (seeded upfront when
  detected). Added the pull case to the agent-layer `AGENTS.md` (both the repo master and the live
  `~/.config/opencode` copy): if no skeleton was seeded but the coder realises mid-task it needs a known-good
  starting point, it can READ and adapt `build-infra/<name>/reference/`. Directly honors the operator's "what if
  after the first pass the coder realises it needs the seed packages only at that point?"
- 🔬 **Mutation-resistance, demonstrated not asserted.** Beyond green runs: each new review-feedback wiring test
  (W11–W15) was shown to KILL its mutant (baseline True → targeted mutation flips it False). The complexity
  [kill] cases are non-vacuous by construction — sentinel defaults (9/7) prove the default path isn't hardcoded,
  monotonicity proves the budget map isn't flat, equality proves the hint is a no-op on absent/unknown.
- 🔬 **A final adversarial ultracode review (3 reviewers + per-finding refutation) caught 5 REAL defects in
  THIS session's code — 4 of them mine.** The .NET-detection commit over-matched: `\bnuget\b` (also the
  PSGallery + vcpkg format) and an unanchored `\.net\b` (matched the `.net` TLD in `example.net` and ".NET
  version") and `\bdotnet\b` (driven FROM a .ps1), all ordered ABOVE powershell/cpp → a PowerShell/C++ task
  got a C# console seed AND a hard C# language pin. Fixed: dotnet-console moved LAST, `\bnuget\b` dropped, the
  .NET token anchored (".NET core/8/framework", asp.net). It also exposed a PRE-EXISTING cpp bug — `\bc\+\+\b`
  never matched "C++ " (the trailing `\b` can't fire on `+`→space) — fixed by dropping the trailing boundary.
  And the complexity signal was DORMANT on the production path (`run-fleet.ps1` never forwarded `$t.complexity`)
  → fixed + `add-fleet-task.ps1` gained a validated `-Complexity`. +6 detection kill-tests + 3 wiring tests; 2
  findings adversarially DISMISSED (ASP.NET→console is correct-language; the web scaffold is Node/JS so routing
  there is worse). LESSON (reinforced): an adversarial panel finds the *over-match/ordering* bugs a builder's
  own green suite never combines into one test — my scaffold suite passed 46/46 yet never paired "nuget" with a
  PowerShell marker. Commit `bfb8ff6`.
- ✅ **Standing gate after the session: 273 passed / 0 failed** across 8 unit suites (complexity 31, ecosystem
  72, errorfeedback 22, merge-decision 16, retry 47, reviewfeedback 33, scaffold 52) — up from 264 after the
  review fixes added the regression + wiring tests.
- ❌→📋 **Android DEFERRED with a written brief** (`docs/fleet-builder-brief-android-target.md`). Two clean probe
  failures share one root cause: `InstallAndroidDependencies` is not a from-zero bootstrapper — it needs a JDK
  (box has none: `JAVA_HOME` empty, `java` not on PATH → `XA0034`) and an existing Android SDK path to install
  into (`MSB4044`/`XA5300`). The MAUI workload + the Android SDK *pack* are installed; the remaining chain (JDK
  11+, Android SDK platform/build-tools + license acceptance, an offline mirror, then scaffold+gate) is a
  provisioning task that is operator-review-required (writes a new toolchain + accepts licenses). The fleet
  simply never seeds `android` until then — nothing is broken by the deferral.
- NEXT: an on-hardware dispatch PROOF that exercises the whole library + error-feedback + the review-feedback
  loop end-to-end (the unit gate is green; the live round-trip is the remaining evidence). Knowledge packs are
  pull-on-demand and already indexed; the multi-pass loop IS the "recursive backend" + the ReAct outer loop the
  operator asked about (the coder already reasons-acts-observes within each pass).

## 2026-06-24 — Android un-deferred: the toolchain installed + a 7th gate-proven scaffold

The operator approved the Android toolchain install (it was operator-review-required — it writes a new
toolchain + accepts third-party licenses). Done + verified the same day, in parallel with one of his dispatch
runs (I sequenced the work to avoid the 30B's load window — RAM stayed clear the whole time, ovms not resident).

- ✅ **JDK 17.0.19 LTS** (Microsoft OpenJDK) via winget; the MSI set `JAVA_HOME` machine-wide → fixes the
  `XA0034` "Failed to get the Java SDK version" cause; the fleet inherits it.
- ✅ **Android SDK** via `dotnet build -t:InstallAndroidDependencies -p:AcceptAndroidSDKLicenses=true` into
  `%LOCALAPPDATA%\Android\Sdk` — platforms android-34/36, build-tools 34.0.0/36.1.0, platform-tools, licenses
  accepted → fixes the `MSB4044`/`XA5300` no-SDK cause. `ANDROID_HOME`+`ANDROID_SDK_ROOT` set user-wide. (One
  transient install warning said platform-tools "could not be resolved", but `platform-tools\adb.exe` was in
  fact present afterward — verify-don't-assert: I inspected the SDK tree rather than trusting the log.)
- ✅ **Offline proven** (the air-gap mirror): a `net8.0-android` app builds ONLINE 0/0 and — the decisive test
  — OFFLINE 0/0 with NuGet pointed at an empty feed (fresh restore from the local cache only). Same offline
  bar as WinUI.
- ✅ **Scaffold #7** `build-infra/android/reference/` (App.csproj + MainActivity wired to a platform-free,
  testable Calculator + manifest with the default icon → text-only, no binary assets + Resources). The SEEDED
  scaffold builds offline 0/0.
- 🔬 **Zero gate change needed — proven, not assumed.** A single-TFM `net8.0-android` csproj builds under the
  EXISTING `dotnet:build` gate; I confirmed by running the gate's exact command (`dotnet build --nologo -v q`)
  on the seed using ONLY the inherited machine/user `JAVA_HOME`+`ANDROID_HOME` (no `-p` override) → 0/0.
- 🔬 **Detection learned the over-match lesson from this morning's review.** Android matches on BUILD signals
  only ("android" + an app-build noun, or `.apk`) so a mere mention ("back up my android phone") can't hijack a
  powershell/python task; ordered BEFORE winui so "a .NET MAUI Android app" seeds android (mobile), not the
  desktop winui scaffold. verify-scaffold +9 (S23/S24 detect, S25/S26 [kill]s, C10/C11 copy+wiring).
- **SEVEN scaffolds now gate-proven** (winui, dotnet-console, python, web, powershell, cpp, android); full
  standing gate **282/0**. The deferral brief (`fleet-builder-brief-android-target.md`) is marked RESOLVED.
  Commit `200e8de`. NEXT unchanged: the on-hardware end-to-end dispatch proof.

---

## 2026-06-24 — The scaffold library didn't fire for how the operator actually speaks; the fix was to stop discarding the 14B's platform read

The matured-pipeline proof — a real `/dispatch rocket-calc` of a pure-product WinUI goal —
**parked** again (~30 min, run `20260624-084153-bd`), and the trace overturned the assumption
baked into the handoff. The seeded scaffold was supposed to prevent the proliferation; the
coder transcript showed the scaffold **never seeded at all** (its first `glob **` saw only the
empty repo; it authored from scratch).

- ❌🔬 **The scaffold library doesn't engage for the operator's real prompts — by its own
  (correct) design.** `Resolve-TaskScaffold` is conservative: it refuses to guess a language
  from an ambiguous goal (the over-match lesson that bit us repeatedly). But the operator's
  prompt is *pure product intent* ("a calculator that looks like a rocket") with zero tech
  signal — by his own mandate. So the resolver no-op'd, nothing seeded, the 30B authored from
  scratch and proliferated: the real app PLUS a Console `Program.cs` with its own `Main()`, a
  2nd test project, and ~7 loose top-level-statement `.cs` runner files → CS8803 + a XAML
  internal error → the 30-min circuit-breaker → park. The CS0246 `using` ceiling was *gone*
  (the coder wrote the usings itself) — but the scaffold, last session's headline deliverable,
  was never the reason and never fired. → A capability proven only by a unit gate
  (verify-scaffold 61/0) can be **inert on the real path**: the seed had never engaged in a
  single live dispatch.

- ✅ **The reframe (operator-led): the 14B IS the system's bridge.** The earlier framing
  ("the operator writes pure product, so nothing technical appears") had been wrongly extended
  from *his prompt* to *the 14B's output*, starving the system of its smartest classifier.
  Corrected: the operator owns product intent; the SYSTEM owns all tech; the 14B translates
  product → a coarse, enum-constrained platform classification, and the deterministic fleet
  maps that to a scaffold. The operator confirms the resolved platform in the PLAN preview —
  human verification at the cheapest point, before any GPU time. SSOT:
  `dispatch-build-signal-architecture.md`.

- ✅ **Increment 1 (BlarAI producer, merged `a293dc2`): the 14B emits the build-signal.** A
  separate enum-constrained model call (mirroring the assumptions pattern, so the criteria /
  assumptions JSON contracts stay byte-identical) emits `build_plan{surface, language_hint,
  complexity, components}`; the goal-level fields thread onto every queue task and survive whole
  through `current.json` → `task-queue.json` to the fleet boundary. Fail-closed (`unknown` =
  today's behaviour). 🔬 **A surprise the trace surfaced: the coarse-signal PRODUCER channel
  did not exist yet.** `complexity` was *consumed* by the fleet (`380e1b2`) but the 14B had
  never actually emitted it — the BlarAI dispatch path had zero `complexity` references.
  Increment 1 built the producer for the first time, carrying surface + complexity together.

- ✅ **Increment 2 (fleet consumer + struct gate, merged `8633046`): surface → the right
  scaffold, and a cheap structural guardrail.** `Resolve-BuildProfile` maps surface(+hint) →
  scaffold + a structural contract; `Resolve-TaskScaffold` *prefers* the label when known
  (falls through to today's heuristic on `unknown`, byte-identical). A new EARLY
  `struct:contract` check (`Test-ProjectStructure`) fails the proliferation in **seconds,
  before the build**, routing the violation through the existing error-feedback channel —
  turning the 30-min-churn-to-park into a recoverable loop. 🔬 **A KNOWN classification
  preempting a fuzzy heuristic is the clean fix for the over-match class — the over-matching
  path is never *reached*, not patched.** (An `automation`/`library` surface + a
  "nuget"/".net"-mentioning prompt still resolves to powershell/python — the keyword heuristic
  is never consulted when the surface is known.)

- ✅🔬 **The independent adversarial gate earned its keep — again.** The fleet builder shipped
  Increment 2 green by its own measure (398 tests, 0 failures, adversarial token-combos, a real
  offline seed build). My independent probe — *my own* inputs, not the builder's — caught a real
  false-positive the whole suite missed: `Test-ProjectStructure` mis-flagged a hand-written
  `AssemblyInfo.cs` (a standalone `[assembly: …]` attribute) as a loose top-level statement → a
  false violation with nonsensical feedback. In a gate whose entire value is that the fleet can
  *trust* it, that matters. Sent back, fixed (`Get-FirstCodeToken` skips assembly/module
  attribute lines), mutation-locked (ST16-22, incl. a proof that removing the skip regresses it).
  Full gate after: **406/0** on PS 5.1 & 7. → "Green ≠ correct" extends to a builder's *most
  thorough* green suite; the probe with novel inputs is what finds the precision edge.

- ❌→✅ **A builder went idle mid-ceremony — trust the artifacts, not the idle signal.** The
  Inc-2 builder applied my exact fix AND wrote the mutation-resistant tests, but went idle
  without committing or reporting; a mid-run snapshot was even *stale* (it was still writing
  when it signalled idle). I verified the committed-vs-working state directly (git status + a
  re-run, not the notification), confirmed the work complete (struct 49/0, my probe all-pass),
  and committed the verified fix myself (`db66ef1`). → an agent's "done" signal is not ground
  truth; the git state + a re-run are.

- → **Net:** the park is fixed at the root (the fleet now seeds from the 14B's platform read),
  and the structural gate makes a future proliferation cheap; both increments ship **dormant**.
  **Next:** the operator's Increment-2 TEST DISPATCH (the seed's first-ever live engagement),
  then Increment 3 (core/shell scaffold + staged prompt) and Increment 4 (the confidence-gated
  clarifying question), each with its own test dispatch.

## 2026-06-24 — The seed proved live then parked on a known wall; a too-big load survived without OOM; and machine-written code got its trust grain

The build-signal entry above ended on "Next: the operator's Increment-2 test dispatch." It ran
(`rocket-calc`, run `20260624-120231-bd`), and three things came out of it worth keeping.

- ✅🔬 **The seed engaged on the first-ever live dispatch — the architecture works end to end.**
  The 14B read "rocket calculator" and emitted `build_plan{surface=winui, complexity=...}`; the
  fleet's `Resolve-BuildProfile` mapped winui → the WinUI scaffold + the `max_projects=1`
  structural contract; the 30B got a *compiling* shell and extended it correctly (themed
  `MainWindow`, a `Calculator` core). Increments 1+2 are no longer dormant theory — they carried
  a real goal from natural language to a seeded, building project. → BlarAI: the 14B-as-bridge
  design (small model emits a coarse platform read; deterministic code maps it to competence) is
  proven, not just unit-green.
- ❌ **It parked on a SPECIFIC, now-known wall: offline test frameworks.** The coder extended the
  app fine, then went to write tests and **invented MSTest** (`[TestMethod]`/`[TestCategory]`)
  with no package reference → `CS0246`, and spun a **second project** to hold them. The struct
  gate caught the 2nd project and fed the error back, but the coder couldn't get a test framework
  working *offline* within its 2-pass budget → breaker → park. This is not a seed-architecture
  failure — it is the next layer down, and Increment 3 fixes it at the root (the scaffold ships a
  dependency-free test harness that already builds offline, so the coder EXTENDS working tests
  instead of inventing a framework). → BlarAI: an offline box changes what "write tests" means —
  seed the working test setup; do not trust the model to assemble one from an empty feed.
- 🔬 **The headline measurement: a ~29 GB load survived a 31 GB box without OOM — and it is not
  magic.** OOM fires on **commit charge > commit LIMIT**, not on working-set > physical RAM, and
  those differ here: commit limit = physical RAM + pagefile = **31.32 + ~11 = 42.32 GB**. The 30B
  load is a ~29 GB committed transient — under the limit, so no OOM; what it does is exhaust
  *physical* headroom (Available → ~67 MB, Committed peak ~29.1 GB — milestone-1's measured
  trough) and spill ~3.3 GB of modified pages to the pagefile (a brief ~200k-pages/s storm; the
  pagefile's 3.36 GB peak-ever is that spill). Three levers make it survive: **swap-first**
  (release the 14B, −11 GB baseline) + the **pagefile lifting the commit ceiling 31→42 GB** + the
  **87% Shared-GPU override** (a ~27 GB iGPU window into the unified pool). Recorded
  community-grade in BlarAI's `PERFORMANCE_LOG.md` +
  `docs/performance/dispatch_swap_telemetry_2026-06-24.json`. → BlarAI: the swap is gated on a
  *headroom* check, not an OOM catch — the box will not OOM, it will page-storm, so the gate must
  read Available-RAM headroom (the milestone-1 lesson), not wait for an allocation failure that
  never comes.
- 🔬 **Capture-sizing bit me: Intel UT buffers in RAM and only writes at `-t` completion — it
  does NOT flush on kill.** I set `-t 2400` to be safe; it buffered 2.34 GB and had to be stopped
  to protect the run, and stopping it lost the swap/load window entirely. The build-tail capture
  I restarted (short, self-completing) wrote fine. **Lesson: pre-size `-t` to the known window,
  arm it BEFORE the event, and never kill it mid-capture.** A sub-second memory sampler armed
  before approval is what would have caught *this* run's load-trough (the milestone-1 numbers
  stand in for it). → BlarAI: same tool, same trap — size the capture to the event.
- 🔬 **Trust grain for machine-written code: UNTRUSTED, datamarked, action-locked — not
  TRUSTED_LOCAL.** The operator asked where dispatch output sits in BlarAI's provenance model.
  The call: provenance is the deciding factor (ADR-023) — `TRUSTED_LOCAL` means the operator
  authored or placed the file; dispatch output is machine-generated and unvetted, provenance
  closer to "untrusted external." Defense-in-depth (the project's core value) says contain it: a
  small model's output *can* carry a propagated injection, and UNTRUSTED + datamarking blocks it
  from driving the 14B's tools while STILL letting the 14B read and discuss the code (near-zero
  cost for the read-and-discuss use case). The realistic injection risk is low (air-gapped, own
  model, own goal), so TRUSTED_LOCAL would be defensible — but the principle + the near-zero cost
  make UNTRUSTED the right default, and it future-proofs the dormant egress path. Recorded on
  #679. The related persistence trace: loaded/grounded file content lives ONLY in the in-RAM
  grounding context (`context_manager._sessions[].grounded_chunks`, no persistence method) — it
  is NOT duplicated to disk; the encrypted `sessions.db` persists conversation turns only.
  → BlarAI: the file-read feature (#679) inherits both — UNTRUSTED grain + ephemeral in-RAM
  grounding.

**Next:** Increment 3 is building (the offline-test scaffold + staged core-then-shell prompt) —
gate it when it lands and run the operator's Increment-3 test dispatch, which should clear the
test-framework wall this run hit. Then Increment 4 (the confidence-gated clarifying question).
Capture the next swap with a pre-sized UT window + a sub-second sampler to publish this run's
load-trough cleanly.

## 2026-06-24 — Increment 3: the offline test harness was the real cure, and the "gate" that isn't a suite

Increment 3 (#676) landed and I gated + merged it (`9f9de57`). It removes the parked run's wall —
the coder inventing MSTest offline (`[TestMethod]` → CS0246) and spinning a 2nd project — at the
root. Four lessons, three from the builder, one I hit gating it.

- ✅ **The structural cure was the SCAFFOLD, not the prompt wording.** The seed now ships a
  dependency-free in-file assert harness (a tiny `TestAssert` that throws on failure, zero NuGet)
  plus `Check_*` methods. That builds offline *every* time; any MSTest/xUnit/NUnit
  `PackageReference` fails restore with NU1101 and the build with CS0246 on an offline box. The
  staged prompt and the AGENTS.md anti-patterns and the `max_projects=1` struct gate are all
  reinforcement — the load-bearing fix is that the seed's tests already compile. → BlarAI: on an
  offline box, "write tests" means seed a package-free harness; never assume a framework restores.
- 🔬 **Verify-don't-assert paid off twice on a "looks like a one-liner" scaffold.** A XAML comment
  containing `--` is a hard `WMC9999` build error (XML forbids `--` inside a comment body) — only a
  real `dotnet build` catches it, no unit assertion would. And a test that greps source for a
  forbidden token (e.g. "no `[TestMethod]`") must comment-strip first, or the file's *own* warn-off
  documentation false-fails it. The builder caught both via its offline build; my independent
  offline build re-confirmed 0/0. → BlarAI: a green unit suite that only inspects file *contents* is
  not a build — run the real compiler before believing a scaffold builds.
- ✅ **Thread new state through the narrowest existing seam.** The staged hint needed no new param
  plumbed through `add-fleet-task`/`run-fleet` — `staged` is derivable from the already-flowing
  `surface` via `Resolve-BuildProfile` at the injection point. Adding a parallel param would have
  been wiring debt; reading it off the existing profile kept the diff minimal and the non-staged
  path byte-identical.
- 🔬 **Know which of your `verify-*` files are assertion suites vs. the gate-under-test.** My
  first instinct — "run every `verify-*.ps1` and check exit codes" — *hung*, because
  `verify-project.ps1` is not a suite: it's the deterministic gate itself, with a `Mandatory`
  `-Path`, so run bare it blocks on an interactive prompt. (The builder flagged the symptom
  "exits 1, not in the count"; the precise cause is the mandatory `-Path`, and the shared gate
  *functions* live in `fleet-lib.ps1`, not in `verify-project.ps1`.) The gate is verified by
  running it *with* a `-Path` against a seeded tree — it returned `overall=pass` on the Inc-3 seed.
  The gate is "forgiving" by design (missing tool / env gap = `skip` so it never blocks a merge;
  only a check that RUNS and returns real non-zero = `fail`), which is what lets auto-merge trust
  it. → BlarAI: when a directory mixes assertion suites with the gate they exercise, drive the gate
  with inputs; don't run it bare and read the exit code as a verdict.

**Next:** the operator's Increment-3 test dispatch — one `/dispatch` that should now carry the
calculator past the test-framework wall (one project the coder extends, clean offline build; the
§9 fallback to a plain calculator still applies if the themed XAML times out the breaker). Then
Increment 4 (the confidence-gated clarifying question — a BlarAI increment).

## 2026-06-24 — The Inc-3 test dispatch: the seed worked, the coder hung itself RUNNING the tests, and "stop doomed runs fast"

The Increment-3 test dispatch (`rocket-calc`, run `20260624-142352-bd`) cleared the wall Inc 3
targeted and surfaced the next one. Four things to keep.

- ✅ **Inc 3 substantially worked.** The whole signal chain fired (desktop-gui -> winui profile,
  seeded skeleton, simple -> budget 2, staged build), the coder EXTENDED the dependency-free
  `Tests/` harness (+36 lines: 4 ops + divide-by-zero) and built the calculator CLEAN. Proof it
  is sound: strip the 3 side-road files (below), build the rest -> 0 warning / 0 error. The
  framework-invention park is gone.
- ❌ **The next failure mode: the coder tried to EXECUTE the tests.** After building clean it
  reasoned "now I need to verify the tests pass" and spun up a console runner (`TestApp.csproj` +
  `ConsoleTestRunner.cs`) to `dotnet run` them. That run hung (0 CPU; a console process that never
  exits), freezing the agent turn. A hang gets NO error-feedback retry (a timeout skips it), so it
  would have ridden the 30-min build cap to a park -- never reaching the theming stage. The staged
  prompt + AGENTS.md forbade a test *framework* and a *second project*, but never said *don't run
  the tests*. → FIX (landed `f4d7993`/`cdee85f`): the staged `$note` + AGENTS.md (repo + live) now
  say explicitly -- do NOT run/execute the tests, no console runner, no `dotnet run`/`dotnet test`;
  the gate is build-only, the tests only need to COMPILE. Kill-test SH7b locks it.
- 🔬 **Stop a DETERMINED run fast -- don't watch it bleed to the breaker.** I monitored the hung
  run ~15 min before stopping. Once a run is determined (hung, 0 CPU, no error-feedback path), stop
  it immediately; the only thing left to extract is forensics, and a frozen run gives you those at
  leisure. Dev-cycle speed is the binding constraint. → operator-validated, emphatically: the slow
  dev loop is THE bottleneck; a fast finish (or a fast stop) beats a thorough watch.
- ❌ **Landmine: `sync-harness.ps1` does its own `git add`/commit of the WHOLE tree.** Running it to
  deploy an AGENTS.md change committed my unrelated fix edits (+ a stray telemetry CSV) under a
  generic "harness sync" message; and its `Sync-One($src,$dst)` copies **live->repo** (it captures
  live drift), so editing the repo then syncing REVERTS the repo edit. Correct workflow: edit the
  LIVE `~/.config/opencode/AGENTS.md`, then sync pulls it into the repo. → FOLLOW-UP (tracked, not
  done here): scope sync-harness's `git add` to only the synced config files (never the whole tree).

**Next:** re-run the Inc-3 test dispatch with the no-execute fix live -- the coder should extend +
theme instead of hanging on a runner (and since the calculator already builds, even a breaker
timeout now yields a working unthemed app, not a park). Then Increment 4.

## 2026-06-24 — The per-command timeout: a hung command can no longer eat the build budget

The Inc-3 hang had two fixes. The prompt fix (above) stops the coder from RUNNING the tests — the
specific trigger. This is the defense-in-depth pair: a hard cap so ANY future hung command dies
fast, not at the 30-min breaker. Operator-requested, emphatically.

- 🔬 **Root cause, precisely.** opencode's bash tool takes a `timeout` (ms) arg, and its description
  tells the model to "retry with a larger timeout if the command is expected to take longer." So the
  coder gave its `dotnet run` a large timeout; when the console runner hung (0 CPU) it sat ~15 min
  before the breaker fired — eating the budget with no error-feedback recovery (a timeout is never
  resampled).
- ✅ **Fix: an opencode PLUGIN that caps the bash timeout.** opencode auto-discovers
  `~/.config/opencode/plugin/*.js` (confirmed via `opencode debug config` -> `plugin_origins`). The
  plugin (`configs/opencode-plugins/command-timeout.js`) hooks `tool.execute.before` and clamps the
  bash/shell tool's `args.timeout` to `OPENCODE_BASH_MAX_MS` (5 min default). Pure CAP — a
  model-chosen SHORTER timeout is left alone; unset/invalid/over-cap -> 5 min. No command can now run
  >5 min, so a single hang costs <=5 min, not 15-30.
- 🔬 **Verified in isolation, not just trusted.** Imported the plugin + ran its hook against fake
  args: `bash 900000 -> 300000`, `bash 5000 -> 5000` (untouched), `unset -> 300000`, `read 900000 ->
  900000` (non-bash untouched); the load-log fired; registration confirmed via `opencode debug
  config`. → lesson: a plugin wired into nothing is the worst outcome — prove load + logic before
  declaring done. The final live-verify (the cap firing in a real coder session) is the next dispatch.
- 🔬 **opencode plugin mechanics (for next time):** plugins are ESM files exporting a `Plugin` async
  function `(input) => Promise<Hooks>`; global ones auto-load from `~/.config/opencode/plugin/`; hooks
  include `tool.execute.before/after` (mutate `output.args`) and `tool.definition`. Deploy is
  reproducible via `01-install-opencode.ps1` (repo `configs/opencode-plugins/` -> the live dir).

**Next:** confirm the cap fires in the next real test dispatch (grep the coder run for the
`[command-timeout]` load-line + watch a long command die at 5 min). Tunable via `OPENCODE_BASH_MAX_MS`.

## 2026-06-25 — The VLM design loop: teaching the fleet to look at its own work

The dead-button arc proved the fleet can build *function*. It can't invent *design* — it shipped a
garish red "Space Rocket Calculator." UC-010 Phase 3 closes that: after a task merges, screenshot the
built app and let Qwen3-VL critique it against the operator's visual criteria, surfacing concrete
feedback. Built dormant this session (BlarAI critique core merged separately; the fleet pieces here).

Three things landed in this repo. The WinUI seed gained a headless `--render-to-file` entry — the one
genuinely hard problem. WinUI 3 Desktop won't render an element that was never in a live visual tree,
so zero-visibility is impossible; the honest answer is *minimal*-visibility: create the window,
`SetWindowPos` it to (-32000,-32000) off every monitor, `ShowWindow` with `SW_SHOWNOACTIVATE` (compositor
runs, focus never moves), then `RenderTargetBitmap`. Live-proved on the Arc 140V: `RENDER-OK`, exit 0,
no window on screen, foreground untouched. `capture-app.ps1` degrades render -> foreground -> structural
floor so the loop NEVER blocks on an unsolved render. `critique-loop.ps1` orchestrates one bounded pass
(it calls BlarAI's `python -m shared.fleet.critique`). The `new-agent-task.ps1` hook is `[6/6]`,
post-merge, **double-dormant** (`-EnableVisualCritique` defaults OFF *and* gated on the task's
`visual_criteria_json`) and fully fail-soft — the merge already happened, so a critique error can never
change the task's RESULT. v1 surfaces the feedback into the report; the auto-rebuild FIX-iteration is
documented at the callback as the next step (deferred because merge destroys the worktree, so re-coding
on merged code is real destabilization risk).

The proof that matters: pointed at a real flawed projects/ calculator, the live critique returned
NEEDS_WORK with *"the bright red background is visually overwhelming and clashes with the yellow and
orange buttons... buttons misaligned... display blank."* It caught exactly what a human would. That is
the whole thesis — the small coder can't invent design, but a vision model can see when it's wrong.

Two defects stayed in, both the same shape: a stubbed test proves the wiring, not the runtime. (1) The
Tier-2 foreground capture's inline `Add-Type` referenced `System.Drawing`, which on PowerShell 7 forwards
through an endless assembly cascade (`Common` -> `Primitives` -> `Private.Windows.GdiPlus`) and fails to
compile — but 63 green tests stubbed the capture and never ran the `Add-Type`. Fixed by delegating the
GDI capture to Windows PowerShell 5.1 (native `System.Drawing`), plus a non-stubbed compile-probe test so
it can't recur. (2) Dot-sourcing `critique-loop.ps1` to load its functions *binds its param block in the
caller's scope*, clobbering `$Goal`/`$VisualCriteriaJson`; fixed by capturing the real values into
`$_`-prefixed locals before the dot-source and restoring after. Both are the mock-passes/prod-crashes
lesson again: exercise the real compile/exec path at least once.

**Next:** the operator's on-hardware go-live — a real dispatch with `-EnableVisualCritique` on a visual
task (30B resident, VLM co-resident ~23 GB, real screenshot + critique), then the auto-rebuild
FIX-iteration, then the OVMS-gated asset-generation ASSETS phase (Playground up front, swap the 30B out —
the measured 32.5 GB breach — generate, swap back).

---

### 2026-06-25 — The auto-rebuild FIX-iteration, proven; and the seam two levels down

The auto-rebuild FIX-iteration the prior entry deferred is built and live-proven. The post-merge `[6/6]`
critique now drives a bounded loop: render the merged app -> Qwen3-VL critiques it against the task's
visual criteria -> if NEEDS_WORK, feed that feedback to the coder for a focused FIX on the still-alive
worktree (the worktree removal is deferred until after the loop, which was the deferral reason) ->
re-verify -> re-merge -> re-critique, capped at MaxIter. A clean run on the Arc 140V did the whole cycle:
critique-0 NEEDS_WORK -> FIX #1 -> critique-1 -> FIX #2 -> critique-2 -> FIX #3, all three *applied +
re-merged + verify=pass*, MaxIter-bounded. The screenshots showed real, feedback-driven change — the
number display went from a small unbordered "0" to a large bold panel, the equals button red -> green for
accent, both verbatim from the VLM's critique. The VLM never declared itself done (it returned a specific
critique every pass); the loop stopped on budget, and the operator's eyeball stays the verdict — exactly
the intended "signal, not judge" posture.

Two seam bugs surfaced live, both the same shape as the two in the prior entry — *the test passes because
it doesn't cross the boundary production crosses.* (1) The capture's render timeout (30s, fine on an idle
box) stalled when the app launched cold under the resident 30B; the warm render is ~1s, so a 90s budget +
a warm-up retry fixes it. (2) The auto-FIX callback used `.GetNewClosure()` to freeze its captured vars —
but GetNewClosure rebinds *function* lookup to global, so two levels deep (`run-fleet` ->
`& new-agent-task.ps1`) the dot-sourced fleet-lib functions vanished ("Add-VisualFeedback is not
recognized") and the entire iteration fail-soft-skipped. 137 unit tests missed it because their mock
callbacks were in-scope and one level deep. Fixed to a plain scriptblock (binds to the script scope; the
captured vars are stable so no freezing was needed) and locked two ways: a static guard (no scriptblock is
GetNewClosure'd) and a behavioural two-level repro that reproduces the throw. 137 -> 140 green;
verify-capture 75/0. Curated as Lesson 6 "Unit-green is not seam-green."

**Next:** tune MaxIter and a "good-enough-to-stop" threshold against more real tasks (3 passes hit the cap
without the VLM ever satisfied — fine for a signal, but worth a stop heuristic); the OVMS-gated
asset-generation ASSETS phase still awaits. Going live stays behind the operator's UC-010 ceremony and the
`-EnableVisualCritique` opt-in; the loop ships dormant.

## 2026-06-25 — A deterministic floor under the design critic (and three other seams)

The design loop went live earlier today, and within a day it showed its load-bearing weakness: its
only judge was a small VLM, and a small VLM is *lenient*. It certified a calculator grid as "neatly
aligned and evenly spaced in a clean grid" when the display sat on top of the keypad and two buttons
were oversized into the wrong cells — and the orchestrator (me) relayed that verdict instead of looking.
The operator caught it ("this is not good enough… did you look at the image?"). The fix is the whole
point of the journal: **the project's master lesson — never trust the model's self-report, verify the
artifact with an objective tool — applies to the CRITIC, not just the coder.** The code loop has compile
+ test + structural gates; the design loop had a soft oracle and nothing under it.

- ✅🔬 **A deterministic layout gate is the missing "Test" tier for design.** `shared/fleet/layout_lint.py`
  parses the generated XAML and flags geometry defects with zero model judgement — two siblings sharing a
  Grid cell (the overlap), a fixed Width/Height fighting a star/auto cell (the oversized `0`/`=`), an
  out-of-range index, a grid whose children claim undefined cells. Precision-guarded so it never nags
  correct layout. A HIGH finding forces a coder FIX **even when the VLM passes**, and because it reads
  markup not pixels it fires even on the structural floor with no screenshot. The proof that matters: a
  live seam test pointed the REAL loop at the broken layout with no app to render and no VLM in the loop,
  and it still returned ShouldIterate=true with the exact actionable feedback. 33 mutation-resistant tests.
  → BlarAI: in Compile→Test→Oracle terms, never let a soft Oracle (an LLM/VLM judge) be the only gate —
  put a deterministic Test tier in front of it for whatever it is lenient about.
- ✅ **Demote the soft oracle to a backstop, and harden it to earn that role.** The VLM critique is now
  stricter + per-criterion, runs as a perspective-diverse multi-vote (layout / hierarchy / theme) taking
  the *skeptical union* (any lens flagging = NEEDS_WORK), and ingests the deterministic findings into its
  own prompt ("confirm each is fixed"). It stays a LOOP SIGNAL only — the visual acceptance tier is
  permanently STATUS_EYEBALL; no VLM verdict marks a design done. The rejected alternative — "just write a
  sterner prompt / use a bigger VLM" — fails on its face: you don't out-prompt a self-report.
- ✅ **Progress-aware timeout: a single absolute wall-clock is wrong in both directions.** The per-coder-run
  breaker killed a productive-but-slow coder at the deadline AND let a hung run bleed the whole budget. The
  pure `Resolve-RunStopDecision` splits it: IDLE (no new step_finish AND no new edit for ~240s = genuinely
  stuck → killed fast) vs CEILING (a generous absolute backstop, 30→60 min). Every edit resets the idle
  clock, so a working coder is never idle-killed, and a doomed run dies in minutes instead of an hour.
  verify-runtimeout 29/29 under PS 5.1 AND 7. → BlarAI: an idle/no-progress timeout is almost always the
  right shape; an absolute deadline alone punishes the slow-but-working and rewards the hung.
- ✅ **The headless harness couldn't reach a production AO.** `for_live` hardcoded the gateway to plaintext
  dev-mode, so the driver could never talk to a production mTLS AO. Fixed to default the per-boot mTLS chain
  (fail-closed if absent). Live-proven: with BlarAI booted in production, the harness opened the real
  per-boot mTLS channel and got a full plan back. 59 dispatch-harness tests.
- ❌🔬 **Operational seam, live: `python -m launcher` in a background (no-TTY) process tears the AO down.**
  The launcher's Textual TUI shares the process with the AO; with no terminal the TUI starts then exits,
  and the AO dies with it — mid-dispatch, leaving a half-swapped box. AND the *detached* fleet pipeline
  (swap → run-fleet → opencode) survives a partial kill: killing the harness + swap_ops didn't stop the
  run-fleet/opencode tree that spawned seconds later. The fix that works is the operator's own path — launch
  in a real console window (a TTY keeps the TUI + AO alive, exactly what `launch_blarai.bat` does). →
  BlarAI: the AO is not headless-serveable today (no `--no-tui` server mode); a driver test must launch
  BlarAI in a console window, and a doomed-run teardown must kill the WHOLE detached tree (run-fleet,
  opencode, node, swap_ops) + stop OVMS, not just the harness.
- ❌ **PowerShell footguns that bit live:** `$pid` is a read-only automatic variable — a `foreach ($pid …)`
  loop throws; use `$procId`. And a process-sweep whose `Where-Object` match string contains the very terms
  it greps (`run-fleet|new-agent-task|swap`) matches *its own shell's command line* and kills the shell
  mid-command. Filter by process name + an explicit keep-list of PIDs, never by a command-line regex that
  includes your own invocation's text.

**Next:** the capstone — the VLM actually rendering + critiquing a real generated rocket-calculator on the
Arc 140V through the full swap pipeline — is running against the windowed (stable) AO; the deterministic
core (layout gate forcing a FIX) and the mTLS handshake are already live-proven. Standing gates green:
verify-runtimeout 29/29, verify-critique-loop 143→170, dispatch-harness mTLS 59, BlarAI suite 4478/0.

### 2026-06-27 — Concurrent best-of-N: the parallel path that leaves the sequential one byte-identical (#695)

Best-of-N (#689) gives the weak local coder several independent shots at a task and lets the deterministic
gate pick the winner; #695 makes those shots run AT THE SAME TIME. The measurement (blarai `09dfc41`) had
already answered the only research question — is the integrated Arc 140V's continuous batching real? — yes:
~1.9-2.4x aggregate, compute-bound, KV-cache-cheap. So this was an engineering job: wire C concurrent
candidates without a scratch on the proven serial path. It went green-on-units immediately and still failed
its first two live dispatches, which is the whole lesson.

- ✅ **Additive, not a refactor: C=1 IS the untouched #689 code.** The build branches on a resolved
  concurrency C. C=1 runs the EXACT sequential `Invoke-BestOfN` over one worktree — indented inside an `if`,
  nothing else. C>1 takes a new path: `Invoke-BestOfNBatched` (the concurrent twin of the orchestrator)
  drives batches of C candidates, each in its OWN worktree off the shared `$codeBase`, built by a Start-Job
  child; the winner's worktree is promoted to be the working tree and the losers are reaped. Live-proven
  both ways on the Arc 140V: a C=1 dispatch still makes the single `<repo>-<task>` worktree and merges as
  before; a C=3 dispatch ran 3 candidates concurrently (OVMS `Scheduled requests: 3` for 85% of the
  generation phase), gate-selected the earliest winner, MERGED, and tore down clean (1 worktree, 0 leftover
  branches). 18/18 verify suites green throughout — including the five that assert the literal
  `$bon = Invoke-BestOfN` wiring, which the indentation preserved.
- ✅ **Start-Job (process), not Start-ThreadJob (thread) — because two seams mutate a process-global.** Both
  the gate's pytest step AND `Invoke-AgentRun` set `$env:PYTHONPATH` to their own worktree; ThreadJobs share
  one process, so two candidates would race on that env var and cross-import each other's tree. Separate
  PROCESSES make each candidate's environment its own — the race cannot exist. The cost (a per-job pwsh
  spawn + a CliXml-serialised result) is nothing against a multi-minute coder run; a small
  `ConvertTo-CandidateResult` shim turns the deserialised result back into a clean hashtable. The right move
  on the brief's "biggest risk" was to delete the risk's root, not manage it.
- ❌🔬 **The live test found the two bugs the unit suite STRUCTURALLY could not — both in the gate↔job seam.**
  87 orchestrator assertions were green and the first concurrent dispatch still hung, then the second still
  parked, for reasons no mocked test can reach because both live in the seam between the gate and the
  Start-Job PROCESS the gate now runs inside:
  (1) **The concurrent-gate stdin hang.** Both candidates sat at 0% CPU on `python -m compileall` for
  minutes. `Invoke-WithTimeout` (every deterministic gate check) spawns `cmd /c` with `-NoNewWindow` +
  redirected stdout/stderr but an INHERITED stdin. In the sequential path that runs in the main,
  console-having process — fine. Inside a console-less Start-Job child the grandchild inherits a piped,
  never-EOF stdin and blocks; two concurrent checks then wedge. It is the EXACT class of bug
  `Invoke-AgentRun` already fixed for headless opencode — the gate just never ran in a job until #695. Fix:
  feed an empty stdin file (one line). Reproduced deterministically (two concurrent gate jobs: 0/2 done in
  75s) and proven fixed (2/2 in 4s).
  (2) **The gate's py:test didn't put the project root on PYTHONPATH** — unlike the two sibling sites that
  already do — so a standard `module.py` + `tests/test_module.py` layout failed gate COLLECTION and was
  wrongly PARKED even though its tests passed (it only ever merged before because the #690 reference repo
  put module+test at the root). Surfaced by the C=1 canary; fixed; the parked work flipped `[fail]`→`[pass]`.
  → BlarAI: the unit suite proves the POLICY; only the live run proves the PLUMBING. Mock the mechanism and
  the mechanism is exactly what you stop testing.
- ✅ **The secret/timeout posture survives batching — the highest-risk regression.** Sequentially a secret or
  a timeout is terminal and breaks the loop before any later candidate runs, so a green and a secret can
  never coexist. A concurrent BATCH can hold both. Policy: the earliest green winner in a batch still wins
  (it is real, independent, gated work; the co-batch secret candidate's work is discarded with its worktree,
  never committed, so it cannot leak — surfaced as a non-blocking note); but with NO winner, a secret/timeout
  stops further batches and is never SELECTED over an earlier real attempt (rank sinks a timeout below every
  real build, a secret far below). 14 of the 96 unit assertions exist only to pin this.
- ✅ **Defaults from evidence, then the operator's call — and a measured eye on what concurrency does NOT buy.**
  The knob (`Resolve-DispatchConcurrency`: explicit > env > built-in default, clamped [1, Max]) shipped at 1;
  I proved the concurrent path live, and the LA set **C=3** within the measured 2-3 sweet spot, paired with
  the **complex best-of-N budget raised 5→8** (more total shots at hard tasks; sampling is near-free locally
  and coverage is the weak-model bottleneck). At C=3 a complex task's 8 candidates run in three waves of
  3,3,2. Both values are mutation-locked (exact + "concurrent-not-sequential" + "within sweet spot" kills,
  and the complex>moderate ordering the old complex>simple test missed). The honest measurement that came
  out of watching the live run: **GPU was ~63% active / 37% idle** across the dispatch — the idle is
  structural (an agentic coder only drives the GPU while generating tokens; planning, file edits, git, and
  the trailing CPU test/mutation gate are all GPU-dark). Concurrency is the lever that FILLS that idle (C=1
  would idle through every candidate's tool-work), and the remaining 37% is spare capacity — which is exactly
  what makes the more-shots strategy cheap. Pushing it higher is its own measured effort (pipeline the gate
  with generation; more candidates bounded by RAM; spec-decode), tracked as a follow-up.

**Next:** land #695 (done: C=1/C=2/C=3 all merged on throwaway repos, two live-found bugs fixed,
verify-bestofn-concurrent 96/0, full fleet gate 18/18). Two follow-ups opened: **#700** unify
`Invoke-CandidateBuild` with the sequential `$BuildTestVerify` (deliberate duplication today to keep C=1
byte-identical; safe to merge now that concurrency is the default), and **#702** a **measured GPU-efficiency
pass** (profile where the 37% idle goes — suspect the `mutmut` gate dominates — then pipeline the gate with
generation, the biggest contiguous GPU-idle block).

### 2026-06-27 — #700: folding the two gate bodies into one (the cleanup #695 deliberately deferred)

#695 shipped the concurrent path as a SELF-CONTAINED twin of the sequential `$BuildTestVerify` — a deliberate
duplication, because the #695 mandate was "C=1 byte-identical, don't refactor the sequential path." The cost
was a drift hazard: two copies of the build→gate body that could silently diverge. #700 is the fold-back, now
that concurrency is the proven default.

- ✅ **One pipeline, two callers, zero behaviour change.** `Invoke-CandidateBuild` (fleet-lib) is now THE
  per-candidate build→gate function. The sequential `$BuildTestVerify` shrank from a 110-line closure to a
  6-line ADAPTER that forwards to it — so its two call sites (the best-of-N RunCandidate and the review-FIX
  loop) didn't change a character; the concurrent Start-Job path already called it. The one structural
  difference (the sequential path reuses ONE worktree and resets between candidates; the concurrent path gets
  a fresh worktree each) became a `-ResetToBase` switch. Net −75 lines. Live-re-proven: a C=1 dispatch
  (sequential, now THROUGH the unified function) and a C=3 dispatch (concurrent) both merged — and the C=3
  re-verify happened to land a batch holding a green winner BESIDE a timed-out candidate, and selected the
  green winner anyway: the §6 secret/timeout-under-batching posture, proven LIVE for free.
- 🔬 **Moving code means moving the kill-tests that pinned its location.** Eleven structural assertions across
  six suites (verify-struct / oracle / errorfeedback / retry / scaffold / mutationgate) pinned gate-body
  patterns — `Format-VerifyError`, the PYTHONPATH pytest step, the oracle-restore ORDER, `$build =
  Invoke-BuildWithRetry` — to `new-agent-task.ps1`'s text. Folding the body into fleet-lib moved every one of
  them, and the gate flagged all eleven the instant I ran it. Re-pointed each to fleet-lib (fixing the
  param-case the move introduced: `$codeBase`→`$CodeBase`, `$oracleActive`→`$OracleActive`) and added a
  dedup-lock that asserts the body is GONE from new-agent-task AND the adapter DELEGATES — so the unification
  can't silently un-unify. → BlarAI: a structural test that greps a specific FILE is a location pin; when you
  move the code, the test is part of the move. The gate turning red on all eleven was the system working.

**Next:** #700 done. The #695 arc's only open thread is **#702** (the measured GPU-efficiency pass —
pipeline the gate with generation).

## 2026-06-30 — The first real New-Project dispatch produced nothing; three linked coder faults (#670 fleet limb)

The BlarAI `#712` New-Project button shipped, and the operator's first end-to-end dispatch through it —
`a webpage with a cartoon elephant saying hello` — ran the whole pipeline correctly (create repo, 14B plan,
swap in the 30B, build, swap back, honest status) and produced `RESULT: Nothing to merge`. The UX was done;
the **coder** was the wall. Three linked faults, each fixed on a branch and **live-proven end-to-end**.

- ❌→✅ **F1 — git-bash ate the coder's Windows paths.** The bash tool runs git-bash (`fleet-lib` pins
  `$env:SHELL`), where `\` is an escape, so the coder's unquoted `cd C:\Users\...\worktree && npm test`
  became `cd: C:Users...: No such file or directory` — it could never enter its own worktree, tests never
  ran, the idle breaker killed it before it committed, and the sweep discarded the work. Reproduced
  byte-for-byte under git-bash before fixing. Fix: a new `path-normalize.js` opencode plugin (mirrors
  `command-timeout.js`'s `tool.execute.before`) that rewrites **only** Windows drive-path tokens (anchored
  on `[A-Za-z]:\`) backslash→forward-slash — a `\b`/`\w` regex or any non-drive command is byte-identical
  (11 node tests). **Verify-don't-assert win:** `AGENTS.md` told the coder "the bash tool runs PowerShell"
  — exactly inverted; it runs git-bash. That stale line was *steering* the coder toward backslash paths.
  Corrected it + added a forward-slash / never-`cd`-into-an-absolute-path rule. → BlarAI: a doc that
  describes the shell wrong is not cosmetic; it actively causes the failure it should prevent.
- ❌→✅ **F3 — the coder's web output depended on the network.** It pulled an external CDN image
  (`placehold.co`) and wrote tests that `fetch`'d a hardcoded `http://localhost:8081` it never started — on
  an air-gapped box every acceptance test `fetch failed`. The web SEED was already offline-clean; the gap
  was that only `winui`/desktop-gui got an "extend this offline seed" prompt — the `web` profile had none.
  Fix: `Add-WebHint` (extend the offline Node skeleton; inline SVG / `data:` URI for images, never an
  external URL; test on an EPHEMERAL port `server.listen(0)` like the seed, never a hardcoded unstarted
  one), an `AGENTS.md` offline rule hardened in place + the `port 8081+`/port-0 guidance reconciled + the
  stale `8000`→`8099` runtime port fixed, and an inline-SVG modeled in the seed's `index.html`. **Another
  verify-don't-assert win:** the exact live wording `webpage` (one word) did NOT match `\bweb\b`, so the
  heuristic path missed it (the dispatch path's `surface=web` covered it); added `\bwebpage\b`.
- 🔬 **F2 — the 30B stalls, and concurrency on a tight box makes the breaker bite.** After F1+F3 I
  re-measured live, six runs across throwaway targets. The honest picture: when the coder gets time, it
  does the RIGHT thing — one run wrote a complete, correct offline page (inline-SVG elephant, no external
  URL, `server.listen(0)` tests) and even added its own "no external sources" assertions. But under
  **concurrent best-of-N on a memory-tight box (~5 GB free with the 30B resident)**, both candidates went
  idle and the 240 s breaker killed them before they produced (once after exploratory reads, once with no
  output at all — OVMS and the `:8099` proxy both probed healthy, so it was coder-side startup/generation
  starvation, not the model server). I did NOT loosen the breaker (the brief's hard line). Two responses:
  (a) an **ACT-FIRST** directive in `Add-WebHint` (LESSONS Exp 3 — write before exploratory reads, each
  read is a derail die-roll); (b) the clean isolation lever — **`-Concurrency 1`** (one candidate gets the
  full GPU, faster first token). The C=1 run **MERGED**: build+tests+verify green, auto-merged
  `agent: create-webpage` to the target's `main`, `index.html` an inline-SVG elephant with **zero external
  URLs anywhere in the tree**, and the merged acceptance suite **9/9 offline**. → the fleet's
  default best-of-N concurrency vs. realistic free RAM is a genuine tuning trade-off (flagged as a
  follow-up): on a tight box, C=3 starves candidates into the idle breaker; sequential succeeds. The
  breaker is doing its job — the lever is contention, not the timeout.

The acceptance-criteria PROMPT (`free of broken links or missing assets`, a Python/Hypothesis preamble on a
Node project) is generated BlarAI-side and pushed the coder toward fetching assets — the fleet fix steers
around it but the durable fix is a BlarAI-side companion, tracked as a separate follow-up.

**Next:** LA independently gates the branch (`feat/670-coder-output-reliability`, 3 commits) before merge.
Open follow-ups: the BlarAI-side acceptance-criteria companion (web-appropriate criteria + drop the
Python/Hypothesis preamble for node); the best-of-N-concurrency-vs-free-RAM tuning question (does C=3 want
a RAM-headroom guard, or a lower default when the box is tight?); and two PRE-EXISTING PS-5.1 suites
(`verify-capture`, `verify-critique-loop`) that fail identically on `main` 5.1 with an emoji/encoding
`ParserError` — unrelated to this change but worth a BOM fix.

## 2026-06-30 — The coder stops drawing the elephant: it references a real generated asset (UC-010 SEAM A W4, #714)

The #670 arc above ended with the coder producing an inline-SVG elephant — the *correct* offline behaviour
given its only two options (draw SVG, or fetch a CDN which is forbidden). But the operator wanted the real
thing: BlarAI's on-device image generator (UC-010) makes a raster PNG, and the coder should *use* it. This
is the fleet half of that (W4); the BlarAI half — SEAM A, generate the asset AO-side while the 14B is
resident and commit it into the baseline the candidates branch from — lands on BlarAI
`feat/uc010-dispatch-asset-gen`.

- ✅ **`Add-AssetHint` — gate on the FILE, not the scaffold.** When the seeded worktree already contains
  raster assets (`public/assets/*.png` for web, `assets/`/`Assets/` otherwise — BlarAI committed them into
  the baseline pre-swap), a new dynamic hint lists them and tells the coder to reference the local file
  offline (`<img src="assets/elephant.png">` for web; a packaged `Image` for desktop), NOT to draw an
  `<svg>` placeholder or reach for a URL. **The seam-bug avoided:** the obvious gate would be
  `$scaffold -eq 'web'` (like `Add-WebHint`) — but `Resolve-TaskScaffold` returns `''` for a project that
  ALREADY exists, so a scaffold gate would MISS the exact case that matters (a real pre-existing repo). The
  hint gates on **actual file presence** in `$wt` instead. No assets → a byte-identical no-op; the
  inline-SVG fallback (`Add-WebHint`/`AGENTS.md`) stands. The "no external URL" rule is UNCHANGED — a local
  relative path is not egress. → BlarAI: when you gate a behaviour on a derived signal, check the signal
  isn't empty in the very case you care about.
- ❌→✅ **The web seed served images as `application/octet-stream`.** The reference `server.js` MIME map had
  only html/js/css, so a committed `public/assets/*.png` wouldn't render reliably in an `<img>`. Added the
  image types (png/jpg/jpeg/webp/gif/svg). A raster served as octet-stream is a "works on my machine" trap
  that fails the acceptance render.
- 🔬 **verify-assets — 15 checks, PS 5.1 AND 7.** Presence-gate, `public/`-strip (web reference = `assets/…`,
  not `public/assets/…`), prompt-preserved-verbatim, non-image-ignored, blank-surface `public/`-detection,
  desktop-vs-web form. Mirrors the house `_pass`/`_fail`/`Assert-*` harness; green on both shells. (Noted a
  PRE-EXISTING PS-5.1 flake in `verify-oracle` — git's CRLF-warning-to-stderr → `NativeCommandError` under
  `$ErrorActionPreference='Stop'`; reproduces on unmodified `#670`, unrelated — same class as the
  `verify-capture`/`verify-critique-loop` note above.)

This closes the loop the F2 note opened: the acceptance-criteria prompt that "pushed the coder toward
fetching assets" is answered not by steering harder, but by *giving the coder a real local asset to use* —
BlarAI generates it, the fleet references it, all offline.

**Next:** the operator-present full end-to-end — `/dispatch <fresh web repo> | a webpage with a cartoon
elephant saying hello` at `-Concurrency 1` (F2's lever) — to watch a *generated* elephant PNG (not SVG)
ride the 14B→30B swap, get referenced offline by the 30B via this hint, and auto-merge. Built on
`feat/uc010-dispatch-asset-w4` off `#670`; LA gates both branches.
