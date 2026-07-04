# models

## FINDINGS
LANDSCAPE SHIFT SINCE THE USER'S OLLAMA BLOBS (mid-2026): Qwen3.5 series shipped Feb 16-Mar 2 2026 (397B-A17B, 122B-A10B, 35B-A3B, 27B dense, then 9B/4B/2B/0.8B). Qwen3.6 shipped April 2026 (35B-A3B on Apr 16, 27B dense on Apr 22), all Apache 2.0, natively multimodal (text+image), 262,144-token native context (YaRN to 1M). Qwen3-Coder-Next (80B-A3B, Feb 2026) and Devstral 2 / Devstral Small 2 (Dec 9 2025) are the other big agentic-coding releases. The user's qwen2.5-coder 14b/7b/1.5b blobs are now 2 generations behind.

=== 1. AGENTIC CODING (ranked for a 31.3GB shared-RAM Lunar Lake machine) ===

TOP PICK — Qwen3.6-35B-A3B (Apr 16 2026, Apache 2.0):
- 35B total / 3B active MoE; 40 layers; hybrid Gated DeltaNet + Gated Attention (256 experts, 8 routed + 1 shared); 262K native context. The hybrid linear-attention design makes KV cache almost free: a 24GB RTX 3090 ran the UD-Q4_K_XL (\~22GB) at 65K context in 21.7GB TOTAL with q8_0 KV cache (aminrj.com benchmark; 80-101 tok/s on 3090).
- Benchmarks (official HF card): SWE-bench Verified 73.4%, SWE-bench Pro 49.5%, Terminal-Bench 2.0 51.5%, MMLU-Pro 85.2. Also scores vision benchmarks (MMBench 92.8, OmniDocBench 89.9, RealWorldQA 85.3) because it is natively multimodal.
- GGUF sizes (bartowski): Q4_K_M 22.29GB, Q4_K_S 21.49GB, IQ4_XS 19.70GB, Q3_K_XL 18.22GB, IQ3_M 17.79GB, Q2_K 13.51GB. For this machine: IQ4_XS (19.7GB) is the quality/fit sweet spot; Q3_K_XL (18.2GB) if VS Code+browser are heavy.
- Tool calling: works well in OpenCode/Cline AFTER two known fixes — enable preserve_thinking ("thinking preservation" is a 3.6 feature) and raise OpenCode's output-token limit (default chopped tool-call arguments mid-stream). Documented in HF discussion "Tool use failure [Fix Found]" and opencode issue #24316. Recommended sampling for coding: temp 0.6, top_p 0.95, presence_penalty 0.
- OpenVINO: OpenVINO 2026.0/2026.1 officially supports Qwen3.6, Qwen3.5, and Qwen3-Coder-Next on CPU and GPU; Intel's day-0 blog states the Gated DeltaNet ops run natively on Xe GPUs and the NPU. Qwen3.6/3.5 (0.8B-35B) are listed in the OpenVINO GenAI supported-models table (as VLMs). Export: optimum-cli export openvino -m Qwen/Qwen3.6-35B-A3B --weight-format int4 (INT4 \~18-19GB).
- Speed expectation: Intel measured 34 tok/s on Qwen3-30B-A3B INT4 via OpenVINO on a Core Ultra 9 285H iGPU; the 258V (Arc 140V, 136.5GB/s LPDDR5X) should land \~15-30 tok/s for A3B-class MoE — only \~1.7GB of active weights are read per token at INT4, so it is genuinely usable, unlike dense 24-27B.

RUNNER-UP — GLM-4.7-Flash (Z.ai, Jan 2026): 30B MoE / \~3.6B active, 202,752-token context, SWE-bench Verified 59.2, GPQA 75.2. \~18GB at 4-bit (UD-Q4_K_XL), 24GB min RAM per Unsloth. Tool-calling settings: temp 0.7, top_p 1.0. GGUFs had inference bugs fixed Jan 21-22 2026 — re-download. Good alternative MoE if Qwen3.6 misbehaves.

PROVEN FALLBACK — Qwen3-Coder-30B-A3B-Instruct (Jul 2025): 30B/3.3B active, 48 layers, 256K native ctx, SWE-bench Verified \~50.3%, purpose-built function-call format with first-class Cline/Qwen Code support, retains FIM. UD-Q4_K_XL \~17.7GB / IQ4_XS \~16.4GB. KV cache \~96KB/token f16 (48L x 4KV x 128d) → 32K ctx = 3GB f16 / 1.5GB q8_0, so 32-48K is the practical ceiling here (vs 64-128K on Qwen3.6's hybrid attention). Still a top-5 community pick but clearly superseded by Qwen3.6-35B-A3B (73.4 vs 50.3 SWE-V).

Devstral Small 2 (24B dense, Dec 2025, Apache 2.0): SWE-bench Verified 68.0%, 256K ctx, image input support, excellent in Cline/OpenHands (Cline did a launch blog). GGUF Q4_K_M 14.33GB / IQ4_XS 12.76GB. BUT it is DENSE: on 136.5GB/s shared LPDDR5X the theoretical ceiling is \~9 tok/s at Q4 (realistic 5-7) — too slow for agentic loops on this iGPU. Great model, wrong hardware.

Qwen3.6-27B dense (Apr 22 2026): secondary sources (openclawdc, codersera) claim 77.2% SWE-bench Verified — the highest of anything that fits 32GB — but same dense-speed problem (\~8 tok/s ceiling at Q4_K_M 16.5GB on this bandwidth). Use only if quality matters more than speed; could not verify 77.2 on qwen.ai directly (blog fetch failed).

gpt-oss-20b: 21B/3.6B active MoE, MXFP4 \~12-13GB, runs in 16GB. Strong on paper (Tau-bench), but a 2026 arXiv eval (ReCUBE, 2603.25770) found it is locked to OpenAI's Harmony format: 25.6 format errors per instance and ZERO successful scaffold tool calls under standard chat-template agents (mini-SWE-agent). Fine in Codex-CLI-style harnesses; unreliable in Cline/OpenCode. Not recommended as the primary agent.

RULED OUT: Qwen3-Coder-Next 80B-A3B — best-in-class agentic (SWE-bench Verified >70% w/ SWE-Agent, 44.3% SWE-bench Pro) but Q4_K_M is \~45GB and Unsloth's "sensible minimum" 3-bit is still \~35GB; does not fit 31.3GB. GLM-4.5-Air/GLM-4.6 (106B): 2-bit still \~40GB+. Qwen3-32B dense, DeepSeek-Coder-V2-Lite, Seed-Coder: superseded and/or dense-slow; no longer competitive per mid-2026 community consensus.

PRACTICAL CONTEXT on this machine: budget \~21-23GB for model+KV (Windows 6-8GB + dev tools). Qwen3.6-35B-A3B IQ4_XS: 64K ctx with q8_0 KV ≈ \~21GB total — fits; community guidance for 32GB boxes is "cap at 64K, raise only if needed". Qwen3-Coder-30B: cap at 32-48K. llama.cpp flags that matter: --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on --jinja --ctx-size 49152.

RUNTIME WARNING: llama.cpp Vulkan on Xe2/Lunar Lake iGPUs has crash reports with k-quants and MoE models (ggml-org issue #19327 and Arc 140V reports); SYCL or OpenVINO GenAI are the stable paths on this hardware. Speculative decoding gives no net speedup on A3B MoE (RTX 3090 benchmark repo, 19 configs tested post llama.cpp PR #19493) — skip the draft model for the MoE; spec-decode only helps dense models here.

=== 2. VISION ===
- KEEP Qwen3-VL-8B (user's existing OpenVINO INT4): still the best \~8B open-weight for UI work as of mid-2026 — ScreenSpot 94.4% (GUI grounding), DocVQA 96.1%, OCRBench 89.6%; the Thinking variant still leads OCRBench in the open-weight category. Nothing in the 8B class has displaced it for UI screenshots.
- Qwen3.6-35B-A3B doubles as a VLM (OmniDocBench 89.9, MMBench 92.8) — one resident model can do agentic coding AND screenshot debugging; in llama.cpp it needs the mmproj file (not in Ollama blobs; use Unsloth/official GGUF), in OpenVINO GenAI it is listed as a supported VLM.
- MiniCPM-V-4.5 (8B, Qwen3-8B + SigLIP2-400M, Aug 2025): best dense-document/PDF parsing among general MLLMs (SOTA OmniDocBench claim, beats GPT-4o-latest on OCRBench), handles 1.8M-pixel images — the better choice than Qwen3-VL-8B for dense OCR pages, slightly worse for GUI grounding. MiniCPM-V-4.6 (1.3B, May 11 2026) is a new ultra-light option for cheap always-on vision; MiniCPM-o-4.5 (9B, Feb 2026) adds audio/duplex.
- InternVL3.5 (Aug 2025): GUI-strong but its sweet spot is 14B-38B — no advantage at 8B on this RAM. No InternVL4 found. Gemma-3-12B-it vision: outdated; Gemma 4 12B exists (2026) but no evidence it beats Qwen3-VL-8B on OCR/GUI.
VERDICT: UI screenshots → Qwen3-VL-8B (already installed). Dense OCR pages → MiniCPM-V-4.5 INT4 (\~5-6GB) or the dedicated OCR pipelines below.

=== 3. OCR PIPELINES (product labels, offline Windows) ===
- BEST FIT: RapidOCR v3.x with PP-OCRv5 models on the OpenVINO backend — pip install rapidocr / rapidocr-openvino; runs PP-OCRv5 in paddle/ONNX/OpenVINO formats; \~50-80MB total footprint, 0.2-1s/page CPU, no PaddlePaddle dependency, fully offline, and via ONNX Runtime's OpenVINO EP can target CPU/iGPU/NPU (the 47-TOPS NPU is ideal for this, freeing GPU RAM). PP-OCRv5 is a 0.07B model with +13% accuracy over v4 and handles scene text/photographed labels, 5 script types.
- PaddleOCR-VL-1.5 (0.9B NaViT+ERNIE, Jan 2026): 94.5% OmniDocBench, \~2.5GB VRAM, 253% faster than dots.ocr — top accuracy-per-GB for full document parsing, BUT no native Windows support (needs WSL2/Docker; user has Hyper-V so WSL is possible).
- dots.ocr (1.7B VLM, rednote): SOTA-ish multilingual layout+text (100+ languages), runs via transformers on Windows (\~4-8GB), but not throughput-optimized, wants 200 DPI, struggles with complex tables/special chars.
- olmOCR-2 (7B, Qwen2.5-VL-based): needs \~20GB GPU as designed (FP8); GGUF exists but it is a PDF-linearization tool, wrong shape for label scanning. Skip.
- Tesseract 5.5.x: tiny, CPU, fine for clean flat scans; weak on photographed/curved/low-contrast labels — exactly the product-label case. Keep only as a fallback.

=== 4. SMALL UTILITY MODELS ===
- Tab autocomplete/FIM: keep Qwen2.5-Coder-1.5B (already in Ollama blobs — blobs are plain GGUF files reusable by llama.cpp directly) or step up to Qwen2.5-Coder-3B. Qwen3-Coder retains FIM but its smallest size is 30B, so the 2.5-Coder small models remain the de-facto FIM standard in Continue.dev-style setups as of 2026. Codestral 22B is the FIM quality leader but dense/22B = too slow here.
- General drafting/utility: Qwen3.5-4B or Qwen3.5-2B (Mar 2026, Apache 2.0) — current best small generalists; 0.8B variant is the vocab-matched draft for Qwen3.5/3.6 (but spec-decode does not pay off on the A3B MoE, see above). These run INT4 on the NPU via OpenVINO, keeping the iGPU free for the big model.
- Embeddings for code+docs RAG: jina-code-embeddings-0.5b (494M, Qwen2.5-Coder backbone, Apache-friendly weights on HF) — 78.41% avg over 25 code-retrieval benchmarks, beating Qwen3-Embedding-0.6B by \~5pts while 20% smaller; 1.5b version is 79.04%. For mixed natural-language docs + multilingual, Qwen3-Embedding-0.6B (32K ctx, MRL dims, instruction-aware) is the safer single choice and is explicitly in OpenVINO GenAI's supported text-embedding list (bge also listed; nomic is NOT listed). nomic-embed-text v1.5 (user's blob) and bge-small are now clearly mid-tier; BGE-M3 and Qwen3-Embedding lead the 2026 open rankings.

## RECOMMENDATION
For THIS machine (31.3GB shared LPDDR5X, Arc 140V, OpenVINO-first workflow):

1. AGENTIC CODING: Qwen3.6-35B-A3B at IQ4_XS (19.7GB GGUF) or OpenVINO INT4 (\~18-19GB via optimum-cli export openvino --weight-format int4). It is the best agentic coder that fits: 73.4% SWE-bench Verified, 3B active params (15-30 tok/s expected on 258V vs \~5-8 for any dense 24-27B), near-free KV cache (hybrid DeltaNet) so 48-64K context fits in \~21GB total with q8_0 KV. Run via OpenVINO GenAI 2026.1 (officially supported, day-0 Xe2/NPU kernels) or llama.cpp SYCL — avoid the Vulkan backend on this iGPU. In OpenCode set preserve_thinking=true and raise the output-token limit, sampling temp 0.6 / top_p 0.95. Keep GLM-4.7-Flash UD-Q4_K_XL (\~18GB) as the alternate MoE, and Qwen3-Coder-30B-A3B UD-Q4_K_XL (17.7GB) as the conservative known-good with native Cline function-call format. Skip Qwen3-Coder-Next (35GB+ at 3-bit), GLM-4.x-Air (106B), gpt-oss-20b (Harmony-format tool-call failures in standard scaffolds), and all dense 22-27B models (bandwidth-starved on this iGPU).

2. VISION: keep your Qwen3-VL-8B OpenVINO INT4 for UI-screenshot debugging (ScreenSpot 94.4 — still class-leading at 8B). Note Qwen3.6-35B-A3B itself accepts images, so for agentic screenshot-in-the-loop debugging you may not need to load a second model at all. Add MiniCPM-V-4.5 INT4 (\~5-6GB) only if dense full-page document OCR via VLM becomes a real workload.

3. LABEL OCR: RapidOCR (PP-OCRv5 models) with the OpenVINO backend / ONNX Runtime OpenVINO EP targeting the NPU — \~80MB, sub-second, fully offline on Windows, leaves GPU RAM untouched. Escalate hard cases (curved/stylized labels) to Qwen3-VL-8B. Treat PaddleOCR-VL-1.5 as the accuracy upgrade only if you accept a WSL2 layer; skip olmOCR (20GB GPU) and keep Tesseract only for clean flat scans.

4. UTILITY: keep qwen2.5-coder:1.5b for FIM tab-complete (the Ollama blob is a reusable GGUF); add Qwen3.5-4B INT4 on the NPU for drafts/summaries. Replace nomic-embed-text with jina-code-embeddings-0.5b for code RAG (+5pts over Qwen3-Embedding-0.6B on code retrieval) or Qwen3-Embedding-0.6B if you want one OpenVINO-supported embedder for code+docs.

Suggested resident-memory layout while coding: Qwen3.6-35B-A3B INT4 (\~19GB) + embedder on NPU (\~0.6GB) + OS/tools (\~9GB) ≈ full; load vision/OCR models on demand or pin the 1.3B MiniCPM-V-4.6 if you need always-on vision.

## CAVEATS
1) iGPU-visible memory: Windows typically exposes only \~16GB "shared GPU memory" to the Arc 140V on a 32GB machine — a 19-22GB model cannot sit fully GPU-side. OpenVINO GenAI/llama.cpp will run it hybrid CPU+GPU (same physical RAM, same 136.5GB/s bus, so the A3B MoE stays fast either way), but this exact configuration (35B-A3B INT4 on a 258V) has no published benchmark I could find — the closest datapoint is 34 tok/s for Qwen3-30B-A3B INT4 on a Core Ultra 9 285H iGPU via OpenVINO. Test before committing; fallback is Q3_K_XL (18.2GB) or Qwen3-Coder-30B (17.7GB). 2) The 73.4% SWE-bench Verified figure is Qwen's own card number with their scaffold; community results in Cline/OpenCode are good but require the preserve_thinking + output-token-limit fixes, and one OpenCode issue (#24316) about naked tool calls was still open recently. 3) Qwen3.6-27B's 77.2% SWE-V score comes from secondary blogs (openclawdc/codersera) — I could not load the official qwen.ai blog to confirm; treat as plausible but unverified. 4) llama.cpp Vulkan crashes on Xe2 iGPUs with k-quants/MoE were reported through early 2026 and may since be fixed — re-check current llama.cpp releases if you prefer Vulkan; SYCL/OpenVINO are safe. 5) OpenVINO GenAI lists Qwen3.6 as supported, but VLM (image) pipelines for the hybrid-DeltaNet models on iGPU are new — the text pipeline is the proven path; vision via mmproj GGUF may lag. 6) PaddleOCR-VL Windows-native support may have changed since Jan 2026 (it required WSL/Docker then). 7) Speed estimates for dense models (\~5-9 tok/s) are bandwidth-ceiling arithmetic, not measurements. 8) Several aggregator sources (openclawdc, benchlm, codersera) look partly AI-generated; I cross-checked headline claims against official HF cards/GitHub where possible, but exact numbers like "Nemotron Cascade 2" rankings were not independently verified. 9) Everything recommended is downloadable as plain files (GGUF/safetensors/ONNX) and runs fully offline once fetched — but do the one-time downloads (19-22GB for the main model) while online.

## SOURCES
https://huggingface.co/Qwen/Qwen3.6-35B-A3B
https://github.com/QwenLM/Qwen3.6
https://huggingface.co/bartowski/Qwen_Qwen3.6-35B-A3B-GGUF
https://aminrj.com/posts/llamacpp-qwen36-35b/
https://unsloth.ai/docs/models/qwen3-coder-next
https://www.hardware-corner.net/qwen3-coder-next-hardware-requirements/
https://mistral.ai/news/devstral-2-vibe-cli/
https://huggingface.co/bartowski/mistralai_Devstral-Small-2-24B-Instruct-2512-GGUF
https://unsloth.ai/docs/models/tutorials/glm-4.7-flash.md
https://openai.com/index/introducing-gpt-oss/
https://arxiv.org/pdf/2603.25770
https://github.com/anomalyco/opencode/issues/24316
https://api-inference.huggingface.co/Qwen/Qwen3.6-35B-A3B/discussions/51
https://medium.com/openvino-toolkit/openvino-2026-0-new-models-enhanced-genai-and-smarter-compression-bf846a59cda8
https://medium.com/openvino-toolkit/early-look-exploring-qwen3-vl-and-qwen3-next-day0-model-integration-for-enhanced-ai-pc-experiences-134498f6b290
https://openvinotoolkit.github.io/openvino.genai/docs/supported-models/
https://github.com/openvinotoolkit/openvino/releases/tag/2026.1.0
https://www.intel.com/content/www/us/en/developer/articles/technical/accelerate-qwen3-large-language-models.html
https://github.com/ggml-org/llama.cpp/issues/19327
https://github.com/thc1006/qwen3.6-speculative-decoding-rtx3090
https://llm-stats.com/models/compare/qwen3-vl-8b-instruct-vs-qwen3.5-9b
https://huggingface.co/openbmb/MiniCPM-V-4_5
https://huggingface.co/openbmb/MiniCPM-V-4.6
https://internvl.github.io/blog/2025-08-26-InternVL-3.5/
https://github.com/RapidAI/RapidOCR
https://pypi.org/project/rapidocr-openvino/
https://paddlepaddle.github.io/PaddleOCR/main/en/version3.x/algorithm/PP-OCRv5/PP-OCRv5.html
https://sonusahani.com/blogs/paddleocr-vl
https://github.com/rednote-hilab/dots.ocr
https://github.com/allenai/olmocr
https://jina.ai/news/jina-code-embeddings-sota-code-retrieval-at-0-5b-and-1-5b/
https://milvus.io/blog/choose-embedding-model-rag-2026.md
https://openclawdc.com/blog/best-local-llms-32gb-ram/
https://qwen.ai/blog?id=qwen3.6-35b-a3b
https://cline.bot/blog/devstral-2-release
