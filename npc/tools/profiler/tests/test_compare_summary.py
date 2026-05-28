#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_compare_module():
    mod_path = Path(__file__).resolve().parents[1] / "compare_summary.py"
    spec = importlib.util.spec_from_file_location("compare_summary", mod_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load module from {mod_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write_summary(path: Path, d_ipc, d_cpi, d_cycles, c_ipc, c_cpi, c_cycles,
                  d_stalls=None, c_stalls=None):
    d_stalls = d_stalls or {}
    c_stalls = c_stalls or {}

    path.write_text(
        json.dumps(
            {
                "dhrystone": {
                    "ipc": d_ipc,
                    "cpi": d_cpi,
                    "cycles": d_cycles,
                    "stall_total": 1000,
                    "stall_category": d_stalls,
                },
                "coremark": {
                    "ipc": c_ipc,
                    "cpi": c_cpi,
                    "cycles": c_cycles,
                    "stall_total": 1000,
                    "stall_category": c_stalls,
                },
            }
        ),
        encoding="utf-8",
    )


class CompareSummaryTest(unittest.TestCase):
    def test_compare_summary_pass_and_warn(self):
        mod = load_compare_module()
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            base = td_path / "base.json"
            cur = td_path / "cur.json"
            write_summary(base, 1.0, 1.0, 1000, 1.0, 1.0, 1000,
                          d_stalls={"frontend_empty": 100},
                          c_stalls={"frontend_empty": 100})
            # ipc -4% (warn), cpi +4% (warn), cycles +6% (warn)
            write_summary(cur, 0.96, 1.04, 1060, 0.96, 1.04, 1060,
                          d_stalls={"frontend_empty": 160},
                          c_stalls={"frontend_empty": 160})

            result = mod.compare_summary_files(base, cur)

        self.assertEqual(result["status"], "warn")
        self.assertEqual(len(result["failures"]), 0)
        self.assertGreater(len(result["warnings"]), 0)

    def test_compare_summary_fail_thresholds(self):
        mod = load_compare_module()
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            base = td_path / "base.json"
            cur = td_path / "cur.json"
            write_summary(base, 1.0, 1.0, 1000, 1.0, 1.0, 1000,
                          d_stalls={"frontend_empty": 100, "lsu_req_blocked": 100, "rob_backpressure": 100},
                          c_stalls={"frontend_empty": 100, "lsu_req_blocked": 100, "rob_backpressure": 100})
            # ipc -6% (fail), cpi +6% (fail), cycles +9% (fail), stall +9pp (fail)
            write_summary(cur, 0.94, 1.06, 1090, 0.94, 1.06, 1090,
                          d_stalls={"frontend_empty": 190, "lsu_req_blocked": 190, "rob_backpressure": 190},
                          c_stalls={"frontend_empty": 190, "lsu_req_blocked": 190, "rob_backpressure": 190})

            result = mod.compare_summary_files(base, cur)

        self.assertEqual(result["status"], "fail")
        self.assertGreater(len(result["failures"]), 0)

    def test_compare_summary_stall_share_delta(self):
        mod = load_compare_module()
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            base = td_path / "base.json"
            cur = td_path / "cur.json"
            write_summary(base, 1.0, 1.0, 1000, 1.0, 1.0, 1000,
                          d_stalls={"frontend_empty": 100},
                          c_stalls={"frontend_empty": 100})
            # stall share +6pp => warn
            write_summary(cur, 1.0, 1.0, 1000, 1.0, 1.0, 1000,
                          d_stalls={"frontend_empty": 160},
                          c_stalls={"frontend_empty": 160})

            result = mod.compare_summary_files(base, cur)

        self.assertEqual(result["status"], "warn")
        self.assertTrue(any("stall" in x.lower() for x in result["warnings"]))


if __name__ == "__main__":
    unittest.main()
