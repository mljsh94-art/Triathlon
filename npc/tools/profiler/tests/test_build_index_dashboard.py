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
        bench = json.loads(
            (Path(__file__).resolve().parent / "fixtures" / "minimal_bench.json").read_text(
                encoding="utf-8"
            )
        )
        bench["kpi"]["ipc"] = ipc
        bench["kpi"]["cpi"] = 1.0 / ipc if ipc else 0.0
        bench["kpi"]["commits"] = int(1000 * ipc)
        bench["predict"]["retire_miss_rate"] = {
            "cond": 0.1,
            "jump": 0.2,
            "ret": 0.05,
            "jump_direct": 0.0,
            "jump_indirect": 0.0,
        }
        bench["predict"]["bpu_train"]["cond_selected_accuracy"] = 0.975
        bench["predict"]["tage"]["table_hit_rate"] = 0.93
        summary = {"schema_version": 2, "coremark": bench, "microbench": bench}
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
            self.assertIn("coremark IPC", html)
            self.assertIn("coremark MKPI", html)
            self.assertNotIn("dhrystone IPC", html)
            self.assertIn("../baseline/summary.html", html)
            self.assertIn("查看完整报告", html)
            self.assertNotIn("file://", html)
            report = root / "baseline" / "summary.html"
            self.assertTrue(report.exists())
            report_text = report.read_text(encoding="utf-8")
            self.assertIn("性能分析报告 - baseline", report_text)
            self.assertIn("Stall 八大类", report_text)
            self.assertIn("KPI · 总体性能", report_text)
            self.assertIn("MKPI", report_text)
            self.assertIn("Direction acc (commit)", html)
            self.assertIn("Top stall", html)
            self.assertIn("1/10", html)
            self.assertIn("分/总", report_text)
            acc = index["runs"][0]["predict_accuracy"]["coremark"]["cond_selected"]
            self.assertAlmostEqual(acc, 0.975)

    def test_build_index_flat_layout(self):
        index_mod = load_module("build_index")
        dash_mod = load_module("build_dashboard")
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bench = json.loads(
                (Path(__file__).resolve().parent / "fixtures" / "minimal_bench.json").read_text(
                    encoding="utf-8"
                )
            )
            bench["kpi"]["ipc"] = 0.42
            bench["kpi"]["cpi"] = 1.0 / 0.42
            bench["kpi"]["commits"] = 420
            bench["predict"]["retire_miss_rate"] = {
                "cond": 0.1,
                "jump": 0.2,
                "ret": 0.05,
                "jump_direct": 0.0,
                "jump_indirect": 0.0,
            }
            bench["predict"]["bpu_train"]["cond_selected_accuracy"] = 0.975
            bench["predict"]["tage"]["table_hit_rate"] = 0.93
            (root / "summary.json").write_text(
                json.dumps({"schema_version": 2, "coremark": bench, "microbench": bench}),
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
