#!/usr/bin/env python3
"""Render a static HTML report from summary.json (schema v2 with v1 fallback)."""

from __future__ import annotations

import html
import json
import sys
from pathlib import Path

_PROFILER_DIR = Path(__file__).resolve().parent
if str(_PROFILER_DIR) not in sys.path:
    sys.path.insert(0, str(_PROFILER_DIR))

from profile_schema import (
    PROFILE_BENCHMARKS,
    STALL_CATEGORY_KEYS,
    bench_commit_width_hist,
    bench_commits,
    bench_control,
    bench_cpi,
    bench_cycles,
    bench_flush,
    bench_hotspots,
    bench_ifu_fq,
    bench_ipc,
    bench_mispredict_diag,
    bench_predict,
    bench_predict_doc,
    bench_stall_category,
    bench_stall_detail,
    bench_stall_section_total,
    bench_stall_total,
    predict_accuracy_part_totals,
    predict_ftb_part_totals,
    predict_ittage_part_totals,
    predict_miss_part_totals,
    predict_provider_part_totals,
)

BENCHMARKS = PROFILE_BENCHMARKS
STALL_DETAIL_SECTIONS = (
    ("decode_blocked", "Decode 阻塞"),
    ("frontend_empty", "前端空取"),
    ("rob_backpressure", "ROB 背压"),
    ("pipeline_bubble", "流水线气泡"),
    ("hol_load_detail", "队头Load无Lane"),
)

TRANSLATIONS = {
    "IPC": "IPC (每周期指令数)",
    "CPI": "CPI (每指令周期数)",
    "Cycles": "总周期数",
    "Commits": "提交指令数",
    "Flush": "流水线冲刷次数",
    "BRU mispred": "BRU 误预测提交槽 (dbg_bru_mispred)",
    "Branch penalty": "分支惩罚周期 (至下次提交)",
    "Flush/kCommit": "每千次提交冲刷次数",
    "pipeline_bubble": "流水线气泡 (decode/ROB 就绪但零提交)",
    "frontend_empty": "前端空取 (Frontend Empty)",
    "rob_backpressure": "ROB 阻塞 (后端背压)",
    "lsu_req_blocked": "LSU 请求阻塞",
    "decode_blocked": "Decode 阶段阻塞",
    "other": "其他 (Other)",
    "flush_recovery": "backend_flush 信号周期 (零提交)",
    "icache_miss_wait": "I-Cache Miss 等待",
    "dcache_miss_wait": "D-Cache Miss 等待",
    "lsug_no_free_lane": "LSU 无空闲通道",
    "st_alloc_blocked": "STQ 分配阻塞",
    "lsug_wait_dcache_owner": "LSU 等待 D-Cache",
    "lsug_wait_ld_req_not_ready_lsu_pte": "LSU Load 等待 D-Cache: LSU 页表遍历抢占",
    "lsug_wait_ld_req_not_ready_ifu_pte": "LSU Load 等待 D-Cache: IFU 页表遍历抢占",
    "lsug_wait_ld_req_not_ready_refill": "LSU Load 等待 D-Cache: Refill 占用",
    "lsug_wait_ld_req_not_ready_pending_load": "LSU Load 等待 D-Cache: pending load",
    "lsug_wait_ld_req_not_ready_store_conflict": "LSU Load 等待 D-Cache: Store 冲突",
    "lsug_wait_ld_req_not_ready_mshr_line_hit": "LSU Load 等待 D-Cache: MSHR 同行命中",
    "lsug_wait_ld_req_not_ready_mshr_blocked": "LSU Load 等待 D-Cache: MSHR 阻塞",
    "lsug_wait_ld_req_not_ready_dcache_idle": "LSU Load 等待 D-Cache: Idle 未就绪",
    "lsug_wait_ld_req_not_ready_dcache_lookup": "LSU Load 等待 D-Cache: Lookup",
    "lsug_wait_ld_req_not_ready_dcache_store_write": "LSU Load 等待 D-Cache: Store 写入",
    "lsug_wait_ld_req_not_ready_dcache_wb_req": "LSU Load 等待 D-Cache: 写回请求",
    "lsug_wait_ld_req_not_ready_dcache_miss_req": "LSU Load 等待 D-Cache: Miss 请求",
    "lsug_wait_ld_req_not_ready_dcache_wait_refill": "LSU Load 等待 D-Cache: 等待 Refill",
    "lsug_wait_ld_req_not_ready_dcache_resp": "LSU Load 等待 D-Cache: 响应阶段",
    "lsug_wait_ld_req_not_ready_dcache_unknown": "LSU Load 等待 D-Cache: 未知状态",
    "lsug_wait_pending_load": "LSU 等待 pending load",
    "lsug_wait_lsu_mmu": "LSU 等待 D-MMU",
    "lsug_wait_dcache_owner_no_ld_req": "LSU 等待 D-Cache: 无 Load 请求",
    "dc_store_wait_same_line": "D-Cache 相同行冲突",
    "pending_replay_wait_full": "等待队列满",
    "pending_replay_progress_full": "进行中队列满",
    "fe_wait_icache_rsp_hit_latency": "等待 I-Cache 命中延迟",
    "fe_req_fire_no_inflight": "前端无在途请求",
    "fe_redirect_recovery": "前端重定向恢复",
    "fe_wait_icache_rsp_miss_wait": "等待 I-Cache Miss",
    "fe_no_req_reqq_empty": "FTQ 空",
    "rob_lsu_incomplete_sm_req_unknown": "LSU 状态机: 请求未知",
    "rob_lsu_incomplete_sm_rsp_unknown": "LSU 状态机: 响应未知",
    "rob_lsu_incomplete_lane_not_found": "LSU: 未找到 ROB 头对应 lane",
    "rob_lsu_incomplete_cdb_hit_no_lane": "LSU: CDB 已命中 ROB 头但 lane 已不可见",
    "rob_lsu_incomplete_group_wb_hit_no_lane": "LSU: group WB 命中 ROB 头但 lane 已不可见",
    "rob_lsu_incomplete_group_wb_not_ready_no_lane": "LSU: group WB 命中 ROB 头但 CDB 未就绪",
    "rob_lsu_incomplete_other_lsu_wb_no_lane": "LSU: 其他 LSU 写回，ROB 头 lane 未找到",
    "rob_lsu_incomplete_sm_req_wait_lane": "LSU: lane 等待发请求",
    "rob_lsu_rsp_to_wb": "LSU: 响应转写回",
    "rob_lsu_wait_wb_visible": "LSU: 写回已选择等待 ROB 可见",
    "rob_lsu_wait_wb_store_priority": "LSU: load 写回被 store completion 优先级阻塞",
    "rob_lsu_wait_wb_select": "LSU: 等待写回选择",
    "rob_lsu_wait_wb_no_lane_valid": "LSU: RESP 无 lane 写回 valid",
    "rob_lsu_mmio_wait_rob": "LSU: MMIO 等待到 ROB 头",
    "rob_lsu_mmio_req": "LSU: MMIO 请求中",
    "rob_lsu_wait_ld_req_grant": "LSU: 等待 D-Cache 请求仲裁",
    "rob_lsu_wait_ld_req_ready_mshr_blocked": "LSU: Load 请求等待 MSHR",
    "rob_lsu_wait_ld_req_ready_miss_port_busy": "LSU: Load 请求等待 miss 端口",
    "rob_store_wait_commit": "Store 等待提交",
    "rob_lsu_wait_ld_rsp_valid": "LSU 等待 Load 响应",
    "rob_empty_refill_ren_fire": "ROB 空且 Rename 就绪",
    "rob_head_branch_wait_operand_or_select_incomplete_nonbp": "ROB头Branch: 等待操作数",
    "rob_head_lsu_incomplete_sm_req_unknown_nonbp": "ROB头LSU: 请求未知",
    "rob_head_lsu_incomplete_sm_rsp_unknown_nonbp": "ROB头LSU: 响应未知",
    "rob_head_lsu_incomplete_lane_not_found_nonbp": "ROB头LSU: 未找到对应 lane",
    "hol_load_no_lane": "队头Load无Lane (分母)",
    "hol_not_in_rs": "队头Load: 未进RS",
    "hol_in_rs_operand_wait": "队头Load: RS等操作数",
    "hol_in_rs_issue_inflight": "队头Load: 本拍正在issue",
    "hol_in_rs_ready_no_issue": "队头Load: RS就绪未issue",
    "hol_in_rs_not_ready_other": "队头Load: RS未就绪(非store-block)",
    "hol_block_store": "队头Load: RS被更老store阻塞",
    "hol_issue_port_busy": "队头Load: issue口被其他项占用",
    "hol_residual": "队头Load: 未分类残余",
    "rob_head_lsu_incomplete_cdb_hit_no_lane_nonbp": "ROB头LSU: CDB 已命中但 lane 已不可见",
    "rob_head_lsu_incomplete_group_wb_hit_no_lane_nonbp": "ROB头LSU: group WB 命中但 lane 已不可见",
    "rob_head_lsu_incomplete_group_wb_not_ready_no_lane_nonbp": "ROB头LSU: group WB 命中但 CDB 未就绪",
    "rob_head_lsu_incomplete_other_lsu_wb_no_lane_nonbp": "ROB头LSU: 其他 LSU 写回且 lane 未找到",
    "rob_head_lsu_incomplete_sm_req_wait_lane_nonbp": "ROB头LSU: lane 等待发请求",
    "rob_head_lsu_incomplete_rsp_to_wb_nonbp": "ROB头LSU: 响应转写回",
    "rob_head_lsu_incomplete_wait_wb_visible_nonbp": "ROB头LSU: 写回已选择等待可见",
    "rob_head_lsu_incomplete_wait_wb_store_priority_nonbp": "ROB头LSU: load 写回被 store completion 阻塞",
    "rob_head_lsu_incomplete_wait_wb_select_nonbp": "ROB头LSU: 等待写回选择",
    "rob_head_lsu_incomplete_wait_wb_no_lane_valid_nonbp": "ROB头LSU: RESP 无 lane 写回 valid",
    "rob_head_lsu_incomplete_mmio_wait_rob_nonbp": "ROB头LSU: MMIO 等待到 ROB 头",
    "rob_head_lsu_incomplete_mmio_req_nonbp": "ROB头LSU: MMIO 请求中",
    "rob_head_lsu_incomplete_wait_req_grant_nonbp": "ROB头LSU: 等待 D-Cache 请求仲裁",
    "rob_head_lsu_incomplete_wait_req_ready_st_conflict_nonbp": "ROB头LSU: Load 请求等待 store 冲突",
    "rob_head_lsu_incomplete_wait_req_ready_mshr_blocked_nonbp": "ROB头LSU: Load 请求等待 MSHR",
    "rob_head_lsu_incomplete_wait_req_ready_miss_port_busy_nonbp": "ROB头LSU: Load 请求等待 miss 端口",
    "rob_head_lsu_incomplete_wait_rsp_valid_nonbp": "ROB头LSU: 等待响应有效",
    "rob_head_lsu_incomplete_sm_idle_nonbp": "ROB头LSU: 空闲",
    "rob_head_lsu_incomplete_wait_req_ready_nonbp": "ROB头LSU: 等待请求就绪",
    "rob_head_store_wait_commit_nonbp": "ROB头Store: 等待提交",
    "rob_head_branch_complete_not_visible_incomplete_nonbp": "ROB头Branch: 完成不可见",
    "rob_head_branch_exec_wait_wb_incomplete_nonbp": "ROB头Branch: 等待写回",
    "lsu_wait_wb_head_lsu_incomplete": "LSU 等待写回",
    "lsu_wait_wb_head_lsu_cdb_visible": "LSU CDB 已命中 ROB 头，等待可见",
    "lsu_wait_wb_head_lsu_group_visible": "LSU group WB 命中 ROB 头，等待 CDB/ROB 可见",
    "lsu_wait_wb_head_lsu_cdb_blocked": "LSU group WB 命中 ROB 头但 CDB 阻塞",
    "lsu_wait_wb_other_lsu_head_lsu_incomplete": "其他 LSU 写回时 ROB 头 LSU 未完成",
    "rob_head_store_wait_other_nonbp": "ROB头Store: 等待其他",
    "rob_head_store_wait_dcache_nonbp": "ROB头Store: 等待 D-Cache",
    "rob_head_alu_exec_wait_wb_incomplete_nonbp": "ROB头ALU: 等待写回",
    "rob_head_lsu_incomplete_wait_owner_or_alloc_nonbp": "ROB头LSU: 等待所有者分配",
    "rob_head_csr_incomplete_nonbp": "ROB头CSR: 未完成",
    "rob_lsu_incomplete_sm_idle": "LSU 状态机空闲",
    "rob_head_fu_branch_incomplete": "ROB头Branch 未完成",
    "rob_lsu_wait_ld_req_ready": "LSU 等待 Load 请求就绪",
    "rob_lsu_wait_ld_req_ready_st_conflict": "LSU Load 请求 STQ 冲突",
    "rob_lsu_wait_wb": "LSU 等待写回",
    "cond_miss_rate": "条件分支误预测率 (提交侧)",
    "jump_miss_rate": "跳转误预测率 (提交侧)",
    "ret_miss_rate": "返回误预测率 (提交侧)",
    "jump_direct_miss_rate": "直接跳转误预测率",
    "jump_indirect_miss_rate": "间接跳转误预测率",
    "cond_selected_accuracy": "BHT 训练自检 (非取指精度)",
    "tage_table_hit_rate": "TAGE 表命中 / lookup",
    "tage_override_accuracy": "TAGE override 事后正确率",
    "cond_pick_rate": "FTB 选用 cond / lookup",
    "jump_pick_rate": "FTB 选用 jump / lookup",
    "table_hit_per_lookup_rate": "ITTAGE 表命中 / lookup",
    "use_per_lookup_rate": "ITTAGE 采用 / lookup",
    "legacy_accuracy": "Legacy provider 准确率",
    "tage_accuracy": "TAGE provider 准确率",
    "fq_occ_avg": "平均占用量",
    "fq_occ_max": "最大占用量",
    "fq_bypass_ratio": "Bypass 比例",
    "fq_full_ratio": "队列满比例",
    "fq_empty_ratio": "队列空比例",
    "fq_nonempty_ratio": "队列非空比例",
    "branch_mispredict": "分支预测失败",
    "exception": "异常 (Exception)",
    "branch_count": "条件分支指令数",
    "jal_count": "JAL 指令数",
    "jalr_count": "JALR 指令数",
    "branch_taken_count": "条件分支跳转数",
    "call_count": "CALL 指令数",
    "ret_count": "RET 指令数",
    "control_count": "总控制流指令数",
    "control_ratio": "控制流占比",
    "cond": "条件分支误预测",
    "jump": "跳转误预测",
    "jump_direct": "直接跳转误预测",
    "jump_indirect": "间接跳转误预测",
    "ret": "返回误预测",
    "dir_wrong": "方向错 (BHT)",
    "dir_ok_target_wrong": "方向对 target 错",
    "slot_offset_bind": "半字 offset 绑定",
    "ftb_no_entry_tag_miss": "FTB 无条目/tag miss",
    "ftb_hit_cond_nt": "FTB 命中 BHT 判 NT",
    "ftb_hit_out_of_range": "FTB 命中窗口外",
    "ftb_hit_shadowed": "FTB 命中被遮蔽",
    "ftb_unclassified": "FTB 未分类",
    "bht_direction": "BHT 方向错 (rollup, 不含 FTB NT)",
    "ftb_structural": "FTB 结构 (rollup)",
    "target_wrong": "Target 错 (rollup)",
    "unclassified": "未分类 (rollup)",
}

SHARED_CSS = """
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; margin: 0; padding: 24px; background: #f4f7f9; color: #24292f; line-height: 1.5; }
    a { color: #0969da; text-decoration: none; }
    a:hover { text-decoration: underline; }
    h1 { margin: 0 0 16px; font-size: 26px; font-weight: 600; color: #111; }
    h2 { margin: 0 0 16px; font-size: 20px; font-weight: 600; color: #222; border-bottom: 2px solid #e1e4e8; padding-bottom: 8px; }
    h3 { margin: 20px 0 12px; font-size: 15px; font-weight: 600; color: #444; }
    .meta { color: #57606a; font-size: 14px; margin-bottom: 24px; background: #fff; padding: 14px 20px; border-radius: 8px; box-shadow: 0 1px 3px rgba(27,31,36,0.04); display: flex; flex-wrap: wrap; gap: 16px; align-items: center; }
    .meta span { background: #f6f8fa; padding: 4px 10px; border-radius: 6px; border: 1px solid #d0d7de; }
    .nav { margin-bottom: 20px; font-size: 14px; font-weight: 600; }
    .card { background: #fff; border: 1px solid #d0d7de; border-radius: 10px; padding: 24px; margin-bottom: 24px; box-shadow: 0 3px 6px rgba(140,149,159,0.05); }
    .bench { margin-top: 12px; }
    .section { margin-top: 20px; padding-top: 16px; border-top: 1px solid #e1e4e8; }
    .section:first-of-type { border-top: none; padding-top: 0; margin-top: 0; }
    .section-title { font-size: 13px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; color: #57606a; margin: 0 0 12px; }
    .metric-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 16px; }
    .metric { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 8px; padding: 16px; text-align: center; transition: transform 0.2s, box-shadow 0.2s; }
    .metric:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(27,31,36,0.08); }
    .metric .label { font-size: 12px; color: #57606a; margin-bottom: 6px; }
    .metric .value { font-size: 22px; font-weight: 600; color: #0969da; }
    table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 13px; }
    th, td { border-bottom: 1px solid #e1e4e8; padding: 10px 12px; text-align: left; vertical-align: middle; }
    th { background: #f6f8fa; color: #57606a; font-weight: 600; font-size: 12px; border-top: 1px solid #e1e4e8; }
    th:first-child { border-top-left-radius: 6px; border-left: 1px solid #e1e4e8; }
    th:last-child { border-top-right-radius: 6px; border-right: 1px solid #e1e4e8; }
    tr td:first-child { border-left: 1px solid #e1e4e8; font-weight: 500; color: #24292f; }
    tr td:last-child { border-right: 1px solid #e1e4e8; }
    tr:last-child td:first-child { border-bottom-left-radius: 6px; }
    tr:last-child td:last-child { border-bottom-right-radius: 6px; }
    tr:hover td { background-color: #f6f8fa; }
    .bar { background: #eaecef; border-radius: 4px; height: 8px; overflow: hidden; min-width: 100px; width: 100%; }
    .bar-fill { background: #2da44e; height: 100%; transition: width 0.3s ease; }
    .bar-fill.warn { background: #bf8700; }
    .bar-fill.hot { background: #cf222e; }
    .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
    details.hotspots { margin-top: 12px; border: 1px solid #d0d7de; border-radius: 8px; padding: 12px 16px; background: #fafbfc; }
    details.hotspots summary { cursor: pointer; font-weight: 600; color: #444; }
    @media (max-width: 900px) { .two-col { grid-template-columns: 1fr; } }
"""


def tr(key: str) -> str:
    return TRANSLATIONS.get(key, key)


def esc(value: object) -> str:
    return html.escape(str(value))


def fmt_num(value: object, digits: int = 4) -> str:
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    if isinstance(value, int):
        return f"{value:,}"
    return esc(value)


def fmt_part_total(part: object, total: object) -> str:
    def _fmt_one(value: object) -> str:
        if isinstance(value, float):
            if value == int(value):
                return f"{int(value):,}"
            return f"{value:.2f}"
        if isinstance(value, int):
            return f"{value:,}"
        return str(value)

    return f"{_fmt_one(part)}/{_fmt_one(total)}"


def metric_card(label: str, value: str) -> str:
    return (
        f"<div class='metric'><div class='label'>{esc(label)}</div>"
        f"<div class='value'>{value}</div></div>"
    )


def bar_table(title: str, items: dict[str, int | float], total: float | None = None) -> str:
    if not items:
        return ""
    if total is None or total <= 0:
        total = float(sum(float(v) for v in items.values()) or 1.0)
    rows: list[str] = []
    for key, raw in sorted(items.items(), key=lambda kv: float(kv[1]), reverse=True):
        val = float(raw)
        pct = 100.0 * val / total if total else 0.0
        bar_class = "hot" if pct >= 20 else ("warn" if pct >= 10 else "")
        rows.append(
            "<tr>"
            f"<td>{esc(tr(key))}</td>"
            f"<td>{fmt_part_total(int(val) if val == int(val) else val, int(total) if total == int(total) else total)}</td>"
            f"<td>{pct:.1f}%</td>"
            f"<td><div class='bar'><div class='bar-fill {bar_class}' style='width:{min(pct, 100):.1f}%'></div></div></td>"
            "</tr>"
        )
    return (
        f"<h3>{esc(title)}</h3>"
        "<table><thead><tr><th>指标项</th><th>分/总</th><th>占比</th><th style='width: 30%'>可视化</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def part_total_bar_table(title: str, items: dict[str, tuple[float, float]]) -> str:
    if not items:
        return ""
    rows: list[str] = []
    for key, (part, row_total) in sorted(items.items(), key=lambda kv: kv[1][0], reverse=True):
        val = float(part)
        total = float(row_total or 1.0)
        pct = 100.0 * val / total if total else 0.0
        bar_class = "hot" if pct >= 20 else ("warn" if pct >= 10 else "")
        rows.append(
            "<tr>"
            f"<td>{esc(tr(key))}</td>"
            f"<td>{fmt_part_total(int(val) if val == int(val) else val, int(total) if total == int(total) else total)}</td>"
            f"<td>{pct:.1f}%</td>"
            f"<td><div class='bar'><div class='bar-fill {bar_class}' style='width:{min(pct, 100):.1f}%'></div></div></td>"
            "</tr>"
        )
    return (
        f"<h3>{esc(title)}</h3>"
        "<table><thead><tr><th>指标项</th><th>分/总</th><th>占比</th><th style='width: 30%'>可视化</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def kv_table(title: str, items: dict, *, total: float | None = None, ratio_keys: set[str] | None = None) -> str:
    if not items:
        return ""
    ratio_keys = ratio_keys or set()
    rows = []
    for k, v in items.items():
        if k in ratio_keys or (isinstance(k, str) and k.endswith("_ratio")):
            cell = fmt_num(v, 4 if isinstance(v, float) else 0)
        elif total is not None and isinstance(v, (int, float)) and not isinstance(v, bool):
            cell = fmt_part_total(v, total)
        else:
            cell = fmt_num(v, 4 if isinstance(v, float) else 0)
        rows.append(f"<tr><td>{esc(tr(k))}</td><td>{cell}</td></tr>")
    return (
        f"<h3>{esc(title)}</h3>"
        "<table><thead><tr><th>指标项</th><th>分/总</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def format_predict_dashboard_lines(predict: dict, flush: dict | None = None) -> tuple[str, str]:
    miss_bits: list[str] = []
    for rate_key, (part, total) in predict_miss_part_totals(predict, flush).items():
        label = rate_key.replace("_miss_rate", "")
        miss_bits.append(f"{label}={fmt_part_total(part, total)}")
    miss = " ".join(miss_bits) if miss_bits else "-"

    acc_bits: list[str] = []
    for rate_key, (part, total) in predict_accuracy_part_totals(predict).items():
        label = {
            "cond_selected_accuracy": "sel",
            "cond_local_accuracy": "local",
            "cond_global_accuracy": "global",
            "tage_table_hit_rate": "tage_hit",
        }.get(rate_key, rate_key)
        acc_bits.append(f"{label}={fmt_part_total(part, total)}")
    for rate_key, (part, total) in predict_ftb_part_totals(predict).items():
        if rate_key == "cond_hit_per_lookup_rate":
            acc_bits.append(f"ftb_cond={fmt_part_total(part, total)}")
        elif rate_key == "jump_hit_per_lookup_rate":
            acc_bits.append(f"ftb_jump={fmt_part_total(part, total)}")
    for rate_key, (part, total) in predict_ittage_part_totals(predict).items():
        if rate_key == "table_hit_per_lookup_rate":
            acc_bits.append(f"ittage={fmt_part_total(part, total)}")
    acc = " | ".join(acc_bits) if acc_bits else "-"
    return miss, acc


def render_hotspots_section(hotspots: dict) -> str:
    top_pc = hotspots.get("top_pc") or []
    top_inst = hotspots.get("top_inst") or []
    bpu_pc = hotspots.get("bpu_taken_control_pc_top") or []
    pc_total = float(sum(int(item.get("count", 0) or 0) for item in top_pc) or 1)
    inst_total = float(sum(int(item.get("count", 0) or 0) for item in top_inst) or 1)
    bpu_total = float(sum(int(item.get("count", 0) or 0) for item in bpu_pc) or 1)
    top_pc_rows = "".join(
        f"<tr><td>{esc(item.get('pc', '-'))}</td>"
        f"<td>{fmt_part_total(item.get('count', 0), pc_total)}</td></tr>"
        for item in top_pc[:8]
    )
    top_inst_rows = "".join(
        f"<tr><td>{esc(item.get('inst', '-'))}</td>"
        f"<td>{fmt_part_total(item.get('count', 0), inst_total)}</td></tr>"
        for item in top_inst[:8]
    )
    bpu_pc_rows = "".join(
        f"<tr><td>{esc(item.get('pc', '-'))}</td>"
        f"<td>{fmt_part_total(item.get('count', 0), bpu_total)}</td></tr>"
        for item in bpu_pc[:6]
    )
    update_kind = hotspots.get("bpu_update_kind") or {}
    return (
        "<details class='hotspots'>"
        "<summary>热点诊断 (Top PC / Inst / BPU)</summary>"
        "<div class='two-col' style='margin-top:12px'>"
        f"<div><h3>Top PC</h3><table><thead><tr><th>PC</th><th>分/总</th></tr></thead>"
        f"<tbody>{top_pc_rows or '<tr><td colspan=2>-</td></tr>'}</tbody></table></div>"
        f"<div><h3>Top Inst</h3><table><thead><tr><th>Inst</th><th>分/总</th></tr></thead>"
        f"<tbody>{top_inst_rows or '<tr><td colspan=2>-</td></tr>'}</tbody></table></div>"
        "</div>"
        f"{bar_table('BPU Update Kind', update_kind) if update_kind else ''}"
        f"<h3>BPU Taken Control PC</h3><table><thead><tr><th>PC</th><th>分/总</th></tr></thead>"
        f"<tbody>{bpu_pc_rows or '<tr><td colspan=2>-</td></tr>'}</tbody></table>"
        "</details>"
    )


def render_benchmark_section(bench_name: str, raw: dict) -> str:
    stall = bench_stall_category(raw)
    stall_total = float(bench_stall_total(raw) or 1.0)
    predict = bench_predict(raw)
    ifu = bench_ifu_fq(raw)
    control = bench_control(raw)
    flush = bench_flush(raw)
    hotspots = bench_hotspots(raw)
    commit_hist = bench_commit_width_hist(raw)
    cycles = bench_cycles(raw) or 1

    kpi_metrics = "".join(
        [
            metric_card(tr("IPC"), fmt_num(bench_ipc(raw))),
            metric_card(tr("CPI"), fmt_num(bench_cpi(raw))),
            metric_card(tr("Cycles"), fmt_num(cycles, 0)),
            metric_card(tr("Commits"), fmt_num(bench_commits(raw), 0)),
        ]
    )

    flush_metrics = "".join(
        [
            metric_card(tr("Flush"), fmt_num(flush.get("count", 0), 0)),
            metric_card(tr("BRU mispred"), fmt_num(flush.get("bru_mispred_count", flush.get("bru_count", 0)), 0)),
            metric_card(tr("Branch penalty"), fmt_num(flush.get("branch_penalty_cycles", 0), 0)),
            metric_card(tr("Flush/kCommit"), fmt_num(flush.get("per_kcommit", flush.get("per_kinst", 0)))),
        ]
    )

    mispredict = flush.get("mispredict") or {}
    stall_gate = {k: stall.get(k, 0) for k in STALL_CATEGORY_KEYS if stall.get(k, 0)}

    stall_detail_sections: list[str] = []
    for section_key, title in STALL_DETAIL_SECTIONS:
        detail = bench_stall_detail(raw, section_key)
        if detail:
            section_total = float(bench_stall_section_total(raw, section_key) or 1.0)
            stall_detail_sections.append(
                bar_table(f"Stall 明细 · {title}", detail, section_total)
            )

    predict_miss_rows = {
        tr(k): v for k, v in predict_miss_part_totals(predict, flush).items()
    }
    predict_acc_rows = {tr(k): v for k, v in predict_accuracy_part_totals(predict).items()}
    ftb_rows = {tr(k): v for k, v in predict_ftb_part_totals(predict).items()}
    ittage_rows = {tr(k): v for k, v in predict_ittage_part_totals(predict).items()}
    provider_rows = {tr(k): v for k, v in predict_provider_part_totals(predict).items()}
    predict_doc = bench_predict_doc(raw)
    predict_doc_html = ""
    if predict_doc:
        doc_rows = "".join(
            f"<tr><td>{esc(k)}</td><td>{esc(v)}</td></tr>"
            for k, v in sorted(predict_doc.items())
        )
        predict_doc_html = (
            "<details class='hotspots' style='margin-top:12px'>"
            "<summary>predict._doc 字段说明</summary>"
            f"<table><tbody>{doc_rows}</tbody></table></details>"
        )
    ifu_rows = {
        k: ifu[k]
        for k in (
            "fq_occ_avg",
            "fq_occ_max",
            "fq_bypass_ratio",
            "fq_full_ratio",
            "fq_empty_ratio",
            "fq_nonempty_ratio",
        )
        if k in ifu
    }

    mispredict_total = float(
        sum(v for k, v in mispredict.items() if k != "flush_count" and v) or 1.0
    )
    mispredict_diag = bench_mispredict_diag(raw)
    diag_detail = {
        tr(k): v
        for k, v in mispredict_diag.items()
        if k not in ("rollup", "classified_total") and v
    }
    rollup = mispredict_diag.get("rollup") or {}
    diag_rollup = {tr(k): v for k, v in rollup.items() if not k.endswith("_ratio") and v}
    diag_total = float(mispredict_diag.get("classified_total", 0) or mispredict.get("flush_count", 0) or 1.0)
    flush_count_total = float(flush.get("count", 0) or 1.0)
    commits_total = float(bench_commits(raw) or 1)

    return (
        f"<section class='bench card'><h2>{esc(bench_name)}</h2>"
        f"<div class='section'><div class='section-title'>KPI · 总体性能</div>"
        f"<div class='metric-grid'>{kpi_metrics}</div></div>"
        f"<div class='section'><div class='section-title'>Flush · 分支误预测代价</div>"
        f"<div class='metric-grid'>{flush_metrics}</div>"
        f"{bar_table('误预测分类', {tr(k): v for k, v in mispredict.items() if k != 'flush_count' and v}, mispredict_total)}"
        f"{bar_table('误预测根因细分', diag_detail, diag_total) if diag_detail else ''}"
        f"{bar_table('误预测根因汇总 (FTB vs BHT)', diag_rollup, diag_total) if diag_rollup else ''}"
        f"{bar_table('Flush 原因', flush.get('reason_histogram') or {}, flush_count_total)}"
        f"{bar_table('Commit 宽度分布', {str(k): v for k, v in commit_hist.items()}, float(cycles))}"
        f"</div>"
        f"<div class='section'><div class='section-title'>Stall · 无提交周期分析</div>"
        f"<div class='two-col'>"
        f"<div>{bar_table('Stall 八大类', stall_gate, stall_total)}"
        f"{''.join(stall_detail_sections[:2])}</div>"
        f"<div>{''.join(stall_detail_sections[2:])}</div>"
        f"</div></div>"
        f"<div class='section'><div class='section-title'>Predict · 分支预测 (见 predict._doc)</div>"
        f"{predict_doc_html}"
        f"<div class='two-col'>"
        f"<div>{part_total_bar_table('提交侧误预测 (flush.mispredict / retire_executed)', predict_miss_rows)}"
        f"{part_total_bar_table('BPU 训练自检', predict_acc_rows) if predict_acc_rows else ''}"
        f"{part_total_bar_table('Cond Provider', provider_rows) if provider_rows else ''}</div>"
        f"<div>{part_total_bar_table('FTB (lookup 侧)', ftb_rows) if ftb_rows else ''}"
        f"{part_total_bar_table('ITTAGE', ittage_rows) if ittage_rows else ''}"
        f"{kv_table('控制流统计', control, total=commits_total, ratio_keys={'control_ratio'})}"
        f"{kv_table('IFU Fetch Queue', ifu_rows, ratio_keys=set(ifu_rows.keys()))}</div>"
        f"</div></div>"
        f"<div class='section'><div class='section-title'>Hotspots · 代码热点</div>"
        f"{render_hotspots_section(hotspots)}</div>"
        "</section>"
    )


def render_run_summary_page(
    run_id: str,
    metadata: dict,
    summary: dict,
    *,
    dashboard_href: str = "../dashboard/index.html",
) -> str:
    display_name = metadata.get("display_name") or run_id
    schema_ver = summary.get("schema_version", 1)
    meta_bits = [
        f"<span><b>名称:</b> {esc(display_name)}</span>",
        f"<span><b>Run ID:</b> {esc(run_id)}</span>",
        f"<span><b>Schema:</b> v{esc(schema_ver)}</span>",
        f"<span><b>Git Commit:</b> {esc(metadata.get('git_sha') or '-')}</span>",
        f"<span><b>分支 (Branch):</b> {esc(metadata.get('git_branch') or '-')}</span>",
        f"<span><b>时间 (Created):</b> {esc(metadata.get('created_at') or '-')}</span>",
        f"<span><b>主机 (Host):</b> {esc(metadata.get('host') or '-')}</span>",
    ]
    bench_sections = [
        render_benchmark_section(bench, summary[bench])
        for bench in BENCHMARKS
        if bench in summary
    ]
    return (
        "<!DOCTYPE html><html lang='zh-CN'><head>"
        "<meta charset='UTF-8' /><meta name='viewport' content='width=device-width, initial-scale=1' />"
        f"<title>Profile Report · {esc(display_name)}</title>"
        f"<style>{SHARED_CSS}</style></head><body>"
        f"<p class='nav'><a href='{esc(dashboard_href)}'>← 返回看板 (Dashboard)</a></p>"
        f"<h1>性能分析报告 - {esc(display_name)}</h1>"
        f"<div class='meta'>{''.join(meta_bits)}</div>"
        f"{''.join(bench_sections)}"
        "<div style='margin-top: 32px; font-size: 13px; color: #57606a;'>"
        "原始数据：<code>summary.json</code>（schema v2 层级结构：meta / kpi / flush / stall / frontend / predict / hotspots）</div>"
        "</body></html>"
    )


def write_summary_html_for_run(run_dir: Path, run_id: str, metadata: dict | None = None) -> Path | None:
    summary_path = run_dir / "summary.json"
    if not summary_path.exists():
        return None
    meta = metadata
    if meta is None:
        meta_path = run_dir / "metadata.json"
        if meta_path.exists():
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        else:
            meta = {"run_id": run_id}
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    out_path = run_dir / "summary.html"
    out_path.write_text(
        render_run_summary_page(run_id, meta, summary, dashboard_href="../dashboard/index.html"),
        encoding="utf-8",
    )
    return out_path
