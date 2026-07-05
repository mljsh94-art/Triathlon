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
  static bool is_compressed_ret_inst(uint16_t inst);
  static bool is_compressed_indirect_jump_inst(uint16_t inst);
  static bool find_flush_commit_insn(const Vtb_triathlon *top,
                                     uint32_t src_pc,
                                     uint32_t commit_width,
                                     uint32_t &decoded_inst);
  static uint32_t flush_jump_classify_inst(const Vtb_triathlon *top,
                                           uint32_t src_pc,
                                           uint32_t commit_width,
                                           const UnifiedMem &mem);

  bool profile_enabled() const {
    return args_.profile || !args_.profile_json_path.empty();
  }
  void finalize_control_tail();
  bool commit_trace_window_active(uint64_t cycle) const;
  bool should_log_verbose_flush(uint64_t cycle) const;
  void record_mispredict_diag(const Vtb_triathlon *top,
                              uint32_t src_pc,
                              uint32_t actual_npc,
                              bool is_branch,
                              bool is_jump);

  uint32_t popcount_commit(uint32_t v) const;
  int classify_stall_cycle(const Vtb_triathlon *top) const;
  int classify_frontend_empty_cycle(const Vtb_triathlon *top) const;
  const char *classify_decode_blocked_detail_cycle(const Vtb_triathlon *top) const;
  const char *classify_rob_backpressure_detail_cycle(const Vtb_triathlon *top) const;
  const char *classify_other_detail_cycle(const Vtb_triathlon *top) const;
  void record_hol_load_cycle(const Vtb_triathlon *top);

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
  uint32_t cfg_fetch_width_bytes_ = 16;
  uint32_t cfg_ftq_depth_ = 32;
  uint32_t cfg_ftq_id_w_ = 5;
  uint32_t cfg_fetch_epoch_w_ = 3;

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
  uint64_t mispredict_diag_dir_wrong_ = 0;
  uint64_t mispredict_diag_dir_ok_target_wrong_ = 0;
  uint64_t mispredict_diag_slot_offset_bind_ = 0;
  uint64_t mispredict_diag_ftb_no_entry_tag_miss_ = 0;
  uint64_t mispredict_diag_ftb_hit_cond_nt_ = 0;
  uint64_t mispredict_diag_ftb_hit_out_of_range_ = 0;
  uint64_t mispredict_diag_ftb_hit_shadowed_ = 0;
  uint64_t mispredict_diag_ftb_hit_shadowed_cond_nt_ = 0;
  uint64_t mispredict_diag_ftb_snap_epoch_mismatch_ = 0;
  uint64_t mispredict_diag_ftb_hit_out_of_range_epoch_ok_ = 0;
  uint64_t mispredict_diag_ftb_unclassified_ = 0;
  uint64_t mispredict_diag_other_ = 0;
  uint64_t mispredict_diag_no_commit_slot_ = 0;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_dir_wrong_pc_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_dir_wrong_kind_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_cond_nt_branch_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_cond_nt_fetch_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_cond_nt_block_byte_off_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_cond_nt_valid_count_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_cond_nt_cond_count_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_cond_nt_jump_count_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_hit_cond_nt_kind_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_shadowed_branch_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_shadowed_snap_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_shadowed_block_byte_off_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_hit_shadowed_kind_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_hit_shadowed_pick_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_shadowed_cond_nt_branch_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_shadowed_cond_nt_shadow_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_hit_shadowed_cond_nt_block_byte_off_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_hit_shadowed_cond_nt_kind_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_hit_shadowed_cond_nt_pick_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_oor_branch_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_oor_snap_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_oor_block_byte_off_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_oor_kind_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_branch_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_fetch_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_fetch_rel_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_fetch_byte_off_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_block_byte_off_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_no_entry_block_delta_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_valid_count_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_cond_count_hist_;
  std::unordered_map<uint32_t, uint64_t> mispredict_diag_ftb_no_entry_jump_count_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_no_entry_kind_hist_;
  std::unordered_map<std::string, uint64_t> mispredict_diag_ftb_no_entry_cause_hist_;
  std::unordered_map<uint32_t, uint64_t> bpu_taken_control_pc_hist_;
  std::unordered_map<uint32_t, uint64_t> bpu_update_pc_hist_;
  std::unordered_map<std::string, uint64_t> bpu_update_kind_hist_;
  std::unordered_map<uint64_t, uint64_t> cond_provider_lane_selected_hist_;
  std::unordered_map<uint64_t, uint64_t> cond_provider_lane_correct_hist_;
  std::unordered_map<uint64_t, uint64_t> cond_provider_lane_miss_hist_;
  std::unordered_map<uint64_t, uint64_t> cond_provider_lane_override_hist_;
  std::unordered_map<uint64_t, uint64_t> cond_provider_lane_override_correct_hist_;
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
  std::unordered_map<std::string, uint64_t> stall_hol_load_detail_hist_;

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
