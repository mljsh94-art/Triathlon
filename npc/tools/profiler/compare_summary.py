#!/usr/bin/env python3
"""Compare two profiler summary.json files and gate performance regressions."""

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional

_PROFILER_DIR = Path(__file__).resolve().parent
if str(_PROFILER_DIR) not in sys.path:
    sys.path.insert(0, str(_PROFILER_DIR))

from profile_schema import (
    PROFILE_BENCHMARKS,
    bench_cpi,
    bench_cycles,
    bench_ipc,
    bench_stall_detail,
    stall_share_pct,
)

BENCHMARKS = PROFILE_BENCHMARKS
STALL_KEYS = ("frontend_empty", "lsu_req_blocked", "rob_backpressure")

THRESHOLDS = {
    "ipc_drop_warn_pct": 3.0,
    "ipc_drop_fail_pct": 5.0,
    "cpi_rise_warn_pct": 3.0,
    "cpi_rise_fail_pct": 5.0,
    "cycles_rise_warn_pct": 5.0,
    "cycles_rise_fail_pct": 8.0,
    "stall_rise_warn_pp": 5.0,
    "stall_rise_fail_pp": 8.0,
}


def _load_json(path: Path) -> Dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _pct_change(base: float, current: float) -> Optional[float]:
    if base == 0:
        return None
    return (current - base) / base * 100.0


def _stall_share_pct(bench_data: Dict, stall_key: str) -> float:
    return stall_share_pct(bench_data, stall_key)


def _compare_degradation(
    label: str,
    degrade_pct: Optional[float],
    warn_threshold: float,
    fail_threshold: float,
    warnings: List[str],
    failures: List[str],
):
    if degrade_pct is None:
        warnings.append(f"{label}: base=0, skip ratio comparison")
        return
    if degrade_pct > fail_threshold:
        failures.append(
            f"{label}: degrade {degrade_pct:.3f}% > fail {fail_threshold:.3f}%"
        )
    elif degrade_pct > warn_threshold:
        warnings.append(
            f"{label}: degrade {degrade_pct:.3f}% > warn {warn_threshold:.3f}%"
        )


def compare_summary_dicts(base: Dict, current: Dict) -> Dict:
    warnings: List[str] = []
    failures: List[str] = []

    for bench in BENCHMARKS:
        if bench not in base or bench not in current:
            warnings.append(f"{bench}: missing in one summary, skip")
            continue

        base_bench = base[bench]
        cur_bench = current[bench]

        ipc_degrade = _pct_change(bench_ipc(base_bench), bench_ipc(cur_bench))
        ipc_degrade = None if ipc_degrade is None else -ipc_degrade
        _compare_degradation(
            f"{bench}.ipc",
            ipc_degrade,
            THRESHOLDS["ipc_drop_warn_pct"],
            THRESHOLDS["ipc_drop_fail_pct"],
            warnings,
            failures,
        )

        cpi_degrade = _pct_change(bench_cpi(base_bench), bench_cpi(cur_bench))
        _compare_degradation(
            f"{bench}.cpi",
            cpi_degrade,
            THRESHOLDS["cpi_rise_warn_pct"],
            THRESHOLDS["cpi_rise_fail_pct"],
            warnings,
            failures,
        )

        cycles_degrade = _pct_change(
            float(bench_cycles(base_bench)), float(bench_cycles(cur_bench))
        )
        _compare_degradation(
            f"{bench}.cycles",
            cycles_degrade,
            THRESHOLDS["cycles_rise_warn_pct"],
            THRESHOLDS["cycles_rise_fail_pct"],
            warnings,
            failures,
        )

        for stall_key in STALL_KEYS:
            base_share = _stall_share_pct(base_bench, stall_key)
            cur_share = _stall_share_pct(cur_bench, stall_key)
            share_rise = cur_share - base_share
            if share_rise > THRESHOLDS["stall_rise_fail_pp"]:
                failures.append(
                    f"{bench}.stall.{stall_key}: rise {share_rise:.3f}pp > fail {THRESHOLDS['stall_rise_fail_pp']:.3f}pp"
                )
            elif share_rise > THRESHOLDS["stall_rise_warn_pp"]:
                warnings.append(
                    f"{bench}.stall.{stall_key}: rise {share_rise:.3f}pp > warn {THRESHOLDS['stall_rise_warn_pp']:.3f}pp"
                )

    if failures:
        status = "fail"
    elif warnings:
        status = "warn"
    else:
        status = "pass"

    return {
        "status": status,
        "warnings": warnings,
        "failures": failures,
        "thresholds": THRESHOLDS,
    }


def compare_summary_files(base_path: Path, current_path: Path) -> Dict:
    base = _load_json(Path(base_path))
    current = _load_json(Path(current_path))
    return compare_summary_dicts(base, current)


def _resolve_summary_path(raw_path: str) -> Path:
    p = Path(raw_path)
    if p.is_dir():
        return p / "summary.json"
    return p


def _print_result(result: Dict, base: Path, current: Path):
    print(f"[compare] base: {base}")
    print(f"[compare] current: {current}")
    print(f"[compare] status: {result['status']}")

    if result["warnings"]:
        print("[compare] warnings:")
        for w in result["warnings"]:
            print(f"  - {w}")

    if result["failures"]:
        print("[compare] failures:")
        for f in result["failures"]:
            print(f"  - {f}")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare profiler summary.json baselines")
    parser.add_argument("--base", required=True, help="base summary.json or directory")
    parser.add_argument("--current", required=True, help="current summary.json or directory")
    parser.add_argument("--out-json", default=None, help="optional output json path")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    base = _resolve_summary_path(args.base)
    current = _resolve_summary_path(args.current)

    result = compare_summary_files(base, current)
    _print_result(result, base, current)

    if args.out_json:
        out_path = Path(args.out_json)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(result, indent=2), encoding="utf-8")

    if result["status"] == "fail":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
