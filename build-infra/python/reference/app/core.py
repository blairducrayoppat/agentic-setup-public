"""Core logic for the app.

This `summarize` function is a PLACEHOLDER so the project builds and its tests pass out of
the box. Replace or extend it with the task's real logic, and keep a matching test in
tests/. It models the quality bar: type hints, a docstring, and an edge case handled.
"""
from __future__ import annotations

from collections.abc import Sequence


def summarize(numbers: Sequence[float]) -> dict[str, float]:
    """Return count, total, and mean for a sequence of numbers.

    An empty input returns zeros rather than raising, so callers need no special-casing.
    """
    if not numbers:
        return {"count": 0.0, "total": 0.0, "mean": 0.0}
    total = float(sum(numbers))
    return {"count": float(len(numbers)), "total": total, "mean": total / len(numbers)}
