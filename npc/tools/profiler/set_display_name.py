#!/usr/bin/env python3
"""Set display_name in a profile run's metadata.json (dashboard label)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description="Set profile run display_name for dashboard")
    ap.add_argument("--run-dir", required=True, help="Profile run directory")
    ap.add_argument("--display-name", required=True, help="Friendly label shown on dashboard")
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    meta_path = run_dir / "metadata.json"
    if not meta_path.exists():
        print(f"[display-name] metadata not found: {meta_path}", file=sys.stderr)
        return 1

    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    meta["display_name"] = args.display_name
    if "run_id" not in meta:
        meta["run_id"] = run_dir.name
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[display-name] {run_dir.name} -> {args.display_name}")
    print("[display-name] run: make -C npc profile-dashboard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
