# OpenCode plugin: Qwen recommended sampling (STAGED — verify before trusting)

`qwen-sampling.js` adds the two sampling parameters the live config is missing —
`top_k=20` and `repetition_penalty=1.05` — which the Qwen model card recommends and
which most curb small-model repetition/looping. It is **staged here, not active**,
because:

- the live OpenCode config lives under `~/.config/opencode` (deny-edit by policy), so
  it must be installed deliberately, not by an unattended agent; and
- the plugin API and parameter forwarding to OVMS could not be tested live during the
  unattended build (it needs a running model + a request inspection).

## Install (do this deliberately, then verify)

1. Copy the plugin into your OpenCode plugin folder:
   ```powershell
   $dst = "$env:USERPROFILE\.config\opencode\plugin"
   New-Item -ItemType Directory -Force $dst | Out-Null
   Copy-Item "C:\Users\mrbla\agentic-setup\configs\opencode-plugins\qwen-sampling.js" $dst
   ```
2. Confirm the hook name/shape matches your installed plugin API. Open:
   `~/.config/opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts`
   and check that a `chat.params` hook exists and exposes `topK` and `options`
   (the field names this plugin sets). Adjust the plugin if the API differs.

## Verify it actually reaches OVMS (REQUIRED)

Adding the plugin is not proof the params arrive at the model. Confirm it:

1. Start a model (e.g. `start-llm.ps1 -Model qwen3-14b`) and run any OpenCode task.
2. Check the newest OVMS log under `agentic-setup\state\logs\ovms-*.out.log` (or the
   server's request log) for `top_k` and `repetition_penalty` on the incoming request.
   - If they are present with values 20 and 1.05 -> it works; keep it.
   - If they are absent -> `@ai-sdk/openai-compatible` is not forwarding `options`/
     `extra_body`; the plugin needs a different field (or the params must be sent via
     the provider `options` block in `opencode.json` instead). Do not assume success.

## Back out

Delete `~/.config/opencode/plugin/qwen-sampling.js`. No other change is needed.
