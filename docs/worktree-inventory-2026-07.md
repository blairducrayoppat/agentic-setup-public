# `.worktrees/` inventory — 2026-07-05

**Author:** M2/W7 hardening sweep (Vikunja #740) · **Rule:** inventory + document only. **No branch or
worktree was deleted, pruned, or force-anything.** All recommendations below are for the orchestrator/LA
to action.

## Method
Read-only git, from `C:/Users/mrbla/agentic-setup` (main @ `bfe1d9d`):
`git worktree list`; `git branch --merged main`; `git rev-list --count main..<branch>` (commits the branch
has that main does not); `git -C <worktree> status --porcelain` (uncommitted/untracked work that a fold
would lose).

## Finding
**Every one of the five pre-existing worktree branches is fully merged into main (0 commits ahead) and its
working tree is clean (nothing uncommitted or untracked).** They are leftover scaffolding — the code is
100% in main; nothing would be lost by folding them. (`.worktrees/m2-w7` is this sweep's own worktree,
still in use.)

| Worktree | Branch | Tip | Last commit | Ahead of main | Working tree | Recommendation |
|---|---|---|---|---|---|---|
| `670-coder-output-reliability` | `feat/670-coder-output-reliability` | `0dd4968` | 2026-06-30 · *docs(#670): LESSONS-LEARNED entry for the coder-output-reliability arc* | **0** (15 behind) | CLEAN | **FOLD** |
| `675-build-signal` | `feat/675-build-signal` | `db66ef1` | 2026-06-24 · *fix(fleet): struct gate skips assembly/module attributes + ST16-22 kill-tests (#675)* | **0** (87 behind) | CLEAN | **FOLD** |
| `676-core-shell` | `feat/676-core-shell` | `3b2f178` | 2026-06-24 · *test(fleet): verify-scaffold asserts the Inc-3 winui core/shell/offline-tests seed (#676)* | **0** (80 behind) | CLEAN | **FOLD** |
| `ram-guard` | `fix/714-ram-aware-concurrency` | `b4f14da` | 2026-07-01 · *fix(fleet): RAM-aware best-of-N concurrency guard (#714)* | **0** (11 behind) | CLEAN | **FOLD** |
| `uc010-w4` | `feat/uc010-dispatch-asset-w4` | `1abc2b3` | 2026-06-30 · *docs(fleet): LESSONS-LEARNED entry for the UC-010 asset-consumption hint (W4, #714)* | **0** (13 behind) | CLEAN | **FOLD** |
| `m2-w7` | `fix/m2-w7` | (this sweep) | 2026-07-05 · W7 hardening | in progress | in use | **KEEP** (active) |

"FOLD" = the merged work is in main and the tree is clean, so the worktree + branch are safe to remove
whenever the orchestrator/LA chooses. Suggested command per entry, for the actioner (not run here):
`git worktree remove .worktrees/<name>` then `git branch -d <branch>` (the `-d` — not `-D` — refuses
unless truly merged, a built-in safety net).

## Note on `feat/uc010-dispatch-asset-w4`
Project memory (`project-714-dispatch-asset-generation.md`) recorded this branch as "UNMERGED for LA
gate." Git ground truth on 2026-07-05 is that it is **fully merged** (0 ahead of main; tip is a docs
commit). The memory note appears stale, or referred to a sibling BlarAI-side branch. Flagging the
discrepancy, not acting on it — the fold recommendation rests on the git facts, and the memory can be
reconciled when the LA reviews.

## Non-worktree branches (out of item scope — noted, never touched)
The only branches **not** merged into main are two backups, and neither is a worktree:
- `backup/wip-main-20260701` @ `19f3433` (2026-07-01, 1 ahead) — *backup: pre-reformat WIP snapshot*
- `backup/wip-rolling` @ `482a52e` (2026-07-03, 7 ahead) — *backup: rolling WIP snapshot*

**KEEP both.** Backups are never deleted (standing rule: backup ≠ authorization to delete). They carry
commits not in main by design; that is what a backup is for.
