#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path


def load_parser_module():
    parser_path = Path(__file__).resolve().parents[1] / "parse_profile.py"
    spec = importlib.util.spec_from_file_location("parse_profile", parser_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load parser module from {parser_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ParseProfileTest(unittest.TestCase):
    def test_parse_single_log_basic_metrics(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "dhrystone.log"
            log.write_text(
                "\n".join(
                    [
                        "[flush ] cycle=10 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000000 redirect_pc=0x80000010 miss_type=cond_branch redirect_distance=16 killed_uops=5",
                        "[bru   ] cycle=10 valid=1 pc=0x80000000",
                        "[flushp] cycle=13 reason=branch_mispredict penalty=3",
                        "[flush ] cycle=30 reason=exception source=rob cause=0x2 src_pc=0x80000030 redirect_pc=0x80000100 miss_type=none redirect_distance=208 killed_uops=0",
                        "[flushp] cycle=36 reason=exception penalty=6",
                        "[pred  ] cond_total=5 cond_miss=1 cond_hit=4 jump_total=2 jump_miss=0 jump_hit=2",
                        "[commit] cycle=11 slot=0 pc=0x80000000 inst=0xfe0716e3 we=0 rd=x0 data=0x0 a0=0x0",
                        "[commit] cycle=11 slot=1 pc=0x80000004 inst=0x00100073 we=0 rd=x0 data=0x0 a0=0x0",
                        "[stall ] cycle=25 no_commit=20 fe(v/r/pc)=0/1/0x80000020 dec(v/r)=0/1 rob_ready=1 lsu_ld(v/r/addr)=0/1/0x0 lsu_rsp(v/r)=0/0 lsu_rs(b/r)=0x0/0x0 lsu_rs_head(v/idx/dst)=0/0x0/0x0 lsu_rs_head(rs1r/rs2r/has1/has2)=0/0/0/0 lsu_rs_head(q1/q2/sb)=0x0/0x0/0x0 lsu_rs_head(ld/st)=0/0 sb_alloc(req/ready/fire)=0x0/1/0 sb_dcache(v/r/addr)=0/1/0x0 ic_miss(v/r)=0/1 dc_miss(v/r)=0/1 flush=0 rdir=0x0 rob_head(fu/comp/is_store/pc)=0x1/1/0/0x80000000 rob_cnt=0 rob_ptr(h/t)=0x0/0x0 rob_q2(v/idx/fu/comp/st/pc)=0/0x0/0x0/0/0/0x0 sb(cnt/h/t)=0x0/0x0/0x0 sb_head(v/c/a/d/addr)=0/0/0/0/0x0",
                        "IPC=0.500000 CPI=2.000000 cycles=20 commits=10",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["cycles"], 20)
        self.assertEqual(result["commits"], 10)
        self.assertEqual(result["flush_count"], 2)
        self.assertEqual(result["bru_count"], 1)
        self.assertEqual(result["commit_width_hist"][2], 1)
        self.assertEqual(result["commit_width_hist"][0], 19)
        self.assertEqual(result["stall_category"]["frontend_empty"], 1)
        self.assertEqual(result["mispredict_flush_count"], 1)
        self.assertEqual(result["branch_penalty_cycles"], 3)
        self.assertEqual(result["flush_reason_histogram"]["branch_mispredict"], 1)
        self.assertEqual(result["flush_reason_histogram"]["exception"], 1)
        self.assertEqual(result["flush_source_histogram"]["rob"], 2)
        self.assertEqual(result["wrong_path_kill_uops"], 5)
        self.assertEqual(result["redirect_distance_samples"], 2)
        self.assertEqual(result["redirect_distance_max"], 208)
        self.assertEqual(result["predict"]["cond_total"], 5)
        self.assertEqual(result["predict"]["cond_miss"], 1)
        self.assertEqual(result["predict"]["jump_total"], 2)
        self.assertEqual(result["predict"]["jump_miss"], 0)

    def test_benchmark_time_falls_back_to_host_time_when_self_reported_zero(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "Total time (ms)  : 0",
                        "[src/cpu/cpu-exec.c:104 statistic] host time spent = 263093 us",
                        "IPC=0.500000 CPI=2.000000 cycles=200 commits=100",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["bench_reported_time_ms"], 0.0)
        self.assertEqual(result["host_time_us"], 263093)
        self.assertAlmostEqual(result["host_time_ms"], 263.093)
        self.assertAlmostEqual(result["effective_benchmark_time_ms"], 263.093)
        self.assertEqual(result["benchmark_time_source"], "host_fallback")
        self.assertTrue(any("self-reported time is 0ms" in msg for msg in result["quality_warnings"]))

    def test_parse_log_directory_summary(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            (out / "dhrystone.log").write_text(
                "IPC=0.400000 CPI=2.500000 cycles=100 commits=40\n",
                encoding="utf-8",
            )
            (out / "coremark.log").write_text(
                "[flush ] cycle=30 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000020 redirect_pc=0x80000030 miss_type=jump redirect_distance=16 killed_uops=4\n"
                "[flushp] cycle=36 reason=branch_mispredict penalty=6\n"
                "[bru   ] cycle=30 valid=1 pc=0x80000020\n"
                "[pred  ] cond_total=7 cond_miss=0 cond_hit=7 jump_total=3 jump_miss=1 jump_hit=2\n"
                "IPC=0.500000 CPI=2.000000 cycles=200 commits=100\n",
                encoding="utf-8",
            )

            summary = mod.parse_log_directory(out)

        self.assertIn("dhrystone", summary)
        self.assertIn("coremark", summary)
        self.assertAlmostEqual(summary["coremark"]["flush_per_kinst"], 10.0)
        self.assertAlmostEqual(summary["coremark"]["bru_per_kinst"], 10.0)
        self.assertEqual(summary["coremark"]["mispredict_flush_count"], 1)
        self.assertEqual(summary["coremark"]["branch_penalty_cycles"], 6)
        self.assertEqual(summary["coremark"]["wrong_path_kill_uops"], 4)
        self.assertEqual(summary["coremark"]["predict"]["jump_miss"], 1)

    def test_parse_flush_noise_lines_are_normalized(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "garbage-prefix [flush ] cycle=11 reason=bra===nch_mispredict source=ros) cause=0x0 src_pc=0x80000000 redirect_pc=0x80000010 miss_type=cond_branch redirect_distance=16 killed_uops=5",
                        "[flush ] cycle=20 reason=bs       ranch_mispredict source=rob cause=0x0 src_pc=0x80000010 redirect_pc=0x80000020 miss_type=jump redirect_distance=16 killed_uops=3",
                        "[flush ] cycle=30 reason=exception source=rob cause=0x2 src_pc=0x80000020 redirect_pc=0x80000100 miss_type=none redirect_distance=224 killed_uops=0",
                        "[flushp] cycle=25 reason=branch_mis penalty=5",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        allowed_reason = {"branch_mispredict", "exception", "rob_other", "external", "unknown"}
        allowed_source = {"rob", "external", "unknown"}
        self.assertTrue(set(result["flush_reason_histogram"].keys()).issubset(allowed_reason))
        self.assertTrue(set(result["flush_source_histogram"].keys()).issubset(allowed_source))
        self.assertEqual(result["mispredict_flush_count"], 2)
        self.assertEqual(result["wrong_path_kill_uops"], 8)
        self.assertEqual(result["branch_penalty_cycles"], 5)

    def test_timeout_log_uses_commit_lines_and_timeout_cycles(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark_commit_sample.log"
            log.write_text(
                "\n".join(
                    [
                        "[commit] cycle=98 slot=0 pc=0x80000000 inst=0x00000013 we=1 rd=x1 data=0x1 a0=0x0",
                        "[commit] cycle=99 slot=0 pc=0x80000004 inst=0x00000013 we=1 rd=x2 data=0x2 a0=0x0",
                        "TIMEOUT after 100 cycles",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["cycles"], 100)
        self.assertEqual(result["commits"], 2)
        self.assertAlmostEqual(result["ipc"], 0.02)
        self.assertAlmostEqual(result["cpi"], 50.0)

    def test_report_has_no_recommendations_section(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            template = Path(__file__).resolve().parents[1] / "report_template.md"
            summary = {
                "dhrystone": {
                    "log_path": str(tdir / "dhrystone.log"),
                    "ipc": 0.4,
                    "cpi": 2.5,
                    "cycles": 100,
                    "commits": 40,
                    "flush_per_kinst": 10.0,
                    "bru_per_kinst": 8.0,
                    "commit_width_hist": {0: 60, 1: 20, 2: 10, 3: 5, 4: 5},
                    "stall_category": {},
                    "stall_total": 0,
                    "control": {"control_ratio": 0.2, "est_misp_per_kinst": 15.0},
                    "top_pc": [],
                }
            }
            report = mod.build_markdown_report(summary, template)

        self.assertNotIn("Suggested Next Steps", report)

    def test_parse_predict_breakdown_includes_return_metrics(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=10 cond_miss=4 cond_hit=6 jump_total=6 jump_miss=3 jump_hit=3 ret_total=3 ret_miss=2 ret_hit=1 call_total=5",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["predict"]["ret_total"], 3)
        self.assertEqual(result["predict"]["ret_miss"], 2)
        self.assertEqual(result["predict"]["ret_hit"], 1)
        self.assertAlmostEqual(result["predict"]["ret_miss_rate"], 2 / 3)
        self.assertEqual(result["predict"]["call_total"], 5)

    def test_parse_predict_breakdown_includes_jump_direct_indirect_metrics(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=10 cond_miss=4 cond_hit=6 jump_total=8 jump_miss=3 jump_hit=5 jump_direct_total=5 jump_direct_miss=1 jump_direct_hit=4 jump_indirect_total=3 jump_indirect_miss=2 jump_indirect_hit=1 ret_total=2 ret_miss=1 ret_hit=1 call_total=5",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        pred = result["predict"]
        self.assertEqual(pred["jump_direct_total"], 5)
        self.assertEqual(pred["jump_direct_miss"], 1)
        self.assertEqual(pred["jump_direct_hit"], 4)
        self.assertAlmostEqual(pred["jump_direct_miss_rate"], 0.2)
        self.assertEqual(pred["jump_indirect_total"], 3)
        self.assertEqual(pred["jump_indirect_miss"], 2)
        self.assertEqual(pred["jump_indirect_hit"], 1)
        self.assertAlmostEqual(pred["jump_indirect_miss_rate"], 2 / 3)

    def test_parse_predict_tournament_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=100 cond_miss=20 cond_hit=80 jump_total=6 jump_miss=1 jump_hit=5 ret_total=3 ret_miss=1 ret_hit=2 call_total=9 cond_update_total=100 cond_local_correct=78 cond_global_correct=70 cond_selected_correct=82 cond_choose_local=60 cond_choose_global=40",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        pred = result["predict"]
        self.assertEqual(pred["cond_update_total"], 100)
        self.assertEqual(pred["cond_local_correct"], 78)
        self.assertEqual(pred["cond_global_correct"], 70)
        self.assertEqual(pred["cond_selected_correct"], 82)
        self.assertEqual(pred["cond_choose_local"], 60)
        self.assertEqual(pred["cond_choose_global"], 40)
        self.assertAlmostEqual(pred["cond_local_accuracy"], 0.78)
        self.assertAlmostEqual(pred["cond_global_accuracy"], 0.70)
        self.assertAlmostEqual(pred["cond_selected_accuracy"], 0.82)
        self.assertAlmostEqual(pred["cond_choose_global_ratio"], 0.40)

    def test_parse_predict_tage_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=100 cond_miss=20 cond_hit=80 jump_total=6 jump_miss=1 jump_hit=5 ret_total=3 ret_miss=1 ret_hit=2 call_total=9 tage_lookup_total=90 tage_hit_total=30 tage_override_total=12 tage_override_correct=8",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        pred = result["predict"]
        self.assertEqual(pred["tage_lookup_total"], 90)
        self.assertEqual(pred["tage_hit_total"], 30)
        self.assertEqual(pred["tage_override_total"], 12)
        self.assertEqual(pred["tage_override_correct"], 8)
        self.assertAlmostEqual(pred["tage_hit_rate"], 1 / 3)
        self.assertAlmostEqual(pred["tage_override_ratio"], 12 / 90)
        self.assertAlmostEqual(pred["tage_override_accuracy"], 2 / 3)

    def test_parse_predict_sc_l_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=100 cond_miss=20 cond_hit=80 jump_total=6 jump_miss=1 jump_hit=5 ret_total=3 ret_miss=1 ret_hit=2 call_total=9 sc_lookup_total=80 sc_confident_total=20 sc_override_total=12 sc_override_correct=9",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        pred = result["predict"]
        self.assertEqual(pred["sc_lookup_total"], 80)
        self.assertEqual(pred["sc_confident_total"], 20)
        self.assertEqual(pred["sc_override_total"], 12)
        self.assertEqual(pred["sc_override_correct"], 9)
        self.assertAlmostEqual(pred["sc_confident_ratio"], 0.25)
        self.assertAlmostEqual(pred["sc_override_ratio"], 12 / 80)
        self.assertAlmostEqual(pred["sc_override_accuracy"], 0.75)

    def test_parse_predict_loop_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=100 cond_miss=20 cond_hit=80 jump_total=6 jump_miss=1 jump_hit=5 ret_total=3 ret_miss=1 ret_hit=2 call_total=9 loop_lookup_total=50 loop_hit_total=40 loop_confident_total=12 loop_override_total=10 loop_override_correct=7",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        pred = result["predict"]
        self.assertEqual(pred["loop_lookup_total"], 50)
        self.assertEqual(pred["loop_hit_total"], 40)
        self.assertEqual(pred["loop_confident_total"], 12)
        self.assertEqual(pred["loop_override_total"], 10)
        self.assertEqual(pred["loop_override_correct"], 7)
        self.assertAlmostEqual(pred["loop_hit_rate"], 0.8)
        self.assertAlmostEqual(pred["loop_confident_ratio"], 0.24)
        self.assertAlmostEqual(pred["loop_override_ratio"], 0.2)
        self.assertAlmostEqual(pred["loop_override_accuracy"], 0.7)

    def test_parse_predict_provider_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=100 cond_miss=20 cond_hit=80 "
                        "cond_update_total=90 cond_selected_correct=72 "
                        "cond_provider_legacy_selected=45 cond_provider_tage_selected=20 cond_provider_sc_selected=15 cond_provider_loop_selected=10 "
                        "cond_provider_legacy_correct=33 cond_provider_tage_correct=18 cond_provider_sc_correct=12 cond_provider_loop_correct=9 "
                        "cond_selected_wrong_alt_legacy_correct=6 cond_selected_wrong_alt_tage_correct=4 cond_selected_wrong_alt_sc_correct=3 cond_selected_wrong_alt_loop_correct=2 cond_selected_wrong_alt_any_correct=10 "
                        "jump_total=0 jump_miss=0 ret_total=0 ret_miss=0 call_total=0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        pred = result["predict"]
        self.assertEqual(pred["cond_provider_legacy_selected"], 45)
        self.assertEqual(pred["cond_provider_tage_selected"], 20)
        self.assertEqual(pred["cond_provider_sc_selected"], 15)
        self.assertEqual(pred["cond_provider_loop_selected"], 10)
        self.assertEqual(pred["cond_provider_total_selected"], 90)
        self.assertEqual(pred["cond_provider_legacy_correct"], 33)
        self.assertEqual(pred["cond_provider_tage_correct"], 18)
        self.assertEqual(pred["cond_provider_sc_correct"], 12)
        self.assertEqual(pred["cond_provider_loop_correct"], 9)
        self.assertAlmostEqual(pred["cond_provider_legacy_accuracy"], 33 / 45)
        self.assertAlmostEqual(pred["cond_provider_tage_accuracy"], 18 / 20)
        self.assertAlmostEqual(pred["cond_provider_sc_accuracy"], 12 / 15)
        self.assertAlmostEqual(pred["cond_provider_loop_accuracy"], 9 / 10)
        self.assertAlmostEqual(pred["cond_provider_coverage"], 1.0)
        self.assertAlmostEqual(pred["cond_provider_tage_share"], 20 / 90)
        self.assertEqual(pred["cond_selected_wrong_total"], 18)
        self.assertEqual(pred["cond_selected_wrong_alt_legacy_correct"], 6)
        self.assertEqual(pred["cond_selected_wrong_alt_tage_correct"], 4)
        self.assertEqual(pred["cond_selected_wrong_alt_sc_correct"], 3)
        self.assertEqual(pred["cond_selected_wrong_alt_loop_correct"], 2)
        self.assertEqual(pred["cond_selected_wrong_alt_any_correct"], 10)
        self.assertAlmostEqual(pred["cond_selected_wrong_alt_any_ratio"], 10 / 18)

    def test_parse_flush_subtype_return_count(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[flush ] cycle=40 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000100 redirect_pc=0x80000200 miss_type=return miss_subtype=return redirect_distance=256 killed_uops=6",
                        "[flushp] cycle=44 reason=branch_mispredict penalty=4",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["mispredict_flush_count"], 1)
        self.assertEqual(result["mispredict_ret_count"], 1)
        self.assertEqual(result["mispredict_cond_count"], 0)
        self.assertEqual(result["mispredict_jump_count"], 0)

    def test_decode_blocked_post_flush_window_metrics(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[flush ] cycle=10 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000000 redirect_pc=0x80000010 miss_type=cond_branch redirect_distance=16 killed_uops=4",
                        "[stall ] cycle=12 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_decode_blocked_total"], 2)
        self.assertEqual(result["stall_decode_blocked_post_flush"], 1)
        self.assertAlmostEqual(result["stall_decode_blocked_post_flush_ratio"], 0.5)
        self.assertEqual(result["stall_decode_blocked_post_branch_flush"], 1)
        self.assertAlmostEqual(result["stall_decode_blocked_post_branch_flush_ratio"], 0.5)
        self.assertEqual(result["stall_post_flush_window_cycles"], 16)

    def test_decode_blocked_detail_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 sb_alloc(req/ready/fire)=0x1/0/0",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs_head(v/idx/dst)=1/0x2/0x3 lsu_rs_head(rs1r/rs2r/has1/has2)=0/1/1/0",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs(b/r)=0xff/0x0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs_head(rs1r/rs2r/has1/has2)=1/0/1/1 rob_q2(v/idx/fu/comp/st/pc)=1/0x1/0x2/0/0/0x80000010",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/0 rob_ready=1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_decode_blocked_total"], 5)
        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["sb_alloc_blocked"], 1)
        self.assertEqual(detail["lsu_operand_wait"], 1)
        self.assertEqual(detail["lsu_rs_pressure"], 1)
        self.assertEqual(detail["rob_q2_wait"], 1)
        self.assertEqual(detail["other"], 1)

    def test_decode_blocked_detail_rob_q2_without_rs2_dependency(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs_head(rs1r/rs2r/has1/has2)=1/1/1/0 rob_q2(v/idx/fu/comp/st/pc)=1/0x1/0x2/0/0/0x80000010",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["other"], 1)
        self.assertEqual(detail.get("rob_q2_wait", 0), 0)

    def test_decode_blocked_detail_secondary_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 gate(alu/bru/lsu/mdu/csr)=1/1/0/1/1 need(alu/bru/lsu/mdu/csr)=0/0/1/0/0 free(alu/bru/lsu/csr)=8/8/0/8",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 gate(alu/bru/lsu/mdu/csr)=0/1/1/1/1 need(alu/bru/lsu/mdu/csr)=1/0/0/0/0 free(alu/bru/lsu/csr)=0/8/8/8",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_sm=1 lsu_ld_fire=0 lsu_rsp_fire=0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_sm=2 lsu_ld_fire=0 lsu_rsp_fire=0",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/0 rob_ready=1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["dispatch_gate_lsu"], 1)
        self.assertEqual(detail["dispatch_gate_alu"], 1)
        self.assertEqual(detail["lsu_wait_ld_req"], 1)
        self.assertEqual(detail["lsu_wait_ld_rsp"], 1)
        self.assertEqual(detail["other"], 1)

    def test_decode_blocked_detail_pending_replay_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/4/1/1/1",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/2/1/1/1",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/4/0/0/0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/1/0/0/0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["pending_replay_progress_full"], 1)
        self.assertEqual(detail["pending_replay_progress_has_room"], 1)
        self.assertEqual(detail["pending_replay_wait_full"], 1)
        self.assertEqual(detail["pending_replay_wait_has_room"], 1)

    def test_decode_blocked_detail_lsu_group_wait_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["lsug_no_free_lane"], 1)
        self.assertEqual(detail["lsug_wait_dcache_owner"], 1)

    def test_decode_blocked_detail_dcache_store_wait_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 dc_store_wait(same/full)=1/0",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 dc_store_wait(same/full)=0/1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["dc_store_wait_same_line"], 1)
        self.assertEqual(detail["dc_store_wait_mshr_full"], 1)

    def test_rob_backpressure_detail_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x1/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x2/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x6/0/0/0x8000001c",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x4/0/0/0x80000020",
                        "[stall ] cycle=60 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x5/0/0/0x80000024",
                        "[stall ] cycle=70 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x80000028 sb_head(v/c/a/d/addr)=1/0/1/1/0x00000100",
                        "[stall ] cycle=80 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x8000002c sb_head(v/c/a/d/addr)=1/1/0/1/0x00000100",
                        "[stall ] cycle=90 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x80000030 sb_head(v/c/a/d/addr)=1/1/1/0/0x00000100",
                        "[stall ] cycle=100 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x80000034 sb_head(v/c/a/d/addr)=1/1/1/1/0x00000100 sb_dcache(v/r/addr)=1/0/0x00000100",
                        "[stall ] cycle=110 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/1/0/0x80000038",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_category"]["rob_backpressure"], 11)
        self.assertEqual(result["stall_rob_backpressure_total"], 11)
        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_incomplete_no_sm"], 1)
        self.assertEqual(detail["rob_head_fu_alu_incomplete"], 1)
        self.assertEqual(detail["rob_head_fu_branch_incomplete"], 1)
        self.assertEqual(detail["rob_head_fu_csr_incomplete"], 1)
        self.assertEqual(detail["rob_head_fu_mdu_incomplete"], 2)
        self.assertEqual(detail["rob_store_wait_commit"], 1)
        self.assertEqual(detail["rob_store_wait_addr"], 1)
        self.assertEqual(detail["rob_store_wait_data"], 1)
        self.assertEqual(detail["rob_store_wait_dcache"], 1)
        self.assertEqual(detail["rob_head_complete_but_not_ready"], 1)

    def test_rob_backpressure_lsu_incomplete_secondary_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001000 lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=2 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=0/1 lsu_rsp_fire=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=2 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=3 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_rob_backpressure_total"], 4)
        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_rsp_valid"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_rsp_fire"], 1)
        self.assertEqual(detail["rob_lsu_wait_wb"], 1)

    def test_rob_backpressure_lsu_req_fire_detail_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x3/0/0x0/0x2 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=0/1 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_wait_ld_owner_rsp_fire"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_owner_rsp_valid"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_owner_rsp_ready"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_arb_no_grant"], 1)

    def test_rob_backpressure_lsu_req_ready_detail_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001000 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x3/0/0x0/0x2 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001004 lsu_ld_fire=0 lsu_rsp(v/r)=0/1 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001008 lsu_ld_fire=0 lsu_rsp(v/r)=1/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x8000100c lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x0/0/0x0/0x0 dc_mshr(cnt/full/empty)=0/1/0 dc_mshr(alloc_rdy/line_hit)=0/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001010 lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x0/0/0x0/0x0 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=1/0/0x80003e9c dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000020",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_owner_rsp_fire"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_owner_rsp_valid"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_owner_rsp_ready"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_mshr_blocked"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_sb_conflict"], 1)

    def test_rob_backpressure_lsu_incomplete_fallback_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_rsp(v/r)=0/0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=2 lsu_ld(v/r/addr)=0/0/0x0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=9 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000020",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_incomplete_no_sm"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_idle"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_req_unknown"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_rsp_unknown"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_illegal"], 1)

    def test_cycle_stall_summary_takes_priority(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "[stallm] mode=cycle stall_total_cycles=60 flush_recovery=5 icache_miss_wait=7 dcache_miss_wait=3 rob_backpressure=20 frontend_empty=11 decode_blocked=9 lsu_req_blocked=1 other=4",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_mode"], "cycle")
        self.assertEqual(result["stall_total"], 60)
        self.assertEqual(result["stall_category"]["rob_backpressure"], 20)
        self.assertEqual(result["stall_category"]["decode_blocked"], 9)
        self.assertEqual(result["stall_category"]["frontend_empty"], 11)

    def test_cycle_stallm2_frontend_empty_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stallm] mode=cycle stall_total_cycles=60 flush_recovery=5 icache_miss_wait=7 dcache_miss_wait=3 rob_backpressure=20 frontend_empty=11 decode_blocked=9 lsu_req_blocked=1 other=4",
                        "[stallm2] mode=cycle frontend_empty_total=13 fe_no_req=2 fe_wait_icache_rsp_hit_latency=2 fe_wait_icache_rsp_miss_wait=1 fe_rsp_blocked_by_fq_full=1 fe_wait_ibuffer_consume=4 fe_redirect_recovery=0 fe_rsp_capture_bubble=2 fe_has_data_decode_gap=0 fe_other=1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_frontend_empty_total"], 13)
        detail = result["stall_frontend_empty_detail"]
        self.assertEqual(detail["fe_no_req"], 2)
        self.assertEqual(detail["fe_wait_icache_rsp_hit_latency"], 2)
        self.assertEqual(detail["fe_wait_icache_rsp_miss_wait"], 1)
        self.assertEqual(detail["fe_rsp_blocked_by_fq_full"], 1)
        self.assertEqual(detail["fe_wait_ibuffer_consume"], 4)
        self.assertEqual(detail["fe_redirect_recovery"], 0)
        self.assertEqual(detail["fe_rsp_capture_bubble"], 2)
        self.assertEqual(detail["fe_has_data_decode_gap"], 0)
        self.assertEqual(detail["fe_other"], 1)

    def test_cycle_stallm2_frontend_empty_secondary_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stallm] mode=cycle stall_total_cycles=100 flush_recovery=0 icache_miss_wait=0 dcache_miss_wait=0 rob_backpressure=20 frontend_empty=60 decode_blocked=20 lsu_req_blocked=0 other=0",
                        "[stallm2] mode=cycle frontend_empty_total=60 fe_no_req=30 fe_wait_icache_rsp_hit_latency=10 fe_wait_icache_rsp_miss_wait=2 fe_rsp_blocked_by_fq_full=0 fe_wait_ibuffer_consume=0 fe_redirect_recovery=1 fe_rsp_capture_bubble=0 fe_has_data_decode_gap=0 fe_drop_stale_rsp=8 fe_no_req_reqq_empty=12 fe_no_req_inf_full=3 fe_no_req_storage_budget=4 fe_no_req_flush_block=9 fe_no_req_other=2 fe_req_fire_no_inflight=5 fe_rsp_no_inflight=2 fe_fq_nonempty_no_fevalid=1 fe_req_ready_nofire=1 fe_other=0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_frontend_empty_detail"]
        self.assertEqual(detail["fe_drop_stale_rsp"], 8)
        self.assertEqual(detail["fe_no_req_reqq_empty"], 12)
        self.assertEqual(detail["fe_no_req_inf_full"], 3)
        self.assertEqual(detail["fe_no_req_storage_budget"], 4)
        self.assertEqual(detail["fe_no_req_flush_block"], 9)
        self.assertEqual(detail["fe_no_req_other"], 2)
        self.assertEqual(detail["fe_req_fire_no_inflight"], 5)
        self.assertEqual(detail["fe_rsp_no_inflight"], 2)
        self.assertEqual(detail["fe_fq_nonempty_no_fevalid"], 1)
        self.assertEqual(detail["fe_req_ready_nofire"], 1)

    def test_cycle_stallm34_secondary_breakdown_takes_priority(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "[stall ] cycle=41 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stallm] mode=cycle stall_total_cycles=60 flush_recovery=5 icache_miss_wait=7 dcache_miss_wait=3 rob_backpressure=20 frontend_empty=11 decode_blocked=9 lsu_req_blocked=1 other=4",
                        "[stallm3] mode=cycle decode_blocked_total=9 pending_replay_wait_full=4 lsu_wait_ld_rsp=5",
                        "[stallm4] mode=cycle rob_backpressure_total=20 rob_lsu_wait_ld_rsp_valid=12 rob_store_wait_dcache=8",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_mode"], "cycle")
        self.assertEqual(result["stall_decode_blocked_total"], 9)
        self.assertEqual(result["stall_decode_blocked_detail"]["pending_replay_wait_full"], 4)
        self.assertEqual(result["stall_decode_blocked_detail"]["lsu_wait_ld_rsp"], 5)
        self.assertEqual(result["stall_rob_backpressure_total"], 20)
        self.assertEqual(result["stall_rob_backpressure_detail"]["rob_lsu_wait_ld_rsp_valid"], 12)
        self.assertEqual(result["stall_rob_backpressure_detail"]["rob_store_wait_dcache"], 8)

    def test_cycle_stallm5_other_secondary_breakdown_takes_priority(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=1 ren(pend/src/sel/fire/rdy)=0/0/0/0/0",
                        "[stall ] cycle=41 no_commit=20 dec(v/r)=1/1 rob_ready=1 ren(pend/src/sel/fire/rdy)=0/0/0/0/1",
                        "[stallm] mode=cycle stall_total_cycles=60 flush_recovery=5 icache_miss_wait=7 dcache_miss_wait=3 rob_backpressure=20 frontend_empty=11 decode_blocked=9 lsu_req_blocked=1 other=4",
                        "[stallm5] mode=cycle other_total=4 ren_not_ready=1 ren_no_fire=2 lsu_wait_wb=1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_mode"], "cycle")
        self.assertEqual(result["stall_other_total"], 4)
        self.assertEqual(result["stall_other_detail"]["ren_not_ready"], 1)
        self.assertEqual(result["stall_other_detail"]["ren_no_fire"], 2)
        self.assertEqual(result["stall_other_detail"]["lsu_wait_wb"], 1)

    def test_cycle_stallm5_phase1_lsu_rob_keys_are_canonicalized(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stallm] mode=cycle stall_total_cycles=40 flush_recovery=1 icache_miss_wait=1 dcache_miss_wait=1 rob_backpressure=8 frontend_empty=8 decode_blocked=6 lsu_req_blocked=2 other=13",
                        "[stallm5] mode=cycle other_total=13 rob_head_lsu_incomplete_wait_req_ready=5 rob_head_lsu_incomplete_wait_rsp_valid=4 rob_empty_refill_ren_fire=4",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_other_detail"]
        self.assertEqual(detail["rob_head_lsu_incomplete_wait_req_ready_nonbp"], 5)
        self.assertEqual(detail["rob_head_lsu_incomplete_wait_rsp_valid_nonbp"], 4)
        self.assertEqual(detail["rob_empty_refill_ren_fire"], 4)
        self.assertNotIn("rob_head_lsu_incomplete_wait_req_ready", detail)
        self.assertNotIn("rob_head_lsu_incomplete_wait_rsp_valid", detail)

    def test_cycle_stallm6_other_aux_counters_are_parsed(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stallm] mode=cycle stall_total_cycles=40 flush_recovery=1 icache_miss_wait=1 dcache_miss_wait=1 rob_backpressure=8 frontend_empty=8 decode_blocked=6 lsu_req_blocked=2 other=13",
                        "[stallm5] mode=cycle other_total=13 rob_head_alu_incomplete_nonbp=5 rob_head_branch_incomplete_nonbp=8",
                        "[stallm6] mode=cycle branch_ready_not_issued=11 alu_ready_not_issued=22 complete_not_visible_to_rob=33",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        aux = result["stall_other_aux"]
        self.assertEqual(aux["branch_ready_not_issued"], 11)
        self.assertEqual(aux["alu_ready_not_issued"], 22)
        self.assertEqual(aux["complete_not_visible_to_rob"], 33)

    def test_sampled_stall_other_secondary_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=1 ren(pend/src/sel/fire/rdy)=0/0/0/0/0",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=1 ren(pend/src/sel/fire/rdy)=0/0/0/0/1",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=1 lsu_sm=3",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_mode"], "sampled")
        self.assertEqual(result["stall_other_total"], 3)
        self.assertEqual(result["stall_other_detail"]["ren_not_ready"], 1)
        self.assertEqual(result["stall_other_detail"]["ren_no_fire"], 1)
        self.assertEqual(result["stall_other_detail"]["lsu_wait_wb"], 1)

    def test_sampled_stall_other_rob_empty_refill_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=1 rob_cnt=0 ren(pend/src/sel/fire/rdy)=0/0/0/1/1 ifu_req(v/r/fire/inflight)=0/1/0/0",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=1 rob_cnt=0 ren(pend/src/sel/fire/rdy)=0/0/0/0/0 ifu_req(v/r/fire/inflight)=0/1/0/0",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=1 rob_cnt=0 ren(pend/src/sel/fire/rdy)=0/0/0/0/1 ifu_req(v/r/fire/inflight)=1/1/0/1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_other_total"], 3)
        detail = result["stall_other_detail"]
        self.assertEqual(detail["rob_empty_refill_ren_fire"], 1)
        self.assertEqual(detail["rob_empty_refill_ren_not_ready"], 1)
        self.assertEqual(detail["rob_empty_refill_wait_frontend_rsp"], 1)

    def test_sampled_stall_other_rob_head_and_lsu_wb_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=1 rob_cnt=5 rob_head(fu/comp/is_store/pc)=0x2/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=1 rob_cnt=5 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014 lsu_sm=2 lsu_rsp(v/r)=0/1",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=1 rob_cnt=5 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018 lsu_sm=3",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_other_total"], 3)
        detail = result["stall_other_detail"]
        self.assertEqual(detail["rob_head_branch_incomplete_nonbp"], 1)
        self.assertEqual(detail["rob_head_lsu_incomplete_wait_rsp_valid_nonbp"], 1)
        self.assertEqual(detail["lsu_wait_wb_head_lsu_incomplete"], 1)

    def test_parse_ifum_fetch_queue_summary(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[ifum] mode=cycle fq_samples=100 fq_enq=40 fq_deq=38 fq_bypass=12 fq_enq_blocked=3 fq_full_cycles=5 fq_empty_cycles=60 fq_nonempty_cycles=40 fq_occ_sum=55 fq_occ_max=3 fq_occ_avg_x1000=550 fq_occ_bin0=60 fq_occ_bin1=25 fq_occ_bin2=10 fq_occ_bin3=5 fq_occ_bin4=0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        fq = result["ifu_fq"]
        self.assertEqual(fq["fq_samples"], 100)
        self.assertEqual(fq["fq_enq"], 40)
        self.assertEqual(fq["fq_deq"], 38)
        self.assertEqual(fq["fq_bypass"], 12)
        self.assertEqual(fq["fq_enq_blocked"], 3)
        self.assertEqual(fq["fq_occ_max"], 3)
        self.assertAlmostEqual(fq["fq_occ_avg"], 0.55)
        self.assertAlmostEqual(fq["fq_occ_avg_from_line"], 0.55)
        self.assertAlmostEqual(fq["fq_bypass_ratio"], 12 / 38)
        self.assertEqual(fq["fq_occ_hist"][0], 60)
        self.assertEqual(fq["fq_occ_hist"][3], 5)

    def test_report_includes_frontend_empty_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            template = Path(__file__).resolve().parents[1] / "report_template.md"
            summary = {
                "coremark": {
                    "log_path": str(tdir / "coremark.log"),
                    "ipc": 0.5,
                    "cpi": 2.0,
                    "cycles": 100,
                    "commits": 50,
                    "flush_per_kinst": 0.0,
                    "bru_per_kinst": 0.0,
                    "mispredict_flush_count": 0,
                    "branch_penalty_cycles": 0,
                    "wrong_path_kill_uops": 0,
                    "redirect_distance_avg": 0.0,
                    "redirect_distance_max": 0,
                    "commit_width_hist": {0: 50, 1: 50, 2: 0, 3: 0, 4: 0},
                    "stall_category": {"frontend_empty": 11},
                    "stall_total": 11,
                    "stall_frontend_empty_total": 13,
                    "stall_frontend_empty_detail": {
                        "fe_no_req": 2,
                        "fe_wait_icache_rsp_hit_latency": 2,
                        "fe_wait_icache_rsp_miss_wait": 1,
                        "fe_rsp_blocked_by_fq_full": 1,
                        "fe_wait_ibuffer_consume": 4,
                        "fe_redirect_recovery": 0,
                        "fe_rsp_capture_bubble": 2,
                        "fe_has_data_decode_gap": 0,
                        "fe_other": 1,
                    },
                    "control": {"control_ratio": 0.0, "est_misp_per_kinst": 0.0},
                    "predict": {
                        "cond_hit": 0,
                        "cond_miss": 0,
                        "cond_miss_rate": 0.0,
                        "jump_hit": 0,
                        "jump_miss": 0,
                        "jump_miss_rate": 0.0,
                        "ret_hit": 0,
                        "ret_miss": 0,
                        "ret_miss_rate": 0.0,
                        "call_total": 0,
                    },
                    "top_pc": [],
                    "top_inst": [],
                    "flush_reason_histogram": {},
                    "flush_source_histogram": {},
                    "has_commit_detail": False,
                    "has_commit_summary": False,
                    "stall_mode": "cycle",
                    "quality_warnings": [],
                    "commit_metrics_source": "none",
                    "stall_metrics_source": "cycle",
                }
            }

            report = mod.build_markdown_report(summary, template)

        self.assertIn("Frontend Empty Breakdown:", report)
        self.assertIn("fe_wait_ibuffer_consume", report)
        self.assertIn("fe_wait_icache_rsp_hit_latency", report)
        self.assertIn("fe_wait_icache_rsp_miss_wait", report)
        self.assertIn("fe_rsp_capture_bubble", report)

    def test_report_includes_fetch_queue_effectiveness(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            template = Path(__file__).resolve().parents[1] / "report_template.md"
            summary = {
                "coremark": {
                    "log_path": str(tdir / "coremark.log"),
                    "ipc": 0.5,
                    "cpi": 2.0,
                    "cycles": 100,
                    "commits": 50,
                    "flush_per_kinst": 0.0,
                    "bru_per_kinst": 0.0,
                    "mispredict_flush_count": 0,
                    "branch_penalty_cycles": 0,
                    "wrong_path_kill_uops": 0,
                    "redirect_distance_avg": 0.0,
                    "redirect_distance_max": 0,
                    "commit_width_hist": {0: 50, 1: 50, 2: 0, 3: 0, 4: 0},
                    "stall_category": {},
                    "stall_total": 0,
                    "control": {"control_ratio": 0.0, "est_misp_per_kinst": 0.0},
                    "predict": {
                        "cond_hit": 0,
                        "cond_miss": 0,
                        "cond_miss_rate": 0.0,
                        "jump_hit": 0,
                        "jump_miss": 0,
                        "jump_miss_rate": 0.0,
                        "ret_hit": 0,
                        "ret_miss": 0,
                        "ret_miss_rate": 0.0,
                        "call_total": 0,
                    },
                    "ifu_fq": {
                        "fq_samples": 100,
                        "fq_enq": 40,
                        "fq_deq": 38,
                        "fq_bypass": 12,
                        "fq_enq_blocked": 3,
                        "fq_full_cycles": 5,
                        "fq_empty_cycles": 60,
                        "fq_nonempty_cycles": 40,
                        "fq_occ_avg": 0.55,
                        "fq_occ_max": 3,
                        "fq_occ_hist": {0: 60, 1: 25, 2: 10, 3: 5},
                    },
                    "top_pc": [],
                    "top_inst": [],
                    "flush_reason_histogram": {},
                    "flush_source_histogram": {},
                    "has_commit_detail": False,
                    "has_commit_summary": False,
                    "stall_mode": "none",
                    "quality_warnings": [],
                    "commit_metrics_source": "none",
                    "stall_metrics_source": "none",
                }
            }

            report = mod.build_markdown_report(summary, template)

        self.assertIn("Fetch Queue Effectiveness:", report)
        self.assertIn("enq/deq/bypass", report)
        self.assertIn("occupancy(avg/max)", report)
        self.assertIn("occ=3", report)

    def test_report_includes_other_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            template = Path(__file__).resolve().parents[1] / "report_template.md"
            summary = {
                "coremark": {
                    "log_path": str(tdir / "coremark.log"),
                    "ipc": 0.5,
                    "cpi": 2.0,
                    "cycles": 100,
                    "commits": 50,
                    "flush_per_kinst": 0.0,
                    "bru_per_kinst": 0.0,
                    "mispredict_flush_count": 0,
                    "branch_penalty_cycles": 0,
                    "wrong_path_kill_uops": 0,
                    "redirect_distance_avg": 0.0,
                    "redirect_distance_max": 0,
                    "commit_width_hist": {0: 50, 1: 50, 2: 0, 3: 0, 4: 0},
                    "stall_category": {"other": 3},
                    "stall_total": 3,
                    "stall_other_total": 3,
                    "stall_other_detail": {"ren_not_ready": 2, "lsu_wait_wb": 1},
                    "control": {"control_ratio": 0.0, "est_misp_per_kinst": 0.0},
                    "predict": {
                        "cond_hit": 0,
                        "cond_miss": 0,
                        "cond_miss_rate": 0.0,
                        "jump_hit": 0,
                        "jump_miss": 0,
                        "jump_miss_rate": 0.0,
                        "ret_hit": 0,
                        "ret_miss": 0,
                        "ret_miss_rate": 0.0,
                        "call_total": 0,
                    },
                    "top_pc": [],
                    "top_inst": [],
                    "flush_reason_histogram": {},
                    "flush_source_histogram": {},
                    "has_commit_detail": False,
                    "has_commit_summary": False,
                    "stall_mode": "cycle",
                    "quality_warnings": [],
                    "commit_metrics_source": "none",
                    "stall_metrics_source": "cycle",
                }
            }

            report = mod.build_markdown_report(summary, template)

        self.assertIn("Other Breakdown:", report)
        self.assertIn("ren_not_ready", report)
        self.assertIn("lsu_wait_wb", report)

    def test_report_includes_predict_tournament_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            template = Path(__file__).resolve().parents[1] / "report_template.md"
            summary = {
                "coremark": {
                    "log_path": str(tdir / "coremark.log"),
                    "ipc": 0.5,
                    "cpi": 2.0,
                    "cycles": 100,
                    "commits": 50,
                    "flush_per_kinst": 0.0,
                    "bru_per_kinst": 0.0,
                    "mispredict_flush_count": 0,
                    "branch_penalty_cycles": 0,
                    "wrong_path_kill_uops": 0,
                    "redirect_distance_avg": 0.0,
                    "redirect_distance_max": 0,
                    "commit_width_hist": {0: 50, 1: 50, 2: 0, 3: 0, 4: 0},
                    "stall_category": {},
                    "stall_total": 0,
                    "control": {"control_ratio": 0.0, "est_misp_per_kinst": 0.0},
                    "predict": {
                        "cond_hit": 80,
                        "cond_miss": 20,
                        "cond_miss_rate": 0.2,
                        "jump_hit": 5,
                        "jump_miss": 1,
                        "jump_miss_rate": 1 / 6,
                        "ret_hit": 2,
                        "ret_miss": 1,
                        "ret_miss_rate": 1 / 3,
                        "call_total": 9,
                        "cond_update_total": 100,
                        "cond_local_correct": 78,
                        "cond_global_correct": 70,
                        "cond_selected_correct": 82,
                        "cond_choose_local": 60,
                        "cond_choose_global": 40,
                        "cond_local_accuracy": 0.78,
                        "cond_global_accuracy": 0.70,
                        "cond_selected_accuracy": 0.82,
                        "cond_choose_global_ratio": 0.40,
                    },
                    "top_pc": [],
                    "top_inst": [],
                    "flush_reason_histogram": {},
                    "flush_source_histogram": {},
                    "has_commit_detail": False,
                    "has_commit_summary": False,
                    "stall_mode": "none",
                    "quality_warnings": [],
                    "commit_metrics_source": "none",
                    "stall_metrics_source": "none",
                }
            }

            report = mod.build_markdown_report(summary, template)

        self.assertIn("predict(cond local/global/selected acc)", report)
        self.assertIn("predict(cond chooser local/global)", report)
        self.assertIn("predict(jump direct hit/miss)", report)
        self.assertIn("predict(jump indirect hit/miss)", report)
        self.assertIn("predict(loop lookup/hit/confident/override/correct)", report)
        self.assertIn("predict(cond provider selected legacy/tage/sc/loop)", report)
        self.assertIn("predict(cond wrong-selected alt-correct legacy/tage/sc/loop/any)", report)

    def test_commit_summary_without_commit_detail(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[commitm] cycles=100 commits=50 width0=60 width1=20 width2=10 width3=5 width4=5",
                        "[controlm] branch_count=30 jal_count=10 jalr_count=5 branch_taken_count=18 call_count=7 ret_count=6",
                        "[hotpcm] rank0_pc=0x80000010 rank0_count=123 rank1_pc=0x80000020 rank1_count=77",
                        "[hotinstm] rank0_inst=0x00100073 rank0_count=40 rank1_inst=0x00000013 rank1_count=30",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertFalse(result["has_commit_detail"])
        self.assertTrue(result["has_commit_summary"])
        self.assertEqual(result["commit_width_hist"][0], 60)
        self.assertEqual(result["commit_width_hist"][4], 5)
        self.assertEqual(result["control"]["branch_count"], 30)
        self.assertEqual(result["control"]["jal_count"], 10)
        self.assertEqual(result["control"]["jalr_count"], 5)
        self.assertEqual(result["top_pc"][0]["pc"], "0x80000010")
        self.assertEqual(result["top_pc"][0]["count"], 123)
        self.assertEqual(result["top_inst"][0]["inst"], "0x00100073")
        self.assertEqual(result["top_inst"][0]["count"], 40)

    def test_commit_summary_accepts_dynamic_width_keys(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[commitm] cycles=100 commits=70 width0=30 width1=20 width2=10 width5=7 width6=3",
                        "IPC=0.700000 CPI=1.428571 cycles=100 commits=70",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertTrue(result["has_commit_summary"])
        self.assertEqual(result["commit_width_hist"][0], 30)
        self.assertEqual(result["commit_width_hist"][5], 7)
        self.assertEqual(result["commit_width_hist"][6], 3)
        self.assertEqual(result["commit_width_hist"][4], 0)

    def test_report_renders_dynamic_commit_width_histogram(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            template = Path(__file__).resolve().parents[1] / "report_template.md"
            summary = {
                "coremark": {
                    "log_path": str(tdir / "coremark.log"),
                    "ipc": 0.7,
                    "cpi": 1.4,
                    "cycles": 100,
                    "commits": 70,
                    "flush_per_kinst": 0.0,
                    "bru_per_kinst": 0.0,
                    "mispredict_flush_count": 0,
                    "branch_penalty_cycles": 0,
                    "wrong_path_kill_uops": 0,
                    "redirect_distance_avg": 0.0,
                    "redirect_distance_max": 0,
                    "benchmark_time_source": "self",
                    "bench_reported_time_ms": 1.0,
                    "host_time_ms": 1.0,
                    "effective_benchmark_time_ms": 1.0,
                    "commit_width_hist": {0: 30, 1: 20, 2: 10, 5: 7, 6: 3},
                    "stall_category": {},
                    "stall_total": 0,
                    "stall_frontend_empty_total": 0,
                    "stall_frontend_empty_detail": {},
                    "stall_decode_blocked_total": 0,
                    "stall_decode_blocked_detail": {},
                    "stall_rob_backpressure_total": 0,
                    "stall_rob_backpressure_detail": {},
                    "stall_other_total": 0,
                    "stall_other_detail": {},
                    "stall_other_aux": {},
                    "control": {"control_ratio": 0.0, "est_misp_per_kinst": 0.0},
                    "top_pc": [],
                    "top_inst": [],
                    "flush_reason_histogram": {},
                    "flush_source_histogram": {},
                    "predict": {},
                    "has_commit_detail": False,
                    "has_commit_summary": True,
                    "stall_mode": "none",
                    "quality_warnings": [],
                    "commit_metrics_source": "summary",
                    "stall_metrics_source": "none",
                }
            }
            report = mod.build_markdown_report(summary, template)

        self.assertIn("- width5: `7`", report)
        self.assertIn("- width6: `3`", report)

    def test_quality_warning_for_sampled_stall_and_missing_commit(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=25 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertFalse(result["has_commit_detail"])
        self.assertFalse(result["has_commit_summary"])
        self.assertEqual(result["stall_mode"], "sampled")
        warnings = result["quality_warnings"]
        self.assertTrue(any("commit" in msg for msg in warnings))
        self.assertTrue(any("sampled" in msg for msg in warnings))


if __name__ == "__main__":
    unittest.main()
