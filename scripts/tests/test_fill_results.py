#!/usr/bin/env python3
"""Tests for fill_results.py (design AC11). stdlib only; fixtures are SYNTHETIC-* and never leave /tmp."""
import csv
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
RESULTS = SCRIPTS.parent / "results"
FIXTURES = HERE / "fixtures"
FILL = SCRIPTS / "fill_results.py"
SCALERS = ("ca", "karpenter", "automode")


def run_fill(*args):
    return subprocess.run([sys.executable, str(FILL), *args], capture_output=True, text=True)


def validate(instance, schema, root, path="$"):
    """Tiny JSON Schema subset validator (type, const, enum, required, properties, additionalProperties, $ref, min/max)."""
    errors = []
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return validate(instance, node, root, path)
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {instance!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} not in {schema['enum']}")
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        py = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None), "integer": int, "number": (int, float)}
        ok = any(isinstance(instance, py[t]) and not (t in ("integer", "number") and isinstance(instance, bool)) for t in types)
        if not ok:
            errors.append(f"{path}: type {type(instance).__name__} not in {types}")
            return errors
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: {instance} < minimum")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: {instance} > maximum")
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required {key}")
        props = schema.get("properties", {})
        for key, value in instance.items():
            if key in props:
                errors += validate(value, props[key], root, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unexpected property {key}")
    return errors


def all_numbers(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from all_numbers(v)
    elif isinstance(node, bool):
        return
    elif isinstance(node, (int, float)):
        yield node


class EmptyTemplates(unittest.TestCase):
    def test_committed_templates_are_header_only(self):
        for name in ("scaleup", "cost", "cost-listmodel", "chaos"):
            lines = (RESULTS / "templates" / f"{name}.csv").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 1, f"{name}.csv must contain only the header")

    def test_template_headers_match_the_reader_contract(self):
        sys.path.insert(0, str(SCRIPTS))
        import fill_results
        for name in ("scaleup", "cost", "cost-listmodel", "chaos"):
            header = (RESULTS / "templates" / f"{name}.csv").read_text(encoding="utf-8").strip().split(",")
            self.assertEqual(header, fill_results.SCHEMAS[name])
            self.assertEqual(fill_results.read_csv(RESULTS / "templates" / f"{name}.csv", name), [])

    def test_empty_input_gives_all_target_and_null(self):
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(RESULTS / "templates", Path(tmp) / "in")
            proc = run_fill("--input-dir", str(Path(tmp) / "in"), "--out", tmp)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            summary = json.loads((Path(tmp) / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(list(summary["scalers"]), list(SCALERS))
        for name in SCALERS:
            s = summary["scalers"][name]
            self.assertEqual(s["status"], "TARGET")
            self.assertEqual(s["cost"]["kind"], "estimate")
            self.assertEqual(list(all_numbers({k: v for k, v in s.items() if k != "status"})), [0, 0, 0])  # only the three n == 0
        self.assertFalse(summary["meta"]["synthetic"])

    def test_committed_summary_is_all_target_and_matches_schema(self):
        summary = json.loads((RESULTS / "summary.json").read_text(encoding="utf-8"))
        schema = json.loads((RESULTS / "schema" / "summary.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(validate(summary, schema, schema), [])
        for name in SCALERS:
            self.assertEqual(summary["scalers"][name]["status"], "TARGET")
            self.assertEqual(sum(1 for _ in all_numbers(summary["scalers"][name])), 3, "only the n=0 counters are numbers")
        self.assertFalse(summary["meta"]["synthetic"])
        md = (RESULTS / "RESULTS.md").read_text(encoding="utf-8")
        self.assertIn("TARGET: ___ s (điền sau khi đo)", md)
        self.assertNotIn("SYNTHETIC", md)

    def test_schema_pins_cost_kind_to_estimate(self):
        schema = json.loads((RESULTS / "schema" / "summary.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(schema["$defs"]["scaler"]["properties"]["cost"]["properties"]["kind"]["const"], "estimate")
        bad = json.loads((RESULTS / "summary.json").read_text(encoding="utf-8"))
        bad["scalers"]["ca"]["cost"]["kind"] = "observed"
        self.assertTrue(validate(bad, schema, schema), "cost.kind=observed must be rejected by the schema")


class FixtureRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="fill-results-test-")
        proc = run_fill("--input-dir", str(FIXTURES), "--prefix", "SYNTHETIC-", "--out", cls.tmp)
        assert proc.returncode == 0, proc.stderr
        cls.summary = json.loads((Path(cls.tmp) / "summary.json").read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_medians_and_n_exclude_cold_rep_and_timeouts(self):
        ca = self.summary["scalers"]["ca"]["scaleup"]
        self.assertEqual(ca["node_provision_s"], {"median": 70, "min": 60, "max": 80, "n": 3})
        self.assertEqual(ca["all_pods_running_s"], {"median": 90, "min": 80, "max": 100, "n": 3})
        kp = self.summary["scalers"]["karpenter"]["scaleup"]
        self.assertEqual(kp["node_provision_s"], {"median": 35.5, "min": 31, "max": 40, "n": 2})

    def test_chaos_recovery_and_probe_metrics_come_from_raw_logs(self):
        chaos = self.summary["scalers"]["ca"]["chaos"]
        self.assertEqual(chaos["recovery_s"], {"median": 100, "min": 90, "max": 110, "n": 2})
        self.assertEqual(chaos["mode"], "terminate")
        # window 1: 20 lines, 5 failed; window 2: 10 lines, 2 failed; lines outside the windows and garbage are ignored
        self.assertEqual((chaos["probe_total"], chaos["probe_failed"], chaos["probe_failed_pct"]), (30, 7, 23.33))

    def test_status_rule(self):
        self.assertEqual(self.summary["scalers"]["ca"]["status"], "MEASURED")
        self.assertEqual(self.summary["scalers"]["karpenter"]["status"], "PARTIAL")
        am = self.summary["scalers"]["automode"]
        self.assertEqual(am["status"], "TARGET")
        self.assertIsNone(am["scaleup"]["node_provision_s"]["median"])
        self.assertEqual(am["scaleup"]["node_provision_s"]["n"], 0)

    def test_cost_is_estimate_uses_latest_run_and_never_changes_status(self):
        ca = self.summary["scalers"]["ca"]["cost"]
        self.assertEqual(ca["kind"], "estimate")
        self.assertEqual(ca["opencost_per_hour_usd"], 0.12)  # latest run, namespace rows only (not 0.5, not the label row)
        self.assertEqual(ca["listmodel_per_hour_usd"], 0.198)
        km = self.summary["scalers"]["karpenter"]
        self.assertIsNone(km["cost"]["listmodel_per_hour_usd"])
        self.assertEqual(km["status"], "PARTIAL")

    def test_synthetic_flag_and_markdown_banner(self):
        self.assertTrue(self.summary["meta"]["synthetic"])
        md = (Path(self.tmp) / "RESULTS.md").read_text(encoding="utf-8")
        self.assertIn("SYNTHETIC", md)

    def test_output_matches_schema_and_committed_fixture(self):
        schema = json.loads((RESULTS / "schema" / "summary.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(validate(self.summary, schema, schema), [])
        committed = json.loads((FIXTURES / "SYNTHETIC-summary.json").read_text(encoding="utf-8"))
        self.assertEqual(committed, self.summary, "tests/fixtures/SYNTHETIC-summary.json is stale: regenerate it")
        self.assertTrue(committed["meta"]["synthetic"])


class SyntheticGuard(unittest.TestCase):
    def test_refuses_to_write_under_demo_results(self):
        before = sorted(p.name for p in RESULTS.iterdir())
        proc = run_fill("--input-dir", str(FIXTURES), "--prefix", "SYNTHETIC-", "--out", str(RESULTS))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("/tmp", proc.stderr)
        self.assertEqual(sorted(p.name for p in RESULTS.iterdir()), before)
        self.assertFalse(json.loads((RESULTS / "summary.json").read_text(encoding="utf-8"))["meta"]["synthetic"])

    def test_refuses_default_output_dir_for_synthetic_input(self):
        with tempfile.TemporaryDirectory(dir=str(HERE)) as tmp:  # a dir NOT under /tmp
            for f in FIXTURES.glob("SYNTHETIC-*"):
                if f.is_file():
                    shutil.copy(f, tmp)
            shutil.copytree(FIXTURES / "raw", Path(tmp) / "raw")
            proc = run_fill("--input-dir", tmp, "--prefix", "SYNTHETIC-")
            self.assertEqual(proc.returncode, 1)
            self.assertFalse((Path(tmp) / "summary.json").exists())

    def test_refuses_out_dir_outside_tmp(self):
        proc = run_fill("--input-dir", str(FIXTURES), "--prefix", "SYNTHETIC-", "--out", str(HERE / "should-not-exist"))
        self.assertEqual(proc.returncode, 1)
        self.assertFalse((HERE / "should-not-exist").exists())

    def test_meta_synthetic_cannot_be_set_by_hand(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = run_fill("--input-dir", str(RESULTS / "templates"), "--out", tmp, "--meta", "synthetic=false")
            self.assertEqual(proc.returncode, 1)


class InvalidInput(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fill-results-bad-"))
        shutil.copytree(FIXTURES, self.tmp / "in")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_header_mismatch_names_file_and_line(self):
        path = self.tmp / "in" / "SYNTHETIC-scaleup-ca.csv"
        path.write_text(path.read_text(encoding="utf-8").replace("run_id,", "runid,", 1), encoding="utf-8")
        proc = run_fill("--input-dir", str(self.tmp / "in"), "--prefix", "SYNTHETIC-", "--out", str(self.tmp / "out"))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("SYNTHETIC-scaleup-ca.csv:1", proc.stderr)

    def test_non_numeric_cell_names_file_and_line(self):
        path = self.tmp / "in" / "SYNTHETIC-scaleup-ca.csv"
        with path.open(encoding="utf-8") as fh:
            rows = list(csv.reader(fh))
        rows[2][rows[0].index("node_provision_s")] = "fast"
        with path.open("w", newline="", encoding="utf-8") as fh:
            csv.writer(fh, lineterminator="\n").writerows(rows)
        proc = run_fill("--input-dir", str(self.tmp / "in"), "--prefix", "SYNTHETIC-", "--out", str(self.tmp / "out"))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("SYNTHETIC-scaleup-ca.csv:3", proc.stderr)

    def test_cost_row_cannot_claim_observed(self):
        path = self.tmp / "in" / "SYNTHETIC-cost-ca.csv"
        path.write_text(path.read_text(encoding="utf-8").replace(",estimate", ",observed"), encoding="utf-8")
        proc = run_fill("--input-dir", str(self.tmp / "in"), "--prefix", "SYNTHETIC-", "--out", str(self.tmp / "out"))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("kind", proc.stderr)

    def test_mixed_real_and_synthetic_run_ids_are_refused(self):
        path = self.tmp / "in" / "SYNTHETIC-scaleup-karpenter.csv"
        path.write_text(path.read_text(encoding="utf-8").replace("SYNTHETIC-bench-1", "bench-real", 1), encoding="utf-8")
        proc = run_fill("--input-dir", str(self.tmp / "in"), "--prefix", "SYNTHETIC-", "--out", str(self.tmp / "out"))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("mixed", proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
