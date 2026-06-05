#!/usr/bin/env python3
"""Write metadata.json for a profile run directory."""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

BENCHMARKS = ("dhrystone", "coremark")


def git_value(*args: str) -> str | None:
    try:
        out = subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL, text=True)
        value = out.strip()
        return value if value else None
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Finalize profile run metadata.json")
    ap.add_argument("--run-dir", required=True, help="Profile run output directory")
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    if not run_dir.is_dir():
        print(f"[finalize] run dir not found: {run_dir}", file=sys.stderr)
        return 1

    summary_path = run_dir / "summary.json"
    benchmarks_present = [b for b in BENCHMARKS if (run_dir / f"{b}.json").exists()]
    if summary_path.exists():
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            benchmarks_present = [b for b in BENCHMARKS if b in summary]
        except json.JSONDecodeError:
            pass

    metadata = {
        "run_id": run_dir.name,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "git_sha": git_value("rev-parse", "HEAD"),
        "git_branch": git_value("rev-parse", "--abbrev-ref", "HEAD"),
        "host": socket.gethostname(),
        "benchmarks": benchmarks_present,
        "summary_path": str(summary_path.resolve()),
    }

    out_path = run_dir / "metadata.json"
    out_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[finalize] metadata json: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
