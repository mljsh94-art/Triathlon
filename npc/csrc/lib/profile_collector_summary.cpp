#include "profile_collector.h"

#include "Vtb_triathlon.h"

#include <algorithm>
#include <iostream>
#include <vector>

namespace npc {

void ProfileCollector::finalize_control_tail() {
  if (!has_prev_commit_) return;
  uint32_t opcode = prev_commit_inst_ & 0x7Fu;
  if (opcode == 0x63u) {
    control_branch_count_++;
  } else if (opcode == 0x6Fu) {
    control_jal_count_++;
  } else if (opcode == 0x67u) {
    control_jalr_count_++;
  }
  if (is_call_inst(prev_commit_inst_)) control_call_count_++;
  if (is_ret_inst(prev_commit_inst_)) control_ret_count_++;
  has_prev_commit_ = false;
}

void ProfileCollector::emit_all_summaries(uint64_t final_cycles, const Vtb_triathlon *top) {
  if (!profile_enabled()) return;
  finalize_control_tail();
  if (args_.profile) {
    emit_summary(final_cycles, top);
  }
  if (!args_.profile_json_path.empty()) {
    emit_summary_json(final_cycles, top);
  }
}

void ProfileCollector::emit_summary(uint64_t final_cycles, const Vtb_triathlon *top) {
  if (!args_.profile) return;
  emit_pred_summary(top);

  uint64_t stall_total_cycles = 0;
  for (uint64_t v : stall_cycle_hist_) stall_total_cycles += v;

  std::cout << "[commitm] cycles=" << final_cycles
            << " commits=" << total_commits_;
  for (size_t i = 0; i < commit_width_hist_.size(); i++) {
    std::cout << " width" << i << "=" << commit_width_hist_[i];
  }
  std::cout << "\n";
  std::cout << "[controlm] branch_count=" << control_branch_count_
            << " jal_count=" << control_jal_count_
            << " jalr_count=" << control_jalr_count_
            << " branch_taken_count=" << control_branch_taken_count_
            << " call_count=" << control_call_count_
            << " ret_count=" << control_ret_count_
            << " control_count=" << (control_branch_count_ + control_jal_count_ + control_jalr_count_)
            << "\n";
  std::cout << "[stallm] mode=cycle"
            << " stall_total_cycles=" << stall_total_cycles
            << " flush_recovery=" << stall_cycle_hist_[kStallFlushRecovery]
            << " icache_miss_wait=" << stall_cycle_hist_[kStallICacheMissWait]
            << " dcache_miss_wait=" << stall_cycle_hist_[kStallDCacheMissWait]
            << " rob_backpressure=" << stall_cycle_hist_[kStallROBBackpressure]
            << " frontend_empty=" << stall_cycle_hist_[kStallFrontendEmpty]
            << " decode_blocked=" << stall_cycle_hist_[kStallDecodeBlocked]
            << " lsu_req_blocked=" << stall_cycle_hist_[kStallLSUReqBlocked]
            << " other=" << stall_cycle_hist_[kStallOther]
            << "\n";

  uint64_t fe_no_req_total = stall_frontend_empty_hist_[kFeNoReq] +
                             stall_frontend_empty_hist_[kFeNoReqReqQEmpty] +
                             stall_frontend_empty_hist_[kFeNoReqInfFull] +
                             stall_frontend_empty_hist_[kFeNoReqStorageBudget] +
                             stall_frontend_empty_hist_[kFeNoReqFlushBlock] +
                             stall_frontend_empty_hist_[kFeNoReqOther];
  std::cout << "[stallm2] mode=cycle"
            << " frontend_empty_total=" << stall_cycle_hist_[kStallFrontendEmpty]
            << " fe_no_req=" << fe_no_req_total
            << " fe_wait_icache_rsp_hit_latency=" << stall_frontend_empty_hist_[kFeWaitICacheRspHitLatency]
            << " fe_wait_icache_rsp_miss_wait=" << stall_frontend_empty_hist_[kFeWaitICacheRspMissWait]
            << " fe_rsp_blocked_by_fq_full=" << stall_frontend_empty_hist_[kFeRspBlockedByFQFull]
            << " fe_wait_ibuffer_consume=" << stall_frontend_empty_hist_[kFeWaitIbufferConsume]
            << " fe_redirect_recovery=" << stall_frontend_empty_hist_[kFeRedirectRecovery]
            << " fe_rsp_capture_bubble=" << stall_frontend_empty_hist_[kFeRspCaptureBubble]
            << " fe_has_data_decode_gap=" << stall_frontend_empty_hist_[kFeHasDataDecodeGap]
            << " fe_drop_stale_rsp=" << stall_frontend_empty_hist_[kFeDropStaleRsp]
            << " fe_no_req_reqq_empty=" << stall_frontend_empty_hist_[kFeNoReqReqQEmpty]
            << " fe_no_req_inf_full=" << stall_frontend_empty_hist_[kFeNoReqInfFull]
            << " fe_no_req_storage_budget=" << stall_frontend_empty_hist_[kFeNoReqStorageBudget]
            << " fe_no_req_flush_block=" << stall_frontend_empty_hist_[kFeNoReqFlushBlock]
            << " fe_no_req_other=" << stall_frontend_empty_hist_[kFeNoReqOther]
            << " fe_req_fire_no_inflight=" << stall_frontend_empty_hist_[kFeReqFireNoInflight]
            << " fe_rsp_no_inflight=" << stall_frontend_empty_hist_[kFeRspNoInflight]
            << " fe_fq_nonempty_no_fevalid=" << stall_frontend_empty_hist_[kFeFQNonemptyNoFeValid]
            << " fe_req_ready_nofire=" << stall_frontend_empty_hist_[kFeReqReadyNoFire]
            << " fe_other=" << stall_frontend_empty_hist_[kFeOther]
            << "\n";

  uint64_t fq_samples = final_cycles;
  uint64_t fq_occ_avg_x1000 =
      (fq_samples == 0) ? 0 : ((ifu_fq_occ_sum_ * 1000ull + fq_samples / 2ull) / fq_samples);
  std::cout << "[ifum] mode=cycle"
            << " fq_samples=" << fq_samples
            << " fq_enq=" << ifu_fq_enq_
            << " fq_deq=" << ifu_fq_deq_
            << " fq_bypass=" << ifu_fq_bypass_
            << " fq_enq_blocked=" << ifu_fq_enq_blocked_
            << " fq_full_cycles=" << ifu_fq_full_cycles_
            << " fq_empty_cycles=" << ifu_fq_empty_cycles_
            << " fq_nonempty_cycles=" << ifu_fq_nonempty_cycles_
            << " fq_occ_sum=" << ifu_fq_occ_sum_
            << " fq_occ_max=" << ifu_fq_occ_max_
            << " fq_occ_avg_x1000=" << fq_occ_avg_x1000;
  for (size_t i = 0; i < ifu_fq_occ_hist_.size(); i++) {
    std::cout << " fq_occ_bin" << i << "=" << ifu_fq_occ_hist_[i];
  }
  std::cout << "\n";

  emit_detail_summary("stallm3", "decode_blocked_total", stall_cycle_hist_[kStallDecodeBlocked],
                      stall_decode_blocked_detail_hist_);
  emit_detail_summary("stallm4", "rob_backpressure_total", stall_cycle_hist_[kStallROBBackpressure],
                      stall_rob_backpressure_detail_hist_);
  emit_detail_summary("stallm5", "other_total", stall_cycle_hist_[kStallOther], stall_other_detail_hist_);
  std::cout << "[stallm6] mode=cycle"
            << " branch_ready_not_issued=" << branch_ready_not_issued_cycles_
            << " alu_ready_not_issued=" << alu_ready_not_issued_cycles_
            << " complete_not_visible_to_rob=" << complete_not_visible_cycles_
            << "\n";
  emit_ranked_summary("hotpcm", "pc", commit_pc_hist_);
  emit_ranked_summary("hotinstm", "inst", commit_inst_hist_);
}

void ProfileCollector::emit_pred_summary(const Vtb_triathlon *top) const {
  if (!profile_enabled()) return;

  uint64_t pred_cond_hit = (pred_cond_total_ >= pred_cond_miss_) ? (pred_cond_total_ - pred_cond_miss_) : 0;
  uint64_t pred_jump_hit = (pred_jump_total_ >= pred_jump_miss_) ? (pred_jump_total_ - pred_jump_miss_) : 0;
  uint64_t pred_jump_direct_hit = (pred_jump_direct_total_ >= pred_jump_direct_miss_)
                                      ? (pred_jump_direct_total_ - pred_jump_direct_miss_)
                                      : 0;
  uint64_t pred_jump_indirect_hit = (pred_jump_indirect_total_ >= pred_jump_indirect_miss_)
                                        ? (pred_jump_indirect_total_ - pred_jump_indirect_miss_)
                                        : 0;
  uint64_t pred_ret_hit = (pred_ret_total_ >= pred_ret_miss_) ? (pred_ret_total_ - pred_ret_miss_) : 0;
  const uint64_t redirect_total = mispredict_flush_count_;

  uint64_t cond_update_total = static_cast<uint64_t>(top->dbg_bpu_cond_update_total_o);
  uint64_t cond_local_correct = static_cast<uint64_t>(top->dbg_bpu_cond_local_correct_o);
  uint64_t cond_global_correct = static_cast<uint64_t>(top->dbg_bpu_cond_global_correct_o);
  uint64_t cond_selected_correct = static_cast<uint64_t>(top->dbg_bpu_cond_selected_correct_o);
  uint64_t cond_choose_local = static_cast<uint64_t>(top->dbg_bpu_cond_choose_local_o);
  uint64_t cond_choose_global = static_cast<uint64_t>(top->dbg_bpu_cond_choose_global_o);
  uint64_t tage_lookup_total = static_cast<uint64_t>(top->dbg_bpu_tage_lookup_total_o);
  uint64_t tage_hit_total = static_cast<uint64_t>(top->dbg_bpu_tage_hit_total_o);
  uint64_t tage_override_total = static_cast<uint64_t>(top->dbg_bpu_tage_override_total_o);
  uint64_t tage_override_correct = static_cast<uint64_t>(top->dbg_bpu_tage_override_correct_o);
  uint64_t sc_lookup_total = static_cast<uint64_t>(top->dbg_bpu_sc_lookup_total_o);
  uint64_t sc_confident_total = static_cast<uint64_t>(top->dbg_bpu_sc_confident_total_o);
  uint64_t sc_override_total = static_cast<uint64_t>(top->dbg_bpu_sc_override_total_o);
  uint64_t sc_override_correct = static_cast<uint64_t>(top->dbg_bpu_sc_override_correct_o);
  uint64_t loop_lookup_total = static_cast<uint64_t>(top->dbg_bpu_loop_lookup_total_o);
  uint64_t loop_hit_total = static_cast<uint64_t>(top->dbg_bpu_loop_hit_total_o);
  uint64_t loop_confident_total = static_cast<uint64_t>(top->dbg_bpu_loop_confident_total_o);
  uint64_t loop_override_total = static_cast<uint64_t>(top->dbg_bpu_loop_override_total_o);
  uint64_t loop_override_correct = static_cast<uint64_t>(top->dbg_bpu_loop_override_correct_o);
  uint64_t cond_provider_legacy_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_selected_o);
  uint64_t cond_provider_tage_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_selected_o);
  uint64_t cond_provider_sc_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_sc_selected_o);
  uint64_t cond_provider_loop_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_loop_selected_o);
  uint64_t cond_provider_legacy_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_correct_o);
  uint64_t cond_provider_tage_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_correct_o);
  uint64_t cond_provider_sc_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_sc_correct_o);
  uint64_t cond_provider_loop_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_loop_correct_o);
  uint64_t cond_selected_wrong_alt_legacy_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_legacy_correct_o);
  uint64_t cond_selected_wrong_alt_tage_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_tage_correct_o);
  uint64_t cond_selected_wrong_alt_sc_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_sc_correct_o);
  uint64_t cond_selected_wrong_alt_loop_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_loop_correct_o);
  uint64_t cond_selected_wrong_alt_any_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_any_correct_o);

  std::ios::fmtflags f(std::cout.flags());
  std::cout << "[pred  ] redirect_total=" << redirect_total
            << " cond_total=" << pred_cond_total_
            << " cond_miss=" << pred_cond_miss_
            << " cond_hit=" << pred_cond_hit
            << " jump_total=" << pred_jump_total_
            << " jump_miss=" << pred_jump_miss_
            << " jump_hit=" << pred_jump_hit
            << " jump_miss_redirect_rate="
            << (redirect_total ? static_cast<double>(pred_jump_miss_) / static_cast<double>(redirect_total) : 0.0)
            << " jump_direct_total=" << pred_jump_direct_total_
            << " jump_direct_miss=" << pred_jump_direct_miss_
            << " jump_direct_hit=" << pred_jump_direct_hit
            << " jump_indirect_total=" << pred_jump_indirect_total_
            << " jump_indirect_miss=" << pred_jump_indirect_miss_
            << " jump_indirect_hit=" << pred_jump_indirect_hit
            << " ret_total=" << pred_ret_total_
            << " ret_miss=" << pred_ret_miss_
            << " ret_hit=" << pred_ret_hit
            << " call_total=" << pred_call_total_
            << " cond_update_total=" << cond_update_total
            << " cond_local_correct=" << cond_local_correct
            << " cond_global_correct=" << cond_global_correct
            << " cond_selected_correct=" << cond_selected_correct
            << " cond_choose_local=" << cond_choose_local
            << " cond_choose_global=" << cond_choose_global
            << " tage_lookup_total=" << tage_lookup_total
            << " tage_hit_total=" << tage_hit_total
            << " tage_override_total=" << tage_override_total
            << " tage_override_correct=" << tage_override_correct
            << " sc_lookup_total=" << sc_lookup_total
            << " sc_confident_total=" << sc_confident_total
            << " sc_override_total=" << sc_override_total
            << " sc_override_correct=" << sc_override_correct
            << " loop_lookup_total=" << loop_lookup_total
            << " loop_hit_total=" << loop_hit_total
            << " loop_confident_total=" << loop_confident_total
            << " loop_override_total=" << loop_override_total
            << " loop_override_correct=" << loop_override_correct
            << " cond_provider_legacy_selected=" << cond_provider_legacy_selected
            << " cond_provider_tage_selected=" << cond_provider_tage_selected
            << " cond_provider_sc_selected=" << cond_provider_sc_selected
            << " cond_provider_loop_selected=" << cond_provider_loop_selected
            << " cond_provider_legacy_correct=" << cond_provider_legacy_correct
            << " cond_provider_tage_correct=" << cond_provider_tage_correct
            << " cond_provider_sc_correct=" << cond_provider_sc_correct
            << " cond_provider_loop_correct=" << cond_provider_loop_correct
            << " cond_selected_wrong_alt_legacy_correct=" << cond_selected_wrong_alt_legacy_correct
            << " cond_selected_wrong_alt_tage_correct=" << cond_selected_wrong_alt_tage_correct
            << " cond_selected_wrong_alt_sc_correct=" << cond_selected_wrong_alt_sc_correct
            << " cond_selected_wrong_alt_loop_correct=" << cond_selected_wrong_alt_loop_correct
            << " cond_selected_wrong_alt_any_correct=" << cond_selected_wrong_alt_any_correct
            << "\n";
  std::cout << "[flushm] wrong_path_killed_uops=" << wrong_path_killed_uops_
            << " redirect_distance_samples=" << redirect_distance_samples_
            << " redirect_distance_sum=" << redirect_distance_sum_
            << " redirect_distance_max=" << redirect_distance_max_
            << " mispredict_diag_dir_wrong=" << mispredict_diag_dir_wrong_
            << " mispredict_diag_dir_ok_target_wrong=" << mispredict_diag_dir_ok_target_wrong_
            << " mispredict_diag_slot_offset_bind=" << mispredict_diag_slot_offset_bind_
            << " mispredict_diag_ftb_no_entry_tag_miss=" << mispredict_diag_ftb_no_entry_tag_miss_
            << " mispredict_diag_ftb_hit_cond_nt=" << mispredict_diag_ftb_hit_cond_nt_
            << " mispredict_diag_ftb_hit_out_of_range=" << mispredict_diag_ftb_hit_out_of_range_
            << " mispredict_diag_ftb_hit_shadowed=" << mispredict_diag_ftb_hit_shadowed_
            << " mispredict_diag_ftb_snap_epoch_mismatch=" << mispredict_diag_ftb_snap_epoch_mismatch_
            << " mispredict_diag_ftb_hit_out_of_range_epoch_ok="
            << mispredict_diag_ftb_hit_out_of_range_epoch_ok_
            << " mispredict_diag_ftb_hit_shadowed_epoch_ok=" << mispredict_diag_ftb_hit_shadowed_epoch_ok_
            << " mispredict_diag_ftb_unclassified=" << mispredict_diag_ftb_unclassified_
            << " mispredict_diag_other=" << mispredict_diag_other_
            << " mispredict_diag_no_commit_slot=" << mispredict_diag_no_commit_slot_
            << "\n";
  std::cout.flags(f);
}

void ProfileCollector::emit_ranked_summary(
    const char *tag,
    const char *value_key,
    const std::unordered_map<uint32_t, uint64_t> &hist) const {
  std::vector<std::pair<uint32_t, uint64_t>> items(hist.begin(), hist.end());
  std::sort(items.begin(), items.end(), [](const auto &a, const auto &b) {
    if (a.second != b.second) return a.second > b.second;
    return a.first < b.first;
  });

  std::ios::fmtflags f(std::cout.flags());
  std::cout << "[" << tag << "]";
  const size_t limit = std::min<size_t>(5, items.size());
  for (size_t i = 0; i < limit; i++) {
    std::cout << " rank" << i << "_" << value_key << "=0x" << std::hex << items[i].first
              << std::dec << " rank" << i << "_count=" << items[i].second;
  }
  std::cout << "\n";
  std::cout.flags(f);
}

void ProfileCollector::emit_detail_summary(
    const char *tag,
    const char *total_key,
    uint64_t total,
    const std::unordered_map<std::string, uint64_t> &hist) const {
  std::vector<std::pair<std::string, uint64_t>> items(hist.begin(), hist.end());
  std::sort(items.begin(), items.end(), [](const auto &a, const auto &b) {
    if (a.first != b.first) return a.first < b.first;
    return a.second > b.second;
  });
  std::cout << "[" << tag << "] mode=cycle " << total_key << "=" << total;
  for (const auto &kv : items) {
    std::cout << " " << kv.first << "=" << kv.second;
  }
  std::cout << "\n";
}

}  // namespace npc
