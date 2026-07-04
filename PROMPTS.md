# Prompt Patterns That Work With Local Models
*(learned on this machine, June 2026 — patterns proven during the Hello-World debugging saga)*

## Which agent for which job (Tab cycles through them in OpenCode)
| Agent | Use when | Behavior |
|---|---|---|
| **Build** | normal coding work | full access, makes changes |
| **Plan** | "how would you approach X?" | restricted — explores, doesn't build |
| **debug** | anything is broken | evidence-first protocol: observe → one hypothesis → smallest fix → verify; stops after 2 failed tries |
| **review** | before merging agent work (the morning gate) | read-only; file:line findings; ends with MERGE / FIX FIRST |

## The patterns

**1. Evidence-first bug report** (feeds the debug agent what it needs):
> The page/test X fails. Here is the exact error: `<paste error text>`. Fix the cause of THIS error. Change nothing else.

**2. Constrain the fix** (small models wander without fences):
> ...Do not start any servers. Do not install anything. Do not change other files.

**3. Two strikes → fresh session.** After two failed attempts, the transcript poisons further tries (the model re-reads its own bad ideas). `/new`, then restate using pattern 1 with everything learned so far.

**4. Skip the thinking phase for trivial asks** (Everyday 14B only — it's a "thinking" model):
> /no_think What does this function return?
Saves minutes on simple questions. Never use it for real coding or debugging.

**5. Right model for the job:** writing new code = either tier; *debugging, refactors, multi-file work = Deep Coding (30B)*. Debugging is harder than writing.

**6. Make it verify itself** (now standard via AGENTS.md, but worth repeating in prompts for emphasis):
> ...When done, open the page with the browser tool and confirm the console is clean.

## Reading the agent's behavior
- Prints raw JSON/XML instead of acting → plumbing problem (wrong model selected vs loaded), not a dumb model.
- Proposes installing things you have → it can't see your machine; tell it what exists.
- Long "Thought" phases on the 14B while the NPU compile or other heavy CPU work runs → contention, not the model's true speed.
