#!/usr/bin/env python3
"""Aggregate results/live/runs.csv -> results/live/summary.csv (median/min/max per scaler x replicas)."""
import csv
import statistics as st
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIVE = ROOT / "results" / "live"
METRICS = ["t_nodeclaim_s", "t_first_node_ready_s", "t_all_nodes_ready_s", "t_all_pods_ready_s",
           "nodes", "packing_pct", "est_cost_per_hour_usd"]


def load(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def aggregate(rows):
    out = []
    keys = sorted({(r["scaler"], int(r["replicas"])) for r in rows}, key=lambda k: (k[1], k[0]))
    for scaler, n in keys:
        grp = [r for r in rows if r["scaler"] == scaler and int(r["replicas"]) == n]
        ok = [r for r in grp if r["status"] == "ok"]
        rec = {"scaler": scaler, "replicas": n, "runs_ok": len(ok), "runs_failed": len(grp) - len(ok)}
        for m in METRICS:
            vals = [float(r[m]) for r in ok if r[m] != ""]
            if vals:
                rec[f"{m}_median"] = round(st.median(vals), 4)
                rec[f"{m}_min"] = min(vals)
                rec[f"{m}_max"] = max(vals)
        rec["instance_types_seen"] = " | ".join(sorted({r["instance_types"] for r in ok}))
        out.append(rec)
    return out


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else LIVE / "runs.csv"
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else LIVE / "summary.csv"
    summary = aggregate(load(src))
    cols = list(summary[0].keys())
    for rec in summary:
        for c in rec:
            if c not in cols:
                cols.append(c)
    with open(dst, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(summary)
    print(f"wrote {dst} ({len(summary)} rows)")


if __name__ == "__main__":
    main()
