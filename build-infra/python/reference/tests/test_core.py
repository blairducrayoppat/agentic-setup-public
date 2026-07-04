"""Smoke tests for app.core. Extend these alongside the real logic you add.

The fleet runs pytest with the project root on PYTHONPATH, so `from app.core import ...`
resolves without an install.
"""
from app.core import summarize


def test_summarize_basic():
    result = summarize([2, 4, 6])
    assert result["count"] == 3
    assert result["total"] == 12.0
    assert result["mean"] == 4.0


def test_summarize_empty_is_safe():
    result = summarize([])
    assert result["count"] == 0
    assert result["total"] == 0.0
    assert result["mean"] == 0.0
