"""The 14B invocation seam — grammar-constrained candidate proposal (plan §3.4 D-5).

The miner substrate is the LOCAL 14B from day one (LA ruling D-5(b): must be local).
This module is the ONE place the model is called, isolated behind a small protocol so
that:

* tests and offline replay drive a FAKE/recorded layer (:class:`RecordedModelClient`) —
  the golden set never touches the GPU; and
* the real pass (:class:`OvmsGrammarClient`) constrains the 14B with the #743
  grammar-first pattern — an OpenAI ``response_format`` ``json_schema`` that OVMS turns
  into an XGrammar constraint — so the model can only emit :data:`CANDIDATE_RESPONSE_SCHEMA`.

IMPORTANT: :class:`OvmsGrammarClient` is DORMANT by construction. It is never
instantiated by the miner unless ``--real`` is passed AND a model is loaded; the first
real mining pass is the coordinator's to run in a scheduled GPU window (post-swap, 14B
restored). Everything below uses only the Python standard library — the fleet box is
offline-first, so no ``requests``/``openai`` dependency is introduced.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Protocol

from lm_schema import CANDIDATE_RESPONSE_SCHEMA

# The system instruction that frames the mining task. It encodes P2-extended-to-Loop-2
# (select and count evidence, NEVER paraphrase it) and the removals-as-removals rule, so
# the constraint is stated to the model even though the deterministic ruler is what
# actually enforces both after the fact.
MINER_SYSTEM_PROMPT = (
    "You are a fleet build-quality analyst. You are given SCORECARDS from many "
    "independent coding-dispatch runs. Your job is to name RECURRING failure shapes "
    "and propose a small improvement to the coder's instruction file (AGENTS.md).\n"
    "\n"
    "Hard rules you must obey:\n"
    "1. Every evidence quote you cite MUST be copied VERBATIM (byte-for-byte) from the "
    "scorecard text you were given. Never paraphrase, summarise, or 'clean up' a quote. "
    "Cite each quote by its run_id and the artifact it came from.\n"
    "2. Only propose a failure shape that recurs across MULTIPLE independent runs. One "
    "bad run is not a lesson.\n"
    "3. Express your proposed AGENTS.md change as a diff. To REMOVE or relax an existing "
    "rule, DELETE the line (a '-' line). Never append a 'stop doing X' line on top of a "
    "rule that still says to do X.\n"
    "4. Do not propose anything that weakens the verify gate, the secret scan, or the "
    "FALSE-DONE cross-check.\n"
    "Return only JSON matching the required schema."
)


class ModelClient(Protocol):
    """The seam: turn an evidence bundle into raw candidate dicts (schema-shaped)."""

    def propose(self, evidence_bundle: str) -> list[dict[str, Any]]:
        """Return the model's ``candidates`` list (each a dict, pre-validation)."""
        ...


class RecordedModelClient:
    """A fake model layer: replays a recorded ``{"candidates": [...]}`` envelope.

    This is what the golden set and offline ``--replay`` drive. It performs NO
    network or GPU work — it simply returns the candidates it was constructed with,
    so the harness (schema + byte-match + ruler) is exercised end-to-end against a
    known-correct set of expected outcomes.
    """

    def __init__(self, candidates: list[dict[str, Any]]) -> None:
        self._candidates = candidates

    @classmethod
    def from_envelope(cls, envelope: dict[str, Any]) -> "RecordedModelClient":
        """Build from a full ``{"candidates": [...]}`` object (e.g. a replay file)."""
        cands = envelope.get("candidates", []) if isinstance(envelope, dict) else []
        return cls(list(cands))

    def propose(self, evidence_bundle: str) -> list[dict[str, Any]]:  # noqa: D401 - protocol impl
        return list(self._candidates)


class QueuedModelClient:
    """A fake that returns a DIFFERENT recorded response on each successive call.

    Chunked mining calls ``propose`` once per batch, in order — this returns the next
    queued list each time (the last is reused if the queue runs dry). It lets a test
    drive the multi-batch corridor deterministically: batch 1 proposes a shape citing
    its runs, batch 3 proposes the SAME shape citing its runs, and the merge must count
    recurrence across both. Also the shape an offline multi-batch replay would take.
    """

    def __init__(self, per_batch: list[list[dict[str, Any]]]) -> None:
        self._per_batch = [list(b) for b in per_batch]
        self._i = 0
        self.calls = 0

    def propose(self, evidence_bundle: str) -> list[dict[str, Any]]:  # noqa: D401 - protocol impl
        self.calls += 1
        if not self._per_batch:
            return []
        idx = min(self._i, len(self._per_batch) - 1)
        self._i += 1
        return list(self._per_batch[idx])


class OvmsGrammarClient:
    """The REAL, DORMANT 14B client: grammar-constrained candidate proposal via OVMS.

    Posts to the OpenAI-compatible ``/v3/chat/completions`` endpoint with a
    ``response_format`` of ``json_schema`` (strict) so generation is XGrammar-constrained
    to :data:`CANDIDATE_RESPONSE_SCHEMA`. The model id is discovered from ``/v3/models``.
    Deterministic by default (temperature 0). Only reached on an explicit ``--real`` pass
    with a model already loaded — never in tests.
    """

    def __init__(
        self,
        endpoint: str,
        *,
        temperature: float = 0.0,
        top_p: float = 1.0,
        max_tokens: int = 4096,
        timeout_s: int = 300,
    ) -> None:
        self._endpoint = endpoint.rstrip("/")
        self._temperature = temperature
        self._top_p = top_p
        self._max_tokens = max_tokens
        self._timeout_s = timeout_s

    def _models(self) -> list[dict[str, Any]]:
        with urllib.request.urlopen(self._endpoint + "/models", timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return list(data.get("data") or [])

    def _model_id(self) -> str:
        models = self._models()
        if not models:
            raise RuntimeError(f"no model loaded at {self._endpoint} — start the 14B first")
        return str(models[0]["id"])

    def context_length(self) -> int | None:
        """Best-effort probe of the served model's context length (tokens), or None.

        Different OVMS builds surface it under different keys (or not at all). We read
        whatever is present so the batcher can size batches to the REAL ceiling; None
        falls the caller back to the conservative configured default (the 400 came from
        guessing the ceiling too HIGH, so the fallback guesses low).
        """
        try:
            models = self._models()
        except Exception:  # noqa: BLE001 — a failed probe is not fatal; the default covers it
            return None
        if not models:
            return None
        m = models[0]
        for key in ("max_model_len", "max_context_length", "context_length",
                    "max_position_embeddings", "max_input_tokens"):
            val = m.get(key)
            if isinstance(val, int) and val > 0:
                return val
        return None

    def propose(self, evidence_bundle: str) -> list[dict[str, Any]]:
        model = self._model_id()
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": MINER_SYSTEM_PROMPT},
                {"role": "user", "content": evidence_bundle},
            ],
            "temperature": self._temperature,
            "top_p": self._top_p,
            "max_tokens": self._max_tokens,
            # The #743 grammar-first constraint: OVMS applies XGrammar so the model can
            # only produce the schema. A malformed body still cannot pass the harness'
            # own validator downstream — grammar is the belt, the validator is the braces.
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "lesson_candidates",
                    "strict": True,
                    "schema": CANDIDATE_RESPONSE_SCHEMA,
                },
            },
        }
        req = urllib.request.Request(
            self._endpoint + "/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=self._timeout_s) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            # Surface the RESPONSE BODY — OVMS puts the real cause there (e.g. a context
            # overflow on an oversized bundle). urllib swallows it in str(exc), so read it.
            try:
                detail = exc.read().decode("utf-8", errors="replace")[:1000]
            except Exception:  # noqa: BLE001
                detail = "(response body unavailable)"
            raise RuntimeError(f"14B request failed: HTTP {exc.code} {exc.reason}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"14B request failed: {exc}") from exc

        content = body["choices"][0]["message"].get("content") or ""
        try:
            envelope = json.loads(content)
        except (ValueError, TypeError) as exc:
            # Grammar-constrained output should always parse; if a substrate quirk yields
            # non-JSON, the whole pass proposes nothing rather than guess (fail-closed).
            raise RuntimeError(f"14B returned non-JSON content: {content[:200]!r}") from exc
        cands = envelope.get("candidates", []) if isinstance(envelope, dict) else []
        return list(cands)
