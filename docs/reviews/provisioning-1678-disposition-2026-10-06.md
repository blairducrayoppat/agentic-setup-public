# Disposition of the independent review of 06c56d6 (X1-X12, O1)

Review: `docs/reviews/code-review-1678-provisioning-2026-10-06.md` (MERGE-READY with containment off, with these to fix first).
Fixed in the commit that adds this note (the one after 06c56d6 on `feat/1678-narrow-projects-provisioning`). Tests are in
`scripts/verify-coder-narrowing.ps1` (section "review round 6"); every fix has at least one mutant in its `-Mutations` set.
Decisions and residuals: `docs/reviews/provisioning-1678-1686-1692-decisions-2026-10-05.md`, "Review round 6".

| # | Disposition | Evidence | What is left (and why it is not a fix) |
|---|---|---|---|
| X1 | FIXED | read-back, dry-run warning and check 5 use `Find-SidWriteAcesTree` with the coder's groups and ownership; test: Users/Authenticated Users group entries make `-Apply` not Ok and are listed by the dry run | group entries and ownership are reported, not removed: the operator's decision (as instructed) |
| X2 | FIXED | `C:\models` in the default model roots (plan, stage, script); test: plan strips the write entry, keeps read | other model/cache roots need adding when they appear |
| X3 | FIXED | `Select-AclRollbackBackup` refuses a bare rollback with several backups; test | none |
| X4 | FIXED | `-Credential` lists travel as a JSON file (`-ParamsFile`); check 2 fails closed on zero read paths; tests incl. the exact `-File` route | `-Credential` with a real credential not run: real-account-only |
| X5 | FIXED | table-driven lint (25 positives, 19 negatives) + a mutant per rule | text lint cannot see launches built from variables; the run-end window check remains the control |
| X6 | FIXED with residual | held checked handle around every icacls call; prose corrected; symlink-swap test | none found: the held handle blocks renaming the folder and its ancestors (measured); the post-call re-check is a second layer tested through a seam |
| X7 | FIXED | subfolders of forbidden roots refused, prefix-aware after normalisation; tests (12 refused, 3 allowed) | the list is still a list |
| X8 | FIXED | doc line corrected; stale-claim scan extended | none |
| X9 | FIXED | message names the backup and the exact `-RestoreFrom` command; test with a planted failure and an exact restore | no automatic rollback (by design) |
| X10 | FIXED | AddGrant absorption in the simulator; real apply with the operator already holding Full control: no mismatch | other Windows merge rules end as a loud MISMATCH |
| X11 | FIXED | `Find-ProtectedChildren` walks every depth; dry run lists up to 50; removal lines say "through a checked handle" | none |
| X12 | FIXED | extended-length open for paths of 240+ characters; 300+ character tree test | none |
| O1 | DEFERRED | NginxGateway (SYSTEM service, binary writable by Authenticated Users) is not part of this branch | blocked-by: #1695 (BlarAI repo) - to be resolved before the containment flip |

## Round 2 (independent re-check of acd4c3b): R2-1..R2-5

Fixed in `7d3a263`. Tests: `scripts/verify-coder-narrowing.ps1`, sections "review round 7"; 22 new mutants (131 in all, 0 survived).

| # | Disposition | Evidence | What is left (and why it is not a fix) |
|---|---|---|---|
| R2-1 | FIXED in 7d3a263 | `Get-CoderGroupInfo`: S-1-5-113, S-1-5-15, BATCH/INTERACTIVE/NETWORK added; lookup errors returned, shown as UNKNOWN GROUPS, a finding at `-Apply`; tests: Modify for each listed SID is found, Local account + This Organization on two repos make `-Apply` not Ok | a group that is neither well-known nor a local group (domain groups) is not on the list; none exist on this machine |
| R2-2 | FIXED in 7d3a263 | UNREADABLE list (path + reason) inside the digest; no digest unless none or `-AllowUnreadable`; tests: de-elevated reader gets no digest and a warning, the elevated reader's digest differs, readable folder gives a digest again | none |
| R2-3 | FIXED in 7d3a263 | `Invoke-WithProbeParamsFile`: file in the fleet root, one read entry for the coder, deleted in `finally`; tests: ACL while it exists, gone afterwards, gone after a failing body | the real `-Credential` run is still real-account-only |
| R2-4 | FIXED in 7d3a263 | 7 styles flagged, 6 negatives pass; mutants per rule | launch built from run-time pieces: the run-end window check is the control |
| R2-5 | FIXED in 7d3a263 | `$script:AclAllowTempRoot` default off; tests both directions and that only the self-test sets it | SystemRoot/Program Files read from the machine has no mutant (identical to the C: list here) |
