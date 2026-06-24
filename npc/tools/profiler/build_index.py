#!/usr/bin/env python3
"""Build profile/index.json from run directories."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_PROFILER_DIR = Path(__file__).resolve().parent
if str(_PROFILER_DIR) not in sys.path:
    sys.path.insert(0, str(_PROFILER_DIR))

from profile_schema import (
    PROFILE_BENCHMARKS,
    bench_commits,
    bench_cpi,
    bench_cycles,
    bench_flush,
    bench_ipc,
    bench_predict,
    predict_miss_rates,
    stall_share_pct,
)

BENCHMARKS = PROFILE_BENCHMARKS
STALL_GATE_KEYS = ("frontend_empty", "rob_backpressure", "lsu_req_blocked")


def load_metadata(run_dir: Path) -> dict:
    meta_path = run_dir / "metadata.json"
    if meta_path.exists():
        try:
            return json.loads(meta_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    return {"run_id": run_dir.name, "created_at": None, "git_sha": None, "git_branch": None}


def extract_run_entry(run_dir: Path) -> dict | None:
    summary_path = run_dir / "summary.json"
    if not summary_path.exists():
        return None
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None

    meta = load_metadata(run_dir)
    run_id = meta.get("run_id", run_dir.name)
    entry = {
        "run_id": run_id,
        "display_name": meta.get("display_name") or run_id,
        "created_at": meta.get("created_at"),
        "git_sha": meta.get("git_sha"),
        "git_branch": meta.get("git_branch"),
        "host": meta.get("host"),
        "summary_path": str(summary_path.resolve()),
        "run_dir": str(run_dir.resolve()),
        "ipc": {},
        "cpi": {},
        "cycles": {},
        "commits": {},
        "stall_gate_share_pct": {},
        "predict_miss_rate": {},
        "predict_accuracy": {},
    }
    for bench in BENCHMARKS:
        if bench not in summary:
            continue
        b = summary[bench]
        entry["ipc"][bench] = bench_ipc(b)
        entry["cpi"][bench] = bench_cpi(b)
        entry["cycles"][bench] = bench_cycles(b)
        entry["commits"][bench] = bench_commits(b)
        entry["stall_gate_share_pct"][bench] = {
            k: stall_share_pct(b, k) for k in STALL_GATE_KEYS
        }
        predict = bench_predict(b)
        flush = bench_flush(b)
        rates = predict_miss_rates(predict, flush)
        entry["predict_miss_rate"][bench] = {
            "cond": rates.get("cond_miss_rate", 0.0),
            "jump": rates.get("jump_miss_rate", 0.0),
            "ret": rates.get("ret_miss_rate", 0.0),
        }
        bpu_train = predict.get("bpu_train") or {}
        tage = predict.get("tage") or {}
        ftb = predict.get("ftb") or {}
        ittage = predict.get("ittage") or {}
        entry["predict_accuracy"][bench] = {
            "cond_selected": float(
                bpu_train.get("cond_selected_accuracy", predict.get("cond_selected_accuracy", 0.0))
                or 0.0
            ),
            "tage_hit": float(tage.get("table_hit_rate", predict.get("tage_table_hit_rate", 0.0)) or 0.0),
            "tage_override": float(tage.get("override_accuracy", 0.0) or 0.0),
            "ftb_cond_pick": float(ftb.get("cond_pick_rate", 0.0) or 0.0),
            "ftb_jump_pick": float(ftb.get("jump_pick_rate", 0.0) or 0.0),
            "ittage_hit": float(ittage.get("table_hit_rate", 0.0) or 0.0),
        }
    return entry


def append_run(runs: list[dict], entry: dict | None) -> None:
    if entry is None:
        return
    run_dir = entry.get("run_dir")
    if any(r.get("run_dir") == run_dir for r in runs):
        return
    runs.append(entry)


def build_index(profile_root: Path, baseline_run_id: str = "baseline") -> dict:
    runs: list[dict] = []
    if not profile_root.is_dir():
        return {"baseline_run_id": baseline_run_id, "runs": runs}

    for child in sorted(profile_root.iterdir()):
        if not child.is_dir():
            continue
        if child.name in ("dashboard",):
            continue
        append_run(runs, extract_run_entry(child))

    if not runs:
        append_run(runs, extract_run_entry(profile_root))

    runs.sort(key=lambda r: r.get("created_at") or r.get("run_id") or "")
    return {"baseline_run_id": baseline_run_id, "runs": runs}


def main() -> int:
    ap = argparse.ArgumentParser(description="Build profile index.json")
    ap.add_argument(
        "--profile-root",
        default=None,
        help="Profile root directory (default: npc/profile)",
    )
    ap.add_argument("--out", default=None, help="Output index.json path")
    ap.add_argument("--baseline-run-id", default="baseline")
    args = ap.parse_args()

    script_dir = Path(__file__).resolve().parent
    npc_home = script_dir.parent.parent
    profile_root = Path(args.profile_root) if args.profile_root else npc_home / "profile"
    out_path = Path(args.out) if args.out else profile_root / "index.json"

    index = build_index(profile_root, baseline_run_id=args.baseline_run_id)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(index, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[index] wrote {out_path} ({len(index['runs'])} runs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
