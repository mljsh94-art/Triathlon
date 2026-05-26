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

}  // namespace

ProfileCollector::ProfileCollector(const SimArgs &args,
                                   uint32_t cfg_instr_per_fetch,
                                   uint32_t cfg_commit_width)
    : args_(args),
      cfg_instr_per_fetch_(cfg_instr_per_fetch),
      cfg_commit_width_(cfg_commit_width),
      cfg_commit_mask_(make_low_mask(cfg_commit_width_)),
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
  if (!(args_.commit_trace || args_.bru_trace) || !top->backend_flush_o) return;

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
      uint32_t src_inst = mem.read_word(src_pc);
      if (is_ret_inst(src_inst)) {
        miss_type = "return";
        miss_subtype = "return";
        pred_ret_miss_++;
      } else if (is_indirect_jump_inst(src_inst)) {
        miss_type = "jump";
        miss_subtype = "jump_indirect";
        pred_jump_miss_++;
        pred_jump_indirect_miss_++;
      } else {
        miss_type = "jump";
        miss_subtype = "jump_direct";
        pred_jump_miss_++;
        pred_jump_direct_miss_++;
      }
    } else if (rob_is_branch) {
      miss_type = "cond_branch";
      miss_subtype = "cond_branch";
      pred_cond_miss_++;
    } else {
      miss_type = "control_unknown";
      miss_subtype = "control_unknown";
    }
  }

  uint32_t redirect_distance =
      (redirect_pc >= src_pc) ? (redirect_pc - src_pc) : (src_pc - redirect_pc);
  redirect_distance_sum_ += redirect_distance;
  redirect_distance_samples_++;
  redirect_distance_max_ = std::max<uint64_t>(redirect_distance_max_, redirect_distance);

  uint32_t commit_pop = popcount_commit(static_cast<uint32_t>(top->commit_valid_o));
  uint32_t rob_count = static_cast<uint32_t>(top->dbg_rob_count_o);
  uint32_t killed_uops = (rob_count >= commit_pop) ? (rob_count - commit_pop) : 0;
  if (flush_reason == "branch_mispredict") {
    wrong_path_killed_uops_ += killed_uops;
  }

  if (!should_log_verbose_flush(cycles)) return;

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

void ProfileCollector::record_commit(uint32_t pc, uint32_t inst) {
  total_commits_++;
  commit_pc_hist_[pc]++;
  commit_inst_hist_[inst]++;

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
  prev_commit_inst_ = inst;

  uint32_t opcode = inst & 0x7Fu;
  if (opcode == 0x63u) {
    pred_cond_total_++;
  } else if (opcode == 0x6Fu || opcode == 0x67u) {
    if (is_ret_inst(inst)) {
      pred_ret_total_++;
    } else {
      pred_jump_total_++;
      if (is_indirect_jump_inst(inst)) {
        pred_jump_indirect_total_++;
      } else {
        pred_jump_direct_total_++;
      }
    }
  }
  if (is_call_inst(inst)) {
    pred_call_total_++;
  }

  last_commit_pc_ = pc;
  last_commit_inst_ = inst;
}

void ProfileCollector::record_commit_width(uint32_t commit_this_cycle) {
  commit_width_hist_[std::min<uint32_t>(commit_this_cycle, cfg_commit_width_)]++;
}

void ProfileCollector::on_commit_cycle(uint64_t cycles) {
  if ((args_.commit_trace || args_.bru_trace) && pending_flush_penalty_ &&
      cycles > pending_flush_cycle_) {
    if (should_log_verbose_flush(cycles)) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[flushp] cycle=" << cycles
                << " reason=" << pending_flush_reason_
                << " penalty=" << (cycles - pending_flush_cycle_)
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

uint32_t ProfileCollector::popcount_commit(uint32_t v) const {
  v &= cfg_commit_mask_;
  return static_cast<uint32_t>(__builtin_popcount(v));
}

}  // namespace npc
