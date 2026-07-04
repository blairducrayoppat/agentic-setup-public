# Step-by-step testing guide (for a non-developer)

Try every new capability, safest first. ~15 min.

> **IMPORTANT - how to paste:** copy and run **ONE line at a time**. Copy a single line,
> click the PowerShell window, right-click to paste, press **Enter**. Do NOT paste several
> lines at once - the console can scramble them (that is what went wrong before). Every
> step below is a single line on purpose.

You'll use:
- **AI Control Panel** - the window you already know (double-click it).
- **PowerShell 7** - press **Start**, type **PowerShell 7**, press **Enter**. Use *this*, not
  plain "Windows PowerShell" (an older built-in version). The scripts now work in either, but
  PowerShell 7 is the faster, modern one you installed.

Quick vocabulary:
- **gitleaks** = a tiny, safe, offline program that flags anything that looks like a
  password / key / token, so the AI can never save one of your secrets into a project.
- **the fleet** = running coding tasks *unattended*. It is **NOT inside OpenCode** -
  OpenCode is the live chat you type in; the fleet is a separate runner that works through
  tasks on its own (from PowerShell or Control Panel key **T**).
- **start-llm.ps1** loads one AI model; you normally trigger it with the Control Panel
  buttons (Load Everyday 14B, etc.), not directly.

---

## TEST 1 - Secret scanner blocks a fake secret (no model needed, ~1 min)

Run this single line:
```
& "$env:USERPROFILE\agentic-setup\scripts\demo-secret-scan.ps1"
```
**Expect:** it plants a fake key (status **blocked**), then clean code (status **clean**),
and ends with **RESULT: PASS**. It cleans up after itself.

---

## TEST 2 - Quality-check harness works (no model needed, ~1 min)

```
& "$env:USERPROFILE\agentic-setup\scripts\run-evals.ps1" -Mock
```
**Expect:** `EVAL SCORE: 2/2 (mock self-test)`.

---

## TEST 3 - Load a model (needed for tests 4-6)

Double-click **AI Control Panel** -> press **3** (Load Everyday 14B). Wait for **READY**.
Leave it open.

---

## TEST 4 - A real unattended task through ALL the safety gates (~2-6 min)

The AI builds something on its own; the gates decide if it's safe to keep. One line:
```
& "$env:USERPROFILE\agentic-setup\scripts\demo-fleet.ps1"
```
It makes a throwaway project, queues one tiny task, and runs it through:
**build -> secret-scan -> tests -> build/lint verify -> review -> merge-or-park.**
- **MERGED** = all gates passed, the code is in the throwaway project.
- **parked** = something wasn't confident, so it's saved for you to look at (never lost).
Both outcomes are safe. The demo is repeatable - run it again any time.

---

## TEST 5 - See the activity report (~30 sec)

In the **AI Control Panel** press **F**. (Or run a single line:)
```
& "$env:USERPROFILE\agentic-setup\scripts\fleet-report.ps1"
```
Shows how many tasks merged / parked / blocked and which guardrails fired.

---

## TEST 6 - (Optional) Does the tool-call guard help? (~5 min, model loaded)

Run, and note the score:
```
& "$env:USERPROFILE\agentic-setup\scripts\test-guided-gen.ps1"
```
Then stop the model (Control Panel -> **5**), and reload it WITH the guard:
```
& "$env:USERPROFILE\agentic-setup\scripts\start-llm.ps1" -Model qwen3-14b -GuidedGen
```
Run `test-guided-gen.ps1` again and compare. If the score is equal-or-better with no errors,
keep launching the Everyday model with `-GuidedGen`. If worse, don't use the flag.

---

## If you want to undo EVERYTHING

Everything is applied to `C:\Users\mrbla\agentic-setup` and is reversible:
1. Click **Backup AI Configs** in the Control Panel (safety net).
2. Then ask me to undo it, or run this one line:
```
git -C "$env:USERPROFILE\agentic-setup" reset --hard 19473c3
```
Your normal **Open Coding Chat** is untouched either way.
