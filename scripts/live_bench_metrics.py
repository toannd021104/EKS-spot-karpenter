#!/usr/bin/env python3
"""Derive one CSV row from a raw per-run snapshot written by live-bench.sh.

All timestamps come from the Kubernetes API server (1 s resolution), and
T0 is the creationTimestamp of the first Pod of the run (server clock), so
client/server clock skew does not enter the numbers.
"""
import csv
import json
import sys
from datetime import datetime, timezone

COLUMNS = [
    "scaler", "replicas", "rep", "t_nodeclaim_s", "t_first_node_ready_s",
    "t_all_nodes_ready_s", "t_all_pods_ready_s", "nodes", "instance_types",
    "packing_pct", "est_cost_per_hour_usd", "cold", "status", "note",
]


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def cond_time(obj, ctype):
    for c in obj.get("status", {}).get("conditions", []):
        if c["type"] == ctype and c["status"] == "True":
            return ts(c["lastTransitionTime"])
    return None


def cpu(q):
    return float(q[:-1]) / 1000 if q.endswith("m") else float(q)


def derive(raw, prices):
    pods = raw["pods"]["items"]
    nodes = raw["nodes"]["items"]
    claims = raw["nodeclaims"]["items"]
    n = raw["replicas"]
    row = {"scaler": raw["scaler"], "replicas": n, "rep": raw["rep"],
           "cold": str(raw["cold"]).lower(), "status": raw["status"], "note": raw.get("note", "")}
    if not pods:
        return row
    t0 = min(ts(p["metadata"]["creationTimestamp"]) for p in pods)
    if claims:
        row["t_nodeclaim_s"] = int(min(ts(c["metadata"]["creationTimestamp"]) for c in claims) - t0)
    ready = [cond_time(nd, "Ready") for nd in nodes]
    ready = [r for r in ready if r is not None]
    if ready:
        row["t_first_node_ready_s"] = int(min(ready) - t0)
        if len(ready) == len(nodes):
            row["t_all_nodes_ready_s"] = int(max(ready) - t0)
    pod_ready = [cond_time(p, "Ready") for p in pods]
    if raw["status"] == "ok" and all(r is not None for r in pod_ready) and len(pods) == n:
        row["t_all_pods_ready_s"] = int(max(pod_ready) - t0)
    types = {}
    cost = alloc = 0.0
    for nd in nodes:
        t = nd["metadata"]["labels"]["node.kubernetes.io/instance-type"]
        types[t] = types.get(t, 0) + 1
        cost += prices[t]["usd_per_hour"]
        alloc += cpu(nd["status"]["allocatable"]["cpu"])
    row["nodes"] = len(nodes)
    row["instance_types"] = " ".join(f"{k}x{v}" for k, v in sorted(types.items()))
    req = sum(cpu(c["resources"].get("requests", {}).get("cpu", "0"))
              for p in pods for c in p["spec"]["containers"])
    if alloc:
        row["packing_pct"] = round(100 * req / alloc, 1)
    row["est_cost_per_hour_usd"] = round(cost, 4)
    return row


def main():
    raw_path, price_path, csv_path = sys.argv[1:4]
    raw = json.load(open(raw_path))
    prices = json.load(open(price_path))["prices"]
    row = derive(raw, prices)
    new = False
    try:
        open(csv_path).close()
    except FileNotFoundError:
        new = True
    with open(csv_path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        if new:
            w.writeheader()
        w.writerow({c: row.get(c, "") for c in COLUMNS})
    print(json.dumps({k: row.get(k, "") for k in COLUMNS}))


if __name__ == "__main__":
    main()
