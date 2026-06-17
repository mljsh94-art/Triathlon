#!/usr/bin/env python3
"""Render a static HTML report from summary.json."""

from __future__ import annotations

import html
import json
from pathlib import Path

BENCHMARKS = ("dhrystone", "coremark", "microbench")
STALL_GATE_KEYS = ("frontend_empty", "rob_backpressure", "lsu_req_blocked")
STALL_DETAIL_KEYS = (
    "stall_decode_blocked_detail",
    "stall_frontend_empty_detail",
    "stall_rob_backpressure_detail",
    "stall_other_detail",
)
PREDICT_MISS_KEYS = (
    "cond_miss_rate",
    "jump_miss_rate",
    "ret_miss_rate",
    "jump_direct_miss_rate",
    "jump_indirect_miss_rate",
)
PREDICT_ACCURACY_KEYS = (
    "cond_selected_accuracy",
    "cond_local_accuracy",
    "cond_global_accuracy",
    "tage_hit_rate",
    "tage_override_accuracy",
    "sc_override_accuracy",
    "loop_override_accuracy",
)
FTB_RATE_KEYS = (
    "cond_hit_rate",
    "jump_hit_rate",
    "cond_pick_rate",
    "jump_pick_rate",
)
ITTAGE_RATE_KEYS = (
    "hit_rate",
    "use_rate",
)
MISPREDICT_DIAG_KEYS = (
    "dir_wrong",
    "dir_ok_target_wrong",
    "slot_offset_bind",
    "ftb_no_entry_tag_miss",
    "ftb_hit_cond_nt",
    "ftb_hit_out_of_range",
    "ftb_hit_shadowed",
    "ftb_snap_epoch_mismatch",
    "ftb_hit_out_of_range_epoch_ok",
    "ftb_hit_shadowed_epoch_ok",
    "ftb_unclassified",
    "ftb_miss",
    "other",
)

TRANSLATIONS = {
    "IPC": "IPC (每周期指令数)",
    "CPI": "CPI (每指令周期数)",
    "Cycles": "总周期数",
    "Commits": "提交指令数",
    "Flush": "流水线冲刷次数",
    "BRU": "分支解析次数 (BRU)",
    "Branch penalty": "分支惩罚周期",
    "Flush/kInst": "每千条指令冲刷",
    "frontend_empty": "前端空取 (Frontend Empty)",
    "rob_backpressure": "ROB 阻塞 (后端背压)",
    "lsu_req_blocked": "LSU 请求阻塞",
    "lsug_no_free_lane": "LSU 无空闲通道",
    "sb_alloc_blocked": "Store Buffer 分配阻塞",
    "lsug_wait_dcache_owner": "LSU 等待 D-Cache",
    "dc_store_wait_same_line": "D-Cache 相同行冲突",
    "pending_replay_wait_full": "等待队列满",
    "pending_replay_progress_full": "进行中队列满",
    "fe_wait_icache_rsp_hit_latency": "等待 I-Cache 命中延迟",
    "fe_req_fire_no_inflight": "前端无在途请求",
    "fe_redirect_recovery": "前端重定向恢复",
    "fe_wait_icache_rsp_miss_wait": "等待 I-Cache Miss",
    "rob_lsu_incomplete_sm_req_unknown": "LSU 状态机: 请求未知",
    "rob_lsu_incomplete_sm_rsp_unknown": "LSU 状态机: 响应未知",
    "rob_store_wait_commit": "Store 等待提交",
    "rob_lsu_wait_ld_rsp_valid": "LSU 等待 Load 响应",
    "rob_empty_refill_ren_fire": "ROB 空且 Rename 就绪",
    "rob_head_branch_wait_operand_or_select_incomplete_nonbp": "ROB头Branch: 等待操作数",
    "rob_head_lsu_incomplete_sm_req_unknown_nonbp": "ROB头LSU: 请求未知",
    "rob_head_lsu_incomplete_sm_rsp_unknown_nonbp": "ROB头LSU: 响应未知",
    "rob_head_lsu_incomplete_wait_rsp_valid_nonbp": "ROB头LSU: 等待响应有效",
    "rob_head_lsu_incomplete_sm_idle_nonbp": "ROB头LSU: 空闲",
    "rob_head_lsu_incomplete_wait_req_ready_nonbp": "ROB头LSU: 等待请求就绪",
    "rob_head_store_wait_commit_nonbp": "ROB头Store: 等待提交",
    "rob_head_branch_complete_not_visible_incomplete_nonbp": "ROB头Branch: 完成不可见",
    "rob_head_branch_exec_wait_wb_incomplete_nonbp": "ROB头Branch: 等待写回",
    "lsu_wait_wb_head_lsu_incomplete": "LSU 等待写回",
    "other": "其他 (Other)",
    "rob_head_store_wait_other_nonbp": "ROB头Store: 等待其他",
    "rob_head_store_wait_dcache_nonbp": "ROB头Store: 等待 D-Cache",
    "rob_head_alu_exec_wait_wb_incomplete_nonbp": "ROB头ALU: 等待写回",
    "rob_head_lsu_incomplete_wait_owner_or_alloc_nonbp": "ROB头LSU: 等待所有者分配",
    "rob_head_csr_incomplete_nonbp": "ROB头CSR: 未完成",
    "rob_lsu_incomplete_sm_idle": "LSU 状态机空闲",
    "rob_head_fu_branch_incomplete": "ROB头Branch 未完成",
    "rob_lsu_wait_ld_req_ready": "LSU 等待 Load 请求就绪",
    "rob_lsu_wait_ld_req_ready_sb_conflict": "LSU Load 请求 SB 冲突",
    "rob_lsu_wait_wb": "LSU 等待写回",
    "icache_miss_wait": "I-Cache Miss 等待",
    "dcache_miss_wait": "D-Cache Miss 等待",
    "flush_recovery": "Pipeline Flush 恢复",
    "decode_blocked": "Decode 阶段阻塞",
    "cond_miss_rate": "条件分支 (Conditional)",
    "jump_miss_rate": "无条件跳转 (占 mispredict redirect)",
    "ret_miss_rate": "函数返回 (Return)",
    "jump_direct_miss_rate": "直接跳转 (占 mispredict redirect)",
    "jump_indirect_miss_rate": "间接跳转 (占 mispredict redirect)",
    "cond_selected_accuracy": "条件分支方向 (Commit 选中精度)",
    "cond_local_accuracy": "条件分支 Local BHT",
    "cond_global_accuracy": "条件分支 Global BHT",
    "tage_hit_rate": "TAGE 命中率",
    "tage_override_accuracy": "TAGE Override 精度",
    "sc_override_accuracy": "SC Override 精度",
    "loop_override_accuracy": "Loop Override 精度",
    "cond_hit_rate": "FTB Cond Hit",
    "jump_hit_rate": "FTB Jump Hit",
    "cond_pick_rate": "FTB Cond Pick",
    "jump_pick_rate": "FTB Jump Pick",
    "hit_rate": "ITTAGE Hit",
    "use_rate": "ITTAGE Use",
    "dir_wrong": "方向错",
    "dir_ok_target_wrong": "方向对 Target 错",
    "slot_offset_bind": "Slot/Offset 绑错",
    "ftb_no_entry_tag_miss": "FTB 无项/Tag Miss",
    "ftb_hit_cond_nt": "FTB Hit 方向 NT",
    "ftb_hit_out_of_range": "FTB Hit 越 Range",
    "ftb_hit_shadowed": "FTB Hit 被遮蔽",
    "ftb_snap_epoch_mismatch": "FTB Snap Epoch 不匹配",
    "ftb_hit_out_of_range_epoch_ok": "FTB Hit 越 Range (Epoch 匹配)",
    "ftb_hit_shadowed_epoch_ok": "FTB Hit 被遮蔽 (Epoch 匹配)",
    "ftb_unclassified": "FTB 未分类",
    "ftb_miss": "FTB Fallthrough 合计",
    "legacy_accuracy": "Legacy Provider",
    "tage_accuracy": "TAGE Provider",
    "sc_accuracy": "SC Provider",
    "loop_accuracy": "Loop Provider",
    "fq_occ_avg": "平均占用量",
    "fq_occ_max": "最大占用量",
    "fq_bypass_ratio": "Bypass 比例",
    "fq_full_ratio": "队列满比例",
    "fq_empty_ratio": "队列空比例",
    "fq_nonempty_ratio": "队列非空比例",
    "cond_branch": "条件分支",
    "return": "函数返回",
    "jump": "无条件跳转",
    "jump_direct": "直接跳转",
    "jump_indirect": "间接跳转",
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
            f"<td>{fmt_num(int(val) if val == int(val) else val, 0 if val == int(val) else 2)}</td>"
            f"<td>{pct:.1f}%</td>"
            f"<td><div class='bar'><div class='bar-fill {bar_class}' style='width:{min(pct, 100):.1f}%'></div></div></td>"
            "</tr>"
        )
    return (
        f"<h3>{esc(title)}</h3>"
        "<table><thead><tr><th>指标项</th><th>计数</th><th>占比</th><th style='width: 30%'>可视化</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def kv_table(title: str, items: dict) -> str:
    if not items:
        return ""
    rows = "".join(
        f"<tr><td>{esc(tr(k))}</td><td>{fmt_num(v, 4 if isinstance(v, float) else 0)}</td></tr>"
        for k, v in items.items()
    )
    return f"<h3>{esc(title)}</h3><table><thead><tr><th>指标项</th><th>数值</th></tr></thead><tbody>{rows}</tbody></table>"


def predict_miss_rows(predict: dict) -> dict[str, float]:
    return {k: float(predict.get(k, 0) or 0) for k in PREDICT_MISS_KEYS if k in predict}


def predict_accuracy_rows(predict: dict) -> dict[str, float]:
    return {k: float(predict.get(k, 0) or 0) for k in PREDICT_ACCURACY_KEYS if k in predict}


def nested_rate_rows(section: dict | None, keys: tuple[str, ...]) -> dict[str, float]:
    if not section:
        return {}
    return {k: float(section.get(k, 0) or 0) for k in keys if k in section}


def provider_accuracy_rows(provider: dict | None) -> dict[str, float]:
    if not provider:
        return {}
    return {
        k: float(provider.get(k, 0) or 0)
        for k in ("legacy_accuracy", "tage_accuracy", "sc_accuracy", "loop_accuracy")
        if k in provider
    }


def mispredict_diag_rows(data: dict) -> dict[str, float]:
    diag = data.get("mispredict_diag", {}) or {}
    return {k: float(diag.get(k, 0) or 0) for k in MISPREDICT_DIAG_KEYS if diag.get(k, 0)}


def format_predict_dashboard_lines(predict: dict) -> tuple[str, str]:
    """Return (miss line, accuracy line) for dashboard Run Details."""
    miss = (
        f"cond={predict.get('cond_miss_rate', 0):.4f} "
        f"jump={predict.get('jump_miss_rate', 0):.4f} "
        f"ret={predict.get('ret_miss_rate', 0):.4f}"
    )
    acc_bits: list[str] = []
    for key, label in (
        ("cond_selected_accuracy", "sel"),
        ("cond_local_accuracy", "local"),
        ("cond_global_accuracy", "global"),
        ("tage_hit_rate", "tage_hit"),
    ):
        if key in predict:
            acc_bits.append(f"{label}={float(predict.get(key, 0) or 0):.4f}")
    ftb = predict.get("ftb") or {}
    if "cond_hit_rate" in ftb:
        acc_bits.append(f"ftb_cond={float(ftb.get('cond_hit_rate', 0) or 0):.4f}")
    if "jump_hit_rate" in ftb:
        acc_bits.append(f"ftb_jump={float(ftb.get('jump_hit_rate', 0) or 0):.4f}")
    ittage = predict.get("ittage") or {}
    if "hit_rate" in ittage:
        acc_bits.append(f"ittage={float(ittage.get('hit_rate', 0) or 0):.4f}")
    acc = " | ".join(acc_bits) if acc_bits else "-"
    return miss, acc


def render_benchmark_section(bench_name: str, data: dict) -> str:
    stall = data.get("stall_category", {}) or {}
    stall_total = float(data.get("stall_total", 0) or 0) or 1.0
    predict = data.get("predict", {}) or {}
    ifu = data.get("ifu_fq", {}) or {}
    control = data.get("control", {}) or {}

    metrics = "".join(
        [
            metric_card(tr("IPC"), fmt_num(data.get("ipc", 0))),
            metric_card(tr("CPI"), fmt_num(data.get("cpi", 0))),
            metric_card(tr("Cycles"), fmt_num(data.get("cycles", 0), 0)),
            metric_card(tr("Commits"), fmt_num(data.get("commits", 0), 0)),
            metric_card(tr("Flush"), fmt_num(data.get("flush_count", 0), 0)),
            metric_card(tr("BRU"), fmt_num(data.get("bru_count", 0), 0)),
            metric_card(tr("Branch penalty"), fmt_num(data.get("branch_penalty_cycles", 0), 0)),
            metric_card(tr("Flush/kInst"), fmt_num(data.get("flush_per_kinst", 0))),
        ]
    )

    stall_gate = {
        k: stall.get(k, 0) for k in STALL_GATE_KEYS if stall.get(k, 0)
    }
    stall_sections = [bar_table("Stall 分类", stall, stall_total)]
    for detail_key in STALL_DETAIL_KEYS:
        detail = data.get(detail_key, {}) or {}
        if detail:
            title = detail_key.removeprefix("stall_").removesuffix("_detail").replace("_", " ")
            if title == "decode blocked":
                title = "Decode 阻塞"
            elif title == "frontend empty":
                title = "前端空取"
            elif title == "rob backpressure":
                title = "ROB 背压"
            elif title == "other":
                title = "其他"
            stall_sections.append(bar_table(f"Stall 明细 · {title}", detail))

    predict_rows = predict_miss_rows(predict)
    predict_acc_rows = predict_accuracy_rows(predict)
    ftb_rows = nested_rate_rows(predict.get("ftb"), FTB_RATE_KEYS)
    ittage_rows = nested_rate_rows(predict.get("ittage"), ITTAGE_RATE_KEYS)
    provider_rows = provider_accuracy_rows(predict.get("cond_provider"))
    diag_rows = mispredict_diag_rows(data)
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

    top_pc_rows = "".join(
        f"<tr><td>{esc(item.get('pc', '-'))}</td><td>{fmt_num(item.get('count', 0), 0)}</td></tr>"
        for item in (data.get("top_pc") or [])[:8]
    )
    top_inst_rows = "".join(
        f"<tr><td>{esc(item.get('inst', '-'))}</td><td>{fmt_num(item.get('count', 0), 0)}</td></tr>"
        for item in (data.get("top_inst") or [])[:8]
    )

    mispredict = data.get("mispredict_breakdown", {}) or {}
    flush_hist = data.get("flush_reason_histogram", {}) or {}
    commit_hist = data.get("commit_width_hist", {}) or {}

    return (
        f"<section class='bench card'><h2>{esc(bench_name)}</h2>"
        f"<div class='metric-grid'>{metrics}</div>"
        f"<div class='two-col' style='margin-top:16px'>"
        f"<div>{''.join(stall_sections[:2])}</div>"
        f"<div>{bar_table('预测 miss 率', {k: float(v) * 100 for k, v in predict_rows.items()}, 100.0)}"
        f"{bar_table('方向预测精度 (Commit 侧)', {k: float(v) * 100 for k, v in predict_acc_rows.items()}, 100.0) if predict_acc_rows else ''}"
        f"{bar_table('FTB 命中率 (Fetch 侧)', {k: float(v) * 100 for k, v in ftb_rows.items()}, 100.0) if ftb_rows else ''}"
        f"{bar_table('ITTAGE (间接跳转)', {k: float(v) * 100 for k, v in ittage_rows.items()}, 100.0) if ittage_rows else ''}"
        f"{bar_table('Cond Provider 精度', {k: float(v) * 100 for k, v in provider_rows.items()}, 100.0) if provider_rows else ''}"
        f"{kv_table('IFU Fetch Queue', ifu_rows)}"
        f"{bar_table('Mispredict 分类 (Insn)', mispredict)}"
        f"{bar_table('Mispredict 诊断 (Flush)', diag_rows) if diag_rows else ''}"
        f"{bar_table('Flush 原因', flush_hist)}"
        f"{bar_table('Commit 宽度分布', {str(k): v for k, v in commit_hist.items()}, float(data.get('cycles', 1) or 1))}"
        f"{kv_table('控制流', control)}"
        f"</div></div>"
        f"<div class='two-col' style='margin-top:16px'>"
        f"<div>{''.join(stall_sections[2:])}</div>"
        f"<div>"
        f"<h3>Top PC</h3><table><thead><tr><th>PC 指令地址</th><th>命中次数</th></tr></thead><tbody>{top_pc_rows or '<tr><td colspan=2>-</td></tr>'}</tbody></table>"
        f"<h3 style='margin-top:16px'>Top Inst</h3><table><thead><tr><th>Inst 指令编码</th><th>命中次数</th></tr></thead><tbody>{top_inst_rows or '<tr><td colspan=2>-</td></tr>'}</tbody></table>"
        f"</div></div>"
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
    meta_bits = [
        f"<span><b>名称:</b> {esc(display_name)}</span>",
        f"<span><b>Run ID:</b> {esc(run_id)}</span>",
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
        "<div style='margin-top: 32px; font-size: 13px; color: #57606a;'>原始数据：<code>summary.json</code>（同目录）</div>"
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
