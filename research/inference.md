# inference

## FINDINGS
## 1. Ollama (upstream) — v0.30.7 (June 7, 2026)
- Vulkan backend: introduced experimental in v0.12.6/0.12.11 (Nov 2025) behind OLLAMA_VULKAN=1; now ENABLED BY DEFAULT when the Vulkan backend is installed (docs.ollama.com/gpu; disable with OLLAMA_VULKAN=0 or GGML_VK_VISIBLE_DEVICES=-1; select device with GGML_VK_VISIBLE_DEVICES). On Windows, vendor drivers bundle Vulkan — no extra setup. So yes, it accelerates on Arc 140V natively now, via Vulkan only (no SYCL path upstream).
- v0.30.0 (May 13, 2026) brought "broader llama.cpp backend support"; v0.30.x adds Hermes Desktop agent, OpenAI /v1 models-list alignment.
- Tool calling for Qwen3-Coder family: shaky. Documented 2026 bugs: qwen3 tool parser returns HTTP 500 on truncated JSON (ollama#14570); Qwen3.5 wired to wrong (Hermes-JSON) renderer/parser instead of the existing Qwen3-Coder XML pipeline (`<function=name><parameter=key>` format) (ollama#14493); unclosed `<think>` blocks corrupt multi-turn tool loops (parser fixed in v0.17.3, renderer still broken at report time); Qwen3-Coder silently switches to XML-in-content when given >\~5 tools, breaking agents like Goose (block/goose#6883).
- Blob store reuse: yes — same `~/.ollama/models` layout; set OLLAMA_MODELS=C:\Users\mrbla\.ollama\models and existing manifests/blobs (qwen2.5-coder 14b-q6_K/7b/1.5b, nomic-embed-text) are picked up by a fresh install. The blobs are also plain GGUF files loadable directly by llama.cpp via their sha256 path.
- Perf concern: Vulkan tg on Intel iGPUs has historically been the weakest backend (see #3), and Ollama exposes no SYCL.

## 2. ipex-llm — DEAD. Repo archived January 28, 2026 (read-only). Intel notice: no maintenance, no bug fixes, patches not accepted, "identified as having known security issues." Last release v2.2.0 (Apr 7, 2025); portable Ollama/llama.cpp zips frozen at \~Ollama 0.6.x-era and old llama.cpp, predating Qwen3-Coder templates and most 2025-26 tool-calling fixes. Historically it was the fastest on Intel iGPU (Dec 2024 llm-tracker, Llama-2-7B Q4_0 on 258V/140V: pp512 708 t/s, tg128 24.4 t/s vs SYCL FP16 526/13.5 and Vulkan 44.6/5.5), but had k-quant breakage on Xe2. Disqualified for a security-first machine in 2026.

## 3. llama.cpp upstream (b9196+, June 2026)
- Windows prebuilts: official releases now ship win-x64 CPU, CUDA, Vulkan AND SYCL zips (latest binaries dated 2026-06-10) — no toolchain needed.
- SYCL vs Vulkan on Arc 140V: historically SYCL FP16 crushed Vulkan at prefill (526 vs 45 t/s pp512, Dec 2024) but Vulkan caught up massively once Xe2 cooperative-matrix/XMX paths landed: April 2026 community scoreboard shows Arc 140V pp512 ≈ 657 t/s under Vulkan (Llama-2-7B Q4_0), M4-Pro-class prefill. Token generation is bandwidth-bound on both (\~136.5 GB/s LPDDR5X ceiling).
- BUT Lunar Lake Vulkan stability is rough in 2026: ggml-org/llama.cpp#20554 — VK_KHR_cooperative_matrix causes GPU TDR/driver reset on Arc 140V with Intel drivers 101.8509/101.8531 (workaround: GGML_VK_DISABLE_COOPMAT=1, which costs prefill speed; older 101.7026 OK; closed as stale awaiting Intel driver fix). ggml-org/llama.cpp#18946 — ErrorOutOfDeviceMemory + memory-accounting overflow on 258V for Qwen3-30B-A3B Q4_K_M in both Vulkan and SYCL; workarounds: Windows "Shared GPU Memory Override" (\~24GB), `-fa off`, conservative `-ngl/-b/-ub`; with these, \~21–25 t/s decode was achieved; closed-not-planned Jan 2026. #20776: Xe2 mobile parts sometimes not detected as INTEL_XE2 → coopmat silently off.
- llama-server OpenAI API + tool calling: mature in 2026 — `--jinja` uses GGUF-embedded chat template, with thinking-content and tool-call parsing including streamed tool calls; Unsloth's Qwen3-Coder-30B-A3B GGUFs embed fixed templates ("already include our fixes"). Recommended: `llama-server -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL --jinja -ngl 99 --ctx-size 32768 --temp 0.7 --top-p 0.8 --top-k 20 --repeat-penalty 1.05`. Residual gotchas: occasional crashes with tools lacking a `properties` field (build 7120 report), past streaming+tools proxies needed (largely fixed by the autoparser work).

## 4. OpenVINO Model Server / GenAI — strongest 2026 story on this exact hardware
- Native Windows: bare-metal ovms.exe since v2025.0 (Windows 11/Server 2022, full generative endpoints, explicit Lunar Lake support); "Windows service deployment" since v2025.4 (Dec 1, 2025). No Docker needed.
- OpenAI-compatible API: /v3/chat/completions (+ completions, embeddings, rerank, /models endpoints; initial /responses endpoint in v2026.2). Continuous batching incl. Qwen3-MoE (v2026.1), prefix caching (v2025.4).
- Tool calling: dedicated `--tool_parser` values hermes3, phi4, qwen3, qwen3coder, gptoss, llama3; `--reasoning_parser qwen3|gptoss`; tool-guided generation via XGrammar (`--enable_tool_guided_generation`, v2025.3); `tool_choice=required`; streaming-with-tools for phi-4/mistral (v2025.4); `tool_calls` finish-reason aligned to OpenAI spec (v2026.1). Qwen3-Coder + Qwen3-30B-A3B parsers added v2025.4.
- 2026 cadence: v2026.0 (Feb 24) INT4 accuracy + agentic chat-template fixes; v2026.1 (Apr 7) Qwen3-MoE/gpt-oss-20b CB, Qwen3-VL function calling; v2026.2 (May 28) Qwen3-30B MoE perf gains, Xe GPU support for MoE models.
- GGUF: preview only, narrow arch list (Qwen2.5 1.5/3/7B, Llama-3.1/3.2, DeepSeek-R1-Distill-Qwen) — for Qwen3-Coder you use OpenVINO IR INT4 instead, pre-quantized on HF: OpenVINO/Qwen3-Coder-30B-A3B-Instruct-int4-ov (\~16.3GB) pulled automatically via `--source_model`. Example serve command (from the agentic demo): `ovms.exe --rest_port 8000 --source_model OpenVINO/Qwen3-Coder-30B-A3B-Instruct-int4-ov --tool_parser qwen3coder --target_device GPU --task text_generation`. NPU target also possible (`--target_device NPU --max_prompt_len 8000`, single-stream).
- Real-world validation: May 2026 write-up (S. Baker) running Qwen3-Coder-30B-A3B INT4 on OVMS + Intel iGPU with OpenCode: \~17GB resident, decode at "3B-class" speed, tool calling worked with a one-file opencode.json.

## 5. LM Studio — 0.4.x (2026)
- Vulkan llama.cpp engine works on Intel Arc (device-selection bugs with multi-GPU; vkconfig "force single device" workaround). 0.4.0 (Jan 2026) added `llmster` pure-headless mode + continuous batching; tool calling improvements ongoing (GLM 4.5, MiniMax M2). OpenAI-compat server with /v1/responses. Closed-source, GUI-oriented; same Intel Vulkan driver risks as llama.cpp since it embeds it.

## Realistic tokens/sec on Arc 140V / 258V (32GB, \~136.5 GB/s)
- 7B Q4 reference: Vulkan pp512 \~657 t/s (2026, coopmat on); tg128 \~10-15 t/s Vulkan/SYCL; CPU \~25 pp / \~11.6 tg.
- 14B dense Q4 (e.g. Qwen 14B): \~9GB weights → bandwidth ceiling \~15 t/s; realistic 7–10 t/s GPU decode, prefill few-hundred t/s (SYCL or coopmat-Vulkan); CPU fallback \~4–6 t/s. The existing qwen2.5-coder:14b q6_K blob (\~12.1GB) will be \~25% slower and is marginal in the \~16GB default shared-GPU window with KV cache.
- 30B-A3B MoE Q4/INT4 (\~3.3B active): llama.cpp Vulkan on 258V: 21–25 t/s decode (after OOM workarounds, #18946); OpenVINO INT4: 34 t/s on Core Ultra 9 285H Arc 140T (Intel-published; 140V expect \~25–30 t/s); \~16–18GB resident. MoE is clearly the right shape for this bandwidth-starved iGPU: \~2.5–3x faster decode than 14B dense at better coding quality.
- Memory overhead: llama-server ≈ model + KV + <0.5GB; ovms.exe ≈ model + \~0.5–1GB runtime; Ollama adds Go supervisor + runner (\~0.5GB); LM Studio GUI \~1–2GB (llmster less).

## RECOMMENDATION
PRIMARY: OpenVINO Model Server (ovms.exe, v2026.2) native on Windows, serving OpenVINO/Qwen3-Coder-30B-A3B-Instruct-int4-ov on GPU with `--tool_parser qwen3coder --reasoning_parser qwen3 --enable_tool_guided_generation --target_device GPU --task text_generation --rest_port 8000`, pointing agents at http://localhost:8000/v3 as an OpenAI base URL. Rationale for THIS machine: (a) you're an OpenVINO contributor and already run OpenVINO GenAI on the 140V — zero new runtime surface, fully offline-installable; (b) it's the only stack with purpose-built qwen3coder XML tool parsing + XGrammar tool-guided generation, exactly what agentic coding needs (Ollama's Qwen3-Coder pipeline is demonstrably miswired, llama.cpp's is good-but-generic); (c) OpenVINO's oneDNN/OpenCL path uses XMX without depending on the Intel Vulkan driver, which currently TDRs on 140V with coopmat (llama.cpp #20554); (d) best published decode for 30B-A3B on Intel iGPU (\~34 t/s on 140T, expect \~25–30 t/s on your 140V vs 21–25 t/s llama.cpp-Vulkan-with-workarounds); (e) Windows-service deployment, continuous batching, prefix caching. Use the 30B-A3B MoE, not 14B dense — at \~136 GB/s the MoE decodes 2.5–3x faster and benches better at coding.

FALLBACK: upstream llama.cpp llama-server, official win-vulkan-x64 prebuilt (SYCL zip as alternate), with unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL: `llama-server -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL --jinja -ngl 99 --ctx-size 32768 --temp 0.7 --top-p 0.8 --top-k 20 --repeat-penalty 1.05`; set GGML_VK_DISABLE_COOPMAT=1 if you hit driver TDRs and `-fa off` if you hit ErrorOutOfDeviceMemory; enable Windows Shared GPU Memory Override (\~24GB) for the 30B MoE. This also lets you reuse your existing 16.8GB of Ollama GGUF blobs directly (they're plain GGUF; pass the blob sha256 path to -m) for qwen2.5-coder 14b/7b and nomic-embed-text without redownloading.

SKIP: ipex-llm (archived Jan 2026 with known security issues — unacceptable for your air-gapped/security posture), Ollama as the serving layer (Vulkan-only on Intel + broken Qwen3-Coder tool templates; fine to keep the blob store), LM Studio (closed-source GUI runtime, same Vulkan driver exposure, no advantage over llama-server headless).

## CAVEATS
- Tokens/sec figures are triangulated, not measured on your unit: the 34 t/s OpenVINO figure is Intel's own number on a 285H/Arc 140T (Intel's article now 403s; figure surfaced via search snippets), and the 21–25 t/s llama.cpp figure comes from one GitHub issue on a 258V. Expect ±30%. The detailed backend table (IPEX 708/24.4 etc.) is from Dec 2024 llm-tracker — directionally useful, numerically stale (Vulkan has improved \~15x at prefill since).
- Capacity squeeze: Qwen3-Coder-30B-A3B INT4 is \~16.3GB vs your \~16GB default shared-GPU window; with KV cache you will likely need the Intel driver "Shared GPU Memory Override" (\~24GB) and should budget \~18GB resident — fine in 31.3GB RAM but cuts into BlarAI/Hyper-V headroom if co-resident. Verify the OVMS GPU plugin handles >16GB allocation on Lunar Lake before committing; otherwise drop to Qwen3-Coder INT4 with smaller group size, a sym-int4 variant, or Qwen3-14B-int4-ov (\~8GB, \~7-10 t/s).
- OVMS GGUF support remains preview and does NOT cover Qwen3-Coder — you must use the IR INT4 artifacts (one-time online pull from HF or transfer for air-gapped use).
- Intel Arc Windows driver regressions are live: coopmat TDR (101.8509/101.8531) affects any Vulkan-based fallback (llama.cpp, Ollama, LM Studio); pin/test driver versions before trusting long agent runs.
- Ollama versioning jumped (0.17.x issues vs 0.30.x releases in 2026); some cited bug statuses may have been fixed in point releases after my sources — recheck ollama/ollama issues #14493/#14570 if you revisit Ollama.
- Streaming + tool-calls in OVMS was listed per-model (phi-4/mistral in 2025.4); confirm streamed tool_calls work with the qwen3coder parser in 2026.2 for your agent client; non-streaming tool calls are solid.
- Could not retrieve OVMS docs pages directly (JS navigation shell); parser/flag details came from the GitHub README of the agentic demo on main branch — flags may differ slightly in the 2026.2 tagged release.

## SOURCES
https://github.com/intel/ipex-llm
https://www.phoronix.com/news/ollama-Experimental-Vulkan
https://docs.ollama.com/gpu
https://github.com/ollama/ollama/releases
https://github.com/ollama/ollama/issues/14493
https://github.com/ollama/ollama/issues/14570
https://github.com/block/goose/issues/6883
https://medium.com/@techhara/local-llm-benchmark-on-intel-lunar-lake-133c39f10455
https://llm-tracker.info/howto/Intel-GPUs
https://github.com/ggml-org/llama.cpp/issues/18946
https://github.com/ggml-org/llama.cpp/issues/20554
https://github.com/ggml-org/llama.cpp/issues/20776
https://github.com/ggml-org/llama.cpp/discussions/16801
https://knightli.com/en/2026/04/23/llama-cpp-gpu-benchmark-cuda-rocm-vulkan-scoreboard/
https://knightli.com/en/2026/05/18/llama-cpp-windows-cuda-vulkan-gguf/
https://github.com/ggml-org/llama.cpp/releases
https://unsloth.ai/docs/models/tutorials/qwen3-coder-how-to-run-locally
https://github.com/openvinotoolkit/model_server/releases
https://raw.githubusercontent.com/openvinotoolkit/model_server/main/demos/continuous_batching/agentic_ai/README.md
https://raw.githubusercontent.com/openvinotoolkit/model_server/main/demos/gguf/README.md
https://docs.openvino.ai/nightly/model-server/ovms_demos_gguf.html
https://www.intel.com/content/www/us/en/developer/articles/technical/accelerate-qwen3-large-language-models.html
https://huggingface.co/OpenVINO/Qwen3-30B-A3B-int4-ov
https://medium.com/@smbaker/agentic-coding-on-an-inexpensive-nuc-with-opencode-and-qwen3-coder-30b-6fd0dddc2ded
https://lmstudio.ai/blog
https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1393
https://webscraft.org/blog/ollama-030-scho-novogo-gguf-vulkan-llamacpp-i-tool-calling?lang=en
