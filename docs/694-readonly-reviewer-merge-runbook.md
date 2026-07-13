# Watched-verify runbook — #694 read-only reviewer (merge + live-deploy)

**Branch:** `feat/694-readonly-reviewer-merged` (HEAD `df3db9b`, forked from local main `235b467`).
**Reconciles:** `feat/694-readonly-reviewer` (`e3ef0e3`, superset) + `fix/694-review-truly-readonly` (`f219074`, already in main history, its `review.md` half reverted by the sync trap #780).
**Runs under:** the coordinator's watched-dispatch discipline — this change touches the LIVE dispatch surface, so it merges on a supervised cycle, never unattended.

This runbook is a script for the human/coordinator who performs the merge. It does **not** get executed by the builder: the builder never merges to main and never writes the live `~/.config/opencode/` tree.

---

## 0. What this branch changes (why the two-part motion is mandatory)

Five files (`git diff --stat main...feat/694-readonly-reviewer-merged`):

| File | Change | Layer |
|---|---|---|
| `configs/agents/review.md` | `bash: deny` restored (+ never-run-commands wording + the 2026-07-09 shared-state criterion) | **contract** (agent def — a *request*) |
| `scripts/fleet-lib.ps1` | `Get-WorktreeDigest` + `Test-ReviewLegMutated` | **harness** (enforcement) |
| `scripts/new-agent-task.ps1` | digest snapshot around the review leg → force `FIX FIRST` + park if the tree moved | **harness** (enforcement) |
| `scripts/verify-review-readonly.ps1` | new offline proof (11 checks) | test |
| `scripts/verify-reviewfeedback.ps1` | W2 regex realigned to the live `#771` loop shape (was false-red on main) | test |
| `scripts/verify-config-deploy-sync.ps1` + `fleet-lib.ps1` (`Get-ConfigDeployDivergence`, `Test-DeployDivergenceFatal`, `ConvertTo-NormalizedContentHash`) | **#780 fix (c)** divergence-direction check: repo-vs-live agent-def hashes, `LIVE_AHEAD` (trap armed) fails, `REPO_AHEAD` warns / fails under `-Strict` (14 checks) | test |

The pre-gathered-diff half of `f219074` (`Resolve-CriticRange` + `revStat`/`revDiff` + 8000-char truncation in `new-agent-task.ps1`) is **already in main** — it was never reverted. Only the `review.md` `bash: deny` half was clobbered by the sync trap, so this branch restores it and adds the harness guard the sync **cannot** touch.

**The harness digest guard is the durable enforcement; the `review.md` deny is defense-in-depth.** That ordering is deliberate: the incident's mutation came from *outside* the agent's tool calls, and a config-sync already proved it can revert the deny. So even if step 2 below were skipped, the reviewer could not silently corrupt a candidate — but skipping step 2 re-opens the exact #780 revert, so both steps ship together.

---

## 1. Pre-merge check (on the merged branch, offline — no model, no GPU)

```powershell
cd C:\Users\mrbla\agentic-setup-wt-694
foreach ($s in 'verify-review-readonly','verify-reviewfeedback','verify-config-deploy-sync','verify-critic-diff','verify-reviewgate','verify-merge-decision','verify-critique-loop') {
    pwsh -NoProfile -File "scripts\$s.ps1"; if ($LASTEXITCODE) { throw "RED: $s" }
}
```

Expected (all exit 0): review-readonly 11/11, reviewfeedback 27/27, config-deploy-sync 14/14 (hermetic — the live probe is opt-in), critic-diff 13/13, reviewgate 8/8, merge-decision 27/27, critique-loop 193. These were green offline on pwsh 7.6.1 at build time.

Optional pre-merge live snapshot (read-only, deploys nothing): `pwsh -NoProfile -File scripts\verify-config-deploy-sync.ps1 -CheckLive` reports the current repo-vs-live verdict. Before the deploy it will say **REPO_AHEAD** (this branch's `review.md` carries `bash: deny`; the live copy does not) — a non-fatal "pending deploy", which is exactly the state step 2b closes. A **LIVE_AHEAD** verdict here would be fatal and must be reconciled before anything else.

---

## 2. Merge motion — repo merge AND live deploy in the SAME motion

> **This is the whole point of the runbook.** Step 2a merges the repo copy; step 2b deploys the same file to the live copy the fleet actually reads. Do **not** stop after 2a. The 2026-07-07 fix (`f219074`) did exactly that — merged the repo edit, left the live copy stale — and `sync-harness.ps1` captured the stale live copy back over it 3h later as `3553b56` ("harness sync: live config drift captured", author `harness-sync`). The live reviewer has run **without** its read-only constraint ever since. (#780.)

### 2a. Merge the branch to main (no-ff, fleet convention)

```powershell
cd C:\Users\mrbla\agentic-setup
git switch main
git merge --no-ff feat/694-readonly-reviewer-merged -m "Merge feat/694-readonly-reviewer-merged: the reviewer is a signal, never an actor (#694, #780)"
```

Re-run the verify set from step 1 against main (paths resolve to the merged tree) to confirm the merge is clean.

### 2b. Deploy `review.md` to the LIVE tree — immediately, same motion

`sync-harness.ps1` is one-way **LIVE → repo** and copies only when the two hashes differ (`Sync-One`, `configs/agents/review.md` line 23-25). So the anti-revert is to make the live copy **hash-identical** to the just-merged repo copy — then the next drift capture sees no difference and commits nothing.

```powershell
$repo = 'C:\Users\mrbla\agentic-setup\configs\agents\review.md'
$live = "$env:USERPROFILE\.config\opencode\agents\review.md"
Copy-Item $repo $live -Force

# PROVE the deploy: the two copies must now be byte-identical.
if ((Get-FileHash $repo).Hash -ne (Get-FileHash $live).Hash) { throw "DEPLOY FAILED — live != repo; sync-harness WILL revert" }
Select-String -Path $live -Pattern '^\s*bash:\s*deny\s*$' -Quiet   # must print True
```

If the operator maintains more than the one edited agent def, deploy every changed `configs/agents/*.md` the same way — the trap applies to any repo-only agent-def edit.

### 2c. Prove sync-harness will NOT revert (do this before walking away)

`sync-harness.ps1` fires from `start-llm.ps1` (every model swap — so it runs repeatedly through the battery night), `control-panel.ps1`, and `backup-config.ps1`. Force one cycle now and confirm it captures nothing:

```powershell
cd C:\Users\mrbla\agentic-setup
$before = git rev-parse HEAD
pwsh -NoProfile -File scripts\sync-harness.ps1     # must NOT print "Harness change detected"
$after  = git rev-parse HEAD
if ($before -ne $after) { throw "sync-harness committed drift — deploy did not match; investigate before proceeding" }
Select-String -Path "$env:USERPROFILE\.config\opencode\agents\review.md" -Pattern '^\s*bash:\s*deny\s*$' -Quiet  # still True
```

A no-op sync-harness run (HEAD unchanged, no "Harness change detected" line, live still carries `bash: deny`) is the proof the #780 trap is disarmed for this change.

**Then run the #780 fix-(c) divergence gate in strict mode as the machine-checked deploy proof:**

```powershell
cd C:\Users\mrbla\agentic-setup
pwsh -NoProfile -File scripts\verify-config-deploy-sync.ps1 -CheckLive -Strict   # must exit 0, verdict IN_SYNC
```

Under `-Strict` this fails on anything but `IN_SYNC`, so it is **red before the deploy** (REPO_AHEAD) and goes **green only once the live copy matches the repo** — a deterministic, re-runnable proof the deploy landed, not just an eyeballed hash. If it reports `LIVE_AHEAD` at any point, stop: the live copy has drifted ahead of the repo and the next sync would capture it — reconcile before proceeding.

---

## 3. The two proofs the watched dispatch MUST show

Run one supervised real coding dispatch (a small, clean, buildable task — the kind that legitimately returns `MERGE`). Watch `new-agent-task.ps1` console + the run's `review.log`/report.

### Proof (a) — a clean review still merges (no false FAIL-CLOSED)

- The review leg runs; the console shows the review verdict resolve to `MERGE`.
- The console does **NOT** print `FAIL-CLOSED (#694): the READ-ONLY review leg MUTATED the worktree …`.
- The report does **NOT** contain a `REVIEW-MUTATION (#694)` line.
- The branch auto-merges as normal.

This proves the digest guard does not false-trip on an honest read-only review: the candidate is already committed at review time, and opencode keeps session state in `~/.local/share/opencode` (share disabled), not the `--dir` worktree — so `Get-WorktreeDigest` is stable across the leg and `Test-ReviewLegMutated` returns `$false`. (If it *does* trip on clean work, that is a real false-positive to fix before this ships live — park and report, do not loosen the guard blindly.)

### Proof (b) — after a sync-harness cycle, live `review.md` still carries `bash: deny`

The battery night runs `start-llm` → `sync-harness` on every swap. After the dispatch above (or after any start-llm cycle), confirm the deploy survived a real sync:

```powershell
Select-String -Path "$env:USERPROFILE\.config\opencode\agents\review.md" -Pattern '^\s*bash:\s*deny\s*$' -Quiet   # True
git -C C:\Users\mrbla\agentic-setup log --oneline -3 --author=harness-sync   # no NEW "live config drift captured" reverting review.md
```

`bash: deny` present in the LIVE file after a genuine sync cycle, with no fresh `harness-sync` revert commit touching `review.md`, is the proof the trap is closed for good (not just for the manual cycle in 2c).

---

## 4. Rollback

The merge is a `--no-ff` merge commit; if either proof fails, `git revert -m 1 <merge-sha>` on main backs the code out. The live copy is restored by re-running `sync-harness.ps1` (which will now copy the reverted repo state forward) **or** by copying the pre-change `review.md` back to `$live`. Never force-push; never hard-reset shared history.

---

## 5. Post-merge bookkeeping

- Close **#694** with the merge SHA + the two proofs' evidence.
- Close **#780** in this same close — step 2b/2c *is* fix (a) (deploy-in-merge-motion), and `verify-config-deploy-sync.ps1` *is* fix (c) (the divergence-direction verify check, now in this branch). Both landed; no #780 residual remains open. (Fix (b) — making sync-harness itself two-way-aware — was the recommended-against alternative; the digest guard + deploy-in-motion + fix-(c) gate cover the risk without touching the capture semantics.)
- Fold the journal fragment `docs/journal_fragments/2026-07-10_694-readonly-reviewer-reconcile.md` (blarai) into `BUILD_JOURNAL.md`.
- Clean up: remove the `feat/694-readonly-reviewer-merged` worktree (`git worktree remove C:\Users\mrbla\agentic-setup-wt-694`) after merge; leave `feat/694-readonly-reviewer` and `fix/694-review-truly-readonly` intact for audit.
