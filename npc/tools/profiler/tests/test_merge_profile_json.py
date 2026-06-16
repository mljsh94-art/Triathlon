#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_merge_module():
    mod_path = Path(__file__).resolve().parents[1] / "merge_profile_json.py"
    spec = importlib.util.spec_from_file_location("merge_profile_json", mod_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {mod_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class MergeProfileJsonTest(unittest.TestCase):
    def test_merge_run_dir_success(self):
        mod = load_merge_module()
        fixture = Path(__file__).resolve().parent / "fixtures" / "minimal_bench.json"
        bench_obj = json.loads(fixture.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td)
            (run_dir / "dhrystone.json").write_text(json.dumps(bench_obj), encoding="utf-8")
            (run_dir / "coremark.json").write_text(json.dumps(bench_obj), encoding="utf-8")
            (run_dir / "microbench.json").write_text(json.dumps(bench_obj), encoding="utf-8")
            summary = mod.merge_run_dir(run_dir)
        self.assertIn("dhrystone", summary)
        self.assertIn("coremark", summary)
        self.assertIn("microbench", summary)
        self.assertEqual(summary["dhrystone"]["ipc"], 0.5)

    def test_merge_run_dir_missing_file(self):
        mod = load_merge_module()
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td)
            with self.assertRaises(FileNotFoundError):
                mod.merge_run_dir(run_dir)


if __name__ == "__main__":
    unittest.main()
