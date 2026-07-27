"""Regression lock for the tool-call severance fix (#991, 2026-07-20).

THE FAILURE
-----------
On 2026-07-19 the 30B coder emitted its tool calls as ``<function/read>`` - a
SLASH where the Qwen3-Coder grammar has ``=`` - nine consecutive times on the B4
flashcards job. ``salvage_tool_calls`` matched only ``<function=`` in both its
reconstruction branch AND its bare-marker guard, so every call fell through to
``(None, None)``; the proxy shipped the text as prose; the agent loop saw no
tool call and exited. From outside, a model being severed mid-work is
indistinguishable from a model that decided to stop - and the whole battery
night was scored as the coder producing nothing.

WHAT IS LOCKED
--------------
1. The EXACT byte-form recovered from the failing transcript reconstructs into a
   real tool call (not a paraphrase - the literal string the model emitted).
2. The canonical ``=`` form still works (no regression).
3. TOGGLE-OFF: reverting the separator to ``=``-only re-breaks the slash form -
   proof the test detects the defect rather than being blind to it (principle 12).
4. The bare-marker guard now flags a slash-form it cannot reconstruct, so an
   unrescuable severance is a retry signal, not silent prose.

Run:  python -m pytest tools/test_qwen_toolcall_severance.py -q
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qwen_toolcall_fix import salvage_tool_calls  # noqa: E402

# The literal block recovered from
# state/reports/battery-b4-flashcards-cli-implement-quiz-logic-20260720-000536.c1.agent.log
# - a real read call the model was severed on. `\n` are real newlines here.
SEVERED = (
    "<tool_call>\n"
    "<function/read>\n"
    "<parameter=filePath>\n"
    "C:/Users/mrbla/agentic-setup/state/worktrees/battery-b4-flashcards-cli/flashcard_app/score_tracker.py\n"
    "</parameter>\n"
    "</function>\n"
    "</tool_call>"
)

CANONICAL = (
    "<tool_call>\n"
    "<function=read>\n"
    "<parameter=filePath>\n"
    "score_tracker.py\n"
    "</parameter>\n"
    "</function>\n"
    "</tool_call>"
)


def test_the_severed_slash_form_now_reconstructs() -> None:
    kind, calls = salvage_tool_calls(SEVERED)
    assert calls, f"the <function/read> form still does not reconstruct (kind={kind!r})"
    assert calls[0]["name"] == "read", calls
    assert "score_tracker.py" in calls[0]["arguments"], calls
    assert "filePath" in calls[0]["arguments"], calls


def test_the_canonical_equals_form_still_works() -> None:
    kind, calls = salvage_tool_calls(CANONICAL)
    assert calls and calls[0]["name"] == "read", (kind, calls)
    assert "score_tracker.py" in calls[0]["arguments"], calls


def test_a_prose_answer_with_no_marker_is_left_alone() -> None:
    kind, calls = salvage_tool_calls("Here is the summary you asked for. Nothing to call.")
    assert not calls, (kind, calls)


def test_toggle_off_the_equals_only_regex_re_breaks_the_slash_form() -> None:
    """If someone reverts the separator to '=' only, the slash form must fail again.

    A lock that keeps passing after the fix is reverted is not a lock. This
    re-implements the OLD regex and asserts it does NOT match the real severed
    string - so the difference the fix makes is proven, not assumed.
    """
    old_xml = re.compile(r"<function=([^>\s]+)>(.*?)</function>", re.S)
    assert not old_xml.search(SEVERED), (
        "the =-only regex matched the slash form - the toggle-off proof is invalid, "
        "which means the positive test proves nothing"
    )
    # And the NEW pattern must match it, for the same string.
    new_xml = re.compile(r"<function[=/]([^>\s]+)>(.*?)</function>", re.S)
    assert new_xml.search(SEVERED), "the widened regex fails to match the real severed form"


def test_bare_marker_guard_flags_an_unreconstructable_slash_form() -> None:
    """A slash-form with no recoverable body must be FLAGGED, not shipped as prose.

    This is what made the severance silent: the old guard was '=' only, so a
    '<function/...>' that could not be rebuilt fell through to (None, None). Now
    it returns a bare-marker retry signal.
    """
    # A function marker with a slash but a body the param-extractor yields nothing from.
    stub = "<tool_call>\n<function/read>\n(the model was cut off here"
    kind, calls = salvage_tool_calls(stub)
    assert calls is None, f"expected no reconstructed calls from a truncated stub, got {calls!r}"
    assert kind == "bare-marker", (
        f"a slash-form marker must be caught as a bare-marker retry signal, got kind={kind!r} "
        f"- before #991 this returned (None, None) and shipped silently as prose"
    )
