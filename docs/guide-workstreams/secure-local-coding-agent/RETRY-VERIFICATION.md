# Verifying & Validating Retry-on-Failure (novice guide)

This guide explains, in plain language, what "retry-on-failure" is, how to **prove it
works** any time you want, and how to read the results. No git or PowerShell knowledge
is required to run the check.

---

## 1. What is retry-on-failure, and why does it exist?

When you give the local coding agent a task, it works in a private copy of your project
and then the fleet checks its work. Sometimes the **small local model finishes an attempt
having changed nothing at all** - a "no-op". This happens because a small/quantized model
occasionally:

- prints what *looks* like a tool call as plain text instead of actually calling the tool, or
- tries to write a file to the wrong place (outside the project), which the safety rules
  correctly block.

Either way: zero changes. A single attempt like that succeeds only \~50% of the time.

**Retry-on-failure** simply notices "this attempt produced no changes" and runs it again,
from a clean copy, up to a few times. Because each attempt is cheap and independent, a few
tries turn that \~50% into \~85-90%. Two rules keep it safe and fast:

1. It retries **only** a no-op (zero changes). It does **not** retry a *timeout* - a timeout
   means the model is genuinely stuck, and re-running would just waste minutes.
2. Each retry starts from a **clean workspace**, so a half-finished or garbled attempt can
   never poison the next one.

The logic lives in one function, `Invoke-BuildWithRetry` (in `scripts/fleet-lib.ps1`), and
the fleet runner `scripts/new-agent-task.ps1` uses it.

---

## 2. How to run the check (the important part)

Open PowerShell and run **one command**:

```powershell
cd C:\Users\mrbla\agentic-setup
.\scripts\verify-retry.ps1
```

That runs the **unit tests**: fast (about a second), deterministic, and they need **nothing
running** - not even the model server. They are the authoritative proof that the retry
*logic* is correct. You should see a list of green `[PASS]` lines ending with:

```
RETRY-ON-FAILURE: VALIDATED. The retry policy behaves exactly as specified.
```

### Optional: watch it happen for real

To also see the retry fire end-to-end against the **real local model**, first make sure your
model server (OVMS) is running, then:

```powershell
.\scripts\verify-retry.ps1 -IncludeLive
```

This spins up a throwaway project and runs the real fleet twice (this takes a few minutes).
It is on top of the unit tests, not a replacement for them.

> Run it normally as shown. Do **not** "dot-source" it (don't put a `.` and a space before
> it) - that's an advanced mode that would close your window when it finishes.

---

## 3. How to read the result

Each check prints one of three markers:

| Marker | Meaning |
|---|---|
| `[PASS]` | The behavior was exactly as specified. Good. |
| `[FAIL]` | The retry **logic** did something wrong. This is the only one that means a real problem - read the message, it says what was expected vs. what happened. The live test is built so that model variance (a timeout, or the model not cooperating) is reported as `[INCONCLUSIVE]`, **never** as a `[FAIL]` - so a `[FAIL]` is always a real signal. |
| `[INCONCLUSIVE]` | Only possible in the live test. The model didn't cooperate this run (it ignored "make no changes", timed out, or couldn't finish the task), or the server was off. This is **model variance, not a retry bug** - the unit tests already proved the logic. Just re-run. |

At the bottom you get a summary and a verdict. The script's exit code is `0` when everything
that could be validated passed, and `1` if any `[FAIL]` occurred (useful if you ever automate it).

**Bottom line for you:** if you see `RETRY-ON-FAILURE: VALIDATED` and no `[FAIL]` lines,
retry-on-failure is working correctly.

---

## 4. What each unit test proves

| ID | Scenario | What it guarantees |
|---|---|---|
| U1 | Model succeeds on the first try | Runs exactly once; never retries or resets when it didn't need to. |
| U2 | No-op, then success | Retries once; **resets the workspace *before*** the retry (exact order checked). |
| U3 | Never produces changes (max 3) | Stops at the cap (3 attempts); resets once before each retry. |
| U4 | Times out on attempt 1 | Does **not** retry a timeout, even with attempts to spare. |
| U5 | No-op, then a timeout | Stops on the timeout instead of using its last attempt. |
| U6 | Cap set to 1 | Runs exactly once, never retries. |
| U7 | Cap set to 0 or a negative number | Safely treated as a single attempt; never crashes or loops. |
| U8 | Cap not specified | Defaults to 3 attempts. |
| U9 | Wiring | A real (non-comment) line in the fleet runner actually *invokes* the tested function - so these tests cover the code you really run, not a copy. |
| U10 | No-op that "exited null" (not a timeout) | Still retried. Proves the retry decision keys on *no changes*, not on a process's exit code - a subtle distinction a naive rewrite gets wrong. |
| U11 | Change-check emits stray/extra output | A no-op with noise is still read as a no-op (retry fires), not mistaken for a change. |
| U12 | Change-check returns nothing/null | Read as a no-op (retry fires). |
| U13 | Agent returns a malformed (non-hashtable) result | Treated as non-timeout, runs safely to the cap, and the result handed to the merge gate is still well-formed - no crash. |
| U14 | Optional callbacks omitted | The default (do-nothing) reset/progress callbacks are safe to invoke. |
| U15 | The agent or change-check throws an error | The error surfaces loudly to the caller instead of being swallowed or looping. |

The live test adds:

- **Live A** - a task that says "make no changes": the retry fires (`after N build attempts`).
  Whether it then exhausts cleanly or recovers with a change, that proves the retry mechanism
  worked. A timeout or a model that ignores the instruction is `[INCONCLUSIVE]`, not a failure.
- **Live B** - a simple "create a file" task: confirms the whole pipeline still works and
  produces a change.

---

## 5. How it stays honest (why the tests can't fool you)

- The unit tests drive the **real** `Invoke-BuildWithRetry` function (not a copy), with a
  fake "agent" whose outcomes are scripted. If the retry ever ran **more** times than the
  script planned, both halves of the fake throw a loud error - so an over-retry can't slip
  through silently regardless of call order.
- U2/U3 check the **exact order** of events (run -> check -> reset -> run) for both a 2-attempt
  and a 3-attempt run, so "it resets at the wrong time" would be caught on every retry.
- The tests assert on the *value returned to the rest of the fleet* (the timeout flag and exit
  code that drive the auto-merge gate), not just the attempt count - so a build can't be made to
  *look* clean while hiding a timeout.
- U9 checks a real (non-comment) line actually *invokes* the function, so the tests can't pass
  while the real runner quietly stops using it.
- The live test reads **this run's** output only - it never trusts an old report file, so a
  previous success can't mask a current failure.
- **Mutation-tested:** the suite was checked against a battery of deliberate code mutations
  (off-by-one cap, retrying timeouts, skipping the reset, faking a clean result, proxying the
  timeout test through the exit code). Every one is *caught* by a `[FAIL]`. An earlier version
  of the suite missed two of these; they are now closed.

---

## 6. If a `[FAIL]` ever appears

1. Read the failing line - it states the scenario and "expected X, got Y".
2. Re-run `.\scripts\verify-retry.ps1` (unit only) to confirm it's reproducible and not a
   fluke.
3. The retry logic is one short function, `Invoke-BuildWithRetry` in
   `scripts/fleet-lib.ps1`. A genuine `[FAIL]` means that function's behavior changed.
4. Ask your assistant (Claude) to look - paste the failing line.

A `[INCONCLUSIVE]` is **not** a failure; just re-run the live test.

---

## 7. Related: the OpenCode update

The agent runtime was updated **OpenCode 1.17.3 -> 1.17.8** (official npm, same author,
patch-level). If you ever need to roll back:

```powershell
npm install -g opencode-ai@1.17.3
```

To check the current version: `opencode --version`.
