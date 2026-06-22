#!/usr/bin/env python3
"""Profile summary JSON schema (v2) helpers and v1 flat-layout compatibility."""

from __future__ import annotations

from typing import Any

SCHEMA_VERSION = 2

# Collected by profile-report and shown on dashboard / regression compare.
PROFILE_BENCHMARKS = ("coremark", "microbench")

STALL_CATEGORY_KEYS = (
    "flush_recovery",
    "icache_miss_wait",
    "dcache_miss_wait",
    "rob_backpressure",
    "frontend_empty",
    "decode_blocked",
    "lsu_req_blocked",
    "other",
)

PREDICT_MISS_RATE_KEYS = (
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


def _dig(data: dict | None, *path: str, default: Any = None) -> Any:
    cur: Any = data
    for key in path:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(key)
        if cur is None:
            return default
    return cur


def is_v2_bench(bench: dict) -> bool:
    return isinstance(bench.get("kpi"), dict) or bench.get("schema_version") == SCHEMA_VERSION


def bench_ipc(bench: dict) -> float:
    return float(_dig(bench, "kpi", "ipc", default=bench.get("ipc", 0.0)) or 0.0)


def bench_cpi(bench: dict) -> float:
    return float(_dig(bench, "kpi", "cpi", default=bench.get("cpi", 0.0)) or 0.0)


def bench_cycles(bench: dict) -> int:
    return int(_dig(bench, "kpi", "cycles", default=bench.get("cycles", 0)) or 0)


def bench_commits(bench: dict) -> int:
    return int(_dig(bench, "kpi", "commits", default=bench.get("commits", 0)) or 0)


def bench_stall_total(bench: dict) -> int:
    return int(_dig(bench, "stall", "total", default=bench.get("stall_total", 0)) or 0)


def bench_stall_category(bench: dict) -> dict[str, int | float]:
    cat = _dig(bench, "stall", "category")
    if isinstance(cat, dict):
        return cat
    legacy = bench.get("stall_category")
    return legacy if isinstance(legacy, dict) else {}


def bench_stall_detail(bench: dict, section: str) -> dict:
    """section: decode_blocked | rob_backpressure | frontend_empty | other"""
    detail = _dig(bench, "stall", section, "detail")
    if isinstance(detail, dict):
        return detail
    legacy_key = f"stall_{section}_detail"
    legacy = bench.get(legacy_key)
    return legacy if isinstance(legacy, dict) else {}


def bench_stall_section_total(bench: dict, section: str) -> int:
    total = _dig(bench, "stall", section, "total")
    if total is not None:
        return int(total or 0)
    legacy_key = f"stall_{section}_total"
    if legacy_key in bench:
        return int(bench.get(legacy_key) or 0)
    detail = bench_stall_detail(bench, section)
    return int(sum(float(v) for v in detail.values()))


def bench_stall_other_aux(bench: dict) -> dict:
    aux = _dig(bench, "stall", "other", "aux")
    if isinstance(aux, dict):
        return aux
    legacy = bench.get("stall_other_aux")
    return legacy if isinstance(legacy, dict) else {}


def bench_commit_width_hist(bench: dict) -> dict:
    hist = _dig(bench, "commit", "width_hist")
    if isinstance(hist, dict):
        return hist
    legacy = bench.get("commit_width_hist")
    return legacy if isinstance(legacy, dict) else {}


def bench_ifu_fq(bench: dict) -> dict:
    fq = _dig(bench, "frontend", "ifu_fq")
    if isinstance(fq, dict):
        return fq
    legacy = bench.get("ifu_fq")
    return legacy if isinstance(legacy, dict) else {}


def bench_control(bench: dict) -> dict:
    ctrl = bench.get("control")
    return ctrl if isinstance(ctrl, dict) else {}


def bench_predict(bench: dict) -> dict:
    pred = bench.get("predict")
    return pred if isinstance(pred, dict) else {}


def bench_hotspots(bench: dict) -> dict:
    hs = bench.get("hotspots")
    if isinstance(hs, dict):
        return hs
    return {
        "top_pc": bench.get("top_pc") or [],
        "top_inst": bench.get("top_inst") or [],
        "bpu_taken_control_pc_top": bench.get("bpu_taken_control_pc_top") or [],
        "bpu_update_pc_top": bench.get("bpu_update_pc_top") or [],
        "bpu_update_kind": bench.get("bpu_update_kind") or {},
    }


def bench_flush(bench: dict) -> dict:
    flush = bench.get("flush")
    if isinstance(flush, dict):
        return flush
    return {
        "count": bench.get("flush_count", 0),
        "bru_count": bench.get("bru_count", 0),
        "per_kinst": bench.get("flush_per_kinst", 0.0),
        "bru_per_kinst": bench.get("bru_per_kinst", 0.0),
        "branch_penalty_cycles": bench.get("branch_penalty_cycles", 0),
        "wrong_path_kill_uops": bench.get("wrong_path_kill_uops", 0),
        "mispredict": {
            "flush_count": bench.get("mispredict_flush_count", 0),
            "cond": bench.get("mispredict_cond_count", 0),
            "jump": bench.get("mispredict_jump_count", 0),
            "jump_direct": bench.get("mispredict_jump_direct_count", 0),
            "jump_indirect": bench.get("mispredict_jump_indirect_count", 0),
            "ret": bench.get("mispredict_ret_count", 0),
        },
        "redirect": {
            "distance_sum": bench.get("redirect_distance_sum", 0),
            "distance_samples": bench.get("redirect_distance_samples", 0),
            "distance_avg": bench.get("redirect_distance_avg", 0.0),
            "distance_max": bench.get("redirect_distance_max", 0),
        },
        "reason_histogram": bench.get("flush_reason_histogram") or {},
        "source_histogram": bench.get("flush_source_histogram") or {},
    }


def bench_mispredict_diag(bench: dict) -> dict:
    flush = bench_flush(bench)
    diag = flush.get("mispredict_diag")
    return diag if isinstance(diag, dict) else {}


def bench_mispredict_diag_rollup(bench: dict) -> dict:
    diag = bench_mispredict_diag(bench)
    rollup = diag.get("rollup")
    return rollup if isinstance(rollup, dict) else {}


def bench_meta(bench: dict) -> dict:
    meta = bench.get("meta")
    if isinstance(meta, dict):
        return meta
    return {
        k: bench.get(k)
        for k in (
            "log_path",
            "has_commit_detail",
            "has_commit_summary",
            "stall_mode",
            "commit_metrics_source",
            "stall_metrics_source",
            "quality_warnings",
            "host_time_us",
            "host_time_ms",
            "bench_reported_time_ms",
            "effective_benchmark_time_ms",
            "benchmark_time_source",
        )
        if k in bench
    }


def stall_share_pct(bench: dict, key: str) -> float:
    stall_total = float(bench_stall_total(bench))
    stall_cat = bench_stall_category(bench)
    if stall_total <= 0:
        return 0.0
    return float(stall_cat.get(key, 0)) / stall_total * 100.0


def predict_miss_rates(predict: dict) -> dict[str, float]:
    return {
        k: float(predict.get(k, 0) or 0)
        for k in PREDICT_MISS_RATE_KEYS
        if k in predict
    }


def predict_accuracy_rates(predict: dict) -> dict[str, float]:
    return {
        k: float(predict.get(k, 0) or 0)
        for k in PREDICT_ACCURACY_KEYS
        if k in predict
    }


def top_stall_categories(bench: dict, limit: int = 3) -> list[tuple[str, int | float, float]]:
    stall_total = float(bench_stall_total(bench) or 1.0)
    items = [
        (k, float(bench_stall_category(bench).get(k, 0) or 0))
        for k in STALL_CATEGORY_KEYS
    ]
    items = [(k, v) for k, v in items if v > 0]
    items.sort(key=lambda kv: kv[1], reverse=True)
    return [(k, v, 100.0 * v / stall_total) for k, v in items[:limit]]


def part_total_pair(data: dict | None, part_key: str, total_key: str) -> tuple[float, float] | None:
    if not data or part_key not in data or total_key not in data:
        return None
    part = float(data.get(part_key, 0) or 0)
    total = float(data.get(total_key, 0) or 0)
    return part, total


def predict_miss_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    rows: dict[str, tuple[float, float]] = {}
    specs = (
        ("cond_miss_rate", "cond_miss", "cond_total"),
        ("jump_miss_rate", "jump_miss", "redirect_total"),
        ("ret_miss_rate", "ret_miss", "ret_total"),
        ("jump_direct_miss_rate", "jump_direct_miss", "redirect_total"),
        ("jump_indirect_miss_rate", "jump_indirect_miss", "redirect_total"),
    )
    for rate_key, part_key, total_key in specs:
        pair = part_total_pair(predict, part_key, total_key)
        if pair is not None:
            rows[rate_key] = pair
    return rows


def predict_accuracy_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    rows: dict[str, tuple[float, float]] = {}
    specs = (
        ("cond_selected_accuracy", "cond_selected_correct", "cond_update_total"),
        ("cond_local_accuracy", "cond_local_correct", "cond_update_total"),
        ("cond_global_accuracy", "cond_global_correct", "cond_update_total"),
        ("tage_hit_rate", "tage_hit_total", "tage_lookup_total"),
        ("tage_override_accuracy", "tage_override_correct", "tage_override_total"),
        ("sc_override_accuracy", "sc_override_correct", "sc_override_total"),
        ("loop_override_accuracy", "loop_override_correct", "loop_override_total"),
    )
    for rate_key, part_key, total_key in specs:
        pair = part_total_pair(predict, part_key, total_key)
        if pair is not None:
            rows[rate_key] = pair
    return rows


def predict_provider_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    provider = predict.get("cond_provider")
    if not isinstance(provider, dict):
        return {}
    rows: dict[str, tuple[float, float]] = {}
    specs = (
        ("legacy_accuracy", "legacy_correct", "legacy_selected"),
        ("tage_accuracy", "tage_correct", "tage_selected"),
        ("sc_accuracy", "sc_correct", "sc_selected"),
        ("loop_accuracy", "loop_correct", "loop_selected"),
    )
    for rate_key, part_key, total_key in specs:
        pair = part_total_pair(provider, part_key, total_key)
        if pair is not None:
            rows[rate_key] = pair
    return rows


def predict_ftb_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    ftb = predict.get("ftb")
    if not isinstance(ftb, dict):
        return {}
    rows: dict[str, tuple[float, float]] = {}
    specs = (
        ("cond_hit_rate", "cond_hit_total", "lookup_total"),
        ("jump_hit_rate", "jump_hit_total", "lookup_total"),
        ("cond_pick_rate", "cond_pick_total", "lookup_total"),
        ("jump_pick_rate", "jump_pick_total", "lookup_total"),
    )
    for rate_key, part_key, total_key in specs:
        pair = part_total_pair(ftb, part_key, total_key)
        if pair is not None:
            rows[rate_key] = pair
    return rows


def predict_ittage_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    ittage = predict.get("ittage")
    if not isinstance(ittage, dict):
        return {}
    rows: dict[str, tuple[float, float]] = {}
    specs = (
        ("hit_rate", "hit_total", "lookup_total"),
        ("use_rate", "use_total", "lookup_total"),
    )
    for rate_key, part_key, total_key in specs:
        pair = part_total_pair(ittage, part_key, total_key)
        if pair is not None:
            rows[rate_key] = pair
    return rows
