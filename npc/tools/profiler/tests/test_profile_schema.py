#!/usr/bin/env python3
import importlib.util
import json
import sys
import unittest
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def load_module(name: str):
    mod_path = Path(__file__).resolve().parents[1] / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, mod_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {mod_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(mod_path.parent))
    spec.loader.exec_module(mod)
    return mod


class ProfileSchemaTest(unittest.TestCase):
    def test_v2_fixture_accessors(self):
        schema = load_module("profile_schema")
        bench = json.loads((FIXTURES / "minimal_bench.json").read_text(encoding="utf-8"))
        self.assertTrue(schema.is_v2_bench(bench))
        self.assertAlmostEqual(schema.bench_ipc(bench), 0.5)
        self.assertEqual(schema.bench_stall_total(bench), 46)
        self.assertEqual(schema.bench_stall_category(bench)["frontend_empty"], 20)
        self.assertEqual(schema.bench_stall_detail(bench, "frontend_empty")["fe_wait_ibuffer_consume"], 20)
        self.assertEqual(schema.bench_stall_section_total(bench, "decode_blocked"), 5)
        self.assertEqual(
            schema.predict_miss_part_totals(bench["predict"], bench["flush"])["cond_miss_rate"],
            (1.0, 10.0),
        )
        self.assertEqual(len(schema.bench_hotspots(bench)["top_pc"]), 1)

    def test_v1_flat_fallback(self):
        schema = load_module("profile_schema")
        bench = {
            "ipc": 0.9,
            "cpi": 1.1,
            "cycles": 100,
            "commits": 90,
            "stall_total": 50,
            "stall_category": {"other": 30, "decode_blocked": 20},
            "stall_decode_blocked_detail": {"st_alloc_blocked": 20},
            "predict": {"cond_miss_rate": 0.05},
        }
        self.assertFalse(schema.is_v2_bench(bench))
        self.assertAlmostEqual(schema.bench_ipc(bench), 0.9)
        self.assertEqual(schema.bench_stall_detail(bench, "decode_blocked")["st_alloc_blocked"], 20)


if __name__ == "__main__":
    unittest.main()
