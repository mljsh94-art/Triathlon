#include "profile_collector.h"

#include "Vtb_triathlon.h"

#include <algorithm>
#include <array>
#include <iostream>
#include <utility>

namespace npc {

namespace {

uint32_t make_low_mask(uint32_t width) {
  if (width == 0u) return 0u;
  if (width >= 32u) return 0xFFFFFFFFu;
  return (1u << width) - 1u;
}

enum class MispredictDiagClass {
  kDirWrong,
  kDirOkTargetWrong,
  kSlotOffsetBind,
  kFtbFallthrough,
  kOther,
};

enum class FtbFallthroughCause {
  kNoEntryTagMiss,
  kHitCondNt,
  kHitOutOfRange,
  kHitShadowed,
  kUnclassified,
};

struct FtbPredSnap {
  bool valid = false;
  bool cond_hit = false;
  bool jump_hit = false;
  bool cond_tag_miss = false;
  bool jump_tag_miss = false;
  bool any_valid = false;
  bool tag_hit = false;
  uint32_t valid_count = 0;
  uint32_t cond_count = 0;
  uint32_t jump_count = 0;
  bool cond_in_range = false;
  bool jump_in_range = false;
  bool cond_taken_pred = false;
  bool pick_cond = false;
  bool pick_jump = false;
  uint32_t fetch_pc = 0;
  uint32_t fetch_epoch = 0;
  uint32_t cond_branch_pc = 0;
  uint32_t jump_branch_pc = 0;
};

bool read_packed_bit(uint16_t vec, uint32_t idx) {
  return ((vec >> idx) & 1u) != 0u;
}

uint32_t read_packed_field(uint16_t vec, uint32_t idx, uint32_t width) {
  const uint32_t mask = (width >= 32u) ? 0xFFFFFFFFu : ((1u << width) - 1u);
  return (vec >> (idx * width)) & mask;
}

uint32_t read_packed_field64(uint64_t vec, uint32_t idx, uint32_t width) {
  const uint64_t mask = (width >= 64u) ? ~0ull : ((1ull << width) - 1ull);
  return static_cast<uint32_t>((vec >> (idx * width)) & mask);
}

FtbPredSnap read_ftb_pred_snap(const Vtb_triathlon *top, uint32_t ftq_id, uint32_t ftq_depth,
                               uint32_t fetch_epoch_w) {
  FtbPredSnap snap;
  if (ftq_id >= ftq_depth) return snap;
  snap.valid = read_packed_bit(top->dbg_bpu_pred_snap_valid_o, ftq_id);
  snap.cond_hit = read_packed_bit(top->dbg_bpu_pred_snap_cond_hit_o, ftq_id);
  snap.jump_hit = read_packed_bit(top->dbg_bpu_pred_snap_jump_hit_o, ftq_id);
  snap.cond_tag_miss = read_packed_bit(top->dbg_bpu_pred_snap_cond_tag_miss_o, ftq_id);
  snap.jump_tag_miss = read_packed_bit(top->dbg_bpu_pred_snap_jump_tag_miss_o, ftq_id);
  snap.any_valid = read_packed_bit(top->dbg_bpu_pred_snap_any_valid_o, ftq_id);
  snap.tag_hit = read_packed_bit(top->dbg_bpu_pred_snap_tag_hit_o, ftq_id);
  snap.valid_count = read_packed_field64(top->dbg_bpu_pred_snap_valid_count_o, ftq_id, 3);
  snap.cond_count = read_packed_field64(top->dbg_bpu_pred_snap_cond_count_o, ftq_id, 3);
  snap.jump_count = read_packed_field64(top->dbg_bpu_pred_snap_jump_count_o, ftq_id, 3);
  snap.cond_in_range = read_packed_bit(top->dbg_bpu_pred_snap_cond_in_range_o, ftq_id);
  snap.jump_in_range = read_packed_bit(top->dbg_bpu_pred_snap_jump_in_range_o, ftq_id);
  snap.cond_taken_pred = read_packed_bit(top->dbg_bpu_pred_snap_cond_taken_pred_o, ftq_id);
  snap.pick_cond = read_packed_bit(top->dbg_bpu_pred_snap_pick_cond_o, ftq_id);
  snap.pick_jump = read_packed_bit(top->dbg_bpu_pred_snap_pick_jump_o, ftq_id);
  snap.fetch_pc = top->dbg_bpu_pred_snap_fetch_pc_o[ftq_id];
  snap.fetch_epoch = read_packed_field64(top->dbg_bpu_pred_snap_fetch_epoch_o, ftq_id,
                                         fetch_epoch_w);
  snap.cond_branch_pc = top->dbg_bpu_pred_snap_cond_branch_pc_o[ftq_id];
  snap.jump_branch_pc = top->dbg_bpu_pred_snap_jump_branch_pc_o[ftq_id];
  return snap;
}

FtbFallthroughCause classify_ftb_fallthrough(const FtbPredSnap &snap,
                                             uint32_t branch_pc,
                                             bool is_jump) {
  if (!snap.valid) return FtbFallthroughCause::kUnclassified;

  if (is_jump) {
    if (!snap.jump_hit) return FtbFallthroughCause::kNoEntryTagMiss;
    if (snap.jump_branch_pc != branch_pc) return FtbFallthroughCause::kHitShadowed;
    if (!snap.jump_in_range) return FtbFallthroughCause::kHitOutOfRange;
    if (!snap.pick_jump) return FtbFallthroughCause::kHitShadowed;
    return FtbFallthroughCause::kUnclassified;
  }

  if (!snap.cond_hit) return FtbFallthroughCause::kNoEntryTagMiss;
  if (snap.cond_branch_pc != branch_pc) return FtbFallthroughCause::kHitShadowed;
  if (!snap.cond_taken_pred) return FtbFallthroughCause::kHitCondNt;
  if (!snap.cond_in_range) return FtbFallthroughCause::kHitOutOfRange;
  if (!snap.pick_cond) return FtbFallthroughCause::kHitShadowed;
  return FtbFallthroughCause::kUnclassified;
}

MispredictDiagClass classify_mispredict(uint32_t pc,
                                        uint32_t pred_npc,
                                        uint32_t actual_npc,
                                        bool is_rvc,
                                        bool is_jump,
                                        uint32_t fetch_width_bytes) {
  const uint32_t instr_size = is_rvc ? 2u : 4u;
  const uint32_t fallthrough = pc + instr_size;
  const bool actual_taken = is_jump || (actual_npc != fallthrough);
  const bool pred_taken = (pred_npc != fallthrough);

  if (!is_jump && !actual_taken && fetch_width_bytes > 0u) {
    const uint32_t block_mask = ~(fetch_width_bytes - 1u);
    const uint32_t block_end = (pc & block_mask) + fetch_width_bytes;
    if (pred_npc == block_end) {
      return MispredictDiagClass::kSlotOffsetBind;
    }
  }

  // pred_npc 仍为 fallthrough 但实际跳转：前端未给出 taken target（需 FTB 快照细分）
  if (pred_npc == fallthrough && actual_npc != fallthrough) {
    return MispredictDiagClass::kFtbFallthrough;
  }

  if (!is_jump && pred_taken != actual_taken) {
    return MispredictDiagClass::kDirWrong;
  }

  if (!is_jump && !actual_taken && pred_npc != fallthrough) {
    return MispredictDiagClass::kSlotOffsetBind;
  }

  if (pred_npc != actual_npc) {
    return MispredictDiagClass::kDirOkTargetWrong;
  }

  return MispredictDiagClass::kOther;
}

}  // namespace

ProfileCollector::ProfileCollector(const SimArgs &args,
                                   uint32_t cfg_instr_per_fetch,
                                   uint32_t cfg_commit_width)
    : args_(args),
      cfg_instr_per_fetch_(cfg_instr_per_fetch),
      cfg_commit_width_(cfg_commit_width),
      cfg_commit_mask_(make_low_mask(cfg_commit_width_)),
      cfg_fetch_width_bytes_(cfg_instr_per_fetch * 4u),
      cfg_ftq_depth_(16u),
      cfg_ftq_id_w_(4u),
      cfg_fetch_epoch_w_(3u),
      commit_width_hist_(std::max<uint32_t>(5u, cfg_commit_width_ + 1u), 0) {}

bool ProfileCollector::commit_trace_window_active(uint64_t cycle) const {
  if (!args_.commit_trace) return false;
  if (cycle < args_.commit_trace_start) return false;
  if (args_.commit_trace_end != 0 && cycle > args_.commit_trace_end) return false;
  return true;
}

bool ProfileCollector::should_log_verbose_flush(uint64_t cycle) const {
  if (args_.commit_trace) return commit_trace_window_active(cycle);
  if (args_.bru_trace) return true;
  return false;
}

void ProfileCollector::observe_cycle(const Vtb_triathlon *top) {
  if (profile_enabled()) {
    bool selected_update = false;
    for (uint32_t i = 0; i < cfg_commit_width_; i++) {
      if (((top->commit_valid_o >> i) & 1u) == 0u) continue;
      const bool is_control = ((top->commit_is_branch_o >> i) & 1u) != 0u;
      if (!is_control) continue;
      const bool is_jump = ((top->commit_is_jump_o >> i) & 1u) != 0u;
      const bool is_rvc = ((top->commit_is_rvc_o >> i) & 1u) != 0u;
      const uint32_t pc = top->commit_pc_o[i];
      const uint32_t instr_size = is_rvc ? 2u : 4u;
      const bool taken = is_jump || (top->commit_actual_npc_o[i] != pc + instr_size);
      if (taken) {
        bpu_taken_control_pc_hist_[pc]++;
      }
      if (!selected_update) {
        selected_update = true;
        bpu_update_pc_hist_[pc]++;
        if (is_jump) {
          bpu_update_kind_hist_[is_rvc ? "jump_rvc" : "jump_32"]++;
        } else {
          bpu_update_kind_hist_[is_rvc ? "cond_rvc" : "cond_32"]++;
        }
      }
    }
  }

  uint32_t fq_count = static_cast<uint32_t>(top->dbg_ifu_fq_count_o);
  if (fq_count >= ifu_fq_occ_hist_.size()) fq_count = static_cast<uint32_t>(ifu_fq_occ_hist_.size() - 1);
  ifu_fq_occ_sum_ += fq_count;
  ifu_fq_occ_hist_[fq_count]++;
  ifu_fq_occ_max_ = std::max<uint64_t>(ifu_fq_occ_max_, fq_count);
  if (top->dbg_ifu_fq_full_o) ifu_fq_full_cycles_++;
  if (top->dbg_ifu_fq_empty_o) {
    ifu_fq_empty_cycles_++;
  } else {
    ifu_fq_nonempty_cycles_++;
  }
  if (top->dbg_ifu_fq_enq_fire_o) ifu_fq_enq_++;
  if (top->dbg_ifu_fq_deq_fire_o) ifu_fq_deq_++;
  if (top->dbg_ifu_fq_bypass_fire_o) ifu_fq_bypass_++;
  if (top->dbg_ifu_fq_enq_blocked_o) ifu_fq_enq_blocked_++;
}

void ProfileCollector::record_flush(uint64_t cycles,
                                    const Vtb_triathlon *top,
                                    const UnifiedMem &mem) {
  if (!top->backend_flush_o) return;
  const bool collect_stats = profile_enabled();

  bool rob_flush = top->dbg_rob_flush_o;
  bool rob_mispred = top->dbg_rob_flush_is_mispred_o;
  bool rob_exception = top->dbg_rob_flush_is_exception_o;
  bool rob_is_branch = top->dbg_rob_flush_is_branch_o;
  bool rob_is_jump = top->dbg_rob_flush_is_jump_o;
  uint32_t cause = static_cast<uint32_t>(top->dbg_rob_flush_cause_o) & 0x1Fu;
  uint32_t src_pc = top->dbg_rob_flush_src_pc_o;
  uint32_t redirect_pc = top->backend_redirect_pc_o;

  std::string flush_reason = "external";
  std::string flush_source = rob_flush ? "rob" : "external";
  if (rob_flush) {
    if (rob_mispred) {
      flush_reason = "branch_mispredict";
    } else if (rob_exception) {
      flush_reason = "exception";
    } else {
      flush_reason = "rob_other";
    }
  }

  std::string miss_type = "none";
  std::string miss_subtype = "none";
  if (flush_reason == "branch_mispredict") {
    if (rob_is_jump) {
      const uint32_t src_inst =
          flush_jump_classify_inst(top, src_pc, cfg_commit_width_, mem);
      if (is_ret_inst(src_inst) ||
          ((src_inst & 0xFFFF0000u) == 0u &&
           is_compressed_ret_inst(static_cast<uint16_t>(src_inst & 0xFFFFu)))) {
        miss_type = "return";
        miss_subtype = "return";
        if (collect_stats) pred_ret_miss_++;
      } else if (is_indirect_jump_inst(src_inst) ||
                 ((src_inst & 0xFFFF0000u) == 0u &&
                  is_compressed_indirect_jump_inst(static_cast<uint16_t>(src_inst & 0xFFFFu)))) {
        miss_type = "jump";
        miss_subtype = "jump_indirect";
        if (collect_stats) {
          pred_jump_miss_++;
          pred_jump_indirect_miss_++;
        }
      } else {
        miss_type = "jump";
        miss_subtype = "jump_direct";
        if (collect_stats) {
          pred_jump_miss_++;
          pred_jump_direct_miss_++;
        }
      }
    } else if (rob_is_branch) {
      miss_type = "cond_branch";
      miss_subtype = "cond_branch";
      if (collect_stats) pred_cond_miss_++;
    } else {
      miss_type = "control_unknown";
      miss_subtype = "control_unknown";
    }
  }

  uint32_t commit_pop = popcount_commit(static_cast<uint32_t>(top->commit_valid_o));
  uint32_t rob_count = static_cast<uint32_t>(top->dbg_rob_count_o);
  uint32_t killed_uops = (rob_count >= commit_pop) ? (rob_count - commit_pop) : 0;

  if (collect_stats) {
    uint32_t redirect_distance =
        (redirect_pc >= src_pc) ? (redirect_pc - src_pc) : (src_pc - redirect_pc);
    flush_count_++;
    flush_reason_hist_[flush_reason]++;
    flush_source_hist_[flush_source]++;
    redirect_distance_sum_ += redirect_distance;
    redirect_distance_samples_++;
    redirect_distance_max_ = std::max<uint64_t>(redirect_distance_max_, redirect_distance);
    if (flush_reason == "branch_mispredict") {
      mispredict_flush_count_++;
      wrong_path_killed_uops_ += killed_uops;
      record_mispredict_diag(top, src_pc, redirect_pc, rob_is_branch, rob_is_jump);
    }
    if (top->dbg_bru_mispred_o) {
      bru_count_++;
    }
  }

  if (!should_log_verbose_flush(cycles)) {
    if (collect_stats && !pending_flush_penalty_) {
      pending_flush_penalty_ = true;
      pending_flush_cycle_ = cycles;
      pending_flush_reason_ = flush_reason;
    }
    return;
  }

  const uint32_t redirect_distance =
      (redirect_pc >= src_pc) ? (redirect_pc - src_pc) : (src_pc - redirect_pc);

  std::ios::fmtflags f(std::cout.flags());
  std::cout << "[flush ] cycle=" << cycles
            << " reason=" << flush_reason
            << " source=" << flush_source
            << " cause=0x" << std::hex << cause
            << " src_pc=0x" << src_pc
            << " redirect_pc=0x" << redirect_pc
            << std::dec
            << " miss_type=" << miss_type
            << " miss_subtype=" << miss_subtype
            << " bpu_arch_ras_count=" << static_cast<uint32_t>(top->dbg_bpu_arch_ras_count_o)
            << " bpu_spec_ras_count=" << static_cast<uint32_t>(top->dbg_bpu_spec_ras_count_o)
            << " bpu_arch_ras_top=0x" << std::hex << static_cast<uint32_t>(top->dbg_bpu_arch_ras_top_o)
            << " bpu_spec_ras_top=0x" << static_cast<uint32_t>(top->dbg_bpu_spec_ras_top_o)
            << std::dec
            << " redirect_distance=" << redirect_distance
            << " killed_uops=" << killed_uops
            << std::dec << "\n";
  if (top->dbg_bru_mispred_o) {
    std::cout << "[bru   ] cycle=" << cycles
              << " valid=" << static_cast<int>(top->dbg_bru_valid_o)
              << " pc=0x" << std::hex << top->dbg_bru_pc_o
              << " imm=0x" << static_cast<uint32_t>(top->dbg_bru_imm_o)
              << " op=" << std::dec << static_cast<int>(top->dbg_bru_op_o)
              << " is_jump=" << static_cast<int>(top->dbg_bru_is_jump_o)
              << " is_branch=" << static_cast<int>(top->dbg_bru_is_branch_o)
              << std::dec << "\n";
  }
  std::cout.flags(f);
  if (!pending_flush_penalty_) {
    pending_flush_penalty_ = true;
    pending_flush_cycle_ = cycles;
    pending_flush_reason_ = flush_reason;
  }
}

void ProfileCollector::record_mispredict_diag(const Vtb_triathlon *top,
                                              uint32_t src_pc,
                                              uint32_t actual_npc,
                                              bool is_branch,
                                              bool is_jump) {
  uint32_t pred_npc = 0;
  bool is_rvc = false;
  uint32_t ftq_id = 0;
  uint32_t commit_fetch_epoch = 0;
  bool found = false;

  for (uint32_t i = 0; i < cfg_commit_width_; i++) {
    if (((top->commit_valid_o >> i) & 1u) == 0u) continue;
    if (top->commit_pc_o[i] != src_pc) continue;
    pred_npc = top->commit_pred_npc_o[i];
    is_rvc = ((top->commit_is_rvc_o >> i) & 1u) != 0;
    ftq_id = read_packed_field(top->commit_ftq_id_o, i, cfg_ftq_id_w_);
    commit_fetch_epoch = read_packed_field(top->commit_fetch_epoch_o, i, cfg_fetch_epoch_w_);
    found = true;
    break;
  }

  if (!found) {
    mispredict_diag_no_commit_slot_++;
    return;
  }

  const bool control_flow = is_branch || is_jump;
  if (!control_flow) {
    mispredict_diag_other_++;
    return;
  }

  const auto cls = classify_mispredict(src_pc, pred_npc, actual_npc, is_rvc, is_jump,
                                       cfg_fetch_width_bytes_);
  switch (cls) {
    case MispredictDiagClass::kDirWrong:
      mispredict_diag_dir_wrong_++;
      break;
    case MispredictDiagClass::kDirOkTargetWrong:
      mispredict_diag_dir_ok_target_wrong_++;
      break;
    case MispredictDiagClass::kSlotOffsetBind:
      mispredict_diag_slot_offset_bind_++;
      break;
    case MispredictDiagClass::kFtbFallthrough: {
      const FtbPredSnap snap =
          read_ftb_pred_snap(top, ftq_id, cfg_ftq_depth_, cfg_fetch_epoch_w_);
      const bool epoch_ok = snap.valid && (snap.fetch_epoch == commit_fetch_epoch);
      if (snap.valid && !epoch_ok) {
        mispredict_diag_ftb_snap_epoch_mismatch_++;
      }
      switch (classify_ftb_fallthrough(snap, src_pc, is_jump)) {
        case FtbFallthroughCause::kNoEntryTagMiss: {
          mispredict_diag_ftb_no_entry_tag_miss_++;
          std::string no_entry_cause = "unknown";
          if (!snap.any_valid) {
            no_entry_cause = "empty_index";
          } else if (!snap.tag_hit) {
            no_entry_cause = "tag_conflict";
          } else if (is_jump && snap.jump_count == 0u) {
            no_entry_cause = "no_jump_slot";
          } else if (!is_jump && snap.cond_count == 0u) {
            no_entry_cause = "no_cond_slot";
          } else {
            no_entry_cause = "inconsistent_snapshot";
          }
          const uint32_t fetch_rel = src_pc - snap.fetch_pc;
          const int32_t block_delta =
              static_cast<int32_t>(src_pc & ~0xFu) - static_cast<int32_t>(snap.fetch_pc & ~0xFu);
          mispredict_diag_ftb_no_entry_branch_pc_hist_[src_pc]++;
          mispredict_diag_ftb_no_entry_fetch_pc_hist_[snap.fetch_pc]++;
          mispredict_diag_ftb_no_entry_fetch_rel_hist_[fetch_rel]++;
          mispredict_diag_ftb_no_entry_fetch_byte_off_hist_[snap.fetch_pc & 0xFu]++;
          mispredict_diag_ftb_no_entry_block_byte_off_hist_[src_pc & 0xFu]++;
          mispredict_diag_ftb_no_entry_block_delta_hist_[std::to_string(block_delta)]++;
          mispredict_diag_ftb_no_entry_valid_count_hist_[snap.valid_count]++;
          mispredict_diag_ftb_no_entry_cond_count_hist_[snap.cond_count]++;
          mispredict_diag_ftb_no_entry_jump_count_hist_[snap.jump_count]++;
          mispredict_diag_ftb_no_entry_cause_hist_[no_entry_cause]++;
          if (is_jump) {
            mispredict_diag_ftb_no_entry_kind_hist_[is_rvc ? "jump_rvc" : "jump_32"]++;
          } else {
            mispredict_diag_ftb_no_entry_kind_hist_[is_rvc ? "cond_rvc" : "cond_32"]++;
          }
          break;
        }
        case FtbFallthroughCause::kHitCondNt:
          mispredict_diag_ftb_hit_cond_nt_++;
          break;
        case FtbFallthroughCause::kHitOutOfRange: {
          const uint32_t snap_pc = is_jump ? snap.jump_branch_pc : snap.cond_branch_pc;
          mispredict_diag_ftb_hit_out_of_range_++;
          if (epoch_ok) mispredict_diag_ftb_hit_out_of_range_epoch_ok_++;
          mispredict_diag_ftb_oor_branch_pc_hist_[src_pc]++;
          mispredict_diag_ftb_oor_snap_pc_hist_[snap_pc]++;
          mispredict_diag_ftb_oor_block_byte_off_hist_[src_pc & 0xFu]++;
          if (is_jump) {
            mispredict_diag_ftb_oor_kind_hist_[is_rvc ? "jump_rvc" : "jump_32"]++;
          } else {
            mispredict_diag_ftb_oor_kind_hist_[is_rvc ? "cond_rvc" : "cond_32"]++;
          }
          break;
        }
        case FtbFallthroughCause::kHitShadowed:
          mispredict_diag_ftb_hit_shadowed_++;
          if (epoch_ok) mispredict_diag_ftb_hit_shadowed_epoch_ok_++;
          break;
        default:
          mispredict_diag_ftb_unclassified_++;
          break;
      }
      break;
    }
    default:
      mispredict_diag_other_++;
      break;
  }
}

void ProfileCollector::record_commit(uint32_t pc, uint32_t raw_inst, uint32_t decoded_inst, bool is_rvc) {
  total_commits_++;
  commit_pc_hist_[pc]++;
  commit_inst_hist_[raw_inst]++;

  if (has_prev_commit_) {
    uint32_t prev_opcode = prev_commit_inst_ & 0x7Fu;
    if (prev_opcode == 0x63u) {
      control_branch_count_++;
      uint32_t expected_next = prev_commit_pc_ + 4u;
      if (pc != expected_next) control_branch_taken_count_++;
    } else if (prev_opcode == 0x6Fu) {
      control_jal_count_++;
    } else if (prev_opcode == 0x67u) {
      control_jalr_count_++;
    }
    if (is_call_inst(prev_commit_inst_)) control_call_count_++;
    if (is_ret_inst(prev_commit_inst_)) control_ret_count_++;
  }
  has_prev_commit_ = true;
  prev_commit_pc_ = pc;
  prev_commit_inst_ = decoded_inst;

  uint32_t opcode = decoded_inst & 0x7Fu;
  if (opcode == 0x63u) {
    pred_cond_total_++;
  } else if (opcode == 0x6Fu || opcode == 0x67u) {
    if (is_ret_inst(decoded_inst)) {
      pred_ret_total_++;
    } else {
      pred_jump_total_++;
      if (is_indirect_jump_inst(decoded_inst)) {
        pred_jump_indirect_total_++;
      } else {
        pred_jump_direct_total_++;
      }
    }
  }
  if (is_call_inst(decoded_inst)) {
    pred_call_total_++;
  }

  last_commit_pc_ = pc;
  last_commit_inst_ = raw_inst;
  last_commit_decoded_inst_ = decoded_inst;
  last_commit_is_rvc_ = is_rvc;
}

void ProfileCollector::record_commit_width(uint32_t commit_this_cycle) {
  commit_width_hist_[std::min<uint32_t>(commit_this_cycle, cfg_commit_width_)]++;
}

void ProfileCollector::on_commit_cycle(uint64_t cycles) {
  if (pending_flush_penalty_ && cycles > pending_flush_cycle_) {
    const uint64_t penalty = cycles - pending_flush_cycle_;
    if (profile_enabled()) {
      branch_penalty_cycles_ += penalty;
    }
    if (should_log_verbose_flush(cycles)) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[flushp] cycle=" << cycles
                << " reason=" << pending_flush_reason_
                << " penalty=" << penalty
                << "\n";
      std::cout.flags(f);
    }
    pending_flush_penalty_ = false;
  }
}

bool ProfileCollector::is_call_inst(uint32_t inst) {
  uint32_t opcode = inst & 0x7Fu;
  uint32_t rd = (inst >> 7) & 0x1Fu;
  if (opcode == 0x6Fu || opcode == 0x67u) {
    return (rd == 1u || rd == 5u);
  }
  return false;
}

bool ProfileCollector::is_ret_inst(uint32_t inst) {
  uint32_t opcode = inst & 0x7Fu;
  if (opcode != 0x67u) return false;
  uint32_t rd = (inst >> 7) & 0x1Fu;
  uint32_t rs1 = (inst >> 15) & 0x1Fu;
  uint32_t imm12 = (inst >> 20) & 0xFFFu;
  return (rd == 0u) && (rs1 == 1u || rs1 == 5u) && (imm12 == 0u);
}

bool ProfileCollector::is_indirect_jump_inst(uint32_t inst) {
  uint32_t opcode = inst & 0x7Fu;
  if (opcode != 0x67u) return false;
  if (is_call_inst(inst) || is_ret_inst(inst)) return false;
  return true;
}

bool ProfileCollector::is_compressed_ret_inst(uint16_t inst) {
  if ((inst & 0xE003u) != 0x8002u) return false;
  const uint32_t rs1 = (inst >> 7) & 0x1Fu;
  return rs1 == 1u || rs1 == 5u;
}

bool ProfileCollector::is_compressed_indirect_jump_inst(uint16_t inst) {
  if ((inst & 0xF003u) != 0x9002u) return false;
  if (is_compressed_ret_inst(inst)) return false;
  return true;
}

bool ProfileCollector::find_flush_commit_insn(const Vtb_triathlon *top,
                                              uint32_t src_pc,
                                              uint32_t commit_width,
                                              uint32_t &decoded_inst) {
  for (uint32_t i = 0; i < commit_width; i++) {
    if (((top->commit_valid_o >> i) & 1u) == 0u) continue;
    if (top->commit_pc_o[i] != src_pc) continue;
    decoded_inst = top->commit_decoded_inst_o[i];
    return true;
  }
  return false;
}

uint32_t ProfileCollector::flush_jump_classify_inst(const Vtb_triathlon *top,
                                                    uint32_t src_pc,
                                                    uint32_t commit_width,
                                                    const UnifiedMem &mem) {
  uint32_t decoded_inst = 0;
  if (find_flush_commit_insn(top, src_pc, commit_width, decoded_inst)) {
    return decoded_inst;
  }

  const uint32_t aligned = src_pc & ~0x3u;
  const uint32_t word = mem.read_word(aligned);
  const uint16_t half = ((src_pc & 0x2u) != 0u) ? static_cast<uint16_t>((word >> 16) & 0xFFFFu)
                                                : static_cast<uint16_t>(word & 0xFFFFu);
  if ((half & 0x3u) != 0x3u) {
    if (is_compressed_ret_inst(half) || is_compressed_indirect_jump_inst(half)) {
      return half;
    }
  }
  return (src_pc & 0x2u) != 0u ? ((word >> 16) & 0xFFFFu) : word;
}

uint32_t ProfileCollector::popcount_commit(uint32_t v) const {
  v &= cfg_commit_mask_;
  return static_cast<uint32_t>(__builtin_popcount(v));
}

}  // namespace npc
