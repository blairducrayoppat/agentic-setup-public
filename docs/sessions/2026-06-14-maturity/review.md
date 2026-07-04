# Morning review - autonomous maturity session (2026-06-14)

> **STATUS (2026-06-14): APPLIED & ARCHIVED.** These changes were merged into `main` and the preview worktree was removed, so the "keep / throw it away" steps below now point at a folder that no longer exists - they are kept only as a record of the original handoff. To undo the changes *now*, use the "If you want to undo EVERYTHING" section of `docs/testing-guide.md`.

Hi. Overnight I built guardrails so smaller models can run **longer unattended sessions safely**, plus a way for you to **see** that it's working. Everything is isolated and reversible. Read this top-to-bottom; it takes \~5 minutes.

## TL;DR
- Your real setup (`C:\Users\mrbla\agentic-setup`, branch `main`) was **not touched**. It still works exactly as before.
- All my work is on a separate branch `maturity/autonomous-2026-06-14`, previewed in the folder **`C:\Users\mrbla\agentic-setup-maturity`** (you can open and read it).
- I installed the `gitleaks` secret scanner (verified checksum) into `agentic-setup\tools\` — that's the only thing that touched your real setup, and it's inert until you keep the changes.
- Nothing runs models or changes your live config on its own. Two items are opt-in and need a quick test with a model loaded (see "Needs a quick test" below).

## Keep it, or throw it away (your choice - one command)

**To KEEP everything** (it fast-forwards cleanly; `main` only gains these commits):
```
cd C:\Users\mrbla\agentic-setup
git merge maturity/autonomous-2026-06-14
git worktree remove C:\Users\mrbla\agentic-setup-maturity
```
Then run **Backup AI Configs** and you're done.

**To THROW IT ALL AWAY** (leaves `main` exactly as it is now, zero trace):
```
cd C:\Users\mrbla\agentic-setup
git worktree remove C:\Users\mrbla\agentic-setup-maturity --force
git branch -D maturity/autonomous-2026-06-14
```
(Optional, to also remove the secret scanner: delete `C:\Users\mrbla\agentic-setup\tools\gitleaks`.)

You can also keep it and change your mind later - it's all in git history.

## What this adds (and how to try each)

Open the **AI Control Panel** - there's a new "maturity tools" section:
- **[F] Fleet activity report** - shows how recent agent tasks went (merged / parked / blocked) and which safety checks fired. Safe to run anytime.
- **[E] Run quality check** - runs 2 small test tasks against the loaded model and scores pass/fail, so you can tell if a change helped or hurt. (Needs a model loaded.)
- **[G] Install secret scanner** - already done; re-run only to update it.
- **[T] Run overnight queue** - processes a list of tasks you've queued (see below).

### The guardrails (automatic, for every fleet task)
When the overnight fleet (`new-agent-task.ps1` / the queue) builds something, before it ever auto-merges it now must pass, in order:
1. **A time limit** - the agent is stopped if it runs too long (default 30 min) so a confused model can't churn all night. It also notices "doom loops" (repeating itself).
2. **A secret scan** - if the agent's code contains anything that looks like a password/key, the change is **not committed and not merged**; it's left for you to look at. (Critical, because your home folder holds real keys.)
3. **A build/lint check** - if the code doesn't compile or fails linting, it won't auto-merge.
4. Only if all of the above pass **and** the review agent says MERGE does it merge. Otherwise it's **parked** safely for you to review - never lost.

Every task writes a report (with TRANSCRIPT / VERIFY / SECRETS / ANOMALIES lines) you can read, and `[F]` summarizes them.

### Longer unattended runs - the queue
Instead of one task, you can queue several and let them run overnight, resumably:
```
# add tasks (each runs in its own isolated copy of the project):
agentic-setup\scripts\add-fleet-task.ps1 -Repo C:\Users\mrbla\projects\myapp -Task fix-logging -Prompt "Fix the logging and add a test."
# then run the whole queue (or use Control Panel [T]):
agentic-setup\scripts\run-fleet.ps1
```
If the machine reboots or you stop it, re-run with `-RunId <the id it printed>` and it continues where it left off. It waits for the model server, writes a journal, and leaves a `SUMMARY.txt` you'll see in the morning.

## Needs a quick test before you rely on it (model must be loaded)
These are **off by default** on purpose - I couldn't safely test them with a live model unattended:

1. **Faster/cleaner tool-calls on the everyday model.** Test it:
   - `start-llm.ps1 -Model qwen3-14b` then `scripts\test-guided-gen.ps1` (note the score).
   - `start-llm.ps1 -Model qwen3-14b -GuidedGen` then `scripts\test-guided-gen.ps1` again.
   - If the second score is equal-or-better with no errors, start the Everyday model with `-GuidedGen` from now on. If worse, just don't use the flag.
2. **Qwen's recommended sampling** (a small quality tweak) is staged at `configs\opencode-plugins\qwen-sampling.js` - **not installed**. Follow `configs\opencode-plugins\README.md` to install and verify it actually reaches the server.
3. **First real overnight run:** queue ONE tiny task, run the fleet, and confirm the report looks right before trusting a full night.

## A couple of honest notes from my own self-review
A 4-way adversarial review flagged 36 things; I fixed the real ones (better error messages, safer handling of corrupt files, fail-closed secret scanning). Two flags were **intentional, pre-existing behavior I deliberately left alone**:
- `start-llm.ps1` reads the 14B model from `BlarAI\models` - that's your existing "share the on-disk copy" decision, not a leak.
- `sync-harness.ps1` backs up your OpenClaw config - existing backup behavior.
One flag (the secret-scanner's exit-code logic) looked scary but I confirmed by live test it's correct (planted key -> blocked, clean -> clean).

## Where to read more
- `plan.md` (this folder) - the full roadmap and safety rules I followed.
- `BLUEPRINT.md` section 13 - the technical summary of everything above.
- Commit history on the branch (`git log main..maturity/autonomous-2026-06-14`) - one commit per feature, each with what + why + how it was tested.

Everything was tested offline as I built it. The only things I could NOT test (no live model unattended) are the three "Needs a quick test" items above - everything else is verified.
