#include "profile_collector.h"

#include "Vtb_triathlon.h"

#include <array>
#include <iostream>

namespace npc {

namespace {

constexpr int kDebugLaneCount = 4;
constexpr int kDebugRobIdxWidth = 7;
// LSU writeback experiment: CDB widened to 9 (6 non-LSU FUs + 3 LSU ports) and
// the LSU exposes 3 writeback ports (2 load + 1 store).
constexpr int kDebugWbWidth = 9;
constexpr int kDebugLsuWbPorts = 3;
constexpr int kDebugLsuFuIndex = 3;

struct LsuHeadLaneSnapshot {
  bool found = false;
  uint32_t lane = 0;
  uint32_t state = 0;
  bool ld_req_valid = false;
  bool ld_rsp_ready = false;
  bool wb_valid = false;
};

bool bit_at(uint32_t mask, int idx) {
  return ((mask >> idx) & 1u) != 0u;
}

uint32_t packed_field(uint32_t value, int idx, int width) {
  const uint32_t mask = (width >= 32) ? 0xffffffffu : ((1u << width) - 1u);
  return (value >> (idx * width)) & mask;
}

uint32_t lsu_lane_state(const Vtb_triathlon *top, int idx) {
  return packed_field(static_cast<uint32_t>(top->dbg_lsu_lane_state_o), idx, 3);
}

uint32_t lsu_lane_req_tag(const Vtb_triathlon *top, int idx) {
  return packed_field(static_cast<uint32_t>(top->dbg_lsu_lane_req_tag_o), idx, kDebugRobIdxWidth);
}

uint32_t lsu_lane_wb_rob_idx(const Vtb_triathlon *top, int idx) {
  return packed_field(static_cast<uint32_t>(top->dbg_lsu_lane_wb_rob_idx_o), idx, kDebugRobIdxWidth);
}

uint32_t wb_rob_idx(const Vtb_triathlon *top, int idx) {
  return packed_field(static_cast<uint32_t>(top->dbg_wb_rob_idx_o), idx, kDebugRobIdxWidth);
}

bool wb_selects_rob_head(const Vtb_triathlon *top, uint32_t head) {
  const uint32_t wb_valid = static_cast<uint32_t>(top->dbg_wb_valid_o);
  for (int i = 0; i < kDebugWbWidth; i++) {
    if (bit_at(wb_valid, i) && wb_rob_idx(top, i) == head) return true;
  }
  return false;
}

// Any of the LSU writeback ports asserting valid this cycle.
bool lsu_group_wb_any(const Vtb_triathlon *top) {
  return static_cast<uint32_t>(top->dbg_lsu_wb_valid_o) != 0u;
}

bool lsu_group_wb_selects_rob_head(const Vtb_triathlon *top, uint32_t head) {
  const uint32_t valid = static_cast<uint32_t>(top->dbg_lsu_wb_valid_o);
  const uint32_t rob_idx_packed = static_cast<uint32_t>(top->dbg_lsu_wb_rob_idx_o);
  for (int p = 0; p < kDebugLsuWbPorts; p++) {
    if (bit_at(valid, p) &&
        packed_field(rob_idx_packed, p, kDebugRobIdxWidth) == head) {
      return true;
    }
  }
  return false;
}

bool lsu_fu_ready(const Vtb_triathlon *top) {
  return bit_at(static_cast<uint32_t>(top->dbg_fu_ready_o), kDebugLsuFuIndex);
}

LsuHeadLaneSnapshot find_lsu_head_lane(const Vtb_triathlon *top) {
  LsuHeadLaneSnapshot snap;
  const uint32_t head = static_cast<uint32_t>(top->dbg_rob_head_ptr_o);
  const uint32_t lane_wb_valid = static_cast<uint32_t>(top->dbg_lsu_lane_wb_valid_o);
  const uint32_t lane_ld_req_valid = static_cast<uint32_t>(top->dbg_lsu_lane_ld_req_valid_o);
  const uint32_t lane_ld_rsp_ready = static_cast<uint32_t>(top->dbg_lsu_lane_ld_rsp_ready_o);

  for (int i = 0; i < kDebugLaneCount; i++) {
    if (bit_at(lane_wb_valid, i) &&
        lsu_lane_wb_rob_idx(top, i) == head) {
      snap.found = true;
      snap.lane = static_cast<uint32_t>(i);
      snap.state = lsu_lane_state(top, i);
      snap.ld_req_valid = bit_at(lane_ld_req_valid, i);
      snap.ld_rsp_ready = bit_at(lane_ld_rsp_ready, i);
      snap.wb_valid = true;
      return snap;
    }
  }

  for (int i = 0; i < kDebugLaneCount; i++) {
    const uint32_t state = lsu_lane_state(top, i);
    if (state != 0u && lsu_lane_req_tag(top, i) == head) {
      snap.found = true;
      snap.lane = static_cast<uint32_t>(i);
      snap.state = state;
      snap.ld_req_valid = bit_at(lane_ld_req_valid, i);
      snap.ld_rsp_ready = bit_at(lane_ld_rsp_ready, i);
      snap.wb_valid = bit_at(lane_wb_valid, i);
      return snap;
    }
  }

  return snap;
}

bool is_hol_load_no_lane(const Vtb_triathlon *top) {
  if (static_cast<uint32_t>(top->dbg_rob_count_o) == 0u) return false;
  if (top->dbg_rob_head_is_store_o) return false;
  if (top->dbg_rob_head_complete_o) return false;
  if (static_cast<uint32_t>(top->dbg_rob_head_fu_o) != 3u) return false;

  const uint32_t head = static_cast<uint32_t>(top->dbg_rob_head_ptr_o);
  if (find_lsu_head_lane(top).found) return false;
  if (wb_selects_rob_head(top, head)) return false;
  if (lsu_group_wb_selects_rob_head(top, head)) return false;
  if (lsu_group_wb_any(top)) return false;
  return true;
}

bool lsu_rs_head_ready(const Vtb_triathlon *top) {
  if (!top->dbg_lsu_rs_head_valid_o) return false;
  const int head_idx = static_cast<int>(top->dbg_lsu_rs_head_idx_o);
  return bit_at(static_cast<uint32_t>(top->dbg_lsu_rs_ready_o), head_idx);
}

bool hol_issue_port_busy(const Vtb_triathlon *top) {
  if (!top->dbg_lsu_rs_head_valid_o || !top->dbg_lsu_rs_head_is_load_o) return false;
  if (!top->dbg_lsu_issue_valid_o) return false;
  if (static_cast<uint32_t>(top->dbg_lsu_sel_dst_o) ==
      static_cast<uint32_t>(top->dbg_rob_head_ptr_o)) {
    return false;
  }
  return !lsu_rs_head_ready(top);
}

const char *classify_hol_load_sub_bucket(const Vtb_triathlon *top) {
  if (!top->dbg_lsu_rs_head_valid_o || !top->dbg_lsu_rs_head_is_load_o) {
    return "hol_not_in_rs";
  }

  const bool has_rs1 = top->dbg_lsu_rs_head_has_rs1_o;
  const bool has_rs2 = top->dbg_lsu_rs_head_has_rs2_o;
  const bool r1_ready = top->dbg_lsu_rs_head_r1_ready_o;
  const bool r2_ready = top->dbg_lsu_rs_head_r2_ready_o;
  if ((has_rs1 && !r1_ready) || (has_rs2 && !r2_ready)) {
    return "hol_in_rs_operand_wait";
  }

  if (top->dbg_lsu_issue_valid_o &&
      static_cast<uint32_t>(top->dbg_lsu_sel_dst_o) ==
          static_cast<uint32_t>(top->dbg_rob_head_ptr_o)) {
    return "hol_in_rs_issue_inflight";
  }

  if (lsu_rs_head_ready(top)) {
    if (!top->dbg_lsu_issue_valid_o) {
      return "hol_in_rs_ready_no_issue";
    }
    return "hol_residual";
  }

  if (top->dbg_lsu_head_block_store_o) {
    return "hol_block_store";
  }
  return "hol_in_rs_not_ready_other";
}

const char *classify_lsu_head_lane_detail(const Vtb_triathlon *top, bool nonbp) {
  LsuHeadLaneSnapshot lane = find_lsu_head_lane(top);
  const uint32_t head = static_cast<uint32_t>(top->dbg_rob_head_ptr_o);
  const bool lsu_wb_selects_head = lsu_group_wb_selects_rob_head(top, head);
  const bool cdb_selects_head = wb_selects_rob_head(top, head);

  if (!lane.found) {
    if (cdb_selects_head) {
      return nonbp ? "rob_head_lsu_incomplete_cdb_hit_no_lane_nonbp"
                   : "rob_lsu_incomplete_cdb_hit_no_lane";
    }
    if (lsu_wb_selects_head) {
      if (!lsu_fu_ready(top)) {
        return nonbp ? "rob_head_lsu_incomplete_group_wb_not_ready_no_lane_nonbp"
                     : "rob_lsu_incomplete_group_wb_not_ready_no_lane";
      }
      return nonbp ? "rob_head_lsu_incomplete_group_wb_hit_no_lane_nonbp"
                   : "rob_lsu_incomplete_group_wb_hit_no_lane";
    }
    if (lsu_group_wb_any(top)) {
      return nonbp ? "rob_head_lsu_incomplete_other_lsu_wb_no_lane_nonbp"
                   : "rob_lsu_incomplete_other_lsu_wb_no_lane";
    }
    return nonbp ? "rob_head_lsu_incomplete_lane_not_found_nonbp"
                 : "rob_lsu_incomplete_lane_not_found";
  }

  switch (lane.state) {
    case 0u:
      return nonbp ? "rob_head_lsu_incomplete_sm_idle_nonbp"
                   : "rob_lsu_incomplete_sm_idle";
    case 1u:
      if (lane.ld_req_valid && !top->dbg_lsu_ld_req_ready_o) {
        if (top->dbg_sb_dcache_req_valid_o && !top->dbg_sb_dcache_req_ready_o) {
          return nonbp ? "rob_head_lsu_incomplete_wait_req_ready_sb_conflict_nonbp"
                       : "rob_lsu_wait_ld_req_ready_sb_conflict";
        }
        if (top->dbg_dc_mshr_full_o || !top->dbg_dc_mshr_alloc_ready_o) {
          return nonbp ? "rob_head_lsu_incomplete_wait_req_ready_mshr_blocked_nonbp"
                       : "rob_lsu_wait_ld_req_ready_mshr_blocked";
        }
        if (top->dcache_miss_req_valid_o && !top->dcache_miss_req_ready_i) {
          return nonbp ? "rob_head_lsu_incomplete_wait_req_ready_miss_port_busy_nonbp"
                       : "rob_lsu_wait_ld_req_ready_miss_port_busy";
        }
        return nonbp ? "rob_head_lsu_incomplete_wait_req_ready_nonbp"
                     : "rob_lsu_wait_ld_req_ready";
      }
      if (lane.ld_req_valid && top->dbg_lsu_ld_req_ready_o && !top->dbg_lsu_ld_fire_o) {
        return nonbp ? "rob_head_lsu_incomplete_wait_req_grant_nonbp"
                     : "rob_lsu_wait_ld_req_grant";
      }
      return nonbp ? "rob_head_lsu_incomplete_sm_req_wait_lane_nonbp"
                   : "rob_lsu_incomplete_sm_req_wait_lane";
    case 2u:
      if (!top->dbg_lsu_ld_rsp_valid_o) {
        return nonbp ? "rob_head_lsu_incomplete_wait_rsp_valid_nonbp"
                     : "rob_lsu_wait_ld_rsp_valid";
      }
      if (!lane.ld_rsp_ready || !top->dbg_lsu_ld_rsp_ready_o) {
        return nonbp ? "rob_head_lsu_incomplete_wait_rsp_ready_nonbp"
                     : "rob_lsu_wait_ld_rsp_ready";
      }
      if (!top->dbg_lsu_rsp_fire_o) {
        return nonbp ? "rob_head_lsu_incomplete_rsp_fire_gap_nonbp"
                     : "rob_lsu_wait_ld_rsp_fire";
      }
      return nonbp ? "rob_head_lsu_incomplete_rsp_to_wb_nonbp"
                   : "rob_lsu_rsp_to_wb";
    case 3u:
      if (lane.wb_valid) {
        if (lsu_wb_selects_head) {
          return nonbp ? "rob_head_lsu_incomplete_wait_wb_visible_nonbp"
                       : "rob_lsu_wait_wb_visible";
        }
        if (top->dbg_lsu_store_wb_head_valid_o) {
          return nonbp ? "rob_head_lsu_incomplete_wait_wb_store_priority_nonbp"
                       : "rob_lsu_wait_wb_store_priority";
        }
        return nonbp ? "rob_head_lsu_incomplete_wait_wb_select_nonbp"
                     : "rob_lsu_wait_wb_select";
      }
      return nonbp ? "rob_head_lsu_incomplete_wait_wb_no_lane_valid_nonbp"
                   : "rob_lsu_wait_wb_no_lane_valid";
    case 4u:
      return nonbp ? "rob_head_lsu_incomplete_mmio_wait_rob_nonbp"
                   : "rob_lsu_mmio_wait_rob";
    case 5u:
      return nonbp ? "rob_head_lsu_incomplete_mmio_req_nonbp"
                   : "rob_lsu_mmio_req";
    default:
      return nonbp ? "rob_head_lsu_incomplete_sm_illegal_nonbp"
                   : "rob_lsu_incomplete_sm_illegal";
  }
}

}  // namespace

void ProfileCollector::record_hol_load_cycle(const Vtb_triathlon *top) {
  if (!is_hol_load_no_lane(top)) return;

  stall_hol_load_detail_hist_["hol_load_no_lane"]++;
  stall_hol_load_detail_hist_[classify_hol_load_sub_bucket(top)]++;

  if (hol_issue_port_busy(top)) {
    stall_hol_load_detail_hist_["hol_issue_port_busy"]++;
  }
}

void ProfileCollector::on_no_commit_cycle(uint64_t cycles,
                                          uint64_t no_commit_cycles,
                                          const Vtb_triathlon *top) {
  int stall_kind = classify_stall_cycle(top);
  stall_cycle_hist_[stall_kind]++;
  if (stall_kind == kStallFrontendEmpty) {
    stall_frontend_empty_hist_[classify_frontend_empty_cycle(top)]++;
  } else if (stall_kind == kStallDecodeBlocked) {
    stall_decode_blocked_detail_hist_[classify_decode_blocked_detail_cycle(top)]++;
  } else if (stall_kind == kStallROBBackpressure) {
    stall_rob_backpressure_detail_hist_[classify_rob_backpressure_detail_cycle(top)]++;
  } else if (stall_kind == kStallOther) {
    stall_other_detail_hist_[classify_other_detail_cycle(top)]++;
  }

  if (top->dbg_bru_ready_not_issued_o) branch_ready_not_issued_cycles_++;
  if (top->dbg_alu_ready_not_issued_o) alu_ready_not_issued_cycles_++;
  if (!top->dbg_rob_head_complete_o &&
      (top->dbg_bru_wb_head_hit_o || top->dbg_alu_wb_head_hit_o ||
       wb_selects_rob_head(top, static_cast<uint32_t>(top->dbg_rob_head_ptr_o)))) {
    complete_not_visible_cycles_++;
  }

  if (args_.stall_trace && args_.stall_threshold > 0 &&
      (no_commit_cycles == args_.stall_threshold ||
       (no_commit_cycles > args_.stall_threshold &&
        no_commit_cycles % args_.stall_threshold == 0))) {
    std::ios::fmtflags f(std::cout.flags());
    std::cout << "[stall ] cycle=" << cycles
              << " no_commit=" << no_commit_cycles
              << " fe(v/r/pc)=" << static_cast<int>(top->dbg_fe_valid_o) << "/"
              << static_cast<int>(top->dbg_fe_ready_o) << "/0x" << std::hex
              << top->dbg_fe_pc_o
              << " fe_inst(0/1)=0x"
              << static_cast<uint32_t>(top->dbg_fe_instrs_o[0]) << "/0x"
              << static_cast<uint32_t>(top->dbg_fe_instrs_o[1])
              << " ifu_req(v/r/fire/inflight)=" << std::dec
              << static_cast<int>(top->dbg_ifu_req_valid_o) << "/"
              << static_cast<int>(top->dbg_ifu_req_ready_o) << "/"
              << static_cast<int>(top->dbg_ifu_req_fire_o) << "/"
              << static_cast<int>(top->dbg_ifu_req_inflight_o)
              << " ifu_rsp(v/cap)="
              << static_cast<int>(top->dbg_ifu_rsp_valid_o) << "/"
              << static_cast<int>(top->dbg_ifu_rsp_capture_o)
              << " ifu_fq(cnt/full/empty/pop)="
              << static_cast<uint32_t>(top->dbg_ifu_fq_count_o) << "/"
              << static_cast<int>(top->dbg_ifu_fq_full_o) << "/"
              << static_cast<int>(top->dbg_ifu_fq_empty_o) << "/"
              << static_cast<int>(top->dbg_ifu_ibuf_pop_o)
              << " ifu_gate(reqq_empty/inf_full/block_flush/block_reqq_empty/block_inf_full/block_storage)="
              << static_cast<int>(top->dbg_ifu_reqq_empty_o) << "/"
              << static_cast<int>(top->dbg_ifu_inf_full_o) << "/"
              << static_cast<int>(top->dbg_ifu_block_flush_o) << "/"
              << static_cast<int>(top->dbg_ifu_block_reqq_empty_o) << "/"
              << static_cast<int>(top->dbg_ifu_block_inf_full_o) << "/"
              << static_cast<int>(top->dbg_ifu_block_storage_budget_o)
              << " ifetch_fault(v/r/pending/csr_en/csr_inject/mmu_st)="
              << static_cast<int>(top->dbg_ifetch_fault_valid_o) << "/"
              << static_cast<int>(top->dbg_ifetch_fault_ready_o) << "/"
              << static_cast<int>(top->dbg_ifu_fault_pending_o) << "/"
              << static_cast<int>(top->dbg_csr_en_o) << "/"
              << static_cast<int>(top->dbg_csr_ifetch_fault_inject_o) << "/"
              << static_cast<uint32_t>(top->dbg_ifu_mmu_state_o)
              << " ifu_mmu(core_st/pte_req_v/r/pte_rsp_v/pte_upd_v/r/mux_inf/owner)="
              << static_cast<uint32_t>(top->dbg_ifu_mmu_core_state_o) << "/"
              << static_cast<int>(top->dbg_ifu_pte_req_valid_o) << "/"
              << static_cast<int>(top->dbg_ifu_pte_req_ready_o) << "/"
              << static_cast<int>(top->dbg_ifu_pte_rsp_valid_o) << "/"
              << static_cast<int>(top->dbg_ifu_pte_upd_valid_o) << "/"
              << static_cast<int>(top->dbg_ifu_pte_upd_ready_o) << "/"
              << static_cast<int>(top->dbg_mux_mmu_ld_inflight_o) << "/"
              << static_cast<int>(top->dbg_mux_mmu_ld_owner_o)
              << " dec(v/r)=" << std::dec << static_cast<int>(top->dbg_dec_valid_o) << "/"
              << static_cast<int>(top->dbg_dec_ready_o)
              << " rob_ready=" << static_cast<int>(top->dbg_rob_ready_o)
              << " ren(pend/src/sel/fire/rdy)="
              << static_cast<int>(top->dbg_ren_src_from_pending_o) << "/"
              << static_cast<uint32_t>(top->dbg_ren_src_count_o) << "/"
              << static_cast<uint32_t>(top->dbg_ren_sel_count_o) << "/"
              << static_cast<int>(top->dbg_ren_fire_o) << "/"
              << static_cast<int>(top->dbg_ren_ready_o)
              << " gate(alu/bru/lsu/mdu/csr)="
              << static_cast<int>(top->dbg_gate_alu_o) << "/"
              << static_cast<int>(top->dbg_gate_bru_o) << "/"
              << static_cast<int>(top->dbg_gate_lsu_o) << "/"
              << static_cast<int>(top->dbg_gate_mdu_o) << "/"
              << static_cast<int>(top->dbg_gate_csr_o)
              << " need(alu/bru/lsu/mdu/csr)="
              << static_cast<uint32_t>(top->dbg_need_alu_o) << "/"
              << static_cast<uint32_t>(top->dbg_need_bru_o) << "/"
              << static_cast<uint32_t>(top->dbg_need_lsu_o) << "/"
              << static_cast<uint32_t>(top->dbg_need_mdu_o) << "/"
              << static_cast<uint32_t>(top->dbg_need_csr_o)
              << " free(alu/bru/lsu/csr)="
              << static_cast<uint32_t>(top->dbg_free_alu_o) << "/"
              << static_cast<uint32_t>(top->dbg_free_bru_o) << "/"
              << static_cast<uint32_t>(top->dbg_free_lsu_o) << "/"
              << static_cast<uint32_t>(top->dbg_free_csr_o)
              << " lsu_ld(v/r/addr)=" << static_cast<int>(top->dbg_lsu_ld_req_valid_o) << "/"
              << static_cast<int>(top->dbg_lsu_ld_req_ready_o) << "/0x" << std::hex
              << top->dbg_lsu_ld_req_addr_o
              << " lsu_rsp(v/r)=" << std::dec << static_cast<int>(top->dbg_lsu_ld_rsp_valid_o)
              << "/" << static_cast<int>(top->dbg_lsu_ld_rsp_ready_o)
              << " lsu_sm=" << static_cast<uint32_t>(top->dbg_lsu_state_o)
              << " lsu_ld_fire=" << static_cast<int>(top->dbg_lsu_ld_fire_o)
              << " lsu_rsp_fire=" << static_cast<int>(top->dbg_lsu_rsp_fire_o)
              << " lsu_issue(raw/pick/blk)=("
              << static_cast<int>(top->dbg_lsu_issue_raw0_o) << ","
              << static_cast<int>(top->dbg_lsu_issue_raw1_o) << ")/("
              << static_cast<int>(top->dbg_lsu_issue_pick0_o) << ","
              << static_cast<int>(top->dbg_lsu_issue_pick1_o) << ")/("
              << static_cast<int>(top->dbg_lsu_issue_blk0_o) << ","
              << static_cast<int>(top->dbg_lsu_issue_blk1_o) << ")"
              << " lsu_sel(pc/ld/st/dst)=0x" << std::hex
              << top->dbg_lsu_sel_pc_o << std::dec << "/"
              << static_cast<int>(top->dbg_lsu_sel_is_load_o) << "/"
              << static_cast<int>(top->dbg_lsu_sel_is_store_o) << "/0x"
              << std::hex << static_cast<uint32_t>(top->dbg_lsu_sel_dst_o) << std::dec
              << " lsu_inflight(tag/addr)=0x" << std::hex
              << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
              << "/0x" << top->dbg_lsu_inflight_addr_o
              << " lsu_lane_state=0x"
              << lsu_lane_state(top, 0)
              << "/" << lsu_lane_state(top, 1)
              << "/" << lsu_lane_state(top, 2)
              << "/" << lsu_lane_state(top, 3)
              << " lsu_lane_req_tag=0x"
              << lsu_lane_req_tag(top, 0)
              << "/" << lsu_lane_req_tag(top, 1)
              << "/" << lsu_lane_req_tag(top, 2)
              << "/" << lsu_lane_req_tag(top, 3)
              << " lsu_lane_wb(v/tag)=0x"
              << std::hex << static_cast<uint32_t>(top->dbg_lsu_lane_wb_valid_o)
              << "/0x" << lsu_lane_wb_rob_idx(top, 0)
              << "/" << lsu_lane_wb_rob_idx(top, 1)
              << "/" << lsu_lane_wb_rob_idx(top, 2)
              << "/" << lsu_lane_wb_rob_idx(top, 3)
              << " lsu_wb(v/tag/store_head)=0x" << static_cast<int>(top->dbg_lsu_wb_valid_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_lsu_wb_rob_idx_o)
              << "/0x" << static_cast<int>(top->dbg_lsu_store_wb_head_valid_o)
              << " wb(v/tags)=0x" << static_cast<uint32_t>(top->dbg_wb_valid_o)
              << "/0x" << wb_rob_idx(top, 0)
              << "/" << wb_rob_idx(top, 1)
              << "/" << wb_rob_idx(top, 2)
              << "/" << wb_rob_idx(top, 3)
              << "/" << wb_rob_idx(top, 4)
              << "/" << wb_rob_idx(top, 5)
              << "/" << wb_rob_idx(top, 6)
              << "/" << wb_rob_idx(top, 7)
              << "/" << wb_rob_idx(top, 8)
              << " fu(v/r)=0x" << static_cast<uint32_t>(top->dbg_fu_valid_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_fu_ready_o)
              << " lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x"
              << static_cast<uint32_t>(top->dbg_lsu_grp_lane_busy_o)
              << std::dec << "/" << static_cast<int>(top->dbg_lsu_grp_alloc_fire_o)
              << "/0x" << std::hex << static_cast<uint32_t>(top->dbg_lsu_grp_alloc_lane_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_lsu_grp_ld_owner_o)
              << std::dec
              << " lsug(req(ld/st)/alloc(lq/sq)/pend/mmu/lq/sq)="
              << static_cast<int>(top->dbg_lsu_load_req_ready_o) << "/"
              << static_cast<int>(top->dbg_lsu_store_req_ready_o) << "/"
              << static_cast<int>(top->dbg_lsu_lq_alloc_ready_o) << "/"
              << static_cast<int>(top->dbg_lsu_sq_alloc_ready_o) << "/"
              << static_cast<int>(top->dbg_lsu_pend_valid_o) << "/"
              << static_cast<uint32_t>(top->dbg_lsu_mmu_state_o) << "/"
              << static_cast<uint32_t>(top->dbg_lsu_lq_count_o) << "/"
              << static_cast<uint32_t>(top->dbg_lsu_sq_count_o)
              << " lsu_rs(b/r)=0x" << std::hex
              << static_cast<uint32_t>(top->dbg_lsu_rs_busy_o) << "/0x"
              << static_cast<uint32_t>(top->dbg_lsu_rs_ready_o)
              << " lsu_rs_head(v/idx/dst)=" << std::dec
              << static_cast<int>(top->dbg_lsu_rs_head_valid_o) << "/0x"
              << std::hex << static_cast<uint32_t>(top->dbg_lsu_rs_head_idx_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_lsu_rs_head_dst_o)
              << " lsu_rs_head(rs1r/rs2r/has1/has2)=" << std::dec
              << static_cast<int>(top->dbg_lsu_rs_head_r1_ready_o) << "/"
              << static_cast<int>(top->dbg_lsu_rs_head_r2_ready_o) << "/"
              << static_cast<int>(top->dbg_lsu_rs_head_has_rs1_o) << "/"
              << static_cast<int>(top->dbg_lsu_rs_head_has_rs2_o)
              << " lsu_rs_head(q1/q2/sb)=0x" << std::hex
              << static_cast<uint32_t>(top->dbg_lsu_rs_head_q1_o) << "/0x"
              << static_cast<uint32_t>(top->dbg_lsu_rs_head_q2_o) << "/0x"
              << static_cast<uint32_t>(top->dbg_lsu_rs_head_sb_id_o)
              << " lsu_rs_head(ld/st)=" << std::dec
              << static_cast<int>(top->dbg_lsu_rs_head_is_load_o) << "/"
              << static_cast<int>(top->dbg_lsu_rs_head_is_store_o)
              << " sb_alloc(req/ready/fire)=0x" << std::hex
              << static_cast<uint32_t>(top->dbg_sb_alloc_req_o)
              << std::dec << "/" << static_cast<int>(top->dbg_sb_alloc_ready_o) << "/"
              << static_cast<int>(top->dbg_sb_alloc_fire_o)
              << " sb_dcache(v/r/addr)=" << static_cast<int>(top->dbg_sb_dcache_req_valid_o)
              << "/" << static_cast<int>(top->dbg_sb_dcache_req_ready_o) << "/0x"
              << std::hex << top->dbg_sb_dcache_req_addr_o
              << " dc_mshr(cnt/full/empty)=" << std::dec
              << static_cast<uint32_t>(top->dbg_dc_mshr_count_o) << "/"
              << static_cast<int>(top->dbg_dc_mshr_full_o) << "/"
              << static_cast<int>(top->dbg_dc_mshr_empty_o)
              << " dc_state/refill(v/r)/pending_ld/line_mshr(ld/st)="
              << static_cast<uint32_t>(top->dbg_dcache_state_o) << "/"
              << static_cast<int>(top->dbg_dcache_refill_valid_o) << "/"
              << static_cast<int>(top->dbg_dcache_refill_ready_o) << "/"
              << static_cast<int>(top->dbg_dcache_pending_ld_valid_o) << "/"
              << static_cast<int>(top->dbg_dcache_ld_line_in_mshr_o) << "/"
              << static_cast<int>(top->dbg_dcache_st_line_in_mshr_o)
              << " dc_mshr(alloc_rdy/line_hit)="
              << static_cast<int>(top->dbg_dc_mshr_alloc_ready_o) << "/"
              << static_cast<int>(top->dbg_dc_mshr_req_line_hit_o)
              << " dc_store_wait(same/full)="
              << static_cast<int>(top->dbg_dc_store_wait_same_line_o) << "/"
              << static_cast<int>(top->dbg_dc_store_wait_mshr_full_o)
              << " ic_miss(v/r)=" << std::dec
              << static_cast<int>(top->icache_miss_req_valid_o) << "/"
              << static_cast<int>(top->icache_miss_req_ready_i)
              << " ic_sm=" << static_cast<uint32_t>(top->dbg_icache_state_o)
              << " dc_miss(v/r)=" << static_cast<int>(top->dcache_miss_req_valid_o) << "/"
              << static_cast<int>(top->dcache_miss_req_ready_i)
              << " flush=" << static_cast<int>(top->backend_flush_o)
              << " rdir=0x" << std::hex << top->backend_redirect_pc_o
              << " rf(cause/exp/mp/br/j)=0x"
              << static_cast<uint32_t>(top->dbg_rob_flush_cause_o) << "/"
              << std::dec << static_cast<int>(top->dbg_rob_flush_is_exception_o) << "/"
              << static_cast<int>(top->dbg_rob_flush_is_mispred_o) << "/"
              << static_cast<int>(top->dbg_rob_flush_is_branch_o) << "/"
              << static_cast<int>(top->dbg_rob_flush_is_jump_o)
              << " rf_src_pc=0x" << std::hex << top->dbg_rob_flush_src_pc_o
              << std::dec
              << " rob_head(fu/comp/is_store/pc)=0x" << std::hex
              << static_cast<uint32_t>(top->dbg_rob_head_fu_o)
              << "/" << static_cast<int>(top->dbg_rob_head_complete_o)
              << "/" << static_cast<int>(top->dbg_rob_head_is_store_o)
              << "/0x" << top->dbg_rob_head_pc_o
              << std::dec
              << " rob_cnt=" << static_cast<uint32_t>(top->dbg_rob_count_o)
              << " rob_ptr(h/t)=0x" << std::hex
              << static_cast<uint32_t>(top->dbg_rob_head_ptr_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_rob_tail_ptr_o)
              << std::dec
              << " rob_q2(v/idx/fu/comp/st/pc)=" << std::dec
              << static_cast<int>(top->dbg_rob_q2_valid_o) << "/0x"
              << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_idx_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_rob_q2_fu_o)
              << std::dec << "/" << static_cast<int>(top->dbg_rob_q2_complete_o)
              << "/" << static_cast<int>(top->dbg_rob_q2_is_store_o)
              << "/0x" << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_pc_o)
              << " sb(cnt/h/t)=0x" << std::hex
              << static_cast<uint32_t>(top->dbg_sb_count_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_sb_head_ptr_o)
              << "/0x" << static_cast<uint32_t>(top->dbg_sb_tail_ptr_o)
              << std::dec
              << " sb_head(v/c/a/d/addr)="
              << static_cast<int>(top->dbg_sb_head_valid_o) << "/"
              << static_cast<int>(top->dbg_sb_head_committed_o) << "/"
              << static_cast<int>(top->dbg_sb_head_addr_valid_o) << "/"
              << static_cast<int>(top->dbg_sb_head_data_valid_o) << "/0x"
              << std::hex << top->dbg_sb_head_addr_o
              << std::dec << "\n";
    std::cout.flags(f);
  }
}

int ProfileCollector::classify_stall_cycle(const Vtb_triathlon *top) const {
  bool pipe_bus_valid = top->dbg_pipe_bus_valid_o != 0;
  bool mem_bus_valid = top->dbg_mem_bus_valid_o != 0;
  bool rob_ready = pipe_bus_valid ? (top->dbg_pipe_bus_rob_ready_o != 0)
                                  : (top->dbg_rob_ready_o != 0);
  bool dec_valid = pipe_bus_valid ? (top->dbg_pipe_bus_dec_valid_o != 0)
                                  : (top->dbg_dec_valid_o != 0);
  bool dec_ready = pipe_bus_valid ? (top->dbg_pipe_bus_dec_ready_o != 0)
                                  : (top->dbg_dec_ready_o != 0);
  bool lsu_issue_valid = mem_bus_valid ? (top->dbg_mem_bus_lsu_issue_valid_o != 0)
                                       : (top->dbg_lsu_issue_valid_o != 0);
  bool lsu_req_ready = mem_bus_valid ? (top->dbg_mem_bus_lsu_req_ready_o != 0)
                                     : (top->dbg_lsu_req_ready_o != 0);

  if (top->backend_flush_o) return kStallFlushRecovery;
  if (top->icache_miss_req_valid_o) return kStallICacheMissWait;
  if (top->dcache_miss_req_valid_o) return kStallDCacheMissWait;
  if (!rob_ready) return kStallROBBackpressure;
  if (!dec_valid) return kStallFrontendEmpty;
  if (dec_valid && !dec_ready) return kStallDecodeBlocked;
  if (lsu_issue_valid && !lsu_req_ready) return kStallLSUReqBlocked;
  return kStallOther;
}

int ProfileCollector::classify_frontend_empty_cycle(const Vtb_triathlon *top) const {
  bool fe_valid = (top->dbg_pipe_bus_valid_o != 0) ?
      (top->dbg_pipe_bus_fe_valid_o != 0) : (top->dbg_fe_valid_o != 0);
  bool fe_ready = top->dbg_fe_ready_o;
  bool ifu_req_valid = top->dbg_ifu_req_valid_o;
  bool ifu_req_ready = top->dbg_ifu_req_ready_o;
  bool ifu_req_fire = top->dbg_ifu_req_fire_o;
  bool ifu_req_inflight = top->dbg_ifu_req_inflight_o;
  bool ifu_rsp_valid = top->dbg_ifu_rsp_valid_o;
  bool ifu_rsp_capture = top->dbg_ifu_rsp_capture_o;
  bool ifu_drop_stale_rsp = top->dbg_ifu_drop_stale_rsp_o;
  bool ifu_fq_full = top->dbg_ifu_fq_full_o;
  bool ifu_fq_empty = top->dbg_ifu_fq_empty_o;
  bool ifu_block_flush = top->dbg_ifu_block_flush_o;
  bool ifu_block_reqq_empty = top->dbg_ifu_block_reqq_empty_o;
  bool ifu_block_inf_full = top->dbg_ifu_block_inf_full_o;
  bool ifu_block_storage_budget = top->dbg_ifu_block_storage_budget_o;

  if (fe_valid && !fe_ready) return kFeWaitIbufferConsume;
  if (fe_valid && fe_ready) return kFeHasDataDecodeGap;
  if (ifu_req_inflight && ifu_rsp_valid && ifu_rsp_capture) return kFeRspCaptureBubble;
  if (ifu_drop_stale_rsp) return kFeDropStaleRsp;
  if (ifu_rsp_valid && !ifu_rsp_capture && ifu_fq_full) return kFeRspBlockedByFQFull;
  if (ifu_req_inflight && !ifu_rsp_valid) {
    uint32_t icache_state = static_cast<uint32_t>(top->dbg_icache_state_o);
    if (icache_state == 2u || icache_state == 3u) return kFeWaitICacheRspMissWait;
    return kFeWaitICacheRspHitLatency;
  }
  if (!ifu_req_inflight && ifu_fq_empty && !ifu_req_valid) {
    if (ifu_block_flush) return kFeNoReqFlushBlock;
    if (ifu_block_reqq_empty) return kFeNoReqReqQEmpty;
    if (ifu_block_inf_full) return kFeNoReqInfFull;
    if (ifu_block_storage_budget) return kFeNoReqStorageBudget;
    if (!ifu_req_ready) return kFeRedirectRecovery;
    return kFeNoReqOther;
  }
  if (!ifu_req_fire && ifu_req_valid && !ifu_req_ready) return kFeRedirectRecovery;
  if (ifu_req_fire && !ifu_req_inflight && !ifu_rsp_valid) return kFeReqFireNoInflight;
  if (ifu_rsp_valid && !ifu_rsp_capture && !ifu_req_inflight) return kFeRspNoInflight;
  if (!ifu_fq_empty && !fe_valid) return kFeFQNonemptyNoFeValid;
  if (ifu_req_valid && ifu_req_ready && !ifu_req_fire) return kFeReqReadyNoFire;
  return kFeOther;
}

const char *ProfileCollector::classify_decode_blocked_detail_cycle(const Vtb_triathlon *top) const {
  const uint32_t kPendingReplayFullSrc = cfg_instr_per_fetch_;
  int has_rs2 = static_cast<int>(top->dbg_lsu_rs_head_has_rs2_o);
  int rs2_ready = static_cast<int>(top->dbg_lsu_rs_head_r2_ready_o);

  if (top->dbg_ren_src_from_pending_o) {
    bool full = static_cast<uint32_t>(top->dbg_ren_src_count_o) >= kPendingReplayFullSrc;
    if (top->dbg_ren_fire_o && static_cast<uint32_t>(top->dbg_ren_sel_count_o) > 0u) {
      return full ? "pending_replay_progress_full" : "pending_replay_progress_has_room";
    }
    return full ? "pending_replay_wait_full" : "pending_replay_wait_has_room";
  }

  if (static_cast<uint32_t>(top->dbg_lsu_grp_lane_busy_o) != 0u && !top->dbg_lsu_grp_alloc_fire_o) {
    if (static_cast<uint32_t>(top->dbg_lsu_grp_ld_owner_o) == 0u) {
      const bool ld_req_wait = top->dbg_lsu_ld_req_valid_o && !top->dbg_lsu_ld_req_ready_o;
      if (ld_req_wait) {
        if (top->dbg_lsu_pte_req_valid_o) return "lsug_wait_ld_req_not_ready_lsu_pte";
        if (top->dbg_ifu_pte_req_valid_o) return "lsug_wait_ld_req_not_ready_ifu_pte";
        if (top->dbg_dcache_refill_valid_o) return "lsug_wait_ld_req_not_ready_refill";
        if (top->dbg_dcache_pending_ld_valid_o) return "lsug_wait_ld_req_not_ready_pending_load";
        if (top->dbg_sb_dcache_req_valid_o && !top->dbg_sb_dcache_req_ready_o) {
          return "lsug_wait_ld_req_not_ready_store_conflict";
        }
        if (top->dbg_dcache_ld_line_in_mshr_o) return "lsug_wait_ld_req_not_ready_mshr_line_hit";
        if (top->dbg_dc_mshr_full_o || !top->dbg_dc_mshr_alloc_ready_o) {
          return "lsug_wait_ld_req_not_ready_mshr_blocked";
        }

        switch (static_cast<uint32_t>(top->dbg_dcache_state_o)) {
          case 0u: return "lsug_wait_ld_req_not_ready_dcache_idle";
          case 1u: return "lsug_wait_ld_req_not_ready_dcache_lookup";
          case 2u: return "lsug_wait_ld_req_not_ready_dcache_store_write";
          case 3u: return "lsug_wait_ld_req_not_ready_dcache_wb_req";
          case 4u: return "lsug_wait_ld_req_not_ready_dcache_miss_req";
          case 5u: return "lsug_wait_ld_req_not_ready_dcache_wait_refill";
          case 6u: return "lsug_wait_ld_req_not_ready_dcache_resp";
          default: return "lsug_wait_ld_req_not_ready_dcache_unknown";
        }
      }

      if (top->dbg_lsu_pend_valid_o) return "lsug_wait_pending_load";
      if (static_cast<uint32_t>(top->dbg_lsu_mmu_state_o) != 0u) return "lsug_wait_lsu_mmu";
      return "lsug_wait_dcache_owner_no_ld_req";
    }
    return "lsug_no_free_lane";
  }

  if (top->dbg_dc_store_wait_same_line_o) return "dc_store_wait_same_line";
  if (top->dbg_dc_store_wait_mshr_full_o) return "dc_store_wait_mshr_full";

  if (static_cast<uint32_t>(top->dbg_sb_alloc_req_o) != 0u && !top->dbg_sb_alloc_ready_o) {
    return "sb_alloc_blocked";
  }

  if (top->dbg_lsu_rs_head_valid_o) {
    bool has_rs1 = top->dbg_lsu_rs_head_has_rs1_o;
    bool rs1_ready = top->dbg_lsu_rs_head_r1_ready_o;
    bool has_rs2_local = top->dbg_lsu_rs_head_has_rs2_o;
    bool rs2_ready_local = top->dbg_lsu_rs_head_r2_ready_o;
    if ((has_rs1 && !rs1_ready) || (has_rs2_local && !rs2_ready_local)) return "lsu_operand_wait";
  }

  if (static_cast<uint32_t>(top->dbg_lsu_rs_busy_o) != 0u &&
      static_cast<uint32_t>(top->dbg_lsu_rs_ready_o) == 0u) {
    return "lsu_rs_pressure";
  }

  if (top->dbg_rob_q2_valid_o && !top->dbg_rob_q2_complete_o && has_rs2 == 1 && rs2_ready == 0) {
    return "rob_q2_wait";
  }

  std::array<int, 5> gate = {static_cast<int>(top->dbg_gate_alu_o), static_cast<int>(top->dbg_gate_bru_o),
                             static_cast<int>(top->dbg_gate_lsu_o), static_cast<int>(top->dbg_gate_mdu_o),
                             static_cast<int>(top->dbg_gate_csr_o)};
  std::array<uint32_t, 5> need = {static_cast<uint32_t>(top->dbg_need_alu_o), static_cast<uint32_t>(top->dbg_need_bru_o),
                                  static_cast<uint32_t>(top->dbg_need_lsu_o), static_cast<uint32_t>(top->dbg_need_mdu_o),
                                  static_cast<uint32_t>(top->dbg_need_csr_o)};
  const std::array<std::pair<int, const char *>, 5> gate_priority = {{
      {2, "dispatch_gate_lsu"},
      {0, "dispatch_gate_alu"},
      {1, "dispatch_gate_bru"},
      {4, "dispatch_gate_csr"},
      {3, "dispatch_gate_mdu"},
  }};
  for (const auto &entry : gate_priority) {
    int idx = entry.first;
    if (gate[idx] == 0 && need[idx] > 0u) return entry.second;
  }
  for (const auto &entry : gate_priority) {
    int idx = entry.first;
    if (gate[idx] == 0) return entry.second;
  }

  uint32_t sm = static_cast<uint32_t>(top->dbg_lsu_state_o);
  if (sm == 1u && !top->dbg_lsu_ld_fire_o) return "lsu_wait_ld_req";
  if (sm == 2u && !top->dbg_lsu_rsp_fire_o) return "lsu_wait_ld_rsp";
  return "other";
}

const char *ProfileCollector::classify_rob_backpressure_detail_cycle(const Vtb_triathlon *top) const {
  uint32_t fu = static_cast<uint32_t>(top->dbg_rob_head_fu_o);
  bool complete = top->dbg_rob_head_complete_o;
  bool is_store = top->dbg_rob_head_is_store_o;

  if (is_store) {
    if (!top->dbg_sb_head_valid_o) return "rob_store_wait_sb_head";
    if (!top->dbg_sb_head_committed_o) return "rob_store_wait_commit";
    if (!top->dbg_sb_head_addr_valid_o) return "rob_store_wait_addr";
    if (!top->dbg_sb_head_data_valid_o) return "rob_store_wait_data";
    if (top->dbg_sb_dcache_req_valid_o && !top->dbg_sb_dcache_req_ready_o) return "rob_store_wait_dcache";
    if (!top->dbg_sb_dcache_req_valid_o) return "rob_store_wait_issue";
    return "rob_store_wait_other";
  }

  if (!complete) {
    if (fu == 1u) return "rob_head_fu_alu_incomplete";
    if (fu == 2u) return "rob_head_fu_branch_incomplete";
    if (fu == 3u) {
      return classify_lsu_head_lane_detail(top, false);
    }
    if (fu == 4u || fu == 5u) return "rob_head_fu_mdu_incomplete";
    if (fu == 6u) return "rob_head_fu_csr_incomplete";
    return "rob_head_fu_unknown_incomplete";
  }

  return "rob_head_complete_but_not_ready";
}

const char *ProfileCollector::classify_other_detail_cycle(const Vtb_triathlon *top) const {
  uint32_t rob_count = static_cast<uint32_t>(top->dbg_rob_count_o);
  bool ren_ready = top->dbg_ren_ready_o;
  bool ren_fire = top->dbg_ren_fire_o;
  uint32_t fu = static_cast<uint32_t>(top->dbg_rob_head_fu_o);
  bool rob_head_complete = top->dbg_rob_head_complete_o;
  bool rob_head_is_store = top->dbg_rob_head_is_store_o;
  bool q2_incomplete = top->dbg_rob_q2_valid_o && !top->dbg_rob_q2_complete_o;

  if (rob_count == 0u) {
    if (!ren_ready) return "rob_empty_refill_ren_not_ready";
    if (ren_fire) return "rob_empty_refill_ren_fire";
    if (top->dbg_ifu_req_inflight_o) return "rob_empty_refill_wait_frontend_rsp";
    if (top->dbg_ifu_rsp_valid_o && top->dbg_ifu_rsp_capture_o) return "rob_empty_refill_rsp_capture";
    return "rob_empty_refill_other";
  }

  if (lsu_group_wb_any(top)) {
    const uint32_t head = static_cast<uint32_t>(top->dbg_rob_head_ptr_o);
    if (fu == 3u && !rob_head_complete) {
      if (wb_selects_rob_head(top, head)) return "lsu_wait_wb_head_lsu_cdb_visible";
      if (lsu_group_wb_selects_rob_head(top, head)) {
        return lsu_fu_ready(top) ? "lsu_wait_wb_head_lsu_group_visible"
                                 : "lsu_wait_wb_head_lsu_cdb_blocked";
      }
      return "lsu_wait_wb_other_lsu_head_lsu_incomplete";
    }
    if (fu == 3u && rob_head_complete) return "lsu_wait_wb_head_lsu_complete";
    if (q2_incomplete) return "lsu_wait_wb_q2_incomplete";
    return "lsu_wait_wb_other";
  }

  if (rob_head_is_store) {
    if (!top->dbg_sb_head_valid_o) return "rob_head_store_wait_sb_head_nonbp";
    if (!top->dbg_sb_head_committed_o) return "rob_head_store_wait_commit_nonbp";
    if (!top->dbg_sb_head_addr_valid_o) return "rob_head_store_wait_addr_nonbp";
    if (!top->dbg_sb_head_data_valid_o) return "rob_head_store_wait_data_nonbp";
    if (top->dbg_sb_dcache_req_valid_o && !top->dbg_sb_dcache_req_ready_o) {
      return "rob_head_store_wait_dcache_nonbp";
    }
    if (!top->dbg_sb_dcache_req_valid_o) return "rob_head_store_wait_issue_nonbp";
    return "rob_head_store_wait_other_nonbp";
  }

  if (!rob_head_complete) {
    if (fu == 1u) {
      if (top->dbg_alu_wb_head_hit_o) return "rob_head_alu_complete_not_visible_incomplete_nonbp";
      if (top->dbg_alu_issue_any_o) return "rob_head_alu_exec_wait_wb_incomplete_nonbp";
      if (top->dbg_alu_ready_not_issued_o) return "rob_head_alu_ready_not_issued_incomplete_nonbp";
      if (!top->dbg_gate_alu_o && static_cast<uint32_t>(top->dbg_need_alu_o) > 0u) {
        return "rob_head_alu_dispatch_blocked_incomplete_nonbp";
      }
      return "rob_head_alu_wait_operand_or_select_incomplete_nonbp";
    }
    if (fu == 2u) {
      if (top->dbg_bru_wb_head_hit_o) return "rob_head_branch_complete_not_visible_incomplete_nonbp";
      if (top->dbg_bru_valid_o) return "rob_head_branch_exec_wait_wb_incomplete_nonbp";
      if (top->dbg_bru_ready_not_issued_o) return "rob_head_branch_ready_not_issued_incomplete_nonbp";
      if (!top->dbg_gate_bru_o && static_cast<uint32_t>(top->dbg_need_bru_o) > 0u) {
        return "rob_head_branch_dispatch_blocked_incomplete_nonbp";
      }
      return "rob_head_branch_wait_operand_or_select_incomplete_nonbp";
    }
    if (fu == 3u) {
      return classify_lsu_head_lane_detail(top, true);
    }
    if (fu == 4u || fu == 5u) return "rob_head_mdu_incomplete_nonbp";
    if (fu == 6u) return "rob_head_csr_incomplete_nonbp";
    return "rob_head_unknown_incomplete_nonbp";
  }

  if (q2_incomplete) return "rob_q2_not_complete_nonstall";
  if (!ren_ready) return "ren_not_ready";
  if (!ren_fire) return "ren_no_fire";

  if (top->dbg_lsu_ld_req_valid_o && top->dbg_lsu_ld_req_ready_o && !top->dbg_lsu_ld_fire_o) {
    return "lsu_req_fire_gap";
  }
  if (top->dbg_lsu_ld_rsp_valid_o && top->dbg_lsu_ld_rsp_ready_o && !top->dbg_lsu_rsp_fire_o) {
    return "lsu_rsp_fire_gap";
  }

  return "other";
}

}  // namespace npc
