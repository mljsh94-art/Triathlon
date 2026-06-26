#!/usr/bin/env python3
"""Profile summary JSON schema (v2) helpers and v1 flat-layout compatibility."""

from __future__ import annotations

from typing import Any

SCHEMA_VERSION = 2

PROFILE_BENCHMARKS = ("coremark", "microbench")

STALL_CATEGORY_KEYS = (
    "flush_recovery",
    "icache_miss_wait",
    "dcache_miss_wait",
    "rob_backpressure",
    "frontend_empty",
    "decode_blocked",
    "lsu_req_blocked",
    "pipeline_bubble",
)

# Flat retire_miss_rate keys (dashboard / index).
RETIRE_MISS_RATE_KEYS = (
    "cond_miss_rate",
    "jump_miss_rate",
    "ret_miss_rate",
    "jump_direct_miss_rate",
    "jump_indirect_miss_rate",
)

PREDICT_BPU_TRAIN_KEYS = ("cond_selected_accuracy",)

PREDICT_TAGE_KEYS = ("table_hit_rate", "override_accuracy")

PREDICT_FTB_RATE_KEYS = ("cond_pick_rate", "jump_pick_rate")

PREDICT_ITTAGE_KEYS = ("table_hit_rate", "use_rate")

PREDICT_PROVIDER_KEYS = ("legacy_accuracy", "tage_accuracy")


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
        if "pipeline_bubble" not in cat and "other" in cat:
            cat = dict(cat)
            cat["pipeline_bubble"] = cat["other"]
        return cat
    legacy = bench.get("stall_category")
    if isinstance(legacy, dict):
        if "pipeline_bubble" not in legacy and "other" in legacy:
            legacy = dict(legacy)
            legacy["pipeline_bubble"] = legacy["other"]
        return legacy
    return {}


def bench_stall_detail(bench: dict, section: str) -> dict:
    """section: decode_blocked | rob_backpressure | frontend_empty | pipeline_bubble | hol_load_detail"""
    if section == "hol_load_detail":
        detail = _dig(bench, "stall", "hol_load_detail", "detail")
        return detail if isinstance(detail, dict) else {}
    detail = _dig(bench, "stall", section, "detail")
    if isinstance(detail, dict):
        return detail
    if section == "pipeline_bubble":
        legacy_detail = _dig(bench, "stall", "other", "detail")
        if isinstance(legacy_detail, dict):
            return legacy_detail
    legacy_key = f"stall_{section}_detail"
    legacy = bench.get(legacy_key)
    return legacy if isinstance(legacy, dict) else {}


def bench_stall_section_total(bench: dict, section: str) -> int:
    if section == "hol_load_detail":
        detail = bench_stall_detail(bench, section)
        return int(detail.get("hol_load_no_lane", 0) or 0)
    total = _dig(bench, "stall", section, "total")
    if total is not None:
        return int(total or 0)
    if section == "pipeline_bubble":
        legacy_total = _dig(bench, "stall", "other", "total")
        if legacy_total is not None:
            return int(legacy_total or 0)
    legacy_key = f"stall_{section}_total"
    if legacy_key in bench:
        return int(bench.get(legacy_key) or 0)
    detail = bench_stall_detail(bench, section)
    return int(sum(float(v) for v in detail.values()))


def bench_stall_other_aux(bench: dict) -> dict:
    aux = _dig(bench, "stall", "pipeline_bubble", "aux")
    if isinstance(aux, dict):
        return aux
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


def bench_predict_doc(bench: dict) -> dict[str, str]:
    doc = _dig(bench, "predict", "_doc")
    return doc if isinstance(doc, dict) else {}


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
        out = dict(flush)
        if "bru_mispred_count" not in out and "bru_count" in out:
            out["bru_mispred_count"] = out["bru_count"]
        if "per_kcommit" not in out and "per_kinst" in out:
            out["per_kcommit"] = out["per_kinst"]
        if "bru_per_kcommit" not in out and "bru_per_kinst" in out:
            out["bru_per_kcommit"] = out["bru_per_kinst"]
        redirect = out.get("redirect")
        if isinstance(redirect, dict):
            redirect_out = dict(redirect)
            if "pc_delta_bytes_sum" not in redirect_out and "distance_sum" in redirect_out:
                redirect_out["pc_delta_bytes_sum"] = redirect_out["distance_sum"]
            if "pc_delta_bytes_samples" not in redirect_out and "distance_samples" in redirect_out:
                redirect_out["pc_delta_bytes_samples"] = redirect_out["distance_samples"]
            if "pc_delta_bytes_avg" not in redirect_out and "distance_avg" in redirect_out:
                redirect_out["pc_delta_bytes_avg"] = redirect_out["distance_avg"]
            if "pc_delta_bytes_max" not in redirect_out and "distance_max" in redirect_out:
                redirect_out["pc_delta_bytes_max"] = redirect_out["distance_max"]
            out["redirect"] = redirect_out
        return out
    redirect = {
        "pc_delta_bytes_sum": bench.get("redirect_distance_sum", 0),
        "pc_delta_bytes_samples": bench.get("redirect_distance_samples", 0),
        "pc_delta_bytes_avg": bench.get("redirect_distance_avg", 0.0),
        "pc_delta_bytes_max": bench.get("redirect_distance_max", 0),
    }
    return {
        "count": bench.get("flush_count", 0),
        "bru_mispred_count": bench.get("bru_count", 0),
        "per_kcommit": bench.get("flush_per_kinst", 0.0),
        "bru_per_kcommit": bench.get("bru_per_kinst", 0.0),
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
        "redirect": redirect,
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


def part_total_pair(data: dict | None, part_key: str, total_key: str) -> tuple[float, float] | None:
    if not data or part_key not in data or total_key not in data:
        return None
    part = float(data.get(part_key, 0) or 0)
    total = float(data.get(total_key, 0) or 0)
    return part, total


def _legacy_retire_miss_rows(predict: dict) -> dict[str, tuple[float, float]]:
    specs = (
        ("cond_miss_rate", "cond_miss", "cond_total"),
        ("jump_miss_rate", "jump_miss", "jump_total"),
        ("ret_miss_rate", "ret_miss", "ret_total"),
        ("jump_direct_miss_rate", "jump_direct_miss", "jump_direct_total"),
        ("jump_indirect_miss_rate", "jump_indirect_miss", "jump_indirect_total"),
    )
    rows: dict[str, tuple[float, float]] = {}
    for rate_key, part_key, total_key in specs:
        pair = part_total_pair(predict, part_key, total_key)
        if pair is not None:
            rows[rate_key] = pair
    return rows


def predict_miss_part_totals(predict: dict, flush: dict | None = None) -> dict[str, tuple[float, float]]:
    retire_rates = predict.get("retire_miss_rate")
    retire_executed = predict.get("retire_executed")
    mispredict = (flush or {}).get("mispredict") if isinstance(flush, dict) else None
    if isinstance(retire_rates, dict) and isinstance(retire_executed, dict) and isinstance(mispredict, dict):
        mapping = (
            ("cond_miss_rate", "cond", "cond"),
            ("jump_miss_rate", "jump", "jump"),
            ("jump_direct_miss_rate", "jump_direct", "jump_direct"),
            ("jump_indirect_miss_rate", "jump_indirect", "jump_indirect"),
            ("ret_miss_rate", "ret", "ret"),
        )
        rows: dict[str, tuple[float, float]] = {}
        for rate_key, miss_key, exec_key in mapping:
            miss = mispredict.get(miss_key)
            executed = retire_executed.get(exec_key)
            if miss is None or executed is None:
                continue
            rows[rate_key] = (float(miss), float(executed))
        return rows
    return _legacy_retire_miss_rows(predict)


def predict_miss_rates(predict: dict, flush: dict | None = None) -> dict[str, float]:
    retire_rates = predict.get("retire_miss_rate")
    if isinstance(retire_rates, dict):
        return {
            "cond_miss_rate": float(retire_rates.get("cond", 0) or 0),
            "jump_miss_rate": float(retire_rates.get("jump", 0) or 0),
            "ret_miss_rate": float(retire_rates.get("ret", 0) or 0),
            "jump_direct_miss_rate": float(retire_rates.get("jump_direct", 0) or 0),
            "jump_indirect_miss_rate": float(retire_rates.get("jump_indirect", 0) or 0),
        }
    return {
        k: float(predict.get(k, 0) or 0)
        for k in RETIRE_MISS_RATE_KEYS
        if k in predict
    }


def predict_accuracy_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    rows: dict[str, tuple[float, float]] = {}
    bpu_train = predict.get("bpu_train")
    if isinstance(bpu_train, dict):
        pair = part_total_pair(bpu_train, "cond_selected_correct", "cond_updates")
        if pair is not None:
            rows["cond_selected_accuracy"] = pair
    else:
        pair = part_total_pair(predict, "cond_selected_correct", "cond_update_total")
        if pair is not None:
            rows["cond_selected_accuracy"] = pair
        for rate_key, part_key, total_key in (
            ("cond_local_accuracy", "cond_local_correct", "cond_update_total"),
            ("cond_global_accuracy", "cond_global_correct", "cond_update_total"),
        ):
            pair = part_total_pair(predict, part_key, total_key)
            if pair is not None:
                rows[rate_key] = pair

    tage = predict.get("tage")
    if isinstance(tage, dict):
        lookups = float(tage.get("lookups", tage.get("lookup_total", 0)) or 0)
        if lookups > 0 and "table_hits" in tage:
            rows["tage_table_hit_rate"] = (float(tage.get("table_hits", 0) or 0), lookups)
        overrides = float(tage.get("override_updates", 0) or 0)
        if overrides > 0 and "override_correct" in tage:
            rows["tage_override_accuracy"] = (float(tage.get("override_correct", 0) or 0), overrides)
    else:
        for rate_key, part_key, total_key in (
            ("tage_table_hit_rate", "tage_hit_total", "tage_lookup_total"),
            ("tage_override_accuracy", "tage_override_correct", "tage_override_total"),
        ):
            pair = part_total_pair(predict, part_key, total_key)
            if pair is not None:
                rows[rate_key] = pair

    return rows


def predict_ftb_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    ftb = predict.get("ftb")
    if not isinstance(ftb, dict):
        ftb = predict.get("ftb") if isinstance(predict.get("ftb"), dict) else {}
    if not isinstance(ftb, dict):
        return {}
    lookups = float(ftb.get("lookups", ftb.get("lookup_total", 0)) or 0)
    if lookups <= 0:
        return {}
    rows: dict[str, tuple[float, float]] = {}
    for rate_key, rate_val, part_key in (
        ("cond_pick_rate", ftb.get("cond_pick_rate", 0), "cond_pick_total"),
        ("jump_pick_rate", ftb.get("jump_pick_rate", 0), "jump_pick_total"),
        ("cond_hit_per_lookup_rate", ftb.get("cond_hit_per_lookup_rate", 0), "cond_hit_total"),
        ("jump_hit_per_lookup_rate", ftb.get("jump_hit_per_lookup_rate", 0), "jump_hit_total"),
    ):
        if part_key in ftb:
            rows[rate_key] = (float(ftb.get(part_key, 0) or 0), lookups)
        elif rate_val:
            rows[rate_key] = (float(rate_val) * lookups, lookups)
    return rows


def predict_ittage_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    ittage = predict.get("ittage")
    if not isinstance(ittage, dict):
        return {}
    lookups = float(ittage.get("lookups", ittage.get("lookup_total", 0)) or 0)
    if lookups <= 0:
        return {}
    rows: dict[str, tuple[float, float]] = {}
    if "table_hits" in ittage:
        rows["table_hit_per_lookup_rate"] = (float(ittage.get("table_hits", 0) or 0), lookups)
    if "uses" in ittage:
        rows["use_per_lookup_rate"] = (float(ittage.get("uses", 0) or 0), lookups)
    return rows


def predict_provider_part_totals(predict: dict) -> dict[str, tuple[float, float]]:
    provider = predict.get("provider")
    if isinstance(provider, dict) and "legacy" in provider:
        rows: dict[str, tuple[float, float]] = {}
        for name, rate_key in (("legacy", "legacy_accuracy"), ("tage", "tage_accuracy")):
            block = provider.get(name)
            if not isinstance(block, dict):
                continue
            pair = part_total_pair(block, "correct", "selected")
            if pair is None:
                selected = float(block.get("selected", 0) or 0)
                if selected > 0:
                    acc = float(block.get("accuracy", 0) or 0)
                    rows[rate_key] = (acc * selected, selected)
            else:
                rows[rate_key] = pair
        return rows
    legacy_provider = predict.get("cond_provider")
    if not isinstance(legacy_provider, dict):
        return {}
    rows: dict[str, tuple[float, float]] = {}
    for rate_key, part_key, total_key in (
        ("legacy_accuracy", "legacy_correct", "legacy_selected"),
        ("tage_accuracy", "tage_correct", "tage_selected"),
        ("sc_accuracy", "sc_correct", "sc_selected"),
        ("loop_accuracy", "loop_correct", "loop_selected"),
    ):
        pair = part_total_pair(legacy_provider, part_key, total_key)
        if pair is not None:
            rows[rate_key] = pair
    return rows


def top_stall_categories(bench: dict, limit: int = 3) -> list[tuple[str, int | float, float]]:
    stall_total = float(bench_stall_total(bench) or 1.0)
    items = [
        (k, float(bench_stall_category(bench).get(k, 0) or 0))
        for k in STALL_CATEGORY_KEYS
    ]
    items = [(k, v) for k, v in items if v > 0]
    items.sort(key=lambda kv: kv[1], reverse=True)
    return [(k, v, 100.0 * v / stall_total) for k, v in items[:limit]]
