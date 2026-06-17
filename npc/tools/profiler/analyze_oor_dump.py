#!/usr/bin/env python3
"""Analyze ftb_oor_* fields from --profile-json output."""
import json
import sys
from collections import Counter


def pc_val(item, key="pc"):
    v = item[key]
    return int(v, 0) if isinstance(v, str) else int(v)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "npc/profile/oor_dump_test.json"
    with open(path) as f:
        d = json.load(f)
    md = d.get("mispredict_diag", {})
    total = md.get("ftb_hit_out_of_range", 0)
    print(f"ftb_hit_out_of_range: {total}\n")

    print("ftb_oor_block_byte_off (commit/snap PC & 0xF):")
    off = md.get("ftb_oor_block_byte_off", {})
    off_total = sum(off.values())
    for k in sorted(off, key=lambda x: int(x)):
        v = off[k]
        print(f"  off={int(k):2d}: {v:6d} ({100.0 * v / off_total:.1f}%)")

    print("\nftb_oor_kind:")
    for k, v in sorted(md.get("ftb_oor_kind", {}).items(), key=lambda x: -x[1]):
        print(f"  {k}: {v} ({100.0 * v / off_total:.1f}%)")

    for name in ("ftb_oor_snap_pc_top", "ftb_oor_branch_pc_top"):
        print(f"\n{name} (top 20):")
        for item in md.get(name, [])[:20]:
            pc = pc_val(item)
            print(f"  0x{pc:08x} off={pc & 0xF} cnt={item['count']}")

    # end_rel = (pc & 0xF) + (4 if 32-bit else 2) for cond_32
    off14_cond32 = off.get("14", 0)
    print(f"\noff=14 count: {off14_cond32} ({100.0 * off14_cond32 / off_total:.1f}%)")
    print("end_rel for cond_32 OOR PCs (off + 4):")
    for k in sorted(off, key=lambda x: int(x)):
        end_rel = int(k) + 4
        print(f"  off={int(k):2d} end_rel={end_rel} cnt={off[k]}")


if __name__ == "__main__":
    main()
