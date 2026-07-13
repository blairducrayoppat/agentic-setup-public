"""The candidate output schema + a dependency-free validator (harness step 1).

The 14B emits candidates into THIS fixed structure — the #743 grammar-first
pattern: the schema below is handed to the model as an OpenAI ``response_format``
``json_schema`` (OVMS constrains generation with XGrammar), and it is ALSO the
mechanical gate the harness applies to whatever comes back. Grammar-constrained
generation makes malformed output rare; the validator makes it *impossible* to
pass — a candidate that does not match is dropped and reported (never repaired,
never paraphrased into shape).

No ``jsonschema`` dependency: the fleet box is offline-first, so the check is a
small hand-rolled walk over the shape the model must produce. What the model may
assert is deliberately thin — ``failure_shape``, ``evidence`` quotes, and a
``proposed_delta``. Everything a candidate is JUDGED on (recurrence count,
evidence diversity, era, novelty) is COMPUTED by the deterministic ruler from the
verified evidence, never trusted from the model (D-5: the model proposes, the
ruler disposes).
"""

from __future__ import annotations

from typing import Any

# The response-format schema (also the model-facing grammar). ``strict`` +
# ``additionalProperties: false`` keep the model on the rails; the validator below
# enforces the same shape after the fact.
CANDIDATE_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "candidates": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "failure_shape": {"type": "string"},
                    "evidence": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "properties": {
                                "run_id": {"type": "string"},
                                "artifact": {"type": "string"},
                                "quote": {"type": "string"},
                            },
                            "required": ["run_id", "artifact", "quote"],
                        },
                    },
                    "proposed_delta": {"type": "string"},
                    "rationale": {"type": "string"},
                },
                "required": ["failure_shape", "evidence", "proposed_delta"],
            },
        }
    },
    "required": ["candidates"],
}


class SchemaError(ValueError):
    """A candidate (or the envelope) did not match :data:`CANDIDATE_RESPONSE_SCHEMA`."""


def validate_envelope(obj: Any) -> list[dict[str, Any]]:
    """Validate the top-level ``{"candidates": [...]}`` object; return the list.

    Raises :class:`SchemaError` on any structural violation of the envelope. Does
    NOT validate the individual candidates — that is :func:`validate_candidate`,
    applied per-item so ONE malformed candidate is dropped without killing the
    whole pass.
    """
    if not isinstance(obj, dict):
        raise SchemaError(f"top-level must be an object, got {type(obj).__name__}")
    if "candidates" not in obj:
        raise SchemaError("missing required key 'candidates'")
    cands = obj["candidates"]
    if not isinstance(cands, list):
        raise SchemaError("'candidates' must be an array")
    return cands


def validate_candidate(cand: Any) -> None:
    """Raise :class:`SchemaError` unless *cand* matches the per-candidate shape.

    Enforces required keys, string types, a non-empty ``evidence`` array of
    ``{run_id, artifact, quote}`` string triples, and no stray keys. Emptiness of
    the human-meaningful fields (blank ``failure_shape`` / ``proposed_delta`` / a
    blank quote) is a violation too — an empty candidate is malformed, not merely
    weak.
    """
    if not isinstance(cand, dict):
        raise SchemaError(f"candidate must be an object, got {type(cand).__name__}")

    allowed = {"failure_shape", "evidence", "proposed_delta", "rationale"}
    stray = set(cand) - allowed
    if stray:
        raise SchemaError(f"candidate has unexpected keys: {sorted(stray)}")

    for key in ("failure_shape", "proposed_delta"):
        val = cand.get(key)
        if not isinstance(val, str) or not val.strip():
            raise SchemaError(f"candidate '{key}' must be a non-empty string")

    if "rationale" in cand and not isinstance(cand["rationale"], str):
        raise SchemaError("candidate 'rationale' must be a string when present")

    evidence = cand.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        raise SchemaError("candidate 'evidence' must be a non-empty array")

    for i, ev in enumerate(evidence):
        if not isinstance(ev, dict):
            raise SchemaError(f"evidence[{i}] must be an object")
        ev_stray = set(ev) - {"run_id", "artifact", "quote"}
        if ev_stray:
            raise SchemaError(f"evidence[{i}] has unexpected keys: {sorted(ev_stray)}")
        for key in ("run_id", "artifact", "quote"):
            val = ev.get(key)
            if not isinstance(val, str) or not val.strip():
                raise SchemaError(f"evidence[{i}].{key} must be a non-empty string")
