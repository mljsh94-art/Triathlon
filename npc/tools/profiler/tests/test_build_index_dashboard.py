#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_module(name: str):
    mod_path = Path(__file__).resolve().parents[1] / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, mod_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {mod_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BuildIndexDashboardTest(unittest.TestCase):
    def _write_run(self, root: Path, run_id: str, ipc: float) -> None:
        run_dir = root / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        bench = {
            "ipc": ipc,
            "cpi": 1.0 / ipc if ipc else 0.0,
            "cycles": 1000,
            "commits": int(1000 * ipc),
            "stall_total": 100,
            "stall_category": {
                "frontend_empty": 40,
                "rob_backpressure": 30,
                "lsu_req_blocked": 10,
            },
            "predict": {"cond_miss_rate": 0.1, "jump_miss_rate": 0.2, "ret_miss_rate": 0.05},
        }
        summary = {"dhrystone": bench, "coremark": bench}
        (run_dir / "summary.json").write_text(json.dumps(summary), encoding="utf-8")
        (run_dir / "metadata.json").write_text(
            json.dumps({"run_id": run_id, "created_at": f"2026-06-05T12:00:00+00:00", "git_sha": "abc123"}),
            encoding="utf-8",
        )

    def test_build_index_and_dashboard(self):
        index_mod = load_module("build_index")
        dash_mod = load_module("build_dashboard")
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._write_run(root, "baseline", 0.5)
            self._write_run(root, "run2", 0.48)
            index = index_mod.build_index(root)
            self.assertEqual(len(index["runs"]), 2)
            index_path = root / "index.json"
            index_path.write_text(json.dumps(index), encoding="utf-8")
            script_dir = Path(__file__).resolve().parents[1]
            dash_mod.write_all_summary_pages(root, index)
            html = dash_mod.render_dashboard(root, script_dir)
            self.assertIn("Triathlon Profile Dashboard", html)
            self.assertIn("run2", html)
            self.assertIn("dhrystone IPC", html)
            self.assertIn("../baseline/summary.html", html)
            self.assertIn("查看完整报告", html)
            self.assertNotIn("file://", html)
            report = root / "baseline" / "summary.html"
            self.assertTrue(report.exists())
            report_text = report.read_text(encoding="utf-8")
            self.assertIn("性能分析报告 - baseline", report_text)
            self.assertIn("Stall 分类", report_text)

    def test_build_index_flat_layout(self):
        index_mod = load_module("build_index")
        dash_mod = load_module("build_dashboard")
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bench = {
                "ipc": 0.42,
                "cpi": 1.0 / 0.42,
                "cycles": 1000,
                "commits": 420,
                "stall_total": 100,
                "stall_category": {
                    "frontend_empty": 40,
                    "rob_backpressure": 30,
                    "lsu_req_blocked": 10,
                },
                "predict": {"cond_miss_rate": 0.1, "jump_miss_rate": 0.2, "ret_miss_rate": 0.05},
            }
            (root / "summary.json").write_text(
                json.dumps({"dhrystone": bench, "coremark": bench}),
                encoding="utf-8",
            )
            (root / "metadata.json").write_text(
                json.dumps({"run_id": "profile", "created_at": "2026-06-05T13:00:00+00:00", "git_sha": "def456"}),
                encoding="utf-8",
            )
            index = index_mod.build_index(root)
            self.assertEqual(len(index["runs"]), 1)
            self.assertEqual(index["runs"][0]["run_id"], "profile")
            (root / "index.json").write_text(json.dumps(index), encoding="utf-8")
            script_dir = Path(__file__).resolve().parents[1]
            dash_mod.write_all_summary_pages(root, index)
            html = dash_mod.render_dashboard(root, script_dir)
            self.assertIn("profile", html)
            self.assertIn("0.4200", html)
            self.assertIn("../summary.html", html)
            self.assertNotIn("file://", html)


if __name__ == "__main__":
    unittest.main()
