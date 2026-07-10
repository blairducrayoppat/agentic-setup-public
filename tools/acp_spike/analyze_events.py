"""Analyze an ACP spike events NDJSON: event-type histogram, tool-call kinds,
status-transition counts, and the inter-event gap distribution (the empirical basis
for an ACP 'no session/update for N s' idle detector vs the production mtime/CPU
heuristic). Pure read; no GPU. Usage: python analyze_events.py <events.ndjson>"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path


def main(path: str) -> int:
    p = Path(path)
    rows = [json.loads(ln) for ln in p.read_text(encoding="utf-8").splitlines() if ln.strip()]
    kinds = Counter()
    su_types = Counter()
    tool_kinds = Counter()
    tool_statuses = Counter()
    failed_tools = 0
    rels = []
    for r in rows:
        kinds[r["kind"]] += 1
        rels.append(r["t_rel_s"])
        pay = r.get("payload", {})
        su = pay.get("sessionUpdate")
        if su:
            su_types[su] += 1
        if su in ("tool_call", "tool_call_update"):
            if pay.get("kind"):
                tool_kinds[pay["kind"]] += 1
            st = pay.get("status")
            if st:
                tool_statuses[st] += 1
                if st == "failed":
                    failed_tools += 1
    # inter-event gaps
    gaps = [round(b - a, 2) for a, b in zip(rels, rels[1:])]
    gaps_sorted = sorted(gaps)

    def pct(q):
        if not gaps_sorted:
            return None
        i = min(len(gaps_sorted) - 1, int(q * len(gaps_sorted)))
        return gaps_sorted[i]

    out = {
        "events_file": str(p),
        "total_events": len(rows),
        "event_kinds": dict(kinds),
        "session_update_types": dict(su_types),
        "tool_call_kinds": dict(tool_kinds),
        "tool_status_counts": dict(tool_statuses),
        "failed_tool_calls": failed_tools,
        "span_s": round(rels[-1] - rels[0], 2) if rels else 0,
        "inter_event_gaps": {
            "count": len(gaps),
            "max_s": max(gaps) if gaps else None,
            "p50_s": pct(0.50),
            "p90_s": pct(0.90),
            "p99_s": pct(0.99),
            "gaps_over_30s": sum(1 for g in gaps if g > 30),
            "gaps_over_60s": sum(1 for g in gaps if g > 60),
            "gaps_over_90s": sum(1 for g in gaps if g > 90),
        },
    }
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
