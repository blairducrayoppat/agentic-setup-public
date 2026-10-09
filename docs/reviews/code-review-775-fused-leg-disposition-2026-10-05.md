---
title: "Disposition -- independent round-4 review of the fused coder leg (#775 / #1691, agentic-setup)"
date: 2026-10-05
review_of: "fix/1691-n1-n3-n5 round 4 (docs/reviews/code-review-775-fused-leg-2026-10-05.md, section 'Round 4'); verdict MERGE-READY with containment off, NOT flip-ready"
reviewer: independent Opus review (author != verifier)
---

# Disposition -- fused-leg round 4 (2026-10-05)

Rounds 1-3 are dispositioned in their commits (L1-L10 `2b38999`, M1-M4/L8 `6905e03`, N1-N5 `49bd0d9`, `b4627ed`);
this record covers the round-4 findings and the flip-blocker list. Format follows BlarAI's disposition records.
The flip is blocked by the DEFERRED rows below, each carrying an observable predicate; none is a momentum ticket.

```disposition
n1-swap-window | FIXED | 49bd0d9 plus d0120f5: the worktree is pinned by a held handle (identity, resolved path, .git anchor); the round-3 reproduction (swap right after the funnel check) is now Access denied and a 173-call random flip race leaked nothing.
elevation-premise | FIXED | the commit carrying this record: docs/fused-leg-operator-uses.md and the Stop-CoderProcessesConfirmed comment no longer assert that run-fleet is non-elevated; both paths are described and 'elevation of run-fleet is UNVERIFIED (read the AO process token live before the flip)' is stated.
wmi-schtasks-escape-nonelevated | DEFERRED | #775 blocked-by: the 'Non-elevated residual' section of docs/fused-leg-operator-uses.md is deleted AND a test spawns a process through WMI Win32_Process.Create as the coder and finds it dead after the leg (symbol: a test named for the WMI escape in scripts/verify-coder-fused-seam.ps1), or flip-blocker-0 shows the AO is elevated and the enumeration path is the gate.
content-edit-between-gate-and-merge | DEFERRED | #775 blocked-by: a tree digest re-verified immediately before merge (symbol: a digest check called from the merge step in scripts/new-agent-task.ps1) or the escape above closed; the pin blocks directory swaps, not file edits by an escaped process.
n6-lone-surrogates | FIXED | 1b62f74: the strict JSON parser refuses unpaired surrogate escapes in values and keys; test plus mutant strict-lone-surrogates (killed).
n7-clock-one-source | REJECTED | The NotBefore check compares the file's creation time with the enqueue instant on one clock, so a machine-wide skew moves both together and opens nothing; a result pre-created in the same second is caught by the owner, id and kind binding, which is the primary control. A future-dated creation time (the only second-source input) is refused separately (449bd53).
flip-blocker-0-measure-ao-elevation | DEFERRED | #775 blocked-by: a dated comment on #775 recording the AO process token elevation read live (Get-Process owner/IsElevated of the running AO), decided by the LA-present session before any flip.
flip-blocker-1-nonelevated-escape | DEFERRED | #775 blocked-by: same predicate as wmi-schtasks-escape-nonelevated.
flip-blocker-2-fleet-acls | DEFERRED | #1686 blocked-by: #1686 closed and the ACL gate (Assert-CoderQueueAclTight) passing on the real C:\blarai-fleet in the verify-coder-containment real-mode run.
flip-blocker-3-projects-modify | DEFERRED | #1678 blocked-by: #1678 closed (the coder no longer holds Modify on C:\Users\mrbla\projects).
flip-blocker-4-coder-setup | DEFERRED | #775 blocked-by: a dated comment on #775 recording the coder account's own opencode config, read grants and the :8099 probe check green (plan step 4).
flip-blocker-5-egress | DEFERRED | #1682 blocked-by: #1682 closed and Assert-CoderEgressContained in scripts/fleet-lib.ps1 throwing when the filter set is absent (the 'accepted gap' log line removed).
flip-blocker-6-live-proof | DEFERRED | #775 blocked-by: a recorded real-mode verify-coder-containment.ps1 -AcceptedEgressGap green, one watched fused dispatch result with the coder SID, and the LA-present flip ceremony on #775.
```
