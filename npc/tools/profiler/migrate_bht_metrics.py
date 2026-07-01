#!/usr/bin/env python3
"""One-shot migration: rename BHT/legacy profile JSON keys to TAGE naming."""

from __future__ import annotations

import json
import sys
from pathlib import Path

DBG_RENAMES = {
    "cond_local_correct": "cond_tage_correct",
    "cond_global_correct": None,
    "cond_choose_local": "cond_t0_selected",
    "cond_choose_global": None,
    "cond_provider_legacy_selected": "cond_provider_t0_selected",
    "cond_provider_legacy_correct": "cond_provider_t0_correct",
    "cond_selected_wrong_alt_legacy_correct": "cond_selected_wrong_alt_t0_correct",
}


def migrate_bench(bench: dict) -> None:
    doc = bench.get("predict", {}).get("_doc")
    if isinstance(doc, dict):
        if "bpu_train" in doc:
            doc["bpu_train"] = doc["bpu_train"].replace("BHT", "TAGE")
        doc["provider"] = (
            "取指时 cond 方向 provider(T0 base / TAGE override) "
            "及训练回溯准确率(样本=selected)"
        )

    provider = bench.get("predict", {}).get("provider")
    if isinstance(provider, dict):
        if "legacy" in provider:
            provider["t0_base"] = provider.pop("legacy")
        if "tage" in provider:
            provider["tage_override"] = provider.pop("tage")

    diag = bench.get("flush", {}).get("mispredict_diag")
    if isinstance(diag, dict):
        diag.pop("ftb_hit_shadowed_epoch_ok", None)

    rollup = diag.get("rollup") if isinstance(diag, dict) else None
    if isinstance(rollup, dict):
        if "bht_direction" in rollup:
            rollup["tage_direction"] = rollup.pop("bht_direction")
        if "bht_direction_ratio" in rollup:
            rollup["tage_direction_ratio"] = rollup.pop("bht_direction_ratio")

    dbg = bench.get("dbg_bpu")
    if isinstance(dbg, dict):
        for old, new in DBG_RENAMES.items():
            if old not in dbg:
                continue
            val = dbg.pop(old)
            if new is not None:
                dbg[new] = val


def migrate_file(path: Path) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    for key in ("coremark", "microbench"):
        if key in data:
            migrate_bench(data[key])
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} <summary.json>", file=sys.stderr)
        return 2
    migrate_file(Path(argv[1]))
    print(f"migrated {argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
