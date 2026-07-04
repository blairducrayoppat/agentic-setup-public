# BlarAI builder brief — mature `/dispatch` target project-handling (select-or-create, actionable not-found, honest run-line)

**Audience:** a Claude session in `C:\Users\mrbla\BlarAI` (BlarAI runtime code). Author-side: this brief is written from the fleet repo, but the changes land in **BlarAI**.
**Tracking:** #670 (dispatch UX maturation — follow-up after the end-to-end pipeline was proven on-hardware).
**Authored:** 2026-06-23, by the dispatch LA, after tracing the live PLAN path end-to-end.
**Severity:** UX/friction, **not** a blocker — the pipeline works (a correct `/dispatch` merges real code to `main`). This removes the **dead-end a non-developer hits when the target repo doesn't exist yet**, and fixes a misleading post-run line. Ships **dormant**.

---

## 0. Why — the real gap (and the myth to drop FIRST)

**Drop this myth before you start:** an earlier framing claimed *"the PLAN step does not check whether the
repo exists — it previews criteria for ANY name, so it looks like it just works; existence only bites at
EXECUTE."* **That is false.** I traced the live path and confirmed it with an existing passing test. Do **not**
"add a missing existence check" — it already exists:

```
/dispatch <repo> | <goal>
  → gateway DispatchCoordinator._plan            (services/ui_gateway/src/dispatch_coordinator.py:141-182)
  → injected plan_fn = TransportGateway._dispatch_plan_fn   (services/ui_gateway/src/transport.py:977)
  → IPC PLAN_REQUEST → AO _handle_plan_request   (services/assistant_orchestrator/src/entrypoint.py:1773-1817)
  → generate_plan(goal, repo, projects_dir=…)    (shared/fleet/acceptance.py:597-649, call at :615)
  → decompose_request(...)                        (shared/fleet/decompose.py:434)
  → validate_repo(repo_path, projects_dir) RUNS FIRST      (decompose.py:458-461)
       → missing repo → DecomposeResult(ok=False, "Could not dispatch — <abs path> is not a git repository.")
  → generate_plan returns PlanResult(ok=False)    (acceptance.py:618-619)
  → _plan returns plan.message                    (dispatch_coordinator.py:157-158)
```
Proof test (passing today): `services/assistant_orchestrator/tests/test_plan_handler.py:111`
`test_plan_handler_bad_repo_returns_not_ok` — `repo="does-not-exist"` → `ok is False`, commented
*"generate_plan rejects the repo, never crashes."* **Confirm this yourself** by reading those lines before you
write anything — it is the foundation of this brief.

**So PLAN already rejects a non-existent repo.** The real immaturity is what happens *after* the rejection,
for a **non-developer operator**:

1. **The rejection is a dead-end.** `"Could not dispatch — C:\Users\mrbla\projects\rocket-calc is not a git
   repository."` tells a novice nothing he can act on. There is **no way to create the target** from the
   dispatch surface — today the LA hand-creates an empty git repo for him every time. (The fleet already
   assumes this affordance should exist: `agentic-setup/scripts/add-fleet-task.ps1:15` prints *"use 'Open
   Coding Chat' once to create the project (it git-inits safely)"* — an affordance `/dispatch` does not have.)
2. **No visibility:** he can't see which projects exist, and PLAN never confirms **which folder** it's about to
   build in.
3. **Silent same-name reuse:** re-dispatching an existing repo accumulates `agent/<slug>` branches with no
   word about what's already there.
4. **A misleading post-run line:** the status report ends with `Open the app:  python -m <repo>` (wrong for a
   loose-module Python repo) or `dotnet run` (wrong for an unpackaged self-contained WinUI `App.exe`) —
   `detect_run_command` (`shared/fleet/acceptance.py:477-499`, emitted at `:587-588`).

This brief matures all four into a **select-or-create + confirm + honest-report** flow.

---

## 1. Ground rules (read before designing)

- **Structural keystone — do the new work GATEWAY-side, around the `plan_fn` call. NO new IPC verb.**
  `validate_repo` runs **AO-side** inside `decompose_request`; the gateway's `_dispatch_plan_fn` receives only
  the free-text `PlanResult.message` (transport.py:986-988) — it never sees the resolved path or a reason code.
  But the **gateway already knows `projects_dir`** (`self._config.projects_dir`, used by `_repo_path`) and runs
  on the host. So the not-found detection, the existing-projects list, create, reuse-feedback, and the
  folder-confirm all belong in the **gateway** (`dispatch_coordinator.py` + helpers in `shared/fleet/dispatch.py`).
  **Re-derive "creatable vs not" by calling the same `validate_repo`/containment helpers locally — NEVER by
  string-matching `plan.message`.** That string-match brittleness is exactly what we're avoiding.
- The AO-side `validate_repo` stays the **authoritative fail-closed gate**. The gateway layer is an
  operator-experience shell in front of it, never a replacement — a freshly created repo still has to pass
  `validate_repo` on the subsequent PLAN.
- **Ships dormant for free.** Every new path is reached only *after* `handle_command` passes the
  `[fleet_dispatch].enabled` gate (`dispatch_coordinator.py:121`). With the flag false, `/dispatch new` returns
  the disabled notice and creates nothing. Prove this with a test.
- **Surgical commits.** Touch only the named files. **Preserve the operator's uncommitted working-tree
  changes** — the `enabled=true` flip in `services/assistant_orchestrator/config/default.toml` and the
  `services/ui_winui/MainWindow.xaml.cs` edit. **Never `git add -A`.**
- Offline, deterministic, fail-closed. **No new network egress.**
- **Create only under `projects_dir`**, respect the `BlarAI`/`.openclaw` fence, **sanitize-by-REJECT**.
- **Dev env (worktree-venv rule):** a git worktree doesn't carry `.venv`, so `python` falls back to system
  Python (`ModuleNotFoundError`). Use `C:\Users\mrbla\BlarAI\.venv\Scripts\python.exe` with
  `PYTHONPATH=<worktree-root>`.

---

## 2. The fixes

### 2.1 Gaps 1 + 2 — select-or-create + actionable not-found (the heart)

**New deterministic, offline helpers in `shared/fleet/dispatch.py`** (the module that already owns
`validate_repo`, so its fence+containment logic is reused, not reinvented):

- `list_projects(projects_dir) -> list[str]` — names of direct children that have a `.git` dir **and** pass
  the same fence/containment predicate `validate_repo` uses; name-sorted; best-effort (`os.scandir`, OSError →
  `[]`). The caller caps the rendered count (~12, then `(+N more)`).
- `create_git_repo(name, projects_dir) -> DispatchResult` — create `projects_dir/<name>` as a fresh git repo
  with **one** initial commit so `validate_repo`'s `.git` check passes. Safety, reusing `validate_repo`'s frame:
  1. **Sanitize by REJECT, never mangle.** Refuse if the name contains a path separator, `..`, a drive letter,
     is absolute, or is empty → return `ok=False` with a plain-English *"use a simple name like `rocket-calc`"*
     message. (Do **not** reuse `slugify_task` — it *mangles* `"my app"→"my-app"`, which would create a folder
     under a different name than the operator later dispatches.)
  2. **Factor `_assert_under_projects(resolved, projects_dir)` out of `validate_repo`** so there is exactly ONE
     containment+fence implementation, and run it BEFORE touching disk.
  3. **Refuse to clobber.** If the resolved path already exists, return `ok=False` (that path is "reuse", not
     "create"). Use `.resolve()` / `.exists()` so the **NTFS case-insensitive** collision (`Calc` vs `calc`) is
     caught.
  4. `git init`; write a minimal `.gitignore` + `README.md`; `git add` **those two named files** (never `-A`);
     commit with an inline identity `-c user.email='blarai@local' -c user.name='blarai'` (mirrors
     `add-fleet-task.ps1`/`new-agent-task.ps1`, so it works without a global git identity).
  5. **Roll back** a partial dir on any failure (a `.git` dir with no commit would pass `validate_repo`'s
     `.git` check yet be worktree-hostile). Guard the whole thing behind `shutil.which("git")`. Use the
     existing `_safe_run` vector-argv + bounded-timeout pattern (`dispatch.py:93-105`).

**Gateway `_plan` pre-flight** (in `dispatch_coordinator.py`, *before* calling `plan_fn`): resolve via the
existing `_repo_path`. If the resolved path is **missing** AND the name is **creatable** (sanitizes + passes
containment/fence — checked locally via the helpers above, **not** by inspecting `plan.message`), return an
actionable message instead of relaying the bare rejection:

```
I don't see a project named "rocket-calc" yet.
  It would live at: C:\Users\mrbla\projects\rocket-calc
To create it as a new empty project and plan against it, reply:
  /dispatch new rocket-calc | <your goal>
Your existing projects: fleet-shakedown, palindrome-demo, notes-app   (or "none yet")
```

If the name is **uncreatable** (fence hit / outside `projects_dir` / bad chars), do **not** offer to create —
relay a plain refusal naming why. The gateway classifies the reason with the same `validate_repo` /
`_assert_under_projects` helpers, so it can never diverge from the AO's gate.

### 2.2 Gap 1 — the `new` verb (the chosen create-new UX)

> **UX decision (LA, with the operator): explicit `/dispatch new <name> | <goal>` verb.** It never mutates the
> filesystem implicitly, the not-found message hands the novice the exact command to copy-paste, it fits the
> existing verb grammar, and it's the cleanest to verify. *Auto-create-on-missing* was rejected (a typo
> silently spawns a junk repo — novice-hostile, not fail-closed); *interactive "reply yes to create"* was
> rejected (a second confirm-state colliding with the one-pending-dispatch slot).

`parse_dispatch_command` (`dispatch_coordinator.py:72-88`) gains **one** branch, placed **before** the generic
`"|" in rest` run-parse so `new` isn't mistaken for a repo name:

```python
if low == "new" or low.startswith("new "):
    body = rest[len("new"):].strip()
    repo, goal = (body.split("|", 1) + [""])[:2]   # /dispatch new <name> | <goal>
    return DispatchCommand(kind="new", repo=repo.strip(), goal=goal.strip())
```

Widen the `DispatchCommand.kind` doc to include `"new"`. `handle_command` gains a `new` branch →
`_create_then_plan`, which: (1) checks the pending slot **FIRST** (`dispatch_coordinator.py:147-152`) and
refuses (creating **nothing**) if a plan is already waiting; (2) `create_git_repo(...)`, returning its message
on failure; (3) on success falls straight into the normal `_plan(session_id, repo, goal)` — which now finds a
valid repo, shows the folder-confirmation + criteria, and stores the pending slot. So `new` is **"create + the
identical confirmed PLAN flow"** — the mandatory approve step is unchanged; no work fires from `new`.

### 2.3 Gap 3 — folder confirmation at PLAN

In `_plan`, after a successful plan and before `render_criteria_preview`'s output
(`dispatch_coordinator.py:171`), prepend one line (via a tiny, unit-testable coordinator helper):

```
Building in: C:\Users\mrbla\projects\rocket-calc
```

### 2.4 Gap 4 — same-name reuse feedback

New **read-only** `describe_repo_state(repo) -> str` in `dispatch.py` (best-effort; `git` absent / OSError →
`""`): whether the repo already has commits (`git -C <repo> rev-parse HEAD`) and the parked `agent/<slug>`
branches (`git -C <repo> branch --list "agent/*"`). Surface it in `_plan` **only when the repo pre-existed**
(skip for a just-created `new` repo):

```
Heads up: "fleet-shakedown" already has work in it — 3 commits, and these agent branches from earlier
dispatches are still parked: agent/implement-is-palindrome, agent/add-leap-year. New work merges into main;
parked branches are left as-is. Reply /dispatch reject if you meant a fresh project.
```

This **only makes the silent accumulation visible** — it is read-only and does **not** change the fleet's
accumulation behavior. Fleet-side branch **pruning** (if wanted) is a **separate, deferred agentic-setup
brief**, explicitly out of scope here.

### 2.5 Gap 5 — honest run-command line

Rewrite `detect_run_command` (`shared/fleet/acceptance.py:477-499`):

- **python:** keep the `main.py`/`app.py`/`__main__.py` detection. For the no-entrypoint case, do **not** emit
  `python -m {repo.name}`; if there's exactly one top-level `*.py`, emit `python <that file>`, else fall back
  to the honest `open the folder: <repo>`.
- **dotnet:** prefer a built artifact — glob `bin/**/*.exe` (and `bin/**/<name>.exe`); if found, point at the
  built `App.exe` path (fixes the unpackaged self-contained WinUI case). Else if there's a runnable project,
  `dotnet run`; else `open the folder`. Best-effort, **offline, glob only — never build**.
- **node / unknown:** unchanged (already honest).

`render_acceptance_report` already accepts a `run_command` override and falls back to `detect_run_command(repo)`
(`acceptance.py:587`) — no caller change. The existing expectations in `tests/integration/test_acceptance.py`
(around `:327`, the `dotnet run` and `python -m` cases) **will flip** — that flip **is** the gap-5
green→revert→red evidence, **not** a regression to preserve.

---

## 3. Edge cases / risks to handle

1. **Empty repo after `new` → `detect_ecosystem == 'unknown'`.** A freshly `git init`'d repo has no manifest,
   so `render_criteria_preview` emits its "couldn't tell this project's language" caveat
   (`acceptance.py:539-545`) and `detect_run_command` returns `open the folder`. This is **correct and honest**
   for an empty repo — no code change; just don't be surprised by it. The ruler's build floor still fires, so
   criteria are non-empty.
2. **Concurrency with the one-pending slot.** `_create_then_plan` MUST check the pending slot **before**
   creating the repo — never create-then-discover-pending (which would orphan an empty repo).
3. **NTFS case-insensitive collision** — see 2.1.3.
4. **Sanitize: reject, don't mangle** — see 2.1.1.
5. **`git` availability + half-repo on commit failure** — see 2.1.5.
6. **Surgical-commit hazard.** `create_git_repo`'s `git add` runs inside the NEW target repo under
   `projects/` — a *different* git repo, so it cannot touch BlarAI's index. But your BlarAI commit must still
   be surgical (named files; never `-A`) and preserve the operator's uncommitted `enabled=true` +
   `MainWindow.xaml.cs`.

---

## 4. Verification (mutation-resistant + the live proof)

Dev env: `C:\Users\mrbla\BlarAI\.venv\Scripts\python.exe`, `PYTHONPATH=<worktree-root>`; isolated worktree off
`main`.

**Unit (deterministic, offline — no GPU/AO/fleet):**
- `tests/integration/test_fleet_dispatch.py` (extends the `validate_repo` cluster):
  - `list_projects` returns only `.git` children passing the fence (a `BlarAI`-named child and a non-git child
    excluded; name-sorted).
  - `create_git_repo` happy path: creates `projects/foo`, `validate_repo(foo)` now `None`, **exactly one**
    commit, only `.gitignore`+`README.md` tracked (skip/guard if `git` absent).
  - `create_git_repo` **sanitization matrix** (the security core): `"../escape"`, `"a/b"`, `"C:\\abs"`, `".."`,
    `"BlarAI"`, `""` → **all `ok=False` AND create NOTHING** (assert the path is absent afterward).
  - `create_git_repo` refuses to clobber an existing dir (incl. the case-insensitive `Calc`/`calc` case).
  - `describe_repo_state`: a repo with commits + an `agent/x` branch reports both; an empty / `git`-less repo
    → `""`.
- `tests/integration/test_acceptance.py` (rewrites the `detect_run_command` cases ~`:327`):
  - python no-entry, ONE loose `.py` → `python <file>.py`; MULTIPLE loose `.py` → `open the folder` (the case
    the old `python -m` got wrong).
  - dotnet with a built `bin/.../App.exe` → that exe path; dotnet class-lib only → not `dotnet run`.
- `tests/integration/test_dispatch_coordinator.py` (extends the suite):
  - `parse_dispatch_command("/dispatch new calc | a calc")` → `kind="new"`; `/dispatch new` with no goal →
    usage; `"/dispatch newish | x"` still parses as a RUN against repo `"newish"` (no `new`-prefix
    false-positive).
  - `_plan` against a missing-but-creatable name → the actionable not-found message (names the folder + the
    `new` command + lists projects), does **not** call `plan_fn`, stores **no** slot.
  - `_plan` against an uncreatable name (`"BlarAI"`) → a plain refusal, **no** create offer.
  - `new` happy path: creates the repo, returns a preview WITH `Building in: <abs path>`, stores the slot,
    `execute_fn` NOT called.
  - reuse feedback: a pre-existing repo with an `agent/*` branch → the "already has work" heads-up; a freshly
    `new`'d repo → none.
  - **Dormancy:** `enabled=False` + `/dispatch new …` → the disabled notice, **projects dir untouched**.

**Mutation-resistance (green → revert → red, with REAL terminal output, both directions):**
- Gap 5: revert `detect_run_command` to `python -m {repo.name}` / `dotnet run` → the loose-Python + WinUI-exe
  cases go RED. Restore → green.
- Gap 2: revert the `_plan` pre-flight (fall through to `plan_fn`) → the actionable-message test goes RED.
- **Gap 1 create-safety (the one the LA most wants to see fail loudly):** revert the sanitize/containment guard
  → the `"../escape"` test creates a dir outside `projects_dir` / stops returning `ok=False` → RED. Restore →
  green.
- Gap 4: revert the reuse-feedback prepend → the "already has work" assertion goes RED.

**Live end-to-end (operator's on-hardware step — document the steps, do NOT fire it yourself):** with
`enabled=true`: (1) `/dispatch calc | …` for a non-existent `calc` → the actionable not-found message;
(2) `/dispatch new calc | a calculator an 8-year-old can use` → repo created, PLAN shows `Building in: …\calc`
+ criteria, `/dispatch approve` runs it, the post-run `Open the app:` line is honest for the resulting
ecosystem; (3) re-dispatch to an existing repo with parked `agent/*` → the reuse heads-up appears.

---

## 5. Process

- **Open with a comprehension gate.** State (a) your understanding of the **corrected premise** — PLAN already
  rejects a non-existent repo; **confirm it by reading `decompose.py:458-461` + the passing
  `test_plan_handler_bad_repo_returns_not_ok`** before you write anything; (b) the **gateway-side keystone** (no
  new IPC verb; re-derive creatable-vs-not via the helpers, never by string-matching `plan.message`); and (c)
  your plan for the 5 gaps with the `new` verb (Option A). **Wait for LA confirmation before coding.**
- **Feature branch off `main`** (never commit to `main`).
- **Surgical commit** — only `dispatch_coordinator.py`, `dispatch.py`, `acceptance.py`, and the three test
  files. **Preserve** the operator's uncommitted `default.toml` `enabled=true` flip + `MainWindow.xaml.cs`.
  **Never `git add -A`.**
- **BUILD_JOURNAL fragment** at `docs/journal_fragments/2026-06-23_dispatch-project-handling.md` (narrative +
  `**Next:**`; a `**Proposed lesson:**` block if the work earned one — e.g. *"the existence check was already
  there; the gap was the novice's path forward, not the validation"*).
- **One self-contained package before merge:** the diff, the unit results, the green→revert→red terminal
  output for each gap, and the documented live-proof steps. The **LA independent-gates before any merge**
  (when the operator says **"ultracode"**, via a multi-agent adversarial `Workflow`); ships **dormant**.
