#!/usr/bin/env python3
"""fill_results.py: raw CSVs -> results/summary.json + results/RESULTS.md (design 7.8 and 8). Python stdlib only.

Rules that make "no invented numbers" enforceable:
  * a metric with n == 0 is null (never 0, never a guess); n counts outcome=ok rows with rep >= 1 (rep 0 is the cold start);
  * a scaler's status uses scale-up and chaos only: MEASURED (both n >= 1), PARTIAL (exactly one), TARGET (none);
    cost never contributes and cost.kind is always "estimate";
  * probe_total / probe_failed are computed here from the raw probe log slices, never in shell;
  * synthetic input (run_id starting with SYNTHETIC-) sets meta.synthetic=true and may only be written below /tmp.

Usage: fill_results.py [--input-dir DIR] [--out DIR] [--prefix P] [--meta KEY=VALUE ...]
Exit codes: 0 ok, 1 invalid input or refused output.
"""
import argparse
import csv
import json
import re
import statistics
import sys
from pathlib import Path

RESULTS_DIR = Path(__file__).resolve().parents[1] / "results"
SCALERS = ("ca", "karpenter", "automode")
SYNTHETIC_PREFIX = "SYNTHETIC-"

SCHEMAS = {
    "scaleup": ["run_id", "scaler", "rep", "replicas", "t0_utc", "node_ready_utc", "first_running_utc", "all_running_utc",
                "node_provision_s", "first_pod_running_s", "all_pods_running_s", "nodes_created", "instance_types",
                "capacity_types", "zones", "ami_id", "scaledown_s", "outcome", "notes", "kind"],
    "cost": ["run_id", "scaler", "window", "namespace", "cpu_core_hours", "ram_gib_hours", "cost_usd", "cost_per_hour_usd",
             "monthly_estimate_usd", "basis", "idle_shared", "source", "kind"],
    "cost-listmodel": ["run_id", "scaler", "instance_type", "capacity_type", "node_hours", "unit_price_usd_per_hour",
                       "price_source", "price_date", "cost_usd", "automode_fee_usd", "label", "kind"],
    "chaos": ["run_id", "scaler", "rep", "mode", "victim_node", "victim_instance_id", "victim_capacity_type", "t_kill_utc",
              "replacement_node_ready_utc", "all_pods_ready_utc", "recovery_s", "window_start_epoch", "window_end_epoch",
              "probe_log", "pods_rescheduled", "outcome", "notes", "kind"],
}
INT_COLS = {
    "scaleup": ["rep", "replicas", "node_provision_s", "first_pod_running_s", "all_pods_running_s", "nodes_created", "scaledown_s"],
    "chaos": ["rep", "recovery_s", "window_start_epoch", "window_end_epoch", "pods_rescheduled"],
}
FLOAT_COLS = {
    "cost": ["cpu_core_hours", "ram_gib_hours", "cost_usd", "cost_per_hour_usd", "monthly_estimate_usd"],
    "cost-listmodel": ["node_hours", "unit_price_usd_per_hour", "cost_usd", "automode_fee_usd"],
}
ENUMS = {
    "scaleup": {"outcome": {"ok", "timeout", "isolation_violation"}, "kind": {"observed"}},
    "chaos": {"mode": {"terminate", "fis", "drain"}, "outcome": {"ok", "timeout"}, "kind": {"observed"}},
    "cost": {"basis": {"opencost_estimate"}, "kind": {"estimate"}},
    "cost-listmodel": {"price_source": {"list_snapshot", "spot_market_snapshot"}, "kind": {"estimate"}},
}
LISTMODEL_LABEL = "ước tính theo giá list"
NAMESPACE_SOURCE = "opencost_allocation_namespace"

DEFAULT_META = {
    "cluster": None, "region": "ap-southeast-1", "date_utc": None, "synthetic": False, "layout": None,
    "kubernetes": "1.35", "karpenter": "1.14.2", "cluster_autoscaler": "1.35.0", "opencost": "1.121.3",
    "ca_config": "tuned", "ca_capacity_rebalance": None, "replicas": 4, "reps": 3,
    "note": "n nhỏ, 1 region, 1 buổi; không phải benchmark thống kê",
}


class InputError(Exception):
    pass


def read_csv(path, kind, scaler=None):
    """Return validated rows (dicts with parsed numbers). Raise InputError listing file:line problems."""
    if not path.exists():
        return []
    expected = SCHEMAS[kind]
    problems, rows = [], []
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.reader(fh)
        header = next(reader, None)
        if header != expected:
            raise InputError(f"{path}:1: header mismatch, expected {','.join(expected)}")
        for idx, raw in enumerate(reader, start=2):
            if not raw:
                continue
            if len(raw) != len(expected):
                problems.append(f"{path}:{idx}: expected {len(expected)} columns, got {len(raw)}")
                continue
            row = dict(zip(expected, raw))
            for col in INT_COLS.get(kind, []):
                if row[col] != "":
                    try:
                        row[col] = int(row[col])
                    except ValueError:
                        problems.append(f"{path}:{idx}: {col} is not an integer: {row[col]!r}")
                else:
                    row[col] = None
            for col in FLOAT_COLS.get(kind, []):
                if row[col] != "":
                    try:
                        row[col] = float(row[col])
                    except ValueError:
                        problems.append(f"{path}:{idx}: {col} is not a number: {row[col]!r}")
                else:
                    row[col] = None
            for col, allowed in ENUMS[kind].items():
                if row[col] not in allowed:
                    problems.append(f"{path}:{idx}: {col}={row[col]!r} not in {sorted(allowed)}")
            if kind == "cost-listmodel" and row["label"] != LISTMODEL_LABEL:
                problems.append(f"{path}:{idx}: label must be {LISTMODEL_LABEL!r}")
            if scaler and row["scaler"] != scaler:
                problems.append(f"{path}:{idx}: scaler={row['scaler']!r} in a {scaler} file")
            rows.append(row)
    if problems:
        raise InputError("\n".join(problems))
    return rows


def stats(values):
    values = [v for v in values if v is not None]
    if not values:
        return {"median": None, "min": None, "max": None, "n": 0}
    med = statistics.median(values)
    if float(med).is_integer():
        med = int(med)
    else:
        med = round(med, 2)
    return {"median": med, "min": min(values), "max": max(values), "n": len(values)}


def window_hours(window):
    m = re.fullmatch(r"(\d+)([mhd])", window or "")
    if not m:
        return None
    n, unit = int(m.group(1)), m.group(2)
    return n / 60 if unit == "m" else n if unit == "h" else n * 24


def probe_counts(log_path, start, end):
    total = failed = 0
    with log_path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2 or not parts[0].isdigit():
                continue
            epoch = int(parts[0])
            if not (start <= epoch <= end):
                continue
            total += 1
            if not re.fullmatch(r"2\d\d", parts[1]):
                failed += 1
    return total, failed


def summarise_scaler(scaler, data, input_dir):
    scaleup = [r for r in data["scaleup"] if r["rep"] is not None and r["rep"] >= 1 and r["outcome"] == "ok"]
    chaos = [r for r in data["chaos"] if r["rep"] is not None and r["rep"] >= 1 and r["outcome"] == "ok"]

    cost = {"kind": "estimate", "opencost_per_hour_usd": None, "listmodel_per_hour_usd": None, "monthly_estimate_usd": None}
    ns_rows = [r for r in data["cost"] if r["source"] == NAMESPACE_SOURCE]
    if ns_rows:
        latest = max(r["run_id"] for r in ns_rows)
        used = [r for r in ns_rows if r["run_id"] == latest]
        if all(r["cost_per_hour_usd"] is not None for r in used):
            cost["opencost_per_hour_usd"] = round(sum(r["cost_per_hour_usd"] for r in used), 4)
        if all(r["monthly_estimate_usd"] is not None for r in used):
            cost["monthly_estimate_usd"] = round(sum(r["monthly_estimate_usd"] for r in used), 2)
        hours = window_hours(used[0]["window"])
        lm = [r for r in data["cost-listmodel"] if r["run_id"] == latest]
        if lm and hours and all(r["cost_usd"] is not None for r in lm):
            total = sum(r["cost_usd"] + (r["automode_fee_usd"] or 0.0) for r in lm)
            cost["listmodel_per_hour_usd"] = round(total / hours, 4)

    modes = sorted({r["mode"] for r in chaos})
    total = failed = 0
    for r in chaos:
        if r["window_start_epoch"] is None or r["window_end_epoch"] is None or not r["probe_log"]:
            raise InputError(f"chaos run {r['run_id']} ({scaler}): window or probe_log missing")
        log_path = (input_dir / r["probe_log"]).resolve()
        if input_dir.resolve() not in log_path.parents or not log_path.is_file():
            raise InputError(f"chaos run {r['run_id']} ({scaler}): probe log not found inside {input_dir}: {r['probe_log']}")
        t, f = probe_counts(log_path, r["window_start_epoch"], r["window_end_epoch"])
        total += t
        failed += f
    have_probe = bool(chaos)
    chaos_block = {
        "mode": None if not modes else (modes[0] if len(modes) == 1 else "mixed"),
        "recovery_s": stats([r["recovery_s"] for r in chaos]),
        "probe_total": total if have_probe else None,
        "probe_failed": failed if have_probe else None,
        "probe_failed_pct": (round(100.0 * failed / total, 2) if have_probe and total else None),
    }
    scaleup_block = {
        "node_provision_s": stats([r["node_provision_s"] for r in scaleup]),
        "all_pods_running_s": stats([r["all_pods_running_s"] for r in scaleup]),
    }
    flags = (scaleup_block["node_provision_s"]["n"] >= 1, chaos_block["recovery_s"]["n"] >= 1)
    status = "MEASURED" if all(flags) else "PARTIAL" if any(flags) else "TARGET"
    return {"status": status, "scaleup": scaleup_block, "cost": cost, "chaos": chaos_block}


def parse_meta(items):
    meta = {}
    for item in items or []:
        if "=" not in item:
            raise InputError(f"--meta expects KEY=VALUE, got {item!r}")
        key, value = item.split("=", 1)
        if key == "synthetic":
            raise InputError("meta.synthetic is derived from the run ids and cannot be set by hand")
        try:
            meta[key] = json.loads(value)
        except json.JSONDecodeError:
            meta[key] = value
    return meta


def cell_time(metric, synthetic):
    if metric["n"] < 1:
        return "TARGET: ___ s (điền sau khi đo)"
    text = f"{metric['median']} s (min {metric['min']}, max {metric['max']}, n={metric['n']})"
    return ("SYNTHETIC " if synthetic else "") + text


def render_markdown(summary):
    syn = summary["meta"]["synthetic"]
    lines = ["# Kết quả (tự sinh bởi fill_results.py, không sửa tay)", ""]
    if syn:
        lines += ["> **SYNTHETIC: dữ liệu giả để kiểm thử. Không dùng cho slide hay báo cáo.**", ""]
    lines += [
        "> `TARGET` = chưa đo; ô `TARGET: ___ s` / `Đo: ___` là chỗ trống chờ số đo thật. "
        "Chi phí luôn là **ước tính theo giá list** (kind=estimate), không phải số đo.",
        f"> {summary['meta']['note']}.",
        "",
        "| Scaler | Trạng thái | Node provision | Pod chạy hết | Phục hồi khi mất node | Request lỗi trong cửa sổ | Chi phí/giờ (ước tính) |",
        "|---|---|---|---|---|---|---|",
    ]
    for name in SCALERS:
        s = summary["scalers"][name]
        pct = s["chaos"]["probe_failed_pct"]
        pct_cell = "Đo: ___" if pct is None else (("SYNTHETIC " if syn else "") + f"{pct}% ({s['chaos']['probe_failed']}/{s['chaos']['probe_total']})")
        cph = s["cost"]["opencost_per_hour_usd"]
        cost_cell = "Ước tính (OpenCost, giá list): $___/giờ" if cph is None else ("SYNTHETIC " if syn else "") + f"Ước tính (OpenCost, giá list): ${cph}/giờ"
        lines.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            name, s["status"], cell_time(s["scaleup"]["node_provision_s"], syn), cell_time(s["scaleup"]["all_pods_running_s"], syn),
            cell_time(s["chaos"]["recovery_s"], syn), pct_cell, cost_cell))
    lines += ["", "Mode phá node: " + ", ".join(f"{n}={summary['scalers'][n]['chaos']['mode'] or '___'}" for n in SCALERS), ""]
    return "\n".join(lines)


def build_summary(input_dir, prefix, meta_overrides):
    data = {s: {} for s in SCALERS}
    run_ids = set()
    for s in SCALERS:
        data[s]["scaleup"] = read_csv(input_dir / f"{prefix}scaleup-{s}.csv", "scaleup", s)
        data[s]["cost"] = read_csv(input_dir / f"{prefix}cost-{s}.csv", "cost", s)
        data[s]["chaos"] = read_csv(input_dir / f"{prefix}chaos-{s}.csv", "chaos", s)
        data[s]["cost-listmodel"] = []
    listmodel = read_csv(input_dir / f"{prefix}cost-listmodel.csv", "cost-listmodel")
    for r in listmodel:
        if r["scaler"] not in data:
            raise InputError(f"cost-listmodel: unknown scaler {r['scaler']!r}")
        data[r["scaler"]]["cost-listmodel"].append(r)
    for s in SCALERS:
        for kind in ("scaleup", "cost", "chaos", "cost-listmodel"):
            run_ids.update(r["run_id"] for r in data[s][kind])
    synthetic = [r for r in run_ids if r.startswith(SYNTHETIC_PREFIX)]
    if synthetic and len(synthetic) != len(run_ids):
        raise InputError("mixed synthetic and real run ids in one input set")
    meta = dict(DEFAULT_META)
    meta.update(meta_overrides)
    meta["synthetic"] = bool(synthetic)
    summary = {"schema_version": 1, "meta": meta, "scalers": {s: summarise_scaler(s, data[s], input_dir) for s in SCALERS}}
    return summary


def under(path, root):
    path, root = path.resolve(), root.resolve()
    return path == root or root in path.parents


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--input-dir", type=Path, default=RESULTS_DIR)
    ap.add_argument("--out", type=Path, default=None, help="directory for summary.json and RESULTS.md (default: input dir)")
    ap.add_argument("--prefix", default="", help="file name prefix of the input CSVs (fixtures use SYNTHETIC-)")
    ap.add_argument("--meta", action="append", help="KEY=VALUE override of a meta field (repeatable)")
    args = ap.parse_args(argv)
    input_dir = args.input_dir.resolve()
    out = (args.out or args.input_dir).resolve()
    try:
        summary = build_summary(input_dir, args.prefix, parse_meta(args.meta))
        if summary["meta"]["synthetic"] and not under(out, Path("/tmp")):
            raise InputError(f"synthetic data (run_id SYNTHETIC-*) may only be written below /tmp, not {out}")
        if summary["meta"]["synthetic"] and under(out, RESULTS_DIR):
            raise InputError("synthetic data can never be written under results/")
    except InputError as exc:
        print(f"fill_results.py: {exc}", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "RESULTS.md").write_text(render_markdown(summary), encoding="utf-8")
    print(f"wrote {out / 'summary.json'} and {out / 'RESULTS.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
