# Fleet lesson-candidate miner (#793 — Learning Loop 2, Stage C1)

**Report-only. Post-pass. Nothing self-modifies.**

The coding fleet already records what happens on every dispatch — scorecards
(verdict + attribution vocabulary, per-task/per-wave results, the job-acceptance
oracle result), guest certificates, and campaign history. This miner reads those
outputs and *proposes* small improvements to the coder's instruction file
(`configs/AGENTS.md`) as **machine-proposed, UNTRUSTED** candidates. It writes exactly
one file per pass — `state/lesson-candidates/<date>.md` — and nothing else. It does not
edit `AGENTS.md`, `LESSONS-LEARNED.md`, or anything else; landing a candidate is M4's
gated job (deterministic verify → A/B golden-dispatch → operator card), never this
tool's.

This is Stage C1 of the program's `propose → verify → land` loop: **the local 14B
proposes, a deterministic ruler disposes.** The drift literature (SSGM; Memory
Contagion) is explicit that a small-model consolidator is the exposed case, so the
model's output is never trusted — it is run through a fixed verification harness and
anything that fails is dropped and *reported as dropped* (no silent caps).

## The pipeline, in order

1. **Post-pass guard** (`lm_guard.py`) — refuses to run while a dispatch is live.
   Reads the swap driver's `state/fleet-swap/current.json`; an active phase or a live
   driver process ⇒ refuse. Miner-safe polarity: *unsure ⇒ assume live ⇒ refuse.*
2. **Ingest** (`lm_ingest.py`) — read-only over `state/fleet-runs/<run_id>/`, retaining
   the raw bytes of each artifact so a cited quote can be byte-matched to its source.
3. **The 14B seam** (`lm_model.py`) — grammar-constrained candidate proposal (the #743
   grammar-first pattern: an OpenAI `response_format` `json_schema` OVMS turns into an
   XGrammar constraint). A **recorded/fake** layer drives tests and offline replay; the
   **real** OVMS client is the coordinator's to run in a GPU window.
   - **Chunked + resumable mining** (`lm_batch.py`) — the whole ~113-run corpus (~220k
     tokens) overflows the 14B context and 400s in one message. The corpus is packed into
     batches that provably fit (budget = probed-or-default context − headroom; a
     tokenizer-free, pessimistic estimate), one model call per batch. A single run whose
     evidence exceeds the whole budget is **truncated-with-log**, never dropped silently
     (the kept prefix still byte-matches). Candidates from all batches are then **merged
     by failure shape (evidence unioned) BEFORE the ruler** — so recurrence and diversity
     count across the whole corpus, not per batch. That cross-batch merge is the
     correctness heart (`Harness.merge_verified`).
     - **Resume:** each completed batch's raw output is persisted to
       `state/lesson-candidates/.work/<date>/batch-NN.json` as it finishes; a rerun skips
       cached batches (a 26-batch pass never restarts from zero because one batch timed
       out). Caches carry a bundle hash, so a changed corpus/budget invalidates them.
     - **Per-batch isolation:** a batch that times out or errors is logged as a note and
       skipped (not cached — it retries next run); the merge runs over what completed.
     - **Progress + timeout:** a stdout line per batch (liveness); the per-request timeout
       defaults to 1200 s because a ~10k-token prefill + grammar-constrained generation on
       a thermally-throttled 14B legitimately takes many minutes. The HTTP error body is
       surfaced on failure (the real cause, e.g. a context overflow, not just the code).
4. **Verification harness** (`lm_harness.py`), each stage a drop-and-report:
   - **schema** — matches the required candidate shape;
   - **byte-match** — every cited evidence quote is *verbatim* in its source scorecard
     (the deterministic kill for paraphrase drift; P2 extended to Loop 2);
   - **recurrence** — ≥ N distinct runs (default 3);
   - **diversity** — ≥ 2 distinct jobs or eras (one pathological run cannot mint a lesson);
   - **novelty** — not already in `LESSONS-LEARNED.md` or a prior candidate (keyword match);
   - **forbidden-class lint** — never proposes weakening the verify gate / secret scan /
     FALSE-DONE cross-check;
   - **removals-as-removals lint** — a proposed delta must DELETE lines, never append a
     "stop doing X" negation of a still-present rule (the LA-approved D-4 extension).
   Recurrence, diversity, and the era annotation are **computed here** from the verified
   evidence — never read from the model.
5. **Emit** (`lm_emit.py`) — writes the candidates file (provenance-tagged UNTRUSTED),
   listing survivors *and* every drop with its stage and reason.

## Surfacing is DORMANT (decision D-5/D-6)

The candidates file is always written, but the one-line Vikunja pointer that would
*surface* a pass to the operator is withheld behind `MinerConfig.surfacing_dormant`
(default `True`) until the golden-set quality gate is proven. Flipping it to `False`
(and setting a `campaign_ticket_id`) is the single, auditable go-live — the coordinator/
LA's call after the gate passes.

## Usage

```bash
python lesson_miner.py --check                 # the golden-set quality gate (no GPU/network)
python lesson_miner.py                          # DRY pass: guard + ingest + emit, model NOT invoked
python lesson_miner.py --replay <envelope.json> # mine a RECORDED proposal (offline; full harness)
python lesson_miner.py --real                   # REAL pass — invoke the 14B (coordinator, GPU window)
```

Optional flags: `--repo-root DIR`, `--recurrence N`, `--out-date YYYY-MM-DD`,
`--allow-live` (override the guard — deliberate use only).

## Verify

```powershell
.\scripts\verify-lesson-miner.ps1     # runs --check + the unit tests; exit 0/1
```

The golden mining test set (`lm_golden.py`) is the D-5 quality-gate substrate: seeded
scorecard fixtures with known-correct outcomes, exercising each harness stage — a
non-recurrent kill, a forbidden-class kill, a paraphrase-drift kill, a negate-by-append
kill, plus a non-novel and a malformed kill, against one candidate that must survive.

## The first REAL mining pass (the coordinator's step)

The first real pass needs the GPU. In a **post-swap window (14B restored, no dispatch
in flight)**:

1. Ensure the Everyday 14B is loaded: `scripts/start-llm.ps1 -Model qwen3-14b`
   (confirm `GET http://127.0.0.1:8000/v3/models` returns it).
2. `python tools/lesson_miner/lesson_miner.py --real`
   - It probes the context, sizes the batches, prints the batch count, and then prints a
     progress line as **each batch completes** (liveness for a pass that can run an hour+).
   - Each completed batch is cached under `state/lesson-candidates/.work/<date>/`. **If it
     dies partway (timeout, reboot), just run the same command again — it resumes from the
     last completed batch**, not from zero.
   - Knobs if needed: `--request-timeout S` (default 1200 s; raise if a throttled batch is
     killed mid-generation), `--batch-tokens N` (lower if a batch still 400s — the error
     now carries the OVMS body), `--max-tokens N` (raise if a batch's JSON is truncated).
3. Read `state/lesson-candidates/<date>.md`. Surfacing stays dormant — the pointer is
   built but not posted — until the quality gate is judged acceptable and the flag is
   flipped.

Expected duration is one 14B completion **per batch** (~26 batches at the conservative
no-probe default, fewer if the probe returns a larger context, and each can take several
minutes on a throttled GPU); the harness + emit are sub-second. Candidates are merged
across batches before the ruler, so recurrence/diversity count across the whole corpus.
To force a fully fresh pass, delete `state/lesson-candidates/.work/<date>/` first.
