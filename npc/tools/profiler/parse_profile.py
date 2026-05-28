#!/usr/bin/env python3
"""Parse NPC profiling logs and generate a fixed markdown report."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

IPC_RE = re.compile(r"IPC=([0-9]+(?:\.[0-9]+)?)\s+CPI=([0-9]+(?:\.[0-9]+)?)\s+cycles=(\d+)\s+commits=(\d+)")
TIMEOUT_RE = re.compile(r"TIMEOUT after (\d+) cycles")
HOST_TIME_RE = re.compile(r"host time spent = (\d+)\s+us")
BENCH_TIME_MS_RE = re.compile(r"(?:Finished in|Finised in|Total time \(ms\)\s*:)\s*([0-9]+(?:\.[0-9]+)?)")
FLUSH_RE = re.compile(r"^\[flush \]\s+cycle=(\d+)(?:\s+reason=([a-zA-Z0-9_]+))?")
FLUSHP_RE = re.compile(r"^\[flushp\]\s+cycle=(\d+)\s+reason=([a-zA-Z0-9_]+)\s+penalty=(\d+)")
BRU_RE = re.compile(r"^\[bru\s+\]\s+cycle=(\d+)")
COMMIT_RE = re.compile(r"^\[commit\]\s+cycle=(\d+)\s+slot=(\d+)\s+pc=0x([0-9a-fA-F]+)\s+inst=0x([0-9a-fA-F]+)")
STALL_RE = re.compile(r"^\[stall \]")
KV_RE = re.compile(r"([a-zA-Z_][a-zA-Z0-9_]*)=([^\s]+)")
COMMIT_WIDTH_KEY_RE = re.compile(r"^width(\d+)$")

FLUSH_REASON_ALLOWLIST = {"branch_mispredict", "exception", "rob_other", "external", "unknown"}
FLUSH_SOURCE_ALLOWLIST = {"rob", "external", "unknown"}
MISS_TYPE_ALLOWLIST = {
    "cond_branch",
    "jump",
    "jump_direct",
    "jump_indirect",
    "return",
    "control_unknown",
    "none",
}
STALL_POST_FLUSH_WINDOW_CYCLES = 16
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
STALL_FRONTEND_EMPTY_DETAIL_KEYS = (
    "fe_no_req",
    "fe_wait_icache_rsp_hit_latency",
    "fe_wait_icache_rsp_miss_wait",
    "fe_rsp_blocked_by_fq_full",
    "fe_wait_ibuffer_consume",
    "fe_redirect_recovery",
    "fe_rsp_capture_bubble",
    "fe_has_data_decode_gap",
    "fe_drop_stale_rsp",
    "fe_no_req_reqq_empty",
    "fe_no_req_inf_full",
    "fe_no_req_storage_budget",
    "fe_no_req_flush_block",
    "fe_no_req_other",
    "fe_req_fire_no_inflight",
    "fe_rsp_no_inflight",
    "fe_fq_nonempty_no_fevalid",
    "fe_req_ready_nofire",
    "fe_other",
)
STALL_OTHER_DETAIL_KEY_CANONICAL_MAP = {
    "rob_head_lsu_incomplete_wait_req_ready": "rob_head_lsu_incomplete_wait_req_ready_nonbp",
    "rob_head_lsu_incomplete_wait_rsp_valid": "rob_head_lsu_incomplete_wait_rsp_valid_nonbp",
}


def _canonicalize_stall_other_detail_key(key: str) -> str:
    return STALL_OTHER_DETAIL_KEY_CANONICAL_MAP.get(key, key)


def _safe_div(numer: float, denom: float) -> float:
    return 0.0 if denom == 0 else numer / denom


def _parse_kv_pairs(line: str) -> dict[str, str]:
    return {m.group(1): m.group(2) for m in KV_RE.finditer(line)}


def _parse_int(token: str | None, default: int = 0) -> int:
    if token is None:
        return default
    try:
        return int(token, 0)
    except ValueError:
        return default


def _compact_alpha(token: str) -> str:
    return re.sub(r"[^a-z]", "", token.lower())


def _normalize_flush_reason(token: str | None, line_ctx: str = "") -> str:
    raw = "" if token is None else token.strip().lower()
    if raw in FLUSH_REASON_ALLOWLIST:
        return raw

    compact = _compact_alpha(raw)
    ctx = _compact_alpha(line_ctx)

    if "except" in compact or "except" in ctx:
        return "exception"
    if "robother" in compact or "robother" in ctx:
        return "rob_other"
    if "extern" in compact or "extern" in ctx:
        return "external"
    if "unknown" in compact:
        return "unknown"
    if ("misp" in compact or "mispr" in compact or "misp" in ctx or "mispr" in ctx) and (
        "branch" in compact or "ranch" in compact or "branch" in ctx or "ranch" in ctx
    ):
        return "branch_mispredict"
    return "unknown"


def _normalize_flush_source(token: str | None) -> str:
    raw = "" if token is None else token.strip().lower()
    if raw in FLUSH_SOURCE_ALLOWLIST:
        return raw

    compact = _compact_alpha(raw)
    if "rob" in compact:
        return "rob"
    if "extern" in compact:
        return "external"
    if "unknown" in compact:
        return "unknown"
    return "unknown"


def _normalize_miss_type(token: str | None) -> str:
    raw = "" if token is None else token.strip().lower()
    if raw in MISS_TYPE_ALLOWLIST:
        return raw

    compact = _compact_alpha(raw)
    if compact.startswith("ret") or "return" in compact:
        return "return"
    if "jumpindirect" in compact or "jalr" in compact or "indir" in compact:
        return "jump_indirect"
    if "jumpdirect" in compact:
        return "jump_direct"
    if "jump" in compact or compact.startswith("jal"):
        return "jump"
    if "control" in compact:
        return "control_unknown"
    if "none" in compact:
        return "none"
    if "cond" in compact and "branch" in compact:
        return "cond_branch"
    return "none"


def _classify_stall(line: str) -> str:
    def pair(pattern: str) -> tuple[int, int] | None:
        m = re.search(pattern, line)
        if not m:
            return None
        return int(m.group(1)), int(m.group(2))

    def scalar(pattern: str, default: int = 0) -> int:
        m = re.search(pattern, line)
        return default if not m else int(m.group(1))

    flush = scalar(r"\sflush=(\d)")
    ic = pair(r"ic_miss\(v/r\)=(\d)/(\d)")
    dc = pair(r"dc_miss\(v/r\)=(\d)/(\d)")
    rob_ready = scalar(r"\srob_ready=(\d)", 1)
    dec = pair(r"dec\(v/r\)=(\d)/(\d)")
    lsu_issue = pair(r"lsu_issue\(v/r\)=(\d)/(\d)")

    if flush == 1:
        return "flush_recovery"
    if ic and ic[0] == 1:
        return "icache_miss_wait"
    if dc and dc[0] == 1:
        return "dcache_miss_wait"
    if rob_ready == 0:
        return "rob_backpressure"
    if dec and dec[0] == 0:
        return "frontend_empty"
    if dec and dec[0] == 1 and dec[1] == 0:
        return "decode_blocked"
    if lsu_issue and lsu_issue[0] == 1 and lsu_issue[1] == 0:
        return "lsu_req_blocked"
    return "other"


def _parse_ranked_summary(
    kv: dict[str, str], value_key_suffix: str, max_items: int = 10
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for i in range(max_items):
        value_key = f"rank{i}_{value_key_suffix}"
        count_key = f"rank{i}_count"
        if value_key not in kv or count_key not in kv:
            continue
        value = _parse_int(kv.get(value_key), 0)
        count = _parse_int(kv.get(count_key), 0)
        if value_key_suffix == "pc":
            items.append({"pc": f"0x{value:08x}", "count": count})
        else:
            items.append({"inst": f"0x{value:08x}", "count": count})
    return items


def _extract_cycle(line: str) -> int | None:
    m = re.search(r"\bcycle=(\d+)", line)
    if not m:
        return None
    return int(m.group(1))


def _classify_decode_blocked_detail(line: str) -> str:
    # Current npc dispatch width is 4; use src-count as a proxy to split
    # pending replay into "full" vs "has room" for next-step bottleneck analysis.
    pending_replay_full_src = 4
    rs2_ready: int | None = None
    has_rs2: int | None = None

    m = re.search(r"ren\(pend/src/sel/fire/rdy\)=(\d)/(\d+)/(\d+)/(\d)/(\d)", line)
    if m:
        pend = int(m.group(1))
        src = int(m.group(2))
        sel = int(m.group(3))
        fire = int(m.group(4))
        if pend == 1:
            full_suffix = "full" if src >= pending_replay_full_src else "has_room"
            if fire == 1 and sel > 0:
                return f"pending_replay_progress_{full_suffix}"
            return f"pending_replay_wait_{full_suffix}"

    m = re.search(r"lsug\(busy/alloc_fire/alloc_lane/ld_owner\)=0x([0-9a-fA-F]+)/(\d)/0x([0-9a-fA-F]+)/0x([0-9a-fA-F]+)", line)
    if m:
        busy = int(m.group(1), 16)
        alloc_fire = int(m.group(2))
        ld_owner = int(m.group(4), 16)
        if busy != 0 and alloc_fire == 0:
            if ld_owner == 0:
                return "lsug_wait_dcache_owner"
            return "lsug_no_free_lane"

    m = re.search(r"dc_store_wait\(same/full\)=(\d)/(\d)", line)
    if m:
        same_line = int(m.group(1))
        mshr_full = int(m.group(2))
        if same_line == 1:
            return "dc_store_wait_same_line"
        if mshr_full == 1:
            return "dc_store_wait_mshr_full"

    m = re.search(r"sb_alloc\(req/ready/fire\)=0x([0-9a-fA-F]+)/(\d)/(\d)", line)
    if m:
        alloc_req = int(m.group(1), 16)
        alloc_ready = int(m.group(2))
        if alloc_req != 0 and alloc_ready == 0:
            return "sb_alloc_blocked"

    m_head = re.search(r"lsu_rs_head\(v/idx/dst\)=(\d)/0x[0-9a-fA-F]+/0x[0-9a-fA-F]+", line)
    m_dep = re.search(r"lsu_rs_head\(rs1r/rs2r/has1/has2\)=(\d)/(\d)/(\d)/(\d)", line)
    if m_dep:
        rs2_ready = int(m_dep.group(2))
        has_rs2 = int(m_dep.group(4))
    if m_head and m_dep and int(m_head.group(1)) == 1:
        rs1_ready = int(m_dep.group(1))
        rs2_ready = int(m_dep.group(2))
        has_rs1 = int(m_dep.group(3))
        has_rs2 = int(m_dep.group(4))
        if (has_rs1 and not rs1_ready) or (has_rs2 and not rs2_ready):
            return "lsu_operand_wait"

    m = re.search(r"lsu_rs\(b/r\)=0x([0-9a-fA-F]+)/0x([0-9a-fA-F]+)", line)
    if m:
        busy_mask = int(m.group(1), 16)
        ready_mask = int(m.group(2), 16)
        if busy_mask != 0 and ready_mask == 0:
            return "lsu_rs_pressure"

    m = re.search(r"rob_q2\(v/idx/fu/comp/st/pc\)=(\d)/0x[0-9a-fA-F]+/0x[0-9a-fA-F]+/(\d)/(\d)/0x[0-9a-fA-F]+", line)
    if m:
        q2_valid = int(m.group(1))
        q2_complete = int(m.group(2))
        if q2_valid == 1 and q2_complete == 0 and has_rs2 == 1 and rs2_ready == 0:
            return "rob_q2_wait"

    m_gate = re.search(r"gate\(alu/bru/lsu/mdu/csr\)=(\d)/(\d)/(\d)/(\d)/(\d)", line)
    if m_gate:
        gate = [int(m_gate.group(i)) for i in range(1, 6)]
        need = None
        m_need = re.search(r"need\(alu/bru/lsu/mdu/csr\)=(\d+)/(\d+)/(\d+)/(\d+)/(\d+)", line)
        if m_need:
            need = [int(m_need.group(i)) for i in range(1, 6)]
        gate_priority = [(2, "lsu"), (0, "alu"), (1, "bru"), (4, "csr"), (3, "mdu")]
        if need is not None:
            for idx, fu in gate_priority:
                if gate[idx] == 0 and need[idx] > 0:
                    return f"dispatch_gate_{fu}"
        for idx, fu in gate_priority:
            if gate[idx] == 0:
                return f"dispatch_gate_{fu}"

    m_sm = re.search(r"\slsu_sm=(\d+)", line)
    if m_sm:
        sm = int(m_sm.group(1))
        m_ld_fire = re.search(r"\slsu_ld_fire=(\d)", line)
        m_rsp_fire = re.search(r"\slsu_rsp_fire=(\d)", line)
        if sm == 1 and m_ld_fire and int(m_ld_fire.group(1)) == 0:
            return "lsu_wait_ld_req"
        if sm == 2 and m_rsp_fire and int(m_rsp_fire.group(1)) == 0:
            return "lsu_wait_ld_rsp"

    return "other"


def _classify_rob_backpressure_detail(line: str) -> str:
    m_head = re.search(r"rob_head\(fu/comp/is_store/pc\)=0x([0-9a-fA-F]+)/(\d)/(\d)/0x[0-9a-fA-F]+", line)
    if not m_head:
        return "other"

    fu = int(m_head.group(1), 16)
    complete = int(m_head.group(2))
    is_store = int(m_head.group(3))

    if is_store == 1:
        m_sb_head = re.search(r"sb_head\(v/c/a/d/addr\)=(\d)/(\d)/(\d)/(\d)/0x[0-9a-fA-F]+", line)
        if m_sb_head:
            sb_head_valid = int(m_sb_head.group(1))
            sb_head_committed = int(m_sb_head.group(2))
            sb_head_addr_valid = int(m_sb_head.group(3))
            sb_head_data_valid = int(m_sb_head.group(4))
            if sb_head_valid == 0:
                return "rob_store_wait_sb_head"
            if sb_head_committed == 0:
                return "rob_store_wait_commit"
            if sb_head_addr_valid == 0:
                return "rob_store_wait_addr"
            if sb_head_data_valid == 0:
                return "rob_store_wait_data"

        m_sb_dcache = re.search(r"sb_dcache\(v/r/addr\)=\s*(\d)/(\d)/0x[0-9a-fA-F]+", line)
        if m_sb_dcache:
            sb_req_valid = int(m_sb_dcache.group(1))
            sb_req_ready = int(m_sb_dcache.group(2))
            if sb_req_valid == 1 and sb_req_ready == 0:
                return "rob_store_wait_dcache"
            if sb_req_valid == 0:
                return "rob_store_wait_issue"

        return "rob_store_wait_other"

    if complete == 0:
        if fu == 1:
            return "rob_head_fu_alu_incomplete"
        if fu == 2:
            return "rob_head_fu_branch_incomplete"
        if fu == 3:
            m_sm = re.search(r"\slsu_sm=(\d+)", line)
            m_ld = re.search(r"lsu_ld\(v/r/addr\)=(\d)/(\d)/0x[0-9a-fA-F]+", line)
            m_rsp = re.search(r"lsu_rsp\(v/r\)=(\d)/(\d)", line)
            m_ld_fire = re.search(r"\slsu_ld_fire=(\d)", line)
            m_rsp_fire = re.search(r"\slsu_rsp_fire=(\d)", line)
            m_sb_dcache = re.search(r"sb_dcache\(v/r/addr\)=\s*(\d)/(\d)/0x[0-9a-fA-F]+", line)
            m_mshr_cnt = re.search(r"dc_mshr\(cnt/full/empty\)=(\d+)/(\d)/(\d)", line)
            m_mshr_alloc = re.search(r"dc_mshr\(alloc_rdy/line_hit\)=(\d)/(\d)", line)
            m_dc_miss = re.search(r"dc_miss\(v/r\)=(\d)/(\d)", line)
            m_lsug = re.search(
                r"lsug\(busy/alloc_fire/alloc_lane/ld_owner\)=0x([0-9a-fA-F]+)/(\d)/0x([0-9a-fA-F]+)/0x([0-9a-fA-F]+)",
                line,
            )
            if not m_sm:
                return "rob_lsu_incomplete_no_sm"

            sm = int(m_sm.group(1))
            if sm == 0:
                return "rob_lsu_incomplete_sm_idle"
            if sm == 1:
                if m_ld:
                    ld_valid = int(m_ld.group(1))
                    ld_ready = int(m_ld.group(2))
                    if ld_valid == 1 and ld_ready == 0:
                        owner = 0
                        if m_lsug:
                            owner = int(m_lsug.group(4), 16)
                        if owner != 0 and m_rsp:
                            rsp_valid = int(m_rsp.group(1))
                            rsp_ready = int(m_rsp.group(2))
                            if rsp_valid == 1 and rsp_ready == 1:
                                return "rob_lsu_wait_ld_req_ready_owner_rsp_fire"
                            if rsp_valid == 0 and rsp_ready == 1:
                                return "rob_lsu_wait_ld_req_ready_owner_rsp_valid"
                            if rsp_valid == 1 and rsp_ready == 0:
                                return "rob_lsu_wait_ld_req_ready_owner_rsp_ready"

                        if m_sb_dcache:
                            sb_valid = int(m_sb_dcache.group(1))
                            sb_ready = int(m_sb_dcache.group(2))
                            if sb_valid == 1 and sb_ready == 0:
                                return "rob_lsu_wait_ld_req_ready_sb_conflict"

                        mshr_blocked = False
                        if m_mshr_cnt and int(m_mshr_cnt.group(2)) == 1:
                            mshr_blocked = True
                        if m_mshr_alloc and int(m_mshr_alloc.group(1)) == 0:
                            mshr_blocked = True
                        if mshr_blocked:
                            return "rob_lsu_wait_ld_req_ready_mshr_blocked"

                        if m_dc_miss:
                            dc_miss_valid = int(m_dc_miss.group(1))
                            dc_miss_ready = int(m_dc_miss.group(2))
                            if dc_miss_valid == 1 and dc_miss_ready == 0:
                                return "rob_lsu_wait_ld_req_ready_miss_port_busy"

                        return "rob_lsu_wait_ld_req_ready"
                    if ld_valid == 0 and ld_ready == 0:
                        owner = 0
                        alloc_fire = 0
                        if m_lsug:
                            owner = int(m_lsug.group(4), 16)
                            alloc_fire = int(m_lsug.group(2))
                        if owner != 0:
                            if m_rsp:
                                rsp_valid = int(m_rsp.group(1))
                                rsp_ready = int(m_rsp.group(2))
                                if rsp_valid == 1 and rsp_ready == 1:
                                    return "rob_lsu_wait_ld_owner_rsp_fire"
                                if rsp_valid == 0 and rsp_ready == 1:
                                    return "rob_lsu_wait_ld_owner_rsp_valid"
                                if rsp_valid == 1 and rsp_ready == 0:
                                    return "rob_lsu_wait_ld_owner_rsp_ready"
                            return "rob_lsu_wait_ld_owner_hold"
                        if alloc_fire == 0:
                            return "rob_lsu_wait_ld_arb_no_grant"
                if m_ld_fire and int(m_ld_fire.group(1)) == 0:
                    return "rob_lsu_wait_ld_req_fire"
                return "rob_lsu_incomplete_sm_req_unknown"
            if sm == 2:
                if m_rsp:
                    rsp_valid = int(m_rsp.group(1))
                    rsp_ready = int(m_rsp.group(2))
                    if rsp_valid == 0:
                        return "rob_lsu_wait_ld_rsp_valid"
                    if rsp_valid == 1 and rsp_ready == 0:
                        return "rob_lsu_wait_ld_rsp_ready"
                if m_rsp_fire and int(m_rsp_fire.group(1)) == 0:
                    return "rob_lsu_wait_ld_rsp_fire"
                return "rob_lsu_incomplete_sm_rsp_unknown"
            if sm == 3:
                return "rob_lsu_wait_wb"
            return "rob_lsu_incomplete_sm_illegal"
        if fu == 4 or fu == 5:
            return "rob_head_fu_mdu_incomplete"
        if fu == 6:
            return "rob_head_fu_csr_incomplete"
        return "rob_head_fu_unknown_incomplete"

    return "rob_head_complete_but_not_ready"


def _classify_other_detail(line: str) -> str:
    m_ren = re.search(r"ren\(pend/src/sel/fire/rdy\)=(\d)/(\d+)/(\d+)/(\d)/(\d)", line)
    ren_fire: int | None = None
    ren_ready: int | None = None
    if m_ren:
        ren_fire = int(m_ren.group(4))
        ren_ready = int(m_ren.group(5))

    m_rob_cnt = re.search(r"\srob_cnt=(\d+)", line)
    if m_rob_cnt and int(m_rob_cnt.group(1)) == 0:
        m_ifu_req = re.search(r"ifu_req\(v/r/fire/inflight\)=(\d)/(\d)/(\d)/(\d)", line)
        m_ifu_rsp = re.search(r"ifu_rsp\(v/cap\)=(\d)/(\d)", line)
        if ren_ready == 0:
            return "rob_empty_refill_ren_not_ready"
        if ren_fire == 1:
            return "rob_empty_refill_ren_fire"
        if m_ifu_req and int(m_ifu_req.group(4)) == 1:
            return "rob_empty_refill_wait_frontend_rsp"
        if m_ifu_rsp and int(m_ifu_rsp.group(1)) == 1 and int(m_ifu_rsp.group(2)) == 1:
            return "rob_empty_refill_rsp_capture"
        return "rob_empty_refill_other"

    m_sm = re.search(r"\slsu_sm=(\d+)", line)
    m_head = re.search(r"rob_head\(fu/comp/is_store/pc\)=0x([0-9a-fA-F]+)/(\d)/(\d)/0x[0-9a-fA-F]+", line)
    m_q2 = re.search(r"rob_q2\(v/idx/fu/comp/st/pc\)=(\d)/0x[0-9a-fA-F]+/0x[0-9a-fA-F]+/(\d)/\d/0x[0-9a-fA-F]+", line)
    q2_incomplete = m_q2 is not None and int(m_q2.group(1)) == 1 and int(m_q2.group(2)) == 0

    if m_sm and int(m_sm.group(1)) == 3:
        if m_head:
            fu = int(m_head.group(1), 16)
            complete = int(m_head.group(2))
            if fu == 3 and complete == 0:
                return "lsu_wait_wb_head_lsu_incomplete"
            if fu == 3 and complete == 1:
                return "lsu_wait_wb_head_lsu_complete"
            if q2_incomplete:
                return "lsu_wait_wb_q2_incomplete"
            return "lsu_wait_wb_other"
        return "lsu_wait_wb"

    if m_head:
        fu = int(m_head.group(1), 16)
        complete = int(m_head.group(2))
        is_store = int(m_head.group(3))
        if is_store == 1:
            m_sb_head = re.search(r"sb_head\(v/c/a/d/addr\)=(\d)/(\d)/(\d)/(\d)/0x[0-9a-fA-F]+", line)
            if m_sb_head:
                if int(m_sb_head.group(1)) == 0:
                    return "rob_head_store_wait_sb_head_nonbp"
                if int(m_sb_head.group(2)) == 0:
                    return "rob_head_store_wait_commit_nonbp"
                if int(m_sb_head.group(3)) == 0:
                    return "rob_head_store_wait_addr_nonbp"
                if int(m_sb_head.group(4)) == 0:
                    return "rob_head_store_wait_data_nonbp"
            m_sb_dcache = re.search(r"sb_dcache\(v/r/addr\)=\s*(\d)/(\d)/0x[0-9a-fA-F]+", line)
            if m_sb_dcache:
                sb_valid = int(m_sb_dcache.group(1))
                sb_ready = int(m_sb_dcache.group(2))
                if sb_valid == 1 and sb_ready == 0:
                    return "rob_head_store_wait_dcache_nonbp"
                if sb_valid == 0:
                    return "rob_head_store_wait_issue_nonbp"
            return "rob_head_store_wait_other_nonbp"

        if complete == 0:
            if fu == 1:
                return "rob_head_alu_incomplete_nonbp"
            if fu == 2:
                return "rob_head_branch_incomplete_nonbp"
            if fu == 3:
                if not m_sm:
                    return "rob_head_lsu_incomplete_no_sm_nonbp"
                sm = int(m_sm.group(1))
                m_ld = re.search(r"lsu_ld\(v/r/addr\)=(\d)/(\d)/0x[0-9a-fA-F]+", line)
                m_rsp = re.search(r"lsu_rsp\(v/r\)=(\d)/(\d)", line)
                m_ld_fire = re.search(r"\slsu_ld_fire=(\d)", line)
                m_rsp_fire = re.search(r"\slsu_rsp_fire=(\d)", line)
                if sm == 0:
                    return "rob_head_lsu_incomplete_sm_idle_nonbp"
                if sm == 1:
                    if m_ld:
                        ld_valid = int(m_ld.group(1))
                        ld_ready = int(m_ld.group(2))
                        if ld_valid == 1 and ld_ready == 0:
                            return "rob_head_lsu_incomplete_wait_req_ready_nonbp"
                        if ld_valid == 0 and ld_ready == 0:
                            return "rob_head_lsu_incomplete_wait_owner_or_alloc_nonbp"
                    if m_ld_fire and int(m_ld_fire.group(1)) == 0:
                        return "rob_head_lsu_incomplete_req_fire_gap_nonbp"
                    return "rob_head_lsu_incomplete_sm_req_unknown_nonbp"
                if sm == 2:
                    if m_rsp:
                        rsp_valid = int(m_rsp.group(1))
                        rsp_ready = int(m_rsp.group(2))
                        if rsp_valid == 0:
                            return "rob_head_lsu_incomplete_wait_rsp_valid_nonbp"
                        if rsp_valid == 1 and rsp_ready == 0:
                            return "rob_head_lsu_incomplete_wait_rsp_ready_nonbp"
                    if m_rsp_fire and int(m_rsp_fire.group(1)) == 0:
                        return "rob_head_lsu_incomplete_rsp_fire_gap_nonbp"
                    return "rob_head_lsu_incomplete_sm_rsp_unknown_nonbp"
                return "rob_head_lsu_incomplete_sm_other_nonbp"
            if fu == 4 or fu == 5:
                return "rob_head_mdu_incomplete_nonbp"
            if fu == 6:
                return "rob_head_csr_incomplete_nonbp"
            return "rob_head_unknown_incomplete_nonbp"

    if q2_incomplete:
        return "rob_q2_not_complete_nonstall"

    if ren_ready == 0:
        return "ren_not_ready"
    if ren_fire == 0:
        return "ren_no_fire"

    if m_sm:
        sm = int(m_sm.group(1))
        if sm == 1:
            m_ld = re.search(r"lsu_ld\(v/r/addr\)=(\d)/(\d)/0x[0-9a-fA-F]+", line)
            m_ld_fire = re.search(r"\slsu_ld_fire=(\d)", line)
            if m_ld and m_ld_fire:
                if int(m_ld.group(1)) == 1 and int(m_ld.group(2)) == 1 and int(m_ld_fire.group(1)) == 0:
                    return "lsu_req_fire_gap"
        if sm == 2:
            m_rsp = re.search(r"lsu_rsp\(v/r\)=(\d)/(\d)", line)
            m_rsp_fire = re.search(r"\slsu_rsp_fire=(\d)", line)
            if m_rsp and m_rsp_fire:
                if int(m_rsp.group(1)) == 1 and int(m_rsp.group(2)) == 1 and int(m_rsp_fire.group(1)) == 0:
                    return "lsu_rsp_fire_gap"

    return "other"


def _commit_histogram(cycles: int, commit_by_cycle: dict[int, int]) -> dict[int, int]:
    hist = Counter(commit_by_cycle.values())
    if cycles > 0:
        hist[0] = max(0, cycles - len(commit_by_cycle))
    max_width = max(hist.keys(), default=0)
    max_width = max(max_width, 4)
    for width in range(max_width + 1):
        hist.setdefault(width, 0)
    return {k: hist[k] for k in sorted(hist)}


def _control_flow_metrics(commit_seq: list[tuple[int, int, int, int]]) -> dict[str, float | int]:
    def is_call(inst: int) -> bool:
        opcode = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        if opcode == 0x6F:  # JAL
            return rd in (1, 5)
        if opcode == 0x67:  # JALR
            return rd in (1, 5)
        return False

    def is_ret(inst: int) -> bool:
        opcode = inst & 0x7F
        if opcode != 0x67:  # JALR
            return False
        rd = (inst >> 7) & 0x1F
        rs1 = (inst >> 15) & 0x1F
        imm12 = (inst >> 20) & 0xFFF
        return rd == 0 and rs1 in (1, 5) and imm12 == 0

    commit_seq.sort()
    branch_count = 0
    jal_count = 0
    jalr_count = 0
    branch_taken = 0
    call_count = 0
    ret_count = 0

    for i in range(len(commit_seq) - 1):
        _, _, pc, inst = commit_seq[i]
        _, _, next_pc, _ = commit_seq[i + 1]
        opcode = inst & 0x7F
        if is_call(inst):
            call_count += 1
        if is_ret(inst):
            ret_count += 1
        if opcode == 0x63:
            branch_count += 1
            if next_pc != ((pc + 4) & 0xFFFFFFFF):
                branch_taken += 1
        elif opcode == 0x6F:
            jal_count += 1
        elif opcode == 0x67:
            jalr_count += 1

    commit_total = len(commit_seq)
    control_total = branch_count + jal_count + jalr_count
    est_misp = branch_taken + jal_count + jalr_count  # static not-taken proxy

    return {
        "branch_count": branch_count,
        "jal_count": jal_count,
        "jalr_count": jalr_count,
        "branch_taken_count": branch_taken,
        "call_count": call_count,
        "ret_count": ret_count,
        "control_count": control_total,
        "control_ratio": _safe_div(control_total, commit_total),
        "est_misp_count": est_misp,
        "est_misp_per_kinst": 1000.0 * _safe_div(est_misp, commit_total),
    }


def parse_single_log(path: str | Path) -> dict[str, Any]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"log not found: {p}")

    ipc = 0.0
    cpi = 0.0
    cycles = 0
    commits = 0
    timeout_cycles = 0
    host_time_us = 0
    bench_reported_time_ms: float | None = None

    flush_count = 0
    bru_count = 0
    mispredict_flush_count = 0
    mispredict_cond_count = 0
    mispredict_jump_count = 0
    mispredict_jump_direct_count = 0
    mispredict_jump_indirect_count = 0
    mispredict_ret_count = 0
    branch_penalty_cycles = 0
    wrong_path_kill_uops = 0
    redirect_distance_sum = 0
    redirect_distance_samples = 0
    redirect_distance_max = 0
    flush_reason_hist: Counter[str] = Counter()
    flush_source_hist: Counter[str] = Counter()

    pred_cond_total_line: int | None = None
    pred_cond_miss_line: int | None = None
    pred_jump_total_line: int | None = None
    pred_jump_miss_line: int | None = None
    pred_jump_direct_total_line: int | None = None
    pred_jump_direct_miss_line: int | None = None
    pred_jump_indirect_total_line: int | None = None
    pred_jump_indirect_miss_line: int | None = None
    pred_ret_total_line: int | None = None
    pred_ret_miss_line: int | None = None
    pred_call_total_line: int | None = None
    pred_cond_update_total_line: int | None = None
    pred_cond_local_correct_line: int | None = None
    pred_cond_global_correct_line: int | None = None
    pred_cond_selected_correct_line: int | None = None
    pred_cond_choose_local_line: int | None = None
    pred_cond_choose_global_line: int | None = None
    pred_tage_lookup_total_line: int | None = None
    pred_tage_hit_total_line: int | None = None
    pred_tage_override_total_line: int | None = None
    pred_tage_override_correct_line: int | None = None
    pred_sc_lookup_total_line: int | None = None
    pred_sc_confident_total_line: int | None = None
    pred_sc_override_total_line: int | None = None
    pred_sc_override_correct_line: int | None = None
    pred_loop_lookup_total_line: int | None = None
    pred_loop_hit_total_line: int | None = None
    pred_loop_confident_total_line: int | None = None
    pred_loop_override_total_line: int | None = None
    pred_loop_override_correct_line: int | None = None
    pred_cond_provider_legacy_selected_line: int | None = None
    pred_cond_provider_tage_selected_line: int | None = None
    pred_cond_provider_sc_selected_line: int | None = None
    pred_cond_provider_loop_selected_line: int | None = None
    pred_cond_provider_legacy_correct_line: int | None = None
    pred_cond_provider_tage_correct_line: int | None = None
    pred_cond_provider_sc_correct_line: int | None = None
    pred_cond_provider_loop_correct_line: int | None = None
    pred_cond_selected_wrong_alt_legacy_correct_line: int | None = None
    pred_cond_selected_wrong_alt_tage_correct_line: int | None = None
    pred_cond_selected_wrong_alt_sc_correct_line: int | None = None
    pred_cond_selected_wrong_alt_loop_correct_line: int | None = None
    pred_cond_selected_wrong_alt_any_correct_line: int | None = None

    commit_by_cycle: dict[int, int] = defaultdict(int)
    commit_seq: list[tuple[int, int, int, int]] = []

    stall_counter: Counter[str] = Counter()
    stall_decode_blocked_total = 0
    stall_decode_blocked_post_flush = 0
    stall_decode_blocked_post_branch_flush = 0
    stall_decode_blocked_detail: Counter[str] = Counter()
    stall_rob_backpressure_total = 0
    stall_rob_backpressure_detail: Counter[str] = Counter()
    stall_other_total = 0
    stall_other_detail: Counter[str] = Counter()
    last_flush_cycle: int | None = None
    last_branch_flush_cycle: int | None = None
    hotspot_pc: Counter[int] = Counter()
    hotspot_inst: Counter[int] = Counter()
    has_commit_summary = False
    commit_summary_hist: dict[int, int] = {}
    control_summary: dict[str, int] = {}
    top_pc_summary: list[dict[str, Any]] = []
    top_inst_summary: list[dict[str, Any]] = []
    stall_cycle_summary: Counter[str] = Counter()
    stall_cycle_total = 0
    has_stall_cycle_summary = False
    stall_frontend_empty_detail_summary: Counter[str] = Counter()
    stall_frontend_empty_total = 0
    has_stall_decode_blocked_summary = False
    stall_decode_blocked_total_summary = 0
    stall_decode_blocked_detail_summary: Counter[str] = Counter()
    has_stall_rob_backpressure_summary = False
    stall_rob_backpressure_total_summary = 0
    stall_rob_backpressure_detail_summary: Counter[str] = Counter()
    has_stall_other_summary = False
    stall_other_total_summary = 0
    stall_other_detail_summary: Counter[str] = Counter()
    stall_other_aux_summary: Counter[str] = Counter()
    has_ifu_fq_summary = False
    ifu_fq_summary: dict[str, int] = {}
    ifu_fq_occ_hist_summary: dict[int, int] = {}

    for raw in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = IPC_RE.search(raw)
        if m:
            ipc = float(m.group(1))
            cpi = float(m.group(2))
            cycles = int(m.group(3))
            commits = int(m.group(4))
            continue

        m = TIMEOUT_RE.search(raw)
        if m:
            timeout_cycles = int(m.group(1))
            continue

        m = HOST_TIME_RE.search(raw)
        if m:
            host_time_us = int(m.group(1))
            continue

        m = BENCH_TIME_MS_RE.search(raw)
        if m:
            bench_reported_time_ms = float(m.group(1))
            continue

        flush_pos = raw.find("[flush ]")
        if flush_pos >= 0:
            flush_line = raw[flush_pos:]
            flush_count += 1
            kv = _parse_kv_pairs(flush_line)
            flush_cycle = _extract_cycle(flush_line)
            reason_raw = kv.get("reason", "unknown")
            source_raw = kv.get("source", "unknown")
            miss_type_raw = kv.get("miss_subtype", kv.get("miss_type", "none"))
            redirect_distance = _parse_int(kv.get("redirect_distance"), 0)
            killed_uops = _parse_int(kv.get("killed_uops"), 0)

            # Backward compatibility for old log format: [flush ] cycle=... reason=...
            if reason_raw == "unknown":
                m = FLUSH_RE.match(flush_line)
                if m and m.group(2):
                    reason_raw = m.group(2)

            reason = _normalize_flush_reason(reason_raw, flush_line)
            source = _normalize_flush_source(source_raw)
            miss_type = _normalize_miss_type(miss_type_raw)
            if flush_cycle is not None:
                last_flush_cycle = flush_cycle

            flush_reason_hist[reason] += 1
            flush_source_hist[source] += 1
            redirect_distance_sum += redirect_distance
            redirect_distance_samples += 1
            redirect_distance_max = max(redirect_distance_max, redirect_distance)

            if reason == "branch_mispredict":
                mispredict_flush_count += 1
                wrong_path_kill_uops += killed_uops
                if flush_cycle is not None:
                    last_branch_flush_cycle = flush_cycle
                if miss_type == "cond_branch":
                    mispredict_cond_count += 1
                elif miss_type == "jump":
                    mispredict_jump_count += 1
                elif miss_type == "jump_direct":
                    mispredict_jump_count += 1
                    mispredict_jump_direct_count += 1
                elif miss_type == "jump_indirect":
                    mispredict_jump_count += 1
                    mispredict_jump_indirect_count += 1
                elif miss_type == "return":
                    mispredict_ret_count += 1
            continue

        flushp_pos = raw.find("[flushp]")
        if flushp_pos >= 0:
            m = FLUSHP_RE.match(raw[flushp_pos:])
            if not m:
                continue
            reason = _normalize_flush_reason(m.group(2), raw[flushp_pos:])
            penalty = int(m.group(3))
            if reason == "branch_mispredict":
                branch_penalty_cycles += penalty
            continue

        if BRU_RE.match(raw):
            bru_count += 1
            continue

        pred_pos = raw.find("[pred")
        if pred_pos >= 0:
            pred_kv = _parse_kv_pairs(raw[pred_pos:])
            if "cond_total" in pred_kv:
                pred_cond_total_line = _parse_int(pred_kv.get("cond_total"), 0)
            if "cond_miss" in pred_kv:
                pred_cond_miss_line = _parse_int(pred_kv.get("cond_miss"), 0)
            if "jump_total" in pred_kv:
                pred_jump_total_line = _parse_int(pred_kv.get("jump_total"), 0)
            if "jump_miss" in pred_kv:
                pred_jump_miss_line = _parse_int(pred_kv.get("jump_miss"), 0)
            if "jump_direct_total" in pred_kv:
                pred_jump_direct_total_line = _parse_int(pred_kv.get("jump_direct_total"), 0)
            if "jump_direct_miss" in pred_kv:
                pred_jump_direct_miss_line = _parse_int(pred_kv.get("jump_direct_miss"), 0)
            if "jump_indirect_total" in pred_kv:
                pred_jump_indirect_total_line = _parse_int(pred_kv.get("jump_indirect_total"), 0)
            if "jump_indirect_miss" in pred_kv:
                pred_jump_indirect_miss_line = _parse_int(pred_kv.get("jump_indirect_miss"), 0)
            if "ret_total" in pred_kv:
                pred_ret_total_line = _parse_int(pred_kv.get("ret_total"), 0)
            if "ret_miss" in pred_kv:
                pred_ret_miss_line = _parse_int(pred_kv.get("ret_miss"), 0)
            if "call_total" in pred_kv:
                pred_call_total_line = _parse_int(pred_kv.get("call_total"), 0)
            if "cond_update_total" in pred_kv:
                pred_cond_update_total_line = _parse_int(pred_kv.get("cond_update_total"), 0)
            if "cond_local_correct" in pred_kv:
                pred_cond_local_correct_line = _parse_int(pred_kv.get("cond_local_correct"), 0)
            if "cond_global_correct" in pred_kv:
                pred_cond_global_correct_line = _parse_int(pred_kv.get("cond_global_correct"), 0)
            if "cond_selected_correct" in pred_kv:
                pred_cond_selected_correct_line = _parse_int(pred_kv.get("cond_selected_correct"), 0)
            if "cond_choose_local" in pred_kv:
                pred_cond_choose_local_line = _parse_int(pred_kv.get("cond_choose_local"), 0)
            if "cond_choose_global" in pred_kv:
                pred_cond_choose_global_line = _parse_int(pred_kv.get("cond_choose_global"), 0)
            if "tage_lookup_total" in pred_kv:
                pred_tage_lookup_total_line = _parse_int(pred_kv.get("tage_lookup_total"), 0)
            if "tage_hit_total" in pred_kv:
                pred_tage_hit_total_line = _parse_int(pred_kv.get("tage_hit_total"), 0)
            if "tage_override_total" in pred_kv:
                pred_tage_override_total_line = _parse_int(pred_kv.get("tage_override_total"), 0)
            if "tage_override_correct" in pred_kv:
                pred_tage_override_correct_line = _parse_int(pred_kv.get("tage_override_correct"), 0)
            if "sc_lookup_total" in pred_kv:
                pred_sc_lookup_total_line = _parse_int(pred_kv.get("sc_lookup_total"), 0)
            if "sc_confident_total" in pred_kv:
                pred_sc_confident_total_line = _parse_int(pred_kv.get("sc_confident_total"), 0)
            if "sc_override_total" in pred_kv:
                pred_sc_override_total_line = _parse_int(pred_kv.get("sc_override_total"), 0)
            if "sc_override_correct" in pred_kv:
                pred_sc_override_correct_line = _parse_int(pred_kv.get("sc_override_correct"), 0)
            if "loop_lookup_total" in pred_kv:
                pred_loop_lookup_total_line = _parse_int(pred_kv.get("loop_lookup_total"), 0)
            if "loop_hit_total" in pred_kv:
                pred_loop_hit_total_line = _parse_int(pred_kv.get("loop_hit_total"), 0)
            if "loop_confident_total" in pred_kv:
                pred_loop_confident_total_line = _parse_int(pred_kv.get("loop_confident_total"), 0)
            if "loop_override_total" in pred_kv:
                pred_loop_override_total_line = _parse_int(pred_kv.get("loop_override_total"), 0)
            if "loop_override_correct" in pred_kv:
                pred_loop_override_correct_line = _parse_int(pred_kv.get("loop_override_correct"), 0)
            if "cond_provider_legacy_selected" in pred_kv:
                pred_cond_provider_legacy_selected_line = _parse_int(
                    pred_kv.get("cond_provider_legacy_selected"), 0
                )
            if "cond_provider_tage_selected" in pred_kv:
                pred_cond_provider_tage_selected_line = _parse_int(pred_kv.get("cond_provider_tage_selected"), 0)
            if "cond_provider_sc_selected" in pred_kv:
                pred_cond_provider_sc_selected_line = _parse_int(pred_kv.get("cond_provider_sc_selected"), 0)
            if "cond_provider_loop_selected" in pred_kv:
                pred_cond_provider_loop_selected_line = _parse_int(pred_kv.get("cond_provider_loop_selected"), 0)
            if "cond_provider_legacy_correct" in pred_kv:
                pred_cond_provider_legacy_correct_line = _parse_int(
                    pred_kv.get("cond_provider_legacy_correct"), 0
                )
            if "cond_provider_tage_correct" in pred_kv:
                pred_cond_provider_tage_correct_line = _parse_int(pred_kv.get("cond_provider_tage_correct"), 0)
            if "cond_provider_sc_correct" in pred_kv:
                pred_cond_provider_sc_correct_line = _parse_int(pred_kv.get("cond_provider_sc_correct"), 0)
            if "cond_provider_loop_correct" in pred_kv:
                pred_cond_provider_loop_correct_line = _parse_int(pred_kv.get("cond_provider_loop_correct"), 0)
            if "cond_selected_wrong_alt_legacy_correct" in pred_kv:
                pred_cond_selected_wrong_alt_legacy_correct_line = _parse_int(
                    pred_kv.get("cond_selected_wrong_alt_legacy_correct"), 0
                )
            if "cond_selected_wrong_alt_tage_correct" in pred_kv:
                pred_cond_selected_wrong_alt_tage_correct_line = _parse_int(
                    pred_kv.get("cond_selected_wrong_alt_tage_correct"), 0
                )
            if "cond_selected_wrong_alt_sc_correct" in pred_kv:
                pred_cond_selected_wrong_alt_sc_correct_line = _parse_int(
                    pred_kv.get("cond_selected_wrong_alt_sc_correct"), 0
                )
            if "cond_selected_wrong_alt_loop_correct" in pred_kv:
                pred_cond_selected_wrong_alt_loop_correct_line = _parse_int(
                    pred_kv.get("cond_selected_wrong_alt_loop_correct"), 0
                )
            if "cond_selected_wrong_alt_any_correct" in pred_kv:
                pred_cond_selected_wrong_alt_any_correct_line = _parse_int(
                    pred_kv.get("cond_selected_wrong_alt_any_correct"), 0
                )
            continue

        commitm_pos = raw.find("[commitm]")
        if commitm_pos >= 0:
            kv = _parse_kv_pairs(raw[commitm_pos:])
            has_commit_summary = True
            for key, value in kv.items():
                m = COMMIT_WIDTH_KEY_RE.match(key)
                if not m:
                    continue
                idx = int(m.group(1))
                commit_summary_hist[idx] = _parse_int(value, commit_summary_hist.get(idx, 0))
            continue

        controlm_pos = raw.find("[controlm]")
        if controlm_pos >= 0:
            kv = _parse_kv_pairs(raw[controlm_pos:])
            has_commit_summary = True
            for key in (
                "branch_count",
                "jal_count",
                "jalr_count",
                "branch_taken_count",
                "call_count",
                "ret_count",
                "control_count",
            ):
                if key in kv:
                    control_summary[key] = _parse_int(kv.get(key), 0)
            continue

        hotpcm_pos = raw.find("[hotpcm]")
        if hotpcm_pos >= 0:
            kv = _parse_kv_pairs(raw[hotpcm_pos:])
            parsed = _parse_ranked_summary(kv, "pc")
            if parsed:
                has_commit_summary = True
                top_pc_summary = parsed
            continue

        hotinstm_pos = raw.find("[hotinstm]")
        if hotinstm_pos >= 0:
            kv = _parse_kv_pairs(raw[hotinstm_pos:])
            parsed = _parse_ranked_summary(kv, "inst")
            if parsed:
                has_commit_summary = True
                top_inst_summary = parsed
            continue

        stallm_pos = raw.find("[stallm]")
        if stallm_pos >= 0:
            kv = _parse_kv_pairs(raw[stallm_pos:])
            has_stall_cycle_summary = True
            stall_cycle_total = _parse_int(kv.get("stall_total_cycles"), 0)
            for key in STALL_CATEGORY_KEYS:
                if key in kv:
                    stall_cycle_summary[key] = _parse_int(kv.get(key), 0)
            if stall_cycle_total == 0:
                stall_cycle_total = sum(stall_cycle_summary.values())
            continue

        stallm2_pos = raw.find("[stallm2]")
        if stallm2_pos >= 0:
            kv = _parse_kv_pairs(raw[stallm2_pos:])
            stall_frontend_empty_total = _parse_int(kv.get("frontend_empty_total"), 0)
            for key in STALL_FRONTEND_EMPTY_DETAIL_KEYS:
                if key in kv:
                    stall_frontend_empty_detail_summary[key] = _parse_int(kv.get(key), 0)
            # Backward compatibility: old logs may only provide unsplit key.
            if (
                "fe_wait_icache_rsp" in kv
                and "fe_wait_icache_rsp_hit_latency" not in kv
                and "fe_wait_icache_rsp_miss_wait" not in kv
            ):
                stall_frontend_empty_detail_summary["fe_wait_icache_rsp_miss_wait"] = _parse_int(
                    kv.get("fe_wait_icache_rsp"), 0
                )
            if stall_frontend_empty_total == 0:
                stall_frontend_empty_total = sum(stall_frontend_empty_detail_summary.values())
            continue

        stallm3_pos = raw.find("[stallm3]")
        if stallm3_pos >= 0:
            kv = _parse_kv_pairs(raw[stallm3_pos:])
            has_stall_decode_blocked_summary = True
            stall_decode_blocked_total_summary = _parse_int(kv.get("decode_blocked_total"), 0)
            for key, val in kv.items():
                if key in ("mode", "decode_blocked_total"):
                    continue
                stall_decode_blocked_detail_summary[key] = _parse_int(val, 0)
            if stall_decode_blocked_total_summary == 0:
                stall_decode_blocked_total_summary = sum(stall_decode_blocked_detail_summary.values())
            continue

        stallm4_pos = raw.find("[stallm4]")
        if stallm4_pos >= 0:
            kv = _parse_kv_pairs(raw[stallm4_pos:])
            has_stall_rob_backpressure_summary = True
            stall_rob_backpressure_total_summary = _parse_int(kv.get("rob_backpressure_total"), 0)
            for key, val in kv.items():
                if key in ("mode", "rob_backpressure_total"):
                    continue
                stall_rob_backpressure_detail_summary[key] = _parse_int(val, 0)
            if stall_rob_backpressure_total_summary == 0:
                stall_rob_backpressure_total_summary = sum(stall_rob_backpressure_detail_summary.values())
            continue

        stallm5_pos = raw.find("[stallm5]")
        if stallm5_pos >= 0:
            kv = _parse_kv_pairs(raw[stallm5_pos:])
            has_stall_other_summary = True
            stall_other_total_summary = _parse_int(kv.get("other_total"), 0)
            for key, val in kv.items():
                if key in ("mode", "other_total"):
                    continue
                key = _canonicalize_stall_other_detail_key(key)
                stall_other_detail_summary[key] += _parse_int(val, 0)
            if stall_other_total_summary == 0:
                stall_other_total_summary = sum(stall_other_detail_summary.values())
            continue

        stallm6_pos = raw.find("[stallm6]")
        if stallm6_pos >= 0:
            kv = _parse_kv_pairs(raw[stallm6_pos:])
            for key, val in kv.items():
                if key == "mode":
                    continue
                stall_other_aux_summary[key] = _parse_int(val, 0)
            continue

        ifum_pos = raw.find("[ifum]")
        if ifum_pos >= 0:
            kv = _parse_kv_pairs(raw[ifum_pos:])
            has_ifu_fq_summary = True
            ifu_fq_summary = {}
            ifu_fq_occ_hist_summary = {}
            for key, val in kv.items():
                if key == "mode":
                    continue
                if key.startswith("fq_occ_bin"):
                    idx_text = key[len("fq_occ_bin") :]
                    try:
                        idx = int(idx_text, 10)
                    except ValueError:
                        continue
                    ifu_fq_occ_hist_summary[idx] = _parse_int(val, 0)
                    continue
                ifu_fq_summary[key] = _parse_int(val, 0)
            continue

        m = COMMIT_RE.match(raw)
        if m:
            cycle = int(m.group(1))
            slot = int(m.group(2))
            pc = int(m.group(3), 16)
            inst = int(m.group(4), 16)
            commit_by_cycle[cycle] += 1
            commit_seq.append((cycle, slot, pc, inst))
            hotspot_pc[pc] += 1
            hotspot_inst[inst] += 1
            continue

        if STALL_RE.match(raw):
            stall_kind = _classify_stall(raw)
            stall_counter[stall_kind] += 1
            if stall_kind == "decode_blocked":
                stall_decode_blocked_total += 1
                stall_decode_blocked_detail[_classify_decode_blocked_detail(raw)] += 1
                stall_cycle = _extract_cycle(raw)
                if (
                    stall_cycle is not None
                    and last_flush_cycle is not None
                    and stall_cycle >= last_flush_cycle
                    and (stall_cycle - last_flush_cycle) <= STALL_POST_FLUSH_WINDOW_CYCLES
                ):
                    stall_decode_blocked_post_flush += 1
                if (
                    stall_cycle is not None
                    and last_branch_flush_cycle is not None
                    and stall_cycle >= last_branch_flush_cycle
                    and (stall_cycle - last_branch_flush_cycle) <= STALL_POST_FLUSH_WINDOW_CYCLES
                ):
                    stall_decode_blocked_post_branch_flush += 1
            elif stall_kind == "rob_backpressure":
                stall_rob_backpressure_total += 1
                stall_rob_backpressure_detail[_classify_rob_backpressure_detail(raw)] += 1
            elif stall_kind == "other":
                stall_other_total += 1
                stall_other_detail[_classify_other_detail(raw)] += 1

    commit_width_hist = _commit_histogram(cycles, commit_by_cycle)
    control = _control_flow_metrics(commit_seq)

    cond_total = int(control.get("branch_count", 0))
    jump_direct_total = int(control.get("jal_count", 0))
    jump_indirect_total = max(0, int(control.get("jalr_count", 0)) - int(control.get("ret_count", 0)))
    jump_total = jump_direct_total + jump_indirect_total
    ret_total = int(control.get("ret_count", 0))
    call_total = int(control.get("call_count", 0))
    cond_miss = mispredict_cond_count
    jump_miss = mispredict_jump_count
    jump_direct_miss = mispredict_jump_direct_count
    jump_indirect_miss = mispredict_jump_indirect_count
    ret_miss = mispredict_ret_count
    if pred_cond_total_line is not None:
        cond_total = pred_cond_total_line
    if pred_cond_miss_line is not None:
        cond_miss = pred_cond_miss_line
    if pred_jump_total_line is not None:
        jump_total = pred_jump_total_line
    if pred_jump_miss_line is not None:
        jump_miss = pred_jump_miss_line
    if pred_jump_direct_total_line is not None:
        jump_direct_total = pred_jump_direct_total_line
    if pred_jump_direct_miss_line is not None:
        jump_direct_miss = pred_jump_direct_miss_line
    if pred_jump_indirect_total_line is not None:
        jump_indirect_total = pred_jump_indirect_total_line
    if pred_jump_indirect_miss_line is not None:
        jump_indirect_miss = pred_jump_indirect_miss_line
    if pred_ret_total_line is not None:
        ret_total = pred_ret_total_line
    if pred_ret_miss_line is not None:
        ret_miss = pred_ret_miss_line
    if pred_call_total_line is not None:
        call_total = pred_call_total_line
    cond_update_total = cond_total
    cond_local_correct = 0
    cond_global_correct = 0
    cond_selected_correct = 0
    cond_choose_local = 0
    cond_choose_global = 0
    if pred_cond_update_total_line is not None:
        cond_update_total = pred_cond_update_total_line
    if pred_cond_local_correct_line is not None:
        cond_local_correct = pred_cond_local_correct_line
    if pred_cond_global_correct_line is not None:
        cond_global_correct = pred_cond_global_correct_line
    if pred_cond_selected_correct_line is not None:
        cond_selected_correct = pred_cond_selected_correct_line
    if pred_cond_choose_local_line is not None:
        cond_choose_local = pred_cond_choose_local_line
    if pred_cond_choose_global_line is not None:
        cond_choose_global = pred_cond_choose_global_line
    tage_lookup_total = 0
    tage_hit_total = 0
    tage_override_total = 0
    tage_override_correct = 0
    sc_lookup_total = 0
    sc_confident_total = 0
    sc_override_total = 0
    sc_override_correct = 0
    loop_lookup_total = 0
    loop_hit_total = 0
    loop_confident_total = 0
    loop_override_total = 0
    loop_override_correct = 0
    cond_provider_legacy_selected = 0
    cond_provider_tage_selected = 0
    cond_provider_sc_selected = 0
    cond_provider_loop_selected = 0
    cond_provider_legacy_correct = 0
    cond_provider_tage_correct = 0
    cond_provider_sc_correct = 0
    cond_provider_loop_correct = 0
    cond_selected_wrong_alt_legacy_correct = 0
    cond_selected_wrong_alt_tage_correct = 0
    cond_selected_wrong_alt_sc_correct = 0
    cond_selected_wrong_alt_loop_correct = 0
    cond_selected_wrong_alt_any_correct = 0
    if pred_tage_lookup_total_line is not None:
        tage_lookup_total = pred_tage_lookup_total_line
    if pred_tage_hit_total_line is not None:
        tage_hit_total = pred_tage_hit_total_line
    if pred_tage_override_total_line is not None:
        tage_override_total = pred_tage_override_total_line
    if pred_tage_override_correct_line is not None:
        tage_override_correct = pred_tage_override_correct_line
    if pred_sc_lookup_total_line is not None:
        sc_lookup_total = pred_sc_lookup_total_line
    if pred_sc_confident_total_line is not None:
        sc_confident_total = pred_sc_confident_total_line
    if pred_sc_override_total_line is not None:
        sc_override_total = pred_sc_override_total_line
    if pred_sc_override_correct_line is not None:
        sc_override_correct = pred_sc_override_correct_line
    if pred_loop_lookup_total_line is not None:
        loop_lookup_total = pred_loop_lookup_total_line
    if pred_loop_hit_total_line is not None:
        loop_hit_total = pred_loop_hit_total_line
    if pred_loop_confident_total_line is not None:
        loop_confident_total = pred_loop_confident_total_line
    if pred_loop_override_total_line is not None:
        loop_override_total = pred_loop_override_total_line
    if pred_loop_override_correct_line is not None:
        loop_override_correct = pred_loop_override_correct_line
    if pred_cond_provider_legacy_selected_line is not None:
        cond_provider_legacy_selected = pred_cond_provider_legacy_selected_line
    if pred_cond_provider_tage_selected_line is not None:
        cond_provider_tage_selected = pred_cond_provider_tage_selected_line
    if pred_cond_provider_sc_selected_line is not None:
        cond_provider_sc_selected = pred_cond_provider_sc_selected_line
    if pred_cond_provider_loop_selected_line is not None:
        cond_provider_loop_selected = pred_cond_provider_loop_selected_line
    if pred_cond_provider_legacy_correct_line is not None:
        cond_provider_legacy_correct = pred_cond_provider_legacy_correct_line
    if pred_cond_provider_tage_correct_line is not None:
        cond_provider_tage_correct = pred_cond_provider_tage_correct_line
    if pred_cond_provider_sc_correct_line is not None:
        cond_provider_sc_correct = pred_cond_provider_sc_correct_line
    if pred_cond_provider_loop_correct_line is not None:
        cond_provider_loop_correct = pred_cond_provider_loop_correct_line
    if pred_cond_selected_wrong_alt_legacy_correct_line is not None:
        cond_selected_wrong_alt_legacy_correct = pred_cond_selected_wrong_alt_legacy_correct_line
    if pred_cond_selected_wrong_alt_tage_correct_line is not None:
        cond_selected_wrong_alt_tage_correct = pred_cond_selected_wrong_alt_tage_correct_line
    if pred_cond_selected_wrong_alt_sc_correct_line is not None:
        cond_selected_wrong_alt_sc_correct = pred_cond_selected_wrong_alt_sc_correct_line
    if pred_cond_selected_wrong_alt_loop_correct_line is not None:
        cond_selected_wrong_alt_loop_correct = pred_cond_selected_wrong_alt_loop_correct_line
    if pred_cond_selected_wrong_alt_any_correct_line is not None:
        cond_selected_wrong_alt_any_correct = pred_cond_selected_wrong_alt_any_correct_line
    chooser_total = cond_choose_local + cond_choose_global
    cond_provider_total_selected = (
        cond_provider_legacy_selected
        + cond_provider_tage_selected
        + cond_provider_sc_selected
        + cond_provider_loop_selected
    )
    cond_provider_total_correct = (
        cond_provider_legacy_correct
        + cond_provider_tage_correct
        + cond_provider_sc_correct
        + cond_provider_loop_correct
    )
    cond_selected_wrong_total = max(0, cond_provider_total_selected - cond_provider_total_correct)
    cond_hit = max(0, cond_total - cond_miss)
    jump_direct_hit = max(0, jump_direct_total - jump_direct_miss)
    jump_indirect_hit = max(0, jump_indirect_total - jump_indirect_miss)
    if pred_jump_total_line is None and (
        pred_jump_direct_total_line is not None or pred_jump_indirect_total_line is not None
    ):
        jump_total = jump_direct_total + jump_indirect_total
    if pred_jump_miss_line is None and (
        pred_jump_direct_miss_line is not None or pred_jump_indirect_miss_line is not None
    ):
        jump_miss = jump_direct_miss + jump_indirect_miss
    jump_hit = max(0, jump_total - jump_miss)
    ret_hit = max(0, ret_total - ret_miss)
    predict = {
        "cond_total": cond_total,
        "cond_miss": cond_miss,
        "cond_hit": cond_hit,
        "cond_miss_rate": _safe_div(cond_miss, cond_total),
        "jump_direct_total": jump_direct_total,
        "jump_direct_miss": jump_direct_miss,
        "jump_direct_hit": jump_direct_hit,
        "jump_direct_miss_rate": _safe_div(jump_direct_miss, jump_direct_total),
        "jump_indirect_total": jump_indirect_total,
        "jump_indirect_miss": jump_indirect_miss,
        "jump_indirect_hit": jump_indirect_hit,
        "jump_indirect_miss_rate": _safe_div(jump_indirect_miss, jump_indirect_total),
        "jump_total": jump_total,
        "jump_miss": jump_miss,
        "jump_hit": jump_hit,
        "jump_miss_rate": _safe_div(jump_miss, jump_total),
        "ret_total": ret_total,
        "ret_miss": ret_miss,
        "ret_hit": ret_hit,
        "ret_miss_rate": _safe_div(ret_miss, ret_total),
        "call_total": call_total,
        "cond_update_total": cond_update_total,
        "cond_local_correct": cond_local_correct,
        "cond_global_correct": cond_global_correct,
        "cond_selected_correct": cond_selected_correct,
        "cond_choose_local": cond_choose_local,
        "cond_choose_global": cond_choose_global,
        "cond_local_accuracy": _safe_div(cond_local_correct, cond_update_total),
        "cond_global_accuracy": _safe_div(cond_global_correct, cond_update_total),
        "cond_selected_accuracy": _safe_div(cond_selected_correct, cond_update_total),
        "cond_choose_global_ratio": _safe_div(cond_choose_global, chooser_total),
        "tage_lookup_total": tage_lookup_total,
        "tage_hit_total": tage_hit_total,
        "tage_override_total": tage_override_total,
        "tage_override_correct": tage_override_correct,
        "tage_hit_rate": _safe_div(tage_hit_total, tage_lookup_total),
        "tage_override_ratio": _safe_div(tage_override_total, tage_lookup_total),
        "tage_override_accuracy": _safe_div(tage_override_correct, tage_override_total),
        "sc_lookup_total": sc_lookup_total,
        "sc_confident_total": sc_confident_total,
        "sc_override_total": sc_override_total,
        "sc_override_correct": sc_override_correct,
        "sc_confident_ratio": _safe_div(sc_confident_total, sc_lookup_total),
        "sc_override_ratio": _safe_div(sc_override_total, sc_lookup_total),
        "sc_override_accuracy": _safe_div(sc_override_correct, sc_override_total),
        "loop_lookup_total": loop_lookup_total,
        "loop_hit_total": loop_hit_total,
        "loop_confident_total": loop_confident_total,
        "loop_override_total": loop_override_total,
        "loop_override_correct": loop_override_correct,
        "loop_hit_rate": _safe_div(loop_hit_total, loop_lookup_total),
        "loop_confident_ratio": _safe_div(loop_confident_total, loop_lookup_total),
        "loop_override_ratio": _safe_div(loop_override_total, loop_lookup_total),
        "loop_override_accuracy": _safe_div(loop_override_correct, loop_override_total),
        "cond_provider_legacy_selected": cond_provider_legacy_selected,
        "cond_provider_tage_selected": cond_provider_tage_selected,
        "cond_provider_sc_selected": cond_provider_sc_selected,
        "cond_provider_loop_selected": cond_provider_loop_selected,
        "cond_provider_total_selected": cond_provider_total_selected,
        "cond_provider_legacy_correct": cond_provider_legacy_correct,
        "cond_provider_tage_correct": cond_provider_tage_correct,
        "cond_provider_sc_correct": cond_provider_sc_correct,
        "cond_provider_loop_correct": cond_provider_loop_correct,
        "cond_provider_total_correct": cond_provider_total_correct,
        "cond_provider_legacy_accuracy": _safe_div(cond_provider_legacy_correct, cond_provider_legacy_selected),
        "cond_provider_tage_accuracy": _safe_div(cond_provider_tage_correct, cond_provider_tage_selected),
        "cond_provider_sc_accuracy": _safe_div(cond_provider_sc_correct, cond_provider_sc_selected),
        "cond_provider_loop_accuracy": _safe_div(cond_provider_loop_correct, cond_provider_loop_selected),
        "cond_provider_coverage": _safe_div(cond_provider_total_selected, cond_update_total),
        "cond_provider_legacy_share": _safe_div(cond_provider_legacy_selected, cond_provider_total_selected),
        "cond_provider_tage_share": _safe_div(cond_provider_tage_selected, cond_provider_total_selected),
        "cond_provider_sc_share": _safe_div(cond_provider_sc_selected, cond_provider_total_selected),
        "cond_provider_loop_share": _safe_div(cond_provider_loop_selected, cond_provider_total_selected),
        "cond_selected_wrong_total": cond_selected_wrong_total,
        "cond_selected_wrong_alt_legacy_correct": cond_selected_wrong_alt_legacy_correct,
        "cond_selected_wrong_alt_tage_correct": cond_selected_wrong_alt_tage_correct,
        "cond_selected_wrong_alt_sc_correct": cond_selected_wrong_alt_sc_correct,
        "cond_selected_wrong_alt_loop_correct": cond_selected_wrong_alt_loop_correct,
        "cond_selected_wrong_alt_any_correct": cond_selected_wrong_alt_any_correct,
        "cond_selected_wrong_alt_legacy_ratio": _safe_div(
            cond_selected_wrong_alt_legacy_correct, cond_selected_wrong_total
        ),
        "cond_selected_wrong_alt_tage_ratio": _safe_div(
            cond_selected_wrong_alt_tage_correct, cond_selected_wrong_total
        ),
        "cond_selected_wrong_alt_sc_ratio": _safe_div(cond_selected_wrong_alt_sc_correct, cond_selected_wrong_total),
        "cond_selected_wrong_alt_loop_ratio": _safe_div(
            cond_selected_wrong_alt_loop_correct, cond_selected_wrong_total
        ),
        "cond_selected_wrong_alt_any_ratio": _safe_div(cond_selected_wrong_alt_any_correct, cond_selected_wrong_total),
    }

    # Fallback path for timeout/sample logs without final IPC line.
    if cycles == 0 and timeout_cycles > 0:
        cycles = timeout_cycles
    if commits == 0 and commit_seq:
        commits = len(commit_seq)
    if ipc == 0.0 and cycles > 0 and commits > 0:
        ipc = commits / cycles
    if cpi == 0.0 and commits > 0 and cycles > 0:
        cpi = cycles / commits

    # Recompute width histogram when cycles were recovered from timeout line.
    commit_width_hist = _commit_histogram(cycles, commit_by_cycle)
    has_commit_detail = len(commit_seq) > 0

    if has_commit_summary:
        max_summary_width = max(commit_summary_hist.keys(), default=0)
        max_summary_width = max(max_summary_width, 4)
        commit_width_hist = {k: commit_summary_hist.get(k, 0) for k in range(max_summary_width + 1)}

    if control_summary:
        control["branch_count"] = int(control_summary.get("branch_count", control.get("branch_count", 0)))
        control["jal_count"] = int(control_summary.get("jal_count", control.get("jal_count", 0)))
        control["jalr_count"] = int(control_summary.get("jalr_count", control.get("jalr_count", 0)))
        control["branch_taken_count"] = int(
            control_summary.get("branch_taken_count", control.get("branch_taken_count", 0))
        )
        control["call_count"] = int(control_summary.get("call_count", control.get("call_count", 0)))
        control["ret_count"] = int(control_summary.get("ret_count", control.get("ret_count", 0)))
        control_count = int(
            control_summary.get(
                "control_count",
                control["branch_count"] + control["jal_count"] + control["jalr_count"],
            )
        )
        control["control_count"] = control_count
        est_misp_count = int(control["branch_taken_count"]) + int(control["jal_count"]) + int(control["jalr_count"])
        control["est_misp_count"] = est_misp_count
        control["control_ratio"] = _safe_div(control_count, commits)
        control["est_misp_per_kinst"] = 1000.0 * _safe_div(est_misp_count, commits)

    top_pc = top_pc_summary if top_pc_summary else [{"pc": f"0x{pc:08x}", "count": cnt} for pc, cnt in hotspot_pc.most_common(10)]
    top_inst = (
        top_inst_summary
        if top_inst_summary
        else [{"inst": f"0x{inst:08x}", "count": cnt} for inst, cnt in hotspot_inst.most_common(10)]
    )

    stall_mode = "none"
    stall_category: dict[str, int] = dict(stall_counter)
    stall_total = sum(stall_counter.values())
    if has_stall_cycle_summary:
        stall_mode = "cycle"
        stall_category = dict(stall_cycle_summary)
        stall_total = stall_cycle_total
    elif stall_total > 0:
        stall_mode = "sampled"

    if stall_mode == "cycle":
        cycle_decode_blocked_total = int(stall_category.get("decode_blocked", 0))
        cycle_rob_backpressure_total = int(stall_category.get("rob_backpressure", 0))
        cycle_other_total = int(stall_category.get("other", 0))

        if has_stall_decode_blocked_summary:
            stall_decode_blocked_total = stall_decode_blocked_total_summary
            stall_decode_blocked_detail = Counter(stall_decode_blocked_detail_summary)
        elif cycle_decode_blocked_total > 0:
            stall_decode_blocked_total = cycle_decode_blocked_total

        if has_stall_rob_backpressure_summary:
            stall_rob_backpressure_total = stall_rob_backpressure_total_summary
            stall_rob_backpressure_detail = Counter(stall_rob_backpressure_detail_summary)
        elif cycle_rob_backpressure_total > 0:
            stall_rob_backpressure_total = cycle_rob_backpressure_total

        if has_stall_other_summary:
            stall_other_total = stall_other_total_summary
            stall_other_detail = Counter(stall_other_detail_summary)
        elif cycle_other_total > 0:
            stall_other_total = cycle_other_total

    quality_warnings: list[str] = []
    if not has_commit_detail and not has_commit_summary:
        quality_warnings.append("commit metrics low confidence: missing both [commit] detail and [commitm] summary")
    elif has_commit_summary and not has_commit_detail:
        quality_warnings.append("commit metrics sourced from [commitm]/[controlm] summary without [commit] detail")
    if stall_mode == "sampled":
        quality_warnings.append("stall metrics are sampled events (no_commit threshold), not cycle-accurate cycles")
    elif stall_mode == "none":
        quality_warnings.append("stall metrics unavailable: missing both [stallm] and sampled [stall] events")
    elif stall_mode == "cycle":
        if int(stall_category.get("decode_blocked", 0)) > 0 and not has_stall_decode_blocked_summary:
            quality_warnings.append("decode_blocked secondary split from sampled [stall] only (missing [stallm3])")
        if int(stall_category.get("rob_backpressure", 0)) > 0 and not has_stall_rob_backpressure_summary:
            quality_warnings.append("rob_backpressure secondary split from sampled [stall] only (missing [stallm4])")
        if int(stall_category.get("other", 0)) > 0 and not has_stall_other_summary:
            quality_warnings.append("other secondary split from sampled [stall] only (missing [stallm5])")

    host_time_ms = host_time_us / 1000.0
    benchmark_time_source = "unknown"
    effective_benchmark_time_ms = 0.0
    if bench_reported_time_ms is not None and bench_reported_time_ms > 0.0:
        benchmark_time_source = "self_reported"
        effective_benchmark_time_ms = bench_reported_time_ms
    elif host_time_us > 0:
        benchmark_time_source = "host_fallback"
        effective_benchmark_time_ms = host_time_ms
        if bench_reported_time_ms is not None and bench_reported_time_ms <= 0.0:
            quality_warnings.append("benchmark self-reported time is 0ms; timing context uses host fallback")
    elif bench_reported_time_ms is not None:
        benchmark_time_source = "self_reported"
        effective_benchmark_time_ms = bench_reported_time_ms

    ifu_fq: dict[str, Any] = {}
    if has_ifu_fq_summary:
        fq_samples = int(ifu_fq_summary.get("fq_samples", cycles))
        fq_enq = int(ifu_fq_summary.get("fq_enq", 0))
        fq_deq = int(ifu_fq_summary.get("fq_deq", 0))
        fq_bypass = int(ifu_fq_summary.get("fq_bypass", 0))
        fq_enq_blocked = int(ifu_fq_summary.get("fq_enq_blocked", 0))
        fq_full_cycles = int(ifu_fq_summary.get("fq_full_cycles", 0))
        fq_empty_cycles = int(ifu_fq_summary.get("fq_empty_cycles", 0))
        fq_nonempty_cycles = int(ifu_fq_summary.get("fq_nonempty_cycles", max(0, fq_samples - fq_empty_cycles)))
        fq_occ_sum = int(ifu_fq_summary.get("fq_occ_sum", 0))
        ifu_fq = dict(ifu_fq_summary)
        ifu_fq["fq_samples"] = fq_samples
        ifu_fq["fq_nonempty_cycles"] = fq_nonempty_cycles
        ifu_fq["fq_occ_hist"] = dict(sorted(ifu_fq_occ_hist_summary.items()))
        ifu_fq["fq_occ_avg"] = _safe_div(fq_occ_sum, fq_samples)
        ifu_fq["fq_bypass_ratio"] = _safe_div(fq_bypass, fq_deq)
        ifu_fq["fq_enq_blocked_ratio"] = _safe_div(fq_enq_blocked, fq_samples)
        ifu_fq["fq_full_ratio"] = _safe_div(fq_full_cycles, fq_samples)
        ifu_fq["fq_empty_ratio"] = _safe_div(fq_empty_cycles, fq_samples)
        ifu_fq["fq_nonempty_ratio"] = _safe_div(fq_nonempty_cycles, fq_samples)
        if "fq_occ_avg_x1000" in ifu_fq_summary:
            ifu_fq["fq_occ_avg_from_line"] = _safe_div(int(ifu_fq_summary["fq_occ_avg_x1000"]), 1000.0)

    return {
        "log_path": str(p),
        "ipc": ipc,
        "cpi": cpi,
        "cycles": cycles,
        "commits": commits,
        "flush_count": flush_count,
        "bru_count": bru_count,
        "mispredict_flush_count": mispredict_flush_count,
        "mispredict_cond_count": mispredict_cond_count,
        "mispredict_jump_count": mispredict_jump_count,
        "mispredict_jump_direct_count": mispredict_jump_direct_count,
        "mispredict_jump_indirect_count": mispredict_jump_indirect_count,
        "mispredict_ret_count": mispredict_ret_count,
        "mispredict_breakdown": {
            "cond_branch": mispredict_cond_count,
            "jump_direct": mispredict_jump_direct_count,
            "jump_indirect": mispredict_jump_indirect_count,
            "jump": mispredict_jump_count,
            "return": mispredict_ret_count,
        },
        "branch_penalty_cycles": branch_penalty_cycles,
        "wrong_path_kill_uops": wrong_path_kill_uops,
        "redirect_distance_sum": redirect_distance_sum,
        "redirect_distance_samples": redirect_distance_samples,
        "redirect_distance_avg": _safe_div(redirect_distance_sum, redirect_distance_samples),
        "redirect_distance_max": redirect_distance_max,
        "flush_reason_histogram": dict(flush_reason_hist),
        "flush_source_histogram": dict(flush_source_hist),
        "flush_per_kinst": 1000.0 * _safe_div(flush_count, commits),
        "bru_per_kinst": 1000.0 * _safe_div(bru_count, commits),
        "commit_width_hist": commit_width_hist,
        "stall_category": stall_category,
        "stall_total": stall_total,
        "stall_post_flush_window_cycles": STALL_POST_FLUSH_WINDOW_CYCLES,
        "stall_decode_blocked_total": stall_decode_blocked_total,
        "stall_decode_blocked_post_flush": stall_decode_blocked_post_flush,
        "stall_decode_blocked_post_flush_ratio": _safe_div(stall_decode_blocked_post_flush, stall_decode_blocked_total),
        "stall_decode_blocked_post_branch_flush": stall_decode_blocked_post_branch_flush,
        "stall_decode_blocked_post_branch_flush_ratio": _safe_div(
            stall_decode_blocked_post_branch_flush, stall_decode_blocked_total
        ),
        "stall_decode_blocked_detail": dict(stall_decode_blocked_detail),
        "stall_rob_backpressure_total": stall_rob_backpressure_total,
        "stall_rob_backpressure_detail": dict(stall_rob_backpressure_detail),
        "stall_other_total": stall_other_total,
        "stall_other_detail": dict(stall_other_detail),
        "stall_other_aux": dict(stall_other_aux_summary),
        "stall_frontend_empty_total": stall_frontend_empty_total,
        "stall_frontend_empty_detail": dict(stall_frontend_empty_detail_summary),
        "ifu_fq": ifu_fq,
        "top_pc": top_pc,
        "top_inst": top_inst,
        "control": control,
        "predict": predict,
        "has_commit_detail": has_commit_detail,
        "has_commit_summary": has_commit_summary,
        "stall_mode": stall_mode,
        "quality_warnings": quality_warnings,
        "commit_metrics_source": "detail" if has_commit_detail else ("summary" if has_commit_summary else "none"),
        "stall_metrics_source": stall_mode,
        "host_time_us": host_time_us,
        "host_time_ms": host_time_ms,
        "bench_reported_time_ms": bench_reported_time_ms,
        "effective_benchmark_time_ms": effective_benchmark_time_ms,
        "benchmark_time_source": benchmark_time_source,
    }


def parse_log_directory(log_dir: str | Path) -> dict[str, Any]:
    d = Path(log_dir)
    summary: dict[str, Any] = {}

    candidates = {
        "dhrystone": ["dhrystone.log", "dhrystone_full.log"],
        "coremark": ["coremark.log", "coremark_full.log"],
        "coremark_sample": ["coremark_commit_sample.log"],
    }

    for bench, names in candidates.items():
        chosen = None
        for name in names:
            fp = d / name
            if fp.exists():
                chosen = fp
                break
        if chosen is None:
            continue
        summary[bench] = parse_single_log(chosen)

    return summary


def _fmt_pct(part: int, total: int) -> str:
    return "0.00%" if total == 0 else f"{(part * 100.0 / total):.2f}%"


def _bench_markdown(name: str, data: dict[str, Any]) -> str:
    raw_hist = data.get("commit_width_hist", {})
    hist: dict[int, int] = {}
    for key, value in raw_hist.items():
        try:
            idx = int(key)
        except (TypeError, ValueError):
            continue
        hist[idx] = int(value)
    if not hist:
        hist = {i: 0 for i in range(5)}
    stall = data.get("stall_category", {})
    stall_total = data.get("stall_total", 0)
    stall_post_flush_window = data.get("stall_post_flush_window_cycles", STALL_POST_FLUSH_WINDOW_CYCLES)
    decode_blocked_total = data.get("stall_decode_blocked_total", 0)
    decode_blocked_post_flush = data.get("stall_decode_blocked_post_flush", 0)
    decode_blocked_post_flush_ratio = data.get("stall_decode_blocked_post_flush_ratio", 0.0)
    decode_blocked_post_branch_flush = data.get("stall_decode_blocked_post_branch_flush", 0)
    decode_blocked_post_branch_flush_ratio = data.get("stall_decode_blocked_post_branch_flush_ratio", 0.0)
    decode_blocked_detail = data.get("stall_decode_blocked_detail", {})
    rob_backpressure_total = data.get("stall_rob_backpressure_total", 0)
    rob_backpressure_detail = data.get("stall_rob_backpressure_detail", {})
    other_total = data.get("stall_other_total", 0)
    other_detail = data.get("stall_other_detail", {})
    other_aux = data.get("stall_other_aux", {})
    frontend_empty_total = data.get("stall_frontend_empty_total", 0)
    frontend_empty_detail = data.get("stall_frontend_empty_detail", {})
    ifu_fq = data.get("ifu_fq", {})
    control = data.get("control", {})
    flush_hist = data.get("flush_reason_histogram", {})
    flush_src_hist = data.get("flush_source_histogram", {})
    predict = data.get("predict", {})
    has_commit_detail = data.get("has_commit_detail", False)
    has_commit_summary = data.get("has_commit_summary", False)
    stall_mode = data.get("stall_mode", "none")
    quality_warnings = data.get("quality_warnings", [])
    commit_metrics_source = data.get("commit_metrics_source", "none")
    stall_metrics_source = data.get("stall_metrics_source", stall_mode)

    lines = [
        f"### {name}",
        "",
        f"- IPC/CPI: `{data.get('ipc', 0):.6f}` / `{data.get('cpi', 0):.6f}`",
        f"- cycles/commits: `{data.get('cycles', 0)}` / `{data.get('commits', 0)}`",
        f"- benchmark_time_ms(self/host/effective): `{(data.get('bench_reported_time_ms', 0) if data.get('bench_reported_time_ms', None) is not None else 0):.3f}` / `{data.get('host_time_ms', 0):.3f}` / `{data.get('effective_benchmark_time_ms', 0):.3f}` (source `{data.get('benchmark_time_source', 'unknown')}`)",
        f"- flush_per_kinst: `{data.get('flush_per_kinst', 0):.3f}`",
        f"- bru_per_kinst: `{data.get('bru_per_kinst', 0):.3f}`",
        f"- mispredict_flush_count: `{data.get('mispredict_flush_count', 0)}`",
        f"- branch_penalty_cycles: `{data.get('branch_penalty_cycles', 0)}`",
        f"- wrong_path_kill_uops: `{data.get('wrong_path_kill_uops', 0)}`",
        f"- redirect_distance_avg/max: `{data.get('redirect_distance_avg', 0):.2f}` / `{data.get('redirect_distance_max', 0)}`",
        f"- control_ratio: `{control.get('control_ratio', 0) * 100.0:.2f}%`",
        f"- est_misp_per_kinst(static NT proxy): `{control.get('est_misp_per_kinst', 0):.3f}`",
        f"- predict(cond hit/miss): `{predict.get('cond_hit', 0)}` / `{predict.get('cond_miss', 0)}` (miss_rate `{predict.get('cond_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(jump direct hit/miss): `{predict.get('jump_direct_hit', 0)}` / `{predict.get('jump_direct_miss', 0)}` (miss_rate `{predict.get('jump_direct_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(jump indirect hit/miss): `{predict.get('jump_indirect_hit', 0)}` / `{predict.get('jump_indirect_miss', 0)}` (miss_rate `{predict.get('jump_indirect_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(jump hit/miss): `{predict.get('jump_hit', 0)}` / `{predict.get('jump_miss', 0)}` (miss_rate `{predict.get('jump_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(ret hit/miss): `{predict.get('ret_hit', 0)}` / `{predict.get('ret_miss', 0)}` (miss_rate `{predict.get('ret_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(call total): `{predict.get('call_total', 0)}`",
        f"- predict(cond local/global/selected acc): `{predict.get('cond_local_accuracy', 0) * 100.0:.2f}%` / `{predict.get('cond_global_accuracy', 0) * 100.0:.2f}%` / `{predict.get('cond_selected_accuracy', 0) * 100.0:.2f}%`",
        f"- predict(cond chooser local/global): `{predict.get('cond_choose_local', 0)}` / `{predict.get('cond_choose_global', 0)}` (global_ratio `{predict.get('cond_choose_global_ratio', 0) * 100.0:.2f}%`)",
        f"- predict(tage lookup/hit): `{predict.get('tage_lookup_total', 0)}` / `{predict.get('tage_hit_total', 0)}` (hit_rate `{predict.get('tage_hit_rate', 0) * 100.0:.2f}%`)",
        f"- predict(tage override/correct): `{predict.get('tage_override_total', 0)}` / `{predict.get('tage_override_correct', 0)}` (override_ratio `{predict.get('tage_override_ratio', 0) * 100.0:.2f}%`, override_accuracy `{predict.get('tage_override_accuracy', 0) * 100.0:.2f}%`)",
        f"- predict(sc_l lookup/confident/override/correct): `{predict.get('sc_lookup_total', 0)}` / `{predict.get('sc_confident_total', 0)}` / `{predict.get('sc_override_total', 0)}` / `{predict.get('sc_override_correct', 0)}` (confident_ratio `{predict.get('sc_confident_ratio', 0) * 100.0:.2f}%`, override_ratio `{predict.get('sc_override_ratio', 0) * 100.0:.2f}%`, override_accuracy `{predict.get('sc_override_accuracy', 0) * 100.0:.2f}%`)",
        f"- predict(loop lookup/hit/confident/override/correct): `{predict.get('loop_lookup_total', 0)}` / `{predict.get('loop_hit_total', 0)}` / `{predict.get('loop_confident_total', 0)}` / `{predict.get('loop_override_total', 0)}` / `{predict.get('loop_override_correct', 0)}` (hit_rate `{predict.get('loop_hit_rate', 0) * 100.0:.2f}%`, confident_ratio `{predict.get('loop_confident_ratio', 0) * 100.0:.2f}%`, override_ratio `{predict.get('loop_override_ratio', 0) * 100.0:.2f}%`, override_accuracy `{predict.get('loop_override_accuracy', 0) * 100.0:.2f}%`)",
        f"- predict(cond provider selected legacy/tage/sc/loop): `{predict.get('cond_provider_legacy_selected', 0)}` / `{predict.get('cond_provider_tage_selected', 0)}` / `{predict.get('cond_provider_sc_selected', 0)}` / `{predict.get('cond_provider_loop_selected', 0)}` (coverage `{predict.get('cond_provider_coverage', 0) * 100.0:.2f}%` of cond_update, share `{predict.get('cond_provider_legacy_share', 0) * 100.0:.2f}%` / `{predict.get('cond_provider_tage_share', 0) * 100.0:.2f}%` / `{predict.get('cond_provider_sc_share', 0) * 100.0:.2f}%` / `{predict.get('cond_provider_loop_share', 0) * 100.0:.2f}%`)",
        f"- predict(cond provider acc legacy/tage/sc/loop): `{predict.get('cond_provider_legacy_accuracy', 0) * 100.0:.2f}%` / `{predict.get('cond_provider_tage_accuracy', 0) * 100.0:.2f}%` / `{predict.get('cond_provider_sc_accuracy', 0) * 100.0:.2f}%` / `{predict.get('cond_provider_loop_accuracy', 0) * 100.0:.2f}%`",
        f"- predict(cond wrong-selected alt-correct legacy/tage/sc/loop/any): `{predict.get('cond_selected_wrong_alt_legacy_correct', 0)}` / `{predict.get('cond_selected_wrong_alt_tage_correct', 0)}` / `{predict.get('cond_selected_wrong_alt_sc_correct', 0)}` / `{predict.get('cond_selected_wrong_alt_loop_correct', 0)}` / `{predict.get('cond_selected_wrong_alt_any_correct', 0)}` (wrong_total `{predict.get('cond_selected_wrong_total', 0)}`, any_ratio `{predict.get('cond_selected_wrong_alt_any_ratio', 0) * 100.0:.2f}%`)",
        "",
        "Data Quality:",
        f"- commit_source: `{commit_metrics_source}` (detail={has_commit_detail}, summary={has_commit_summary})",
        f"- stall_source: `{stall_metrics_source}`",
        "",
        "Commit Width Histogram:",
    ]
    max_width_idx = max(hist.keys(), default=0)
    max_width_idx = max(max_width_idx, 4)
    for i in range(max_width_idx + 1):
        lines.append(f"- width{i}: `{hist.get(i, 0)}`")
    lines.append("")
    lines.append("Stall Categories:")

    if stall_total == 0:
        lines.append("- (no stall samples)")
    else:
        for key, val in sorted(stall.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"- {key}: `{val}` ({_fmt_pct(val, stall_total)})")

    if quality_warnings:
        lines.append("")
        lines.append("Quality Warnings:")
        for msg in quality_warnings:
            lines.append(f"- {msg}")

    lines.append("")
    lines.append("Decode-Blocked Correlation:")
    if decode_blocked_total == 0:
        lines.append("- (no decode_blocked stall samples)")
    else:
        lines.append(
            f"- post_flush<={stall_post_flush_window}c: `{decode_blocked_post_flush}` / `{decode_blocked_total}` ({decode_blocked_post_flush_ratio * 100.0:.2f}%)"
        )
        lines.append(
            f"- post_branch_flush<={stall_post_flush_window}c: `{decode_blocked_post_branch_flush}` / `{decode_blocked_total}` ({decode_blocked_post_branch_flush_ratio * 100.0:.2f}%)"
        )
        if decode_blocked_detail:
            lines.append("- detail_breakdown:")
            for key, val in sorted(decode_blocked_detail.items(), key=lambda x: x[1], reverse=True):
                lines.append(f"  - {key}: `{val}` ({_fmt_pct(val, decode_blocked_total)})")

    lines.append("")
    lines.append("Frontend Empty Breakdown:")
    if frontend_empty_total == 0:
        lines.append("- (no frontend_empty breakdown)")
    else:
        for key, val in sorted(frontend_empty_detail.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"- {key}: `{val}` ({_fmt_pct(val, frontend_empty_total)})")

    lines.append("")
    lines.append("Fetch Queue Effectiveness:")
    if not ifu_fq:
        lines.append("- (no fetch_queue summary, missing [ifum])")
    else:
        fq_samples = int(ifu_fq.get("fq_samples", 0))
        fq_enq = int(ifu_fq.get("fq_enq", 0))
        fq_deq = int(ifu_fq.get("fq_deq", 0))
        fq_bypass = int(ifu_fq.get("fq_bypass", 0))
        fq_enq_blocked = int(ifu_fq.get("fq_enq_blocked", 0))
        fq_full_cycles = int(ifu_fq.get("fq_full_cycles", 0))
        fq_empty_cycles = int(ifu_fq.get("fq_empty_cycles", 0))
        fq_nonempty_cycles = int(ifu_fq.get("fq_nonempty_cycles", 0))
        fq_occ_avg = float(ifu_fq.get("fq_occ_avg", 0.0))
        fq_occ_max = int(ifu_fq.get("fq_occ_max", 0))
        lines.append(
            f"- enq/deq/bypass: `{fq_enq}` / `{fq_deq}` / `{fq_bypass}` (bypass_in_deq `{_safe_div(fq_bypass, fq_deq) * 100.0:.2f}%`)"
        )
        lines.append(
            f"- blocked/full/empty/nonempty cycles: `{fq_enq_blocked}` / `{fq_full_cycles}` / `{fq_empty_cycles}` / `{fq_nonempty_cycles}`"
        )
        lines.append(
            f"- ratios(blocked/full/empty/nonempty): `{_safe_div(fq_enq_blocked, fq_samples) * 100.0:.2f}%` / `{_safe_div(fq_full_cycles, fq_samples) * 100.0:.2f}%` / `{_safe_div(fq_empty_cycles, fq_samples) * 100.0:.2f}%` / `{_safe_div(fq_nonempty_cycles, fq_samples) * 100.0:.2f}%`"
        )
        lines.append(f"- occupancy(avg/max): `{fq_occ_avg:.3f}` / `{fq_occ_max}`")
        occ_hist = ifu_fq.get("fq_occ_hist", {})
        if occ_hist:
            lines.append("- occupancy_hist:")
            occ_items = sorted(
                occ_hist.items(),
                key=lambda kv: int(kv[0]) if isinstance(kv[0], str) else kv[0],
            )
            for occ, cnt in occ_items:
                cnt_i = int(cnt)
                if cnt_i == 0:
                    continue
                occ_idx = int(occ)
                lines.append(f"  - occ={occ_idx}: `{cnt_i}` ({_fmt_pct(cnt_i, fq_samples)})")

    lines.append("")
    lines.append("ROB-Backpressure Correlation:")
    if rob_backpressure_total == 0:
        lines.append("- (no rob_backpressure stall samples)")
    else:
        if rob_backpressure_detail:
            lines.append("- detail_breakdown:")
            for key, val in sorted(rob_backpressure_detail.items(), key=lambda x: x[1], reverse=True):
                lines.append(f"  - {key}: `{val}` ({_fmt_pct(val, rob_backpressure_total)})")

    lines.append("")
    lines.append("Other Breakdown:")
    if other_total == 0:
        lines.append("- (no other stall samples)")
    else:
        if other_detail:
            for key, val in sorted(other_detail.items(), key=lambda x: x[1], reverse=True):
                lines.append(f"- {key}: `{val}` ({_fmt_pct(val, other_total)})")
        else:
            lines.append("- (no other detail breakdown)")

    lines.append("")
    lines.append("Other Auxiliary Counters:")
    if other_aux:
        for key, val in sorted(other_aux.items(), key=lambda x: x[0]):
            lines.append(f"- {key}: `{val}`")
    else:
        lines.append("- (no auxiliary counters)")

    lines.append("")
    lines.append("Flush Reasons:")
    if flush_hist:
        for key, val in sorted(flush_hist.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"- {key}: `{val}`")
    else:
        lines.append("- (no flush samples)")

    lines.append("")
    lines.append("Flush Sources:")
    if flush_src_hist:
        for key, val in sorted(flush_src_hist.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"- {key}: `{val}`")
    else:
        lines.append("- (no flush samples)")

    if data.get("top_pc"):
        lines.extend(["", "Top PC Hotspots:"])
        for item in data["top_pc"][:5]:
            lines.append(f"- {item['pc']}: `{item['count']}`")

    return "\n".join(lines)


def build_markdown_report(summary: dict[str, Any], template_path: str | Path) -> str:
    t = Path(template_path).read_text(encoding="utf-8")
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    bench_order = ["dhrystone", "coremark", "coremark_sample"]
    sections = []
    for name in bench_order:
        if name in summary:
            sections.append(_bench_markdown(name, summary[name]))
    body = "\n\n".join(sections) if sections else "(No benchmark logs found)"

    rendered = t
    rendered = rendered.replace("{{GENERATED_AT}}", now)
    rendered = rendered.replace("{{PROFILE_DIR}}", str(Path(summary[next(iter(summary))]["log_path"]).parent) if summary else "N/A")
    rendered = rendered.replace("{{BENCHMARK_SECTIONS}}", body)
    return rendered


def main() -> int:
    ap = argparse.ArgumentParser(description="Parse NPC profiler logs and generate report")
    ap.add_argument("--log-dir", required=True, help="Directory containing benchmark logs")
    ap.add_argument("--template", default="report_template.md", help="Markdown template path")
    ap.add_argument("--out-json", default="summary.json", help="Output summary json path")
    ap.add_argument("--out-md", default="report.md", help="Output markdown report path")
    args = ap.parse_args()

    log_dir = Path(args.log_dir)
    summary = parse_log_directory(log_dir)

    out_json = Path(args.out_json)
    if not out_json.is_absolute():
        out_json = log_dir / out_json
    out_json.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    template = Path(args.template)
    if not template.is_absolute():
        template = Path(__file__).resolve().parent / template

    out_md = Path(args.out_md)
    if not out_md.is_absolute():
        out_md = log_dir / out_md
    out_md.write_text(build_markdown_report(summary, template), encoding="utf-8")

    print(f"[profiler] summary json: {out_json}")
    print(f"[profiler] report md: {out_md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
