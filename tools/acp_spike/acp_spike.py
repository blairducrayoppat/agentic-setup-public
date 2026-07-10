"""ACP driver spike harness (Vikunja #759) -- SIDE-BY-SIDE experiment only.

Drives ONE opencode coder session through opencode's native Agent Client Protocol
(ACP: JSON-RPC 2.0 over stdio, persistent session, typed event stream) and captures
a structured NDJSON event stream, to A/B against the production `opencode run` +
transcript-regex path (scripts/fleet-lib.ps1 Invoke-AgentRun).

This harness NEVER touches the production fleet scripts. It is confined to
tools/acp_spike/ (code) + state/acp-spike/ (evidence). It spawns `opencode acp`
exactly as the SDK does (vector argv, no shell), reading the SAME global config at
~/.config/opencode/ that `opencode run` reads (verified byte-identical to the repo
configs/opencode.json), so the coder behaves identically to production.

Subcommands:
  recon   initialize + session/new only (NO model call -> no GPU needed). Confirms
          ACP handshake (protocolVersion), agent capabilities, session modes/models,
          config-option surface, and -- via opencode's own stderr logs -- that the
          command-timeout + path-normalize plugins load in ACP mode (parity gate).
  run     full session/prompt with live session/update capture to NDJSON, final
          StopReason, wall-clock. Needs OVMS + the coder model up. Optional
          --cancel-after N to probe cooperative session/cancel.

Python 3.14 + agent-client-protocol==0.11.0. Windows Proactor loop (asyncio default
on win32 -- do NOT switch to Selector; subprocess pipes need Proactor).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import acp
from acp import spawn_agent_process, text_block
from acp.schema import (
    AllowedOutcome,
    ClientCapabilities,
    FileSystemCapabilities,
    PermissionOption,
    PlanCapabilities,
    RequestPermissionResponse,
    ToolCallUpdate,
)

GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"
STATE_DIR = Path(r"C:\Users\mrbla\agentic-setup\state\acp-spike")


def resolve_opencode_exe() -> str:
    """The REAL compiled opencode.exe (not the .cmd/.ps1 npm shim). asyncio's
    create_subprocess_exec does not go through a shell, so it cannot resolve the shim;
    Invoke-AgentRun (fleet-lib.ps1:346-356) resolves this exact exe for the same reason."""
    try:
        out = subprocess.run(["where.exe", "opencode"], capture_output=True, text=True, timeout=10)
        for line in out.stdout.splitlines():
            line = line.strip()
            if line.lower().endswith(".ps1") or line.lower().endswith(".cmd") or line.lower().endswith("opencode"):
                shim_dir = str(Path(line).parent)
                exe = Path(shim_dir) / "node_modules" / "opencode-ai" / "bin" / "opencode.exe"
                if exe.exists():
                    return str(exe)
    except Exception:
        pass
    # Fallback to the known install location on this box.
    cand = Path(os.environ.get("APPDATA", "")) / "npm" / "node_modules" / "opencode-ai" / "bin" / "opencode.exe"
    if cand.exists():
        return str(cand)
    return "opencode"  # last resort (will fail loudly if unresolved)


OPENCODE_EXE = resolve_opencode_exe()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ts_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def build_env(workdir: str) -> dict[str, str]:
    """The subset of env opencode needs, mirroring Invoke-AgentRun (fleet-lib.ps1:344-384).

    The SDK's spawn_stdio_transport trims to an allowlist and merges this on top, so
    anything opencode needs beyond that allowlist (git-bash pin, SHELL, PYTHONPATH)
    MUST be passed here explicitly.
    """
    env: dict[str, str] = {}
    # opencode's Windows shell detection prefers WSL when wsl.exe exists -> the bash
    # tool wedges. Pin git-bash exactly as Invoke-AgentRun does (#670 / opencode #8396).
    env["OPENCODE_GIT_BASH_PATH"] = GIT_BASH
    env["SHELL"] = GIT_BASH
    # The agent's own pytest imports root-level modules from the worktree.
    env["PYTHONPATH"] = workdir
    # Carry USERPROFILE so opencode resolves ~/.config/opencode (already in the SDK
    # allowlist, but pass it defensively).
    for k in ("USERPROFILE", "APPDATA", "LOCALAPPDATA", "PATH", "PATHEXT",
              "SYSTEMROOT", "SYSTEMDRIVE", "TEMP", "TMP", "HOMEDRIVE", "HOMEPATH",
              "USERNAME", "PROCESSOR_ARCHITECTURE"):
        v = os.environ.get(k)
        if v is not None:
            env[k] = v
    return env


class RecordingClient:
    """ACP Client: records every session/update to NDJSON, auto-approves permission
    requests per the fleet posture (allow within the worktree), and refuses fs/terminal
    callbacks (we declare those capabilities OFF so opencode uses its own tools -- exactly
    matching `opencode run` today)."""

    def __init__(self, ndjson_path: Path, *, verbose: bool = True) -> None:
        self.ndjson_path = ndjson_path
        self.verbose = verbose
        self.events: list[dict[str, Any]] = []
        self.permission_grants: list[dict[str, Any]] = []
        self.tool_calls: dict[str, dict[str, Any]] = {}
        self.start_monotonic = time.monotonic()
        self._fh = ndjson_path.open("a", encoding="utf-8")

    # ---- recording -------------------------------------------------------
    def _emit(self, kind: str, payload: dict[str, Any]) -> None:
        rec = {
            "t_iso": _now_iso(),
            "t_rel_s": round(time.monotonic() - self.start_monotonic, 4),
            "kind": kind,
            "payload": payload,
        }
        self.events.append(rec)
        self._fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self._fh.flush()
        if self.verbose:
            brief = payload.get("sessionUpdate") or payload.get("_summary") or kind
            print(f"  [{rec['t_rel_s']:>7.2f}s] {kind}: {brief}", flush=True)

    def close(self) -> None:
        try:
            self._fh.close()
        except Exception:
            pass

    # ---- Client protocol methods ----------------------------------------
    async def session_update(self, session_id: str, update: Any, **kwargs: Any) -> None:
        try:
            payload = update.model_dump(mode="json", by_alias=True, exclude_none=True)
        except Exception:
            payload = {"_repr": repr(update)}
        su = payload.get("sessionUpdate", "?")
        # Track tool-call lifecycle for the fidelity count.
        if su in ("tool_call", "tool_call_update"):
            tcid = payload.get("toolCallId") or payload.get("id") or ""
            entry = self.tool_calls.setdefault(tcid, {"statuses": [], "kind": payload.get("kind"), "title": payload.get("title")})
            status = payload.get("status")
            if status:
                entry["statuses"].append(status)
            if payload.get("kind"):
                entry["kind"] = payload["kind"]
            if payload.get("title"):
                entry["title"] = payload["title"]
        self._emit("session_update", payload)

    async def request_permission(
        self, session_id: str, tool_call: ToolCallUpdate, options: list[PermissionOption], **kwargs: Any
    ) -> RequestPermissionResponse:
        # Fleet posture: allow within the worktree. Prefer allow_once (auditable per-call)
        # over allow_always so every grant is logged individually.
        chosen = None
        for kind_pref in ("allow_once", "allow_always"):
            for opt in options:
                if opt.kind == kind_pref:
                    chosen = opt
                    break
            if chosen:
                break
        if chosen is None and options:
            chosen = options[0]
        try:
            tc = tool_call.model_dump(mode="json", by_alias=True, exclude_none=True)
        except Exception:
            tc = {"_repr": repr(tool_call)}
        grant = {
            "t_rel_s": round(time.monotonic() - self.start_monotonic, 4),
            "tool_call": tc,
            "options": [{"optionId": o.option_id, "kind": o.kind, "name": o.name} for o in options],
            "chosen": {"optionId": chosen.option_id, "kind": chosen.kind} if chosen else None,
        }
        self.permission_grants.append(grant)
        self._emit("request_permission", {"_summary": f"grant {chosen.kind if chosen else 'NONE'} for {tc.get('title', tc.get('kind','?'))}", **grant})
        return RequestPermissionResponse(outcome=AllowedOutcome(outcome="selected", option_id=chosen.option_id))

    # fs/terminal are declared OFF -> these should never be called. Log loudly if they are.
    async def write_text_file(self, session_id: str, path: str, content: str, **kwargs: Any):
        self._emit("UNEXPECTED_fs_write", {"path": path})
        raise acp.RequestError.method_not_found("fs/write_text_file (capability OFF)")

    async def read_text_file(self, session_id: str, path: str, line=None, limit=None, **kwargs: Any):
        self._emit("UNEXPECTED_fs_read", {"path": path})
        raise acp.RequestError.method_not_found("fs/read_text_file (capability OFF)")

    async def create_terminal(self, session_id: str, command: str, args=None, env=None, cwd=None, output_byte_limit=None, **kwargs: Any):
        self._emit("UNEXPECTED_terminal", {"command": command})
        raise acp.RequestError.method_not_found("terminal (capability OFF)")

    async def terminal_output(self, *a, **k):
        raise acp.RequestError.method_not_found("terminal (capability OFF)")

    async def release_terminal(self, *a, **k):
        raise acp.RequestError.method_not_found("terminal (capability OFF)")

    async def wait_for_terminal_exit(self, *a, **k):
        raise acp.RequestError.method_not_found("terminal (capability OFF)")

    async def kill_terminal(self, *a, **k):
        raise acp.RequestError.method_not_found("terminal (capability OFF)")

    async def create_elicitation(self, message: str, mode: Any, **kwargs: Any):
        raise acp.RequestError.method_not_found("elicitation unsupported")

    async def complete_elicitation(self, elicitation_id: str, **kwargs: Any) -> None:
        return None

    async def ext_method(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self._emit("ext_method", {"method": method})
        return {}

    async def ext_notification(self, method: str, params: dict[str, Any]) -> None:
        self._emit("ext_notification", {"method": method, "params": params})

    def on_connect(self, conn: Any) -> None:
        self._conn = conn


def _client_capabilities() -> ClientCapabilities:
    # fs read/write OFF + terminal OFF (opencode uses its OWN tools -> matches `opencode run`).
    # plan={} advertises we can receive plan_update events (we WANT to observe them).
    return ClientCapabilities(
        fs=FileSystemCapabilities(read_text_file=False, write_text_file=False),
        terminal=False,
        plan=PlanCapabilities(),
    )


async def _handshake(conn, client, cwd: str, log) -> tuple[Any, Any]:
    init = await conn.initialize(
        protocol_version=acp.PROTOCOL_VERSION,
        client_capabilities=_client_capabilities(),
    )
    log("initialize", init.model_dump(mode="json", by_alias=True, exclude_none=True))
    sess = await conn.new_session(cwd=cwd)
    log("new_session", sess.model_dump(mode="json", by_alias=True, exclude_none=True))
    return init, sess


async def cmd_recon(args) -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    slug = _ts_slug()
    stderr_path = STATE_DIR / f"recon-{slug}.opencode-stderr.log"
    report_path = STATE_DIR / f"recon-{slug}.json"
    ndjson_path = STATE_DIR / f"recon-{slug}.events.ndjson"
    cwd = args.cwd
    report: dict[str, Any] = {"phase": "recon", "t_iso": _now_iso(), "cwd": cwd,
                              "sdk_protocol_version": acp.PROTOCOL_VERSION, "records": {}}

    def log(name, obj):
        report["records"][name] = obj
        print(f"--- {name} ---")
        print(json.dumps(obj, indent=2, ensure_ascii=False)[:4000], flush=True)

    client = RecordingClient(ndjson_path, verbose=False)
    stderr_fh = stderr_path.open("wb")
    print(f"Spawning: opencode acp --print-logs --log-level INFO  (cwd={cwd})", flush=True)
    try:
        async with spawn_agent_process(
            client,
            OPENCODE_EXE, "acp", "--print-logs", "--log-level", "INFO",
            env=build_env(cwd),
            cwd=cwd,
            transport_kwargs={"stderr": stderr_fh},
        ) as (conn, proc):
            report["opencode_pid"] = proc.pid
            init, sess = await asyncio.wait_for(_handshake(conn, client, cwd, log), timeout=args.timeout)
            # Give opencode a moment to flush plugin load-lines to stderr.
            await asyncio.sleep(1.0)
    except Exception as exc:  # noqa: BLE001
        report["error"] = f"{type(exc).__name__}: {exc}"
        print(f"RECON ERROR: {report['error']}", file=sys.stderr, flush=True)
    finally:
        client.close()
        try:
            stderr_fh.close()
        except Exception:
            pass

    # Parity check: did the plugins load? (their designed-in stderr load-lines)
    stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
    markers = {
        "command-timeout": "[command-timeout] loaded" in stderr_text,
        "path-normalize": "[path-normalize] loaded" in stderr_text,
    }
    loader_errors = [ln.strip() for ln in stderr_text.splitlines()
                     if "failed to load plugin" in ln.lower() or "plugin export is not a function" in ln.lower()][:10]
    report["plugin_parity"] = {"markers": markers, "loader_errors": loader_errors,
                               "stderr_log": str(stderr_path), "stderr_bytes": len(stderr_text)}
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n=== PLUGIN PARITY: {markers}  loader_errors={len(loader_errors)} ===", flush=True)
    print(f"Recon report: {report_path}", flush=True)
    print(f"opencode stderr: {stderr_path}", flush=True)
    return 0


async def cmd_run(args) -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    slug = _ts_slug()
    stderr_path = STATE_DIR / f"run-{slug}.opencode-stderr.log"
    report_path = STATE_DIR / f"run-{slug}.json"
    ndjson_path = STATE_DIR / f"run-{slug}.events.ndjson"
    cwd = args.cwd
    prompt_text = Path(args.prompt_file).read_text(encoding="utf-8") if args.prompt_file else args.prompt
    report: dict[str, Any] = {
        "phase": "run", "t_iso": _now_iso(), "cwd": cwd, "model": args.model,
        "prompt_chars": len(prompt_text), "cancel_after_s": args.cancel_after,
        "events_ndjson": str(ndjson_path),
    }
    client = RecordingClient(ndjson_path, verbose=True)
    stderr_fh = stderr_path.open("wb")
    acp_args = ["acp", "--print-logs", "--log-level", "INFO"]
    print(f"Spawning: opencode {' '.join(acp_args)}  (cwd={cwd}, model={args.model})", flush=True)
    t0 = time.monotonic()
    stop_reason = None
    try:
        async with spawn_agent_process(
            client, OPENCODE_EXE, *acp_args,
            env=build_env(cwd), cwd=cwd, transport_kwargs={"stderr": stderr_fh},
        ) as (conn, proc):
            report["opencode_pid"] = proc.pid
            init = await conn.initialize(protocol_version=acp.PROTOCOL_VERSION, client_capabilities=_client_capabilities())
            report["initialize"] = init.model_dump(mode="json", by_alias=True, exclude_none=True)
            sess = await conn.new_session(cwd=cwd)
            session_id = sess.session_id
            report["new_session"] = sess.model_dump(mode="json", by_alias=True, exclude_none=True)
            report["session_id"] = session_id

            # Model selection: prefer an ACP config-option if opencode exposes one; the
            # caller passes --model and we try set_config_option('model', ...). If that
            # is unsupported, the worktree opencode.json override (written by the runner
            # ps1) governs. Recorded either way.
            if args.model:
                try:
                    r = await conn.set_config_option(config_id="model", session_id=session_id, value=args.model)
                    report["model_selection"] = {"via": "set_config_option", "ok": True,
                                                  "resp": (r.model_dump(mode="json", by_alias=True, exclude_none=True) if r else None)}
                except Exception as exc:  # noqa: BLE001
                    report["model_selection"] = {"via": "set_config_option", "ok": False, "error": f"{type(exc).__name__}: {exc}"}

            prompt_task = asyncio.create_task(
                conn.prompt(session_id=session_id, prompt=[text_block(prompt_text)])
            )
            if args.cancel_after and args.cancel_after > 0:
                async def _canceller():
                    await asyncio.sleep(args.cancel_after)
                    print(f"  >>> sending session/cancel after {args.cancel_after}s", flush=True)
                    report["cancel_sent_t_rel_s"] = round(time.monotonic() - t0, 3)
                    await conn.cancel(session_id=session_id)
                asyncio.create_task(_canceller())

            pr = await asyncio.wait_for(prompt_task, timeout=args.timeout)
            stop_reason = pr.stop_reason
            report["prompt_response"] = pr.model_dump(mode="json", by_alias=True, exclude_none=True)
    except asyncio.TimeoutError:
        report["error"] = f"prompt timed out after {args.timeout}s"
        print(f"RUN TIMEOUT: {report['error']}", file=sys.stderr, flush=True)
    except Exception as exc:  # noqa: BLE001
        report["error"] = f"{type(exc).__name__}: {exc}"
        print(f"RUN ERROR: {report['error']}", file=sys.stderr, flush=True)
    finally:
        client.close()
        try:
            stderr_fh.close()
        except Exception:
            pass

    wall = round(time.monotonic() - t0, 3)
    # Fidelity: count tool-call events + status transitions the ACP side saw.
    tool_call_events = sum(1 for e in client.events if e["payload"].get("sessionUpdate") in ("tool_call", "tool_call_update"))
    tool_calls_started = len(client.tool_calls)
    status_transitions = sum(len(v["statuses"]) for v in client.tool_calls.values())
    report.update({
        "wall_clock_s": wall,
        "stop_reason": stop_reason,
        "event_count": len(client.events),
        "tool_call_event_count": tool_call_events,
        "distinct_tool_calls": tool_calls_started,
        "tool_status_transitions": status_transitions,
        "permission_grants": len(client.permission_grants),
        "tool_call_summary": [
            {"id": k, "kind": v.get("kind"), "title": v.get("title"), "statuses": v["statuses"]}
            for k, v in client.tool_calls.items()
        ],
        "stderr_log": str(stderr_path),
    })
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n=== RUN DONE: stop_reason={stop_reason} wall={wall}s events={len(client.events)} "
          f"tool_calls={tool_calls_started} transitions={status_transitions} grants={len(client.permission_grants)} ===", flush=True)
    print(f"Run report: {report_path}", flush=True)
    print(f"Events NDJSON: {ndjson_path}", flush=True)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="ACP driver spike harness (#759)")
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("recon", help="handshake only (no GPU)")
    pr.add_argument("--cwd", required=True)
    pr.add_argument("--timeout", type=float, default=60.0)

    prun = sub.add_parser("run", help="full prompt run (needs coder model up)")
    prun.add_argument("--cwd", required=True)
    prun.add_argument("--model", default="local/coder-30b")
    g = prun.add_mutually_exclusive_group(required=True)
    g.add_argument("--prompt")
    g.add_argument("--prompt-file")
    prun.add_argument("--timeout", type=float, default=1800.0)
    prun.add_argument("--cancel-after", type=float, default=0.0)

    args = p.parse_args()
    # NOTE: on win32 + py3.14 asyncio.run already uses the Proactor loop (required for
    # subprocess pipes). Do NOT force Selector. No explicit policy set needed.
    if args.cmd == "recon":
        return asyncio.run(cmd_recon(args))
    if args.cmd == "run":
        return asyncio.run(cmd_run(args))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
