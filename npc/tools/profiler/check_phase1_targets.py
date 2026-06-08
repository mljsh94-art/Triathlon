#!/usr/bin/env python3
"""Phase 1 backend/LSU performance gate."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class Baseline:
    coremark_hol_incomplete_sum: float
    coremark_decode_blocked_lsu_sum: float


PHASE1_BASELINE = Baseline(
    # Frozen from npc/profile/latest/summary.json on 2026-02-21.
    coremark_hol_incomplete_sum=560_529.0,
    coremark_decode_blocked_lsu_sum=132_936.0,
)


@dataclass(frozen=True)
class Target:
    name: str
    metric: str
    comparator: str
    threshold: float
    value: float | None

    def passed(self) -> bool:
        if self.value is None:
            return False
        if self.comparator == ">=":
            return self.value >= self.threshold
        if self.comparator == "<=":
            return self.value <= self.threshold
        raise ValueError(f"Unsupported comparator: {self.comparator}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check Phase 1 performance targets.")
    parser.add_argument("--summary", required=True, type=Path, help="Path to summary.json")
    return parser.parse_args()


def load_summary(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("summary root must be a JSON object")
    return data


def to_float(value: object) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def get_bench(summary: dict, name: str) -> dict:
    bench = summary.get(name)
    if not isinstance(bench, dict):
        return {}
    return bench


def get_coremark_other_share(coremark: dict) -> float | None:
    stall_total = to_float(coremark.get("stall_total"))
    stall_category = coremark.get("stall_category")
    if not isinstance(stall_category, dict):
        return None
    stall_other = to_float(stall_category.get("other"))
    if stall_total is None or stall_other is None or stall_total <= 0:
        return None
    return stall_other / stall_total


def get_hol_incomplete_sum(coremark: dict) -> float | None:
    detail = coremark.get("stall_other_detail")
    if not isinstance(detail, dict):
        return None

    total = to_float(detail.get("lsu_wait_wb_head_lsu_incomplete")) or 0.0
    for key, value in detail.items():
        if re.match(r"^rob_head_.*_incomplete_nonbp$", key):
            fv = to_float(value)
            if fv is None:
                return None
            total += fv
    return total


def get_decode_blocked_lsu_sum(coremark: dict) -> float | None:
    detail = coremark.get("stall_decode_blocked_detail")
    if not isinstance(detail, dict):
        return None
    a = to_float(detail.get("lsug_wait_dcache_owner"))
    b = to_float(detail.get("lsug_no_free_lane"))
    if a is None or b is None:
        return None
    return a + b


def make_target(
    name: str,
    metric: str,
    comparator: str,
    threshold: float,
    extractor: Callable[[], float | None],
) -> Target:
    return Target(
        name=name,
        metric=metric,
        comparator=comparator,
        threshold=threshold,
        value=extractor(),
    )


def format_float(value: float | None) -> str:
    if value is None:
        return "missing"
    return f"{value:.6f}"


def main() -> int:
    args = parse_args()
    summary = load_summary(args.summary)
    coremark = get_bench(summary, "coremark")
    dhrystone = get_bench(summary, "dhrystone")

    targets = [
        make_target(
            name="CoreMark IPC",
            metric="coremark.ipc",
            comparator=">=",
            threshold=1.20,
            extractor=lambda: to_float(coremark.get("ipc")),
        ),
        make_target(
            name="Dhrystone IPC",
            metric="dhrystone.ipc",
            comparator=">=",
            threshold=0.82,
            extractor=lambda: to_float(dhrystone.get("ipc")),
        ),
        make_target(
            name="CoreMark other-stall share",
            metric="coremark.stall_category.other / coremark.stall_total",
            comparator="<=",
            threshold=0.40,
            extractor=lambda: get_coremark_other_share(coremark),
        ),
        make_target(
            name="HOL incomplete stall reduction",
            metric=(
                "sum(coremark.stall_other_detail.rob_head_*_incomplete_nonbp)"
                " + coremark.stall_other_detail.lsu_wait_wb_head_lsu_incomplete"
            ),
            comparator="<=",
            threshold=PHASE1_BASELINE.coremark_hol_incomplete_sum * 0.55,
            extractor=lambda: get_hol_incomplete_sum(coremark),
        ),
        make_target(
            name="Decode-blocked LSU lane-pressure reduction",
            metric=(
                "coremark.stall_decode_blocked_detail.lsug_wait_dcache_owner"
                " + coremark.stall_decode_blocked_detail.lsug_no_free_lane"
            ),
            comparator="<=",
            threshold=PHASE1_BASELINE.coremark_decode_blocked_lsu_sum * 0.50,
            extractor=lambda: get_decode_blocked_lsu_sum(coremark),
        ),
    ]

    print(f"[phase1] summary={args.summary}")
    passed_count = 0
    for target in targets:
        passed = target.passed()
        status = "PASS" if passed else "FAIL"
        if passed:
            passed_count += 1
        print(
            f"{status:>4} | {target.name}: "
            f"{format_float(target.value)} {target.comparator} {target.threshold:.6f} "
            f"({target.metric})"
        )

    if passed_count != len(targets):
        print(f"FAIL: {passed_count}/{len(targets)} targets met")
        return 1

    print(f"PASS: {passed_count}/{len(targets)} targets met")
    return 0


if __name__ == "__main__":
    sys.exit(main())
