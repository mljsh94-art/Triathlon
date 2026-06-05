#pragma once

#include "args_parser.h"
#include "memory_models.h"

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

class Vtb_triathlon;

namespace npc {

class ProfileCollector {
 public:
  ProfileCollector(const SimArgs &args,
                   uint32_t cfg_instr_per_fetch,
                   uint32_t cfg_commit_width);

  void observe_cycle(const Vtb_triathlon *top);
  void record_flush(uint64_t cycles, const Vtb_triathlon *top, const UnifiedMem &mem);
  void record_commit(uint32_t pc, uint32_t raw_inst, uint32_t decoded_inst, bool is_rvc);
  void record_commit_width(uint32_t commit_this_cycle);
  void on_commit_cycle(uint64_t cycles);
  void on_no_commit_cycle(uint64_t cycles, uint64_t no_commit_cycles, const Vtb_triathlon *top);
  void emit_summary(uint64_t final_cycles, const Vtb_triathlon *top);
  void emit_summary_json(uint64_t final_cycles, const Vtb_triathlon *top);
  void emit_all_summaries(uint64_t final_cycles, const Vtb_triathlon *top);

  uint64_t total_commits() const { return total_commits_; }
  uint32_t last_commit_pc() const { return last_commit_pc_; }
  uint32_t last_commit_inst() const { return last_commit_inst_; }
  uint32_t last_commit_decoded_inst() const { return last_commit_decoded_inst_; }
  bool last_commit_is_rvc() const { return last_commit_is_rvc_; }

 private:
  enum StallKindIdx : int {
    kStallFlushRecovery = 0,
    kStallICacheMissWait = 1,
    kStallDCacheMissWait = 2,
    kStallROBBackpressure = 3,
    kStallFrontendEmpty = 4,
    kStallDecodeBlocked = 5,
    kStallLSUReqBlocked = 6,
    kStallOther = 7,
  };

  enum FrontendEmptyDetailIdx : int {
    kFeNoReq = 0,
    kFeWaitICacheRspHitLatency = 1,
    kFeWaitICacheRspMissWait = 2,
    kFeRspBlockedByFQFull = 3,
    kFeWaitIbufferConsume = 4,
    kFeRedirectRecovery = 5,
    kFeRspCaptureBubble = 6,
    kFeHasDataDecodeGap = 7,
    kFeOther = 8,
    kFeDropStaleRsp = 9,
    kFeNoReqReqQEmpty = 10,
    kFeNoReqInfFull = 11,
    kFeNoReqStorageBudget = 12,
    kFeNoReqFlushBlock = 13,
    kFeNoReqOther = 14,
    kFeReqFireNoInflight = 15,
    kFeRspNoInflight = 16,
    kFeFQNonemptyNoFeValid = 17,
    kFeReqReadyNoFire = 18,
  };

  static bool is_call_inst(uint32_t inst);
  static bool is_ret_inst(uint32_t inst);
  static bool is_indirect_jump_inst(uint32_t inst);

  bool profile_enabled() const {
    return args_.profile || !args_.profile_json_path.empty();
  }
  void finalize_control_tail();
  bool commit_trace_window_active(uint64_t cycle) const;
  bool should_log_verbose_flush(uint64_t cycle) const;

  uint32_t popcount_commit(uint32_t v) const;
  int classify_stall_cycle(const Vtb_triathlon *top) const;
  int classify_frontend_empty_cycle(const Vtb_triathlon *top) const;
  const char *classify_decode_blocked_detail_cycle(const Vtb_triathlon *top) const;
  const char *classify_rob_backpressure_detail_cycle(const Vtb_triathlon *top) const;
  const char *classify_other_detail_cycle(const Vtb_triathlon *top) const;

  void emit_pred_summary(const Vtb_triathlon *top) const;
  void emit_ranked_summary(const char *tag,
                           const char *value_key,
                           const std::unordered_map<uint32_t, uint64_t> &hist) const;
  void emit_detail_summary(const char *tag,
                           const char *total_key,
                           uint64_t total,
                           const std::unordered_map<std::string, uint64_t> &hist) const;

  SimArgs args_;
  uint32_t cfg_instr_per_fetch_ = 4;
  uint32_t cfg_commit_width_ = 4;
  uint32_t cfg_commit_mask_ = 0xFu;

  uint64_t total_commits_ = 0;
  uint32_t last_commit_pc_ = 0;
  uint32_t last_commit_inst_ = 0;
  uint32_t last_commit_decoded_inst_ = 0;
  bool last_commit_is_rvc_ = false;

  bool pending_flush_penalty_ = false;
  uint64_t pending_flush_cycle_ = 0;
  std::string pending_flush_reason_ = "unknown";

  uint64_t pred_cond_total_ = 0;
  uint64_t pred_cond_miss_ = 0;
  uint64_t pred_jump_total_ = 0;
  uint64_t pred_jump_miss_ = 0;
  uint64_t pred_jump_direct_total_ = 0;
  uint64_t pred_jump_direct_miss_ = 0;
  uint64_t pred_jump_indirect_total_ = 0;
  uint64_t pred_jump_indirect_miss_ = 0;
  uint64_t pred_ret_total_ = 0;
  uint64_t pred_ret_miss_ = 0;
  uint64_t pred_call_total_ = 0;

  uint64_t control_branch_count_ = 0;
  uint64_t control_jal_count_ = 0;
  uint64_t control_jalr_count_ = 0;
  uint64_t control_branch_taken_count_ = 0;
  uint64_t control_call_count_ = 0;
  uint64_t control_ret_count_ = 0;

  uint64_t redirect_distance_sum_ = 0;
  uint64_t redirect_distance_samples_ = 0;
  uint64_t redirect_distance_max_ = 0;
  uint64_t wrong_path_killed_uops_ = 0;

  uint64_t flush_count_ = 0;
  uint64_t bru_count_ = 0;
  uint64_t mispredict_flush_count_ = 0;
  uint64_t branch_penalty_cycles_ = 0;
  std::unordered_map<std::string, uint64_t> flush_reason_hist_;
  std::unordered_map<std::string, uint64_t> flush_source_hist_;

  std::unordered_map<uint32_t, uint64_t> commit_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> commit_inst_hist_;
  std::vector<uint64_t> commit_width_hist_;
  std::array<uint64_t, 8> stall_cycle_hist_ = {};
  std::array<uint64_t, 19> stall_frontend_empty_hist_ = {};
  std::unordered_map<std::string, uint64_t> stall_decode_blocked_detail_hist_;
  std::unordered_map<std::string, uint64_t> stall_rob_backpressure_detail_hist_;
  std::unordered_map<std::string, uint64_t> stall_other_detail_hist_;

  uint64_t branch_ready_not_issued_cycles_ = 0;
  uint64_t alu_ready_not_issued_cycles_ = 0;
  uint64_t complete_not_visible_cycles_ = 0;

  uint64_t ifu_fq_enq_ = 0;
  uint64_t ifu_fq_deq_ = 0;
  uint64_t ifu_fq_bypass_ = 0;
  uint64_t ifu_fq_enq_blocked_ = 0;
  uint64_t ifu_fq_full_cycles_ = 0;
  uint64_t ifu_fq_empty_cycles_ = 0;
  uint64_t ifu_fq_nonempty_cycles_ = 0;
  uint64_t ifu_fq_occ_sum_ = 0;
  uint64_t ifu_fq_occ_max_ = 0;
  std::array<uint64_t, 16> ifu_fq_occ_hist_ = {};

  bool has_prev_commit_ = false;
  uint32_t prev_commit_pc_ = 0;
  uint32_t prev_commit_inst_ = 0;
};

}  // namespace npc
