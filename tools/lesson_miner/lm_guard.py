"""Post-pass window guard — the miner MUST NOT run during a live dispatch (plan §3.1).

The swap driver (BlarAI ``shared/fleet/swap_driver.py``, ADR-034) tears the 14B
down, runs the 30B coder fleet, then restores the 14B, write-ahead-logging its
state to ``state/fleet-swap/current.json``. The miner is 14B-resident post-pass
work: it may run ONLY after the 14B is restored, never mid-dispatch (it would fight
the 30B for the GPU, and — since scorecards are runner-owned files — it could read a
half-written run).

This guard reads that swap-state file and answers one question with miner-safe
polarity: *is a dispatch live right now?* Where the driver's OWN reconciler fails
"not alive -> recover" (stranding a crashed swap forever is the worse outcome for
IT), this guard fails the OTHER way — **unsure => assume live => refuse** — because
for the miner the worse outcome is stepping on a running dispatch. The phase set and
the driver-liveness probe mirror ``swap_state.py`` deliberately; they are duplicated
here (not imported) because agentic-setup does not depend on the BlarAI package.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

# Phases in which NO swap is active — a boot/read here is a genuine post-pass window
# (or the fleet never swapped). Mirrors swap_state.py: IDLE/RECOVERED are its terminal
# set; FAILED/CANCELLED are dispatch END states (badly, but not *live*) so the miner
# treats them as not-live too. Everything else (RESERVE..REPORT, LOAD-30B, CODE, ...)
# means a dispatch is mid-flight.
_NOT_LIVE_PHASES = frozenset(
    {"IDLE-14B", "RECOVERED", "FAILED", "CANCELLED"}
)


@dataclass(frozen=True)
class DispatchStatus:
    """Whether a dispatch is live, and the human-readable reason for the verdict."""

    live: bool
    reason: str
    run_id: str = ""
    phase: str = ""


def _driver_alive(driver_pid: int, driver_pid_created: float) -> bool | None:
    """Is the recorded detached driver process still running?

    Returns True/False when psutil can answer, or None when it cannot (psutil
    absent, or probe error) — the caller treats None conservatively. The
    create-time match (±2 s) guards pid reuse, exactly as swap_state.driver_alive.
    """
    if not driver_pid:
        return False
    try:
        import psutil
    except ImportError:
        return None
    try:
        proc = psutil.Process(driver_pid)
    except psutil.NoSuchProcess:
        return False  # the recorded pid is gone -> the driver is dead, not unknown
    except Exception:  # noqa: BLE001 — any other probe failure is genuinely unknown
        return None
    try:
        if not proc.is_running():
            return False
        if driver_pid_created > 0:
            return abs(float(proc.create_time()) - driver_pid_created) < 2.0
        return True
    except Exception:  # noqa: BLE001 — an unprobeable driver is "unknown", not "dead"
        return None


def dispatch_status(swap_state_path: Path) -> DispatchStatus:
    """Read the swap state and decide whether a dispatch is live (miner-safe).

    - No swap-state file, or a non-object / no-run_id record  -> NOT live (never
      swapped, or a clean cleared state): safe to mine.
    - Phase in the not-live set (IDLE/RECOVERED/FAILED/CANCELLED) AND the driver is
      not alive -> NOT live: safe to mine (the normal RECOVERED post-pass window).
    - Any active phase, OR a live driver, OR an unreadable/ambiguous record ->
      LIVE: refuse.
    """
    try:
        raw = swap_state_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return DispatchStatus(live=False, reason="no swap-state file — no dispatch has run")
    except OSError as exc:
        # A present-but-unreadable state file is exactly the "unsure" case -> refuse.
        return DispatchStatus(live=True, reason=f"swap-state unreadable ({exc}) — refusing to be safe")

    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return DispatchStatus(live=True, reason="swap-state is not valid JSON — refusing to be safe")
    if not isinstance(data, dict) or not data.get("run_id"):
        return DispatchStatus(live=False, reason="swap-state carries no run — no dispatch in flight")

    phase = str(data.get("phase", ""))
    run_id = str(data.get("run_id", ""))
    try:
        driver_pid = int(data.get("driver_pid", 0) or 0)
    except (TypeError, ValueError):
        driver_pid = 0
    try:
        driver_pid_created = float(data.get("driver_pid_created", 0.0) or 0.0)
    except (TypeError, ValueError):
        driver_pid_created = 0.0

    alive = _driver_alive(driver_pid, driver_pid_created)
    if alive is True:
        return DispatchStatus(
            live=True, run_id=run_id, phase=phase,
            reason=f"dispatch {run_id} driver process is ALIVE (phase {phase or '?'}) — a run is in flight",
        )

    if phase not in _NOT_LIVE_PHASES:
        return DispatchStatus(
            live=True, run_id=run_id, phase=phase,
            reason=f"dispatch {run_id} is in active phase {phase or '?'} — a run is in flight",
        )

    # Terminal/idle phase and the driver is not alive (or unprobeable-but-terminal):
    # a genuine post-pass window.
    note = "" if alive is False else " (driver liveness unprobeable; phase is terminal)"
    return DispatchStatus(
        live=False, run_id=run_id, phase=phase,
        reason=f"dispatch {run_id} phase is {phase or 'idle'} — post-pass window{note}",
    )
