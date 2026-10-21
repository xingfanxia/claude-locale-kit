"""Summarize an audit JSONL log into the per-field table the feasibility report needs.

Usage: python summarize.py LOG.jsonl
Prints Markdown: counts, then one row per (template, location, kind, matches). The log already
holds only fixed names, kinds and match labels, so the summary adds nothing new.
"""

from __future__ import annotations

import json
import sys
from collections import Counter


def summarize(lines: list[str]) -> str:
    recs = [json.loads(line) for line in lines if line.strip()]
    events = Counter(r["event"] for r in recs)
    rows: Counter = Counter()
    statuses: Counter = Counter()
    unlisted: Counter = Counter()
    for r in recs:
        if r["event"] != "request":
            continue
        t = r["template"]
        statuses[(t, r["body"].get("status"))] += 1
        for h in r["headers"]:
            rows[(t, "header " + h["at"], h["kind"], ",".join(h["matches"]) or "-")] += 1
        for q in r["query"]:
            rows[(t, "query " + q["at"], q["kind"], ",".join(q["matches"]) or "-")] += 1
        for f in r["body"].get("fields", []):
            rows[(t, "body " + f["at"], f["kind"], ",".join(f["matches"]) or "-")] += f["count"]
        for label, n in {**r.get("unlisted_exact_value_matches", {})}.items():
            unlisted[(t, "header/query", label)] += n
        for label, n in r["body"].get("unlisted_exact_value_matches", {}).items():
            unlisted[(t, "body", label)] += n
    out = ["| event | count |", "|---|---|"] + [f"| {k} | {v} |" for k, v in sorted(events.items())]
    out += ["", "| template | body status | requests |", "|---|---|---|"]
    out += [f"| `{t}` | {s} | {n} |" for (t, s), n in sorted(statuses.items())]
    out += ["", "| template | location | kind | matches | count |", "|---|---|---|---|---|"]
    out += [f"| `{t}` | `{loc}` | {k} | {m} | {n} |" for (t, loc, k, m), n in sorted(rows.items())]
    if unlisted:
        out += ["", "Values equal to a reference under names outside the fixed lists (location not recorded):", "",
                "| template | where | equals | count |", "|---|---|---|---|"]
        out += [f"| `{t}` | {w} | {label} | {n} |" for (t, w, label), n in sorted(unlisted.items())]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: summarize.py LOG.jsonl")
    with open(sys.argv[1], encoding="utf-8") as f:
        sys.stdout.write(summarize(f.readlines()))
