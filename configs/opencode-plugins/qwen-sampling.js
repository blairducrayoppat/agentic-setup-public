// qwen-sampling.js - OpenCode plugin that applies Qwen's full recommended sampling
// to every request to the local provider: top_k=20 and repetition_penalty=1.05
// (the live config already sets temperature=0.7 / top_p=0.8). These two extra
// params are the ones most tied to small-model repetition/degeneration loops, so
// adding them improves tool-call stability at zero RAM cost.
//
// SOURCE: Qwen3-Coder-30B-A3B-Instruct model card, Best Practices
//   (temperature=0.7, top_p=0.8, top_k=20, repetition_penalty=1.05)
//
// !!! STAGED, NOT ACTIVE, AND NOT YET VERIFIED ON THIS MACHINE !!!
// The OpenCode plugin API (the `chat.params` hook shape) and how @ai-sdk/
// openai-compatible forwards `topK`/`options` to OVMS can change between versions.
// Before trusting this, follow configs/opencode-plugins/README.md to install it AND
// confirm via an OVMS request log that /v3 actually receives top_k and
// repetition_penalty. Do NOT assume it works just because OpenCode loads it.

export const QwenSampling = async () => {
  return {
    // Called by OpenCode just before it builds the model request. Mutate the
    // outgoing params. `output.topK` is a first-class field; repetition_penalty is
    // an OVMS/OpenVINO extra that rides along in `output.options` (-> extra_body).
    "chat.params": async (input, output) => {
      // Only touch our local OVMS provider, never any other.
      const providerId = input?.provider?.id ?? input?.providerID ?? "";
      if (providerId && providerId !== "local") return;

      if (output.topK == null) output.topK = 20;
      output.options = { ...(output.options ?? {}), repetition_penalty: 1.05 };
    },
  };
};
