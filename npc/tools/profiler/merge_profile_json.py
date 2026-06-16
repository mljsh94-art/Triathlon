#!/usr/bin/env python3
"""Merge per-benchmark profile JSON files into summary.json."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

BENCHMARKS = ("dhrystone", "coremark", "microbench")


def merge_run_dir(run_dir: Path) -> dict:
    summary: dict = {}
    missing: list[str] = []
    for bench in BENCHMARKS:
        fp = run_dir / f"{bench}.json"
        if not fp.exists():
            missing.append(bench)
            continue
        with fp.open("r", encoding="utf-8") as f:
            summary[bench] = json.load(f)
    if missing:
        raise FileNotFoundError(
            f"missing benchmark json in {run_dir}: {', '.join(missing)}"
        )
    return summary


def main() -> int:
    ap = argparse.ArgumentParser(description="Merge benchmark JSON files into summary.json")
    ap.add_argument("--run-dir", required=True, help="Profile run output directory")
    ap.add_argument(
        "--out",
        default=None,
        help="Output summary.json path (default: <run-dir>/summary.json)",
    )
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    if not run_dir.is_dir():
        print(f"[merge] run dir not found: {run_dir}", file=sys.stderr)
        return 1

    try:
        summary = merge_run_dir(run_dir)
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        print(f"[merge] {exc}", file=sys.stderr)
        return 1

    out_path = Path(args.out) if args.out else run_dir / "summary.json"
    out_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[merge] summary json: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
