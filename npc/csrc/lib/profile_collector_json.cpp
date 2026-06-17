#include "profile_collector.h"

#include "Vtb_triathlon.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <vector>

namespace npc {

namespace {

double safe_div(double numer, double denom) {
  return denom == 0.0 ? 0.0 : numer / denom;
}

std::string json_escape(const std::string &s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default: out += c; break;
    }
  }
  return out;
}

void append_str_map(std::ostringstream &os,
                    const std::unordered_map<std::string, uint64_t> &m) {
  bool first = true;
  os << "{";
  std::vector<std::pair<std::string, uint64_t>> items(m.begin(), m.end());
  std::sort(items.begin(), items.end(),
            [](const auto &a, const auto &b) { return a.first < b.first; });
  for (const auto &kv : items) {
    if (!first) os << ",";
    first = false;
    os << "\"" << json_escape(kv.first) << "\":" << kv.second;
  }
  os << "}";
}

void append_uint_map(std::ostringstream &os, const std::unordered_map<uint32_t, uint64_t> &m) {
  std::vector<std::pair<uint32_t, uint64_t>> items(m.begin(), m.end());
  std::sort(items.begin(), items.end(),
            [](const auto &a, const auto &b) { return a.first < b.first; });
  os << "{";
  bool first = true;
  for (const auto &kv : items) {
    if (!first) os << ",";
    first = false;
    os << "\"" << kv.first << "\":" << kv.second;
  }
  os << "}";
}

void append_top_uint(std::ostringstream &os,
                     const std::unordered_map<uint32_t, uint64_t> &hist,
                     const char *field_name) {
  std::vector<std::pair<uint32_t, uint64_t>> items(hist.begin(), hist.end());
  std::sort(items.begin(), items.end(), [](const auto &a, const auto &b) {
    if (a.second != b.second) return a.second > b.second;
    return a.first < b.first;
  });
  os << "[";
  const size_t limit = std::min<size_t>(64, items.size());
  for (size_t i = 0; i < limit; i++) {
    if (i > 0) os << ",";
    os << "{\"" << field_name << "\":\"0x" << std::hex << items[i].first << std::dec
       << "\",\"count\":" << items[i].second << "}";
  }
  os << "]";
}

const char *frontend_empty_detail_key(int idx) {
  static const char *kKeys[] = {
      "fe_no_req",
      "fe_wait_icache_rsp_hit_latency",
      "fe_wait_icache_rsp_miss_wait",
      "fe_rsp_blocked_by_fq_full",
      "fe_wait_ibuffer_consume",
      "fe_redirect_recovery",
      "fe_rsp_capture_bubble",
      "fe_has_data_decode_gap",
      "fe_other",
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
  };
  if (idx < 0 || idx >= static_cast<int>(sizeof(kKeys) / sizeof(kKeys[0]))) {
    return "fe_unknown";
  }
  return kKeys[idx];
}

}  // namespace

void ProfileCollector::emit_summary_json(uint64_t final_cycles, const Vtb_triathlon *top) {
  if (args_.profile_json_path.empty()) return;

  const uint64_t cycles = final_cycles;
  const uint64_t commits = total_commits_;
  const double ipc = safe_div(static_cast<double>(commits), static_cast<double>(cycles));
  const double cpi = safe_div(static_cast<double>(cycles), static_cast<double>(commits));

  uint64_t stall_total = 0;
  for (uint64_t v : stall_cycle_hist_) stall_total += v;

  static const char *kStallKeys[] = {
      "flush_recovery",     "icache_miss_wait", "dcache_miss_wait", "rob_backpressure",
      "frontend_empty",     "decode_blocked",   "lsu_req_blocked",  "other",
  };

  const uint64_t pred_cond_hit =
      pred_cond_total_ >= pred_cond_miss_ ? pred_cond_total_ - pred_cond_miss_ : 0;
  const uint64_t pred_jump_hit =
      pred_jump_total_ >= pred_jump_miss_ ? pred_jump_total_ - pred_jump_miss_ : 0;
  const uint64_t pred_jump_direct_hit = pred_jump_direct_total_ >= pred_jump_direct_miss_
                                            ? pred_jump_direct_total_ - pred_jump_direct_miss_
                                            : 0;
  const uint64_t pred_jump_indirect_hit =
      pred_jump_indirect_total_ >= pred_jump_indirect_miss_
          ? pred_jump_indirect_total_ - pred_jump_indirect_miss_
          : 0;
  const uint64_t pred_ret_hit = pred_ret_total_ >= pred_ret_miss_ ? pred_ret_total_ - pred_ret_miss_ : 0;
  // jump_*_miss 在 flush/redirect 时累计；miss_rate 分母用 mispredict redirect 总数，避免相对 commit 口径 >100%。
  const uint64_t redirect_total = mispredict_flush_count_;

  const uint64_t cond_update_total = static_cast<uint64_t>(top->dbg_bpu_cond_update_total_o);
  const uint64_t cond_local_correct = static_cast<uint64_t>(top->dbg_bpu_cond_local_correct_o);
  const uint64_t cond_global_correct = static_cast<uint64_t>(top->dbg_bpu_cond_global_correct_o);
  const uint64_t cond_selected_correct = static_cast<uint64_t>(top->dbg_bpu_cond_selected_correct_o);
  const uint64_t cond_choose_local = static_cast<uint64_t>(top->dbg_bpu_cond_choose_local_o);
  const uint64_t cond_choose_global = static_cast<uint64_t>(top->dbg_bpu_cond_choose_global_o);
  const uint64_t tage_lookup_total = static_cast<uint64_t>(top->dbg_bpu_tage_lookup_total_o);
  const uint64_t tage_hit_total = static_cast<uint64_t>(top->dbg_bpu_tage_hit_total_o);
  const uint64_t tage_override_total = static_cast<uint64_t>(top->dbg_bpu_tage_override_total_o);
  const uint64_t tage_override_correct = static_cast<uint64_t>(top->dbg_bpu_tage_override_correct_o);
  const uint64_t sc_lookup_total = static_cast<uint64_t>(top->dbg_bpu_sc_lookup_total_o);
  const uint64_t sc_confident_total = static_cast<uint64_t>(top->dbg_bpu_sc_confident_total_o);
  const uint64_t sc_override_total = static_cast<uint64_t>(top->dbg_bpu_sc_override_total_o);
  const uint64_t sc_override_correct = static_cast<uint64_t>(top->dbg_bpu_sc_override_correct_o);
  const uint64_t loop_lookup_total = static_cast<uint64_t>(top->dbg_bpu_loop_lookup_total_o);
  const uint64_t loop_hit_total = static_cast<uint64_t>(top->dbg_bpu_loop_hit_total_o);
  const uint64_t loop_confident_total = static_cast<uint64_t>(top->dbg_bpu_loop_confident_total_o);
  const uint64_t loop_override_total = static_cast<uint64_t>(top->dbg_bpu_loop_override_total_o);
  const uint64_t loop_override_correct = static_cast<uint64_t>(top->dbg_bpu_loop_override_correct_o);

  const uint64_t ftb_lookup_total = static_cast<uint64_t>(top->dbg_bpu_ftb_lookup_total_o);
  const uint64_t ftb_cond_hit_total = static_cast<uint64_t>(top->dbg_bpu_ftb_cond_hit_total_o);
  const uint64_t ftb_jump_hit_total = static_cast<uint64_t>(top->dbg_bpu_ftb_jump_hit_total_o);
  const uint64_t ftb_cond_pick_total = static_cast<uint64_t>(top->dbg_bpu_ftb_cond_pick_total_o);
  const uint64_t ftb_jump_pick_total = static_cast<uint64_t>(top->dbg_bpu_ftb_jump_pick_total_o);
  const uint64_t ftb_cond_tag_miss_total = static_cast<uint64_t>(top->dbg_bpu_ftb_cond_tag_miss_total_o);
  const uint64_t ftb_jump_tag_miss_total = static_cast<uint64_t>(top->dbg_bpu_ftb_jump_tag_miss_total_o);
  const uint64_t ftb_train_cond_total = static_cast<uint64_t>(top->dbg_bpu_ftb_train_cond_total_o);
  const uint64_t ftb_train_jump_total = static_cast<uint64_t>(top->dbg_bpu_ftb_train_jump_total_o);
  const uint64_t ittage_lookup_total = static_cast<uint64_t>(top->dbg_bpu_ittage_lookup_total_o);
  const uint64_t ittage_hit_total = static_cast<uint64_t>(top->dbg_bpu_ittage_hit_total_o);
  const uint64_t ittage_use_total = static_cast<uint64_t>(top->dbg_bpu_ittage_use_total_o);
  const uint64_t ittage_train_total = static_cast<uint64_t>(top->dbg_bpu_ittage_train_total_o);
  const uint64_t cond_provider_legacy_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_selected_o);
  const uint64_t cond_provider_tage_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_selected_o);
  const uint64_t cond_provider_sc_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_sc_selected_o);
  const uint64_t cond_provider_loop_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_loop_selected_o);
  const uint64_t cond_provider_legacy_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_correct_o);
  const uint64_t cond_provider_tage_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_correct_o);
  const uint64_t cond_provider_sc_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_sc_correct_o);
  const uint64_t cond_provider_loop_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_loop_correct_o);
  const uint64_t cond_selected_wrong_alt_legacy_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_legacy_correct_o);
  const uint64_t cond_selected_wrong_alt_tage_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_tage_correct_o);
  const uint64_t cond_selected_wrong_alt_sc_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_sc_correct_o);
  const uint64_t cond_selected_wrong_alt_loop_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_loop_correct_o);
  const uint64_t cond_selected_wrong_alt_any_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_any_correct_o);

  const uint64_t control_total =
      control_branch_count_ + control_jal_count_ + control_jalr_count_;
  const uint64_t fq_samples = cycles;
  const uint64_t fq_nonempty_cycles =
      ifu_fq_nonempty_cycles_ > 0 ? ifu_fq_nonempty_cycles_
                                 : (fq_samples > ifu_fq_empty_cycles_ ? fq_samples - ifu_fq_empty_cycles_ : 0);

  std::ostringstream os;
  os << std::fixed << std::setprecision(6);
  os << "{";
  os << "\"log_path\":\"" << json_escape(args_.profile_json_path) << "\",";
  os << "\"ipc\":" << ipc << ",\"cpi\":" << cpi << ",\"cycles\":" << cycles
     << ",\"commits\":" << commits << ",";
  os << "\"flush_count\":" << flush_count_ << ",\"bru_count\":" << bru_count_
     << ",\"mispredict_flush_count\":" << mispredict_flush_count_
     << ",\"mispredict_cond_count\":" << pred_cond_miss_
     << ",\"mispredict_jump_count\":" << pred_jump_miss_
     << ",\"mispredict_jump_direct_count\":" << pred_jump_direct_miss_
     << ",\"mispredict_jump_indirect_count\":" << pred_jump_indirect_miss_
     << ",\"mispredict_ret_count\":" << pred_ret_miss_ << ",";
  os << "\"mispredict_breakdown\":{";
  os << "\"cond_branch\":" << pred_cond_miss_ << ",\"jump_direct\":" << pred_jump_direct_miss_
     << ",\"jump_indirect\":" << pred_jump_indirect_miss_ << ",\"jump\":" << pred_jump_miss_
     << ",\"return\":" << pred_ret_miss_ << "},";
  const uint64_t mispredict_diag_ftb_miss =
      mispredict_diag_ftb_no_entry_tag_miss_ + mispredict_diag_ftb_hit_cond_nt_ +
      mispredict_diag_ftb_hit_out_of_range_ + mispredict_diag_ftb_hit_shadowed_ +
      mispredict_diag_ftb_unclassified_;
  const uint64_t mispredict_diag_classified =
      mispredict_diag_dir_wrong_ + mispredict_diag_dir_ok_target_wrong_ +
      mispredict_diag_slot_offset_bind_ + mispredict_diag_ftb_miss + mispredict_diag_other_;
  os << "\"mispredict_diag\":{";
  os << "\"dir_wrong\":" << mispredict_diag_dir_wrong_
     << ",\"dir_ok_target_wrong\":" << mispredict_diag_dir_ok_target_wrong_
     << ",\"slot_offset_bind\":" << mispredict_diag_slot_offset_bind_
     << ",\"ftb_no_entry_tag_miss\":" << mispredict_diag_ftb_no_entry_tag_miss_
     << ",\"ftb_hit_cond_nt\":" << mispredict_diag_ftb_hit_cond_nt_
     << ",\"ftb_hit_out_of_range\":" << mispredict_diag_ftb_hit_out_of_range_
     << ",\"ftb_hit_shadowed\":" << mispredict_diag_ftb_hit_shadowed_
     << ",\"ftb_snap_epoch_mismatch\":" << mispredict_diag_ftb_snap_epoch_mismatch_
     << ",\"ftb_hit_out_of_range_epoch_ok\":" << mispredict_diag_ftb_hit_out_of_range_epoch_ok_
     << ",\"ftb_hit_shadowed_epoch_ok\":" << mispredict_diag_ftb_hit_shadowed_epoch_ok_
     << ",\"ftb_unclassified\":" << mispredict_diag_ftb_unclassified_
     << ",\"ftb_miss\":" << mispredict_diag_ftb_miss
     << ",\"other\":" << mispredict_diag_other_
     << ",\"no_commit_slot\":" << mispredict_diag_no_commit_slot_
     << ",\"classified_total\":" << mispredict_diag_classified
     << ",\"dir_wrong_rate\":" << safe_div(static_cast<double>(mispredict_diag_dir_wrong_),
                                           static_cast<double>(mispredict_flush_count_))
     << ",\"dir_ok_target_wrong_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_dir_ok_target_wrong_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"slot_offset_bind_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_slot_offset_bind_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_no_entry_tag_miss_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_no_entry_tag_miss_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_hit_cond_nt_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_hit_cond_nt_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_hit_out_of_range_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_hit_out_of_range_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_hit_shadowed_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_hit_shadowed_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_snap_epoch_mismatch_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_snap_epoch_mismatch_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_hit_out_of_range_epoch_ok_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_hit_out_of_range_epoch_ok_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_hit_shadowed_epoch_ok_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_hit_shadowed_epoch_ok_),
                static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_miss_rate\":"
     << safe_div(static_cast<double>(mispredict_diag_ftb_miss),
                static_cast<double>(mispredict_flush_count_));
  os << ",\"ftb_oor_block_byte_off\":";
  append_uint_map(os, mispredict_diag_ftb_oor_block_byte_off_hist_);
  os << ",\"ftb_oor_kind\":";
  append_str_map(os, mispredict_diag_ftb_oor_kind_hist_);
  os << ",\"ftb_oor_snap_pc_top\":";
  append_top_uint(os, mispredict_diag_ftb_oor_snap_pc_hist_, "pc");
  os << ",\"ftb_oor_branch_pc_top\":";
  append_top_uint(os, mispredict_diag_ftb_oor_branch_pc_hist_, "pc");
  os << ",\"ftb_no_entry_block_byte_off\":";
  append_uint_map(os, mispredict_diag_ftb_no_entry_block_byte_off_hist_);
  os << ",\"ftb_no_entry_fetch_rel\":";
  append_uint_map(os, mispredict_diag_ftb_no_entry_fetch_rel_hist_);
  os << ",\"ftb_no_entry_fetch_byte_off\":";
  append_uint_map(os, mispredict_diag_ftb_no_entry_fetch_byte_off_hist_);
  os << ",\"ftb_no_entry_block_delta\":";
  append_str_map(os, mispredict_diag_ftb_no_entry_block_delta_hist_);
  os << ",\"ftb_no_entry_valid_count\":";
  append_uint_map(os, mispredict_diag_ftb_no_entry_valid_count_hist_);
  os << ",\"ftb_no_entry_cond_count\":";
  append_uint_map(os, mispredict_diag_ftb_no_entry_cond_count_hist_);
  os << ",\"ftb_no_entry_jump_count\":";
  append_uint_map(os, mispredict_diag_ftb_no_entry_jump_count_hist_);
  os << ",\"ftb_no_entry_kind\":";
  append_str_map(os, mispredict_diag_ftb_no_entry_kind_hist_);
  os << ",\"ftb_no_entry_cause\":";
  append_str_map(os, mispredict_diag_ftb_no_entry_cause_hist_);
  os << ",\"ftb_no_entry_fetch_pc_top\":";
  append_top_uint(os, mispredict_diag_ftb_no_entry_fetch_pc_hist_, "pc");
  os << ",\"ftb_no_entry_branch_pc_top\":";
  append_top_uint(os, mispredict_diag_ftb_no_entry_branch_pc_hist_, "pc");
  os << ",\"bpu_taken_control_pc_top\":";
  append_top_uint(os, bpu_taken_control_pc_hist_, "pc");
  os << ",\"bpu_update_pc_top\":";
  append_top_uint(os, bpu_update_pc_hist_, "pc");
  os << ",\"bpu_update_kind\":";
  append_str_map(os, bpu_update_kind_hist_);
  os << "},";
  os << "\"branch_penalty_cycles\":" << branch_penalty_cycles_
     << ",\"wrong_path_kill_uops\":" << wrong_path_killed_uops_
     << ",\"redirect_distance_sum\":" << redirect_distance_sum_
     << ",\"redirect_distance_samples\":" << redirect_distance_samples_
     << ",\"redirect_distance_avg\":" << safe_div(static_cast<double>(redirect_distance_sum_),
                                                  static_cast<double>(redirect_distance_samples_))
     << ",\"redirect_distance_max\":" << redirect_distance_max_ << ",";
  os << "\"flush_reason_histogram\":";
  append_str_map(os, flush_reason_hist_);
  os << ",\"flush_source_histogram\":";
  append_str_map(os, flush_source_hist_);
  os << ",\"flush_per_kinst\":" << safe_div(static_cast<double>(flush_count_) * 1000.0, static_cast<double>(commits))
     << ",\"bru_per_kinst\":" << safe_div(static_cast<double>(bru_count_) * 1000.0, static_cast<double>(commits))
     << ",";

  os << "\"commit_width_hist\":{";
  for (size_t i = 0; i < commit_width_hist_.size(); i++) {
    if (i > 0) os << ",";
    os << "\"" << i << "\":" << commit_width_hist_[i];
  }
  os << "},";

  os << "\"stall_category\":{";
  for (int i = 0; i < 8; i++) {
    if (i > 0) os << ",";
    os << "\"" << kStallKeys[i] << "\":" << stall_cycle_hist_[static_cast<size_t>(i)];
  }
  os << "},\"stall_total\":" << stall_total << ",\"stall_post_flush_window_cycles\":16,";
  os << "\"stall_decode_blocked_total\":" << stall_cycle_hist_[kStallDecodeBlocked] << ",";
  os << "\"stall_decode_blocked_post_flush\":0,\"stall_decode_blocked_post_flush_ratio\":0,";
  os << "\"stall_decode_blocked_post_branch_flush\":0,\"stall_decode_blocked_post_branch_flush_ratio\":0,";
  os << "\"stall_decode_blocked_detail\":";
  append_str_map(os, stall_decode_blocked_detail_hist_);
  os << ",\"stall_rob_backpressure_total\":" << stall_cycle_hist_[kStallROBBackpressure] << ",";
  os << "\"stall_rob_backpressure_detail\":";
  append_str_map(os, stall_rob_backpressure_detail_hist_);
  os << ",\"stall_other_total\":" << stall_cycle_hist_[kStallOther] << ",";
  os << "\"stall_other_detail\":";
  append_str_map(os, stall_other_detail_hist_);
  os << ",\"stall_other_aux\":{";
  os << "\"branch_ready_not_issued\":" << branch_ready_not_issued_cycles_
     << ",\"alu_ready_not_issued\":" << alu_ready_not_issued_cycles_
     << ",\"complete_not_visible_to_rob\":" << complete_not_visible_cycles_ << "},";
  os << "\"stall_frontend_empty_total\":" << stall_cycle_hist_[kStallFrontendEmpty] << ",";
  os << "\"stall_frontend_empty_detail\":{";
  bool fe_first = true;
  for (size_t i = 0; i < stall_frontend_empty_hist_.size(); i++) {
    if (stall_frontend_empty_hist_[i] == 0) continue;
    if (!fe_first) os << ",";
    fe_first = false;
    os << "\"" << frontend_empty_detail_key(static_cast<int>(i)) << "\":"
       << stall_frontend_empty_hist_[i];
  }
  os << "},";

  os << "\"ifu_fq\":{";
  os << "\"fq_samples\":" << fq_samples << ",\"fq_enq\":" << ifu_fq_enq_
     << ",\"fq_deq\":" << ifu_fq_deq_ << ",\"fq_bypass\":" << ifu_fq_bypass_
     << ",\"fq_enq_blocked\":" << ifu_fq_enq_blocked_ << ",\"fq_full_cycles\":" << ifu_fq_full_cycles_
     << ",\"fq_empty_cycles\":" << ifu_fq_empty_cycles_
     << ",\"fq_nonempty_cycles\":" << fq_nonempty_cycles << ",\"fq_occ_sum\":" << ifu_fq_occ_sum_
     << ",\"fq_occ_max\":" << ifu_fq_occ_max_
     << ",\"fq_occ_avg\":" << safe_div(static_cast<double>(ifu_fq_occ_sum_),
                                        static_cast<double>(fq_samples))
     << ",\"fq_bypass_ratio\":" << safe_div(static_cast<double>(ifu_fq_bypass_),
                                             static_cast<double>(ifu_fq_deq_))
     << ",\"fq_enq_blocked_ratio\":" << safe_div(static_cast<double>(ifu_fq_enq_blocked_),
                                                 static_cast<double>(fq_samples))
     << ",\"fq_full_ratio\":" << safe_div(static_cast<double>(ifu_fq_full_cycles_),
                                           static_cast<double>(fq_samples))
     << ",\"fq_empty_ratio\":" << safe_div(static_cast<double>(ifu_fq_empty_cycles_),
                                            static_cast<double>(fq_samples))
     << ",\"fq_nonempty_ratio\":" << safe_div(static_cast<double>(fq_nonempty_cycles),
                                               static_cast<double>(fq_samples))
     << "},";

  os << "\"top_pc\":";
  append_top_uint(os, commit_pc_hist_, "pc");
  os << ",\"top_inst\":";
  append_top_uint(os, commit_inst_hist_, "inst");
  os << ",";

  os << "\"control\":{";
  os << "\"branch_count\":" << control_branch_count_ << ",\"jal_count\":" << control_jal_count_
     << ",\"jalr_count\":" << control_jalr_count_
     << ",\"branch_taken_count\":" << control_branch_taken_count_
     << ",\"call_count\":" << control_call_count_ << ",\"ret_count\":" << control_ret_count_
     << ",\"control_count\":" << control_total
     << ",\"control_ratio\":" << safe_div(static_cast<double>(control_total), static_cast<double>(commits))
     << "},";

  os << "\"predict\":{";
  os << "\"redirect_total\":" << redirect_total << ",";
  os << "\"cond_total\":" << pred_cond_total_ << ",\"cond_miss\":" << pred_cond_miss_
     << ",\"cond_hit\":" << pred_cond_hit
     << ",\"cond_miss_rate\":" << safe_div(static_cast<double>(pred_cond_miss_),
                                            static_cast<double>(pred_cond_total_))
     << ",\"jump_total\":" << pred_jump_total_ << ",\"jump_miss\":" << pred_jump_miss_
     << ",\"jump_hit\":" << pred_jump_hit
     << ",\"jump_miss_rate\":" << safe_div(static_cast<double>(pred_jump_miss_),
                                            static_cast<double>(redirect_total))
     << ",\"jump_direct_total\":" << pred_jump_direct_total_
     << ",\"jump_direct_miss\":" << pred_jump_direct_miss_
     << ",\"jump_direct_hit\":" << pred_jump_direct_hit
     << ",\"jump_direct_miss_rate\":"
     << safe_div(static_cast<double>(pred_jump_direct_miss_),
                 static_cast<double>(redirect_total))
     << ",\"jump_indirect_total\":" << pred_jump_indirect_total_
     << ",\"jump_indirect_miss\":" << pred_jump_indirect_miss_
     << ",\"jump_indirect_hit\":" << pred_jump_indirect_hit
     << ",\"jump_indirect_miss_rate\":"
     << safe_div(static_cast<double>(pred_jump_indirect_miss_),
                 static_cast<double>(redirect_total))
     << ",\"ret_total\":" << pred_ret_total_ << ",\"ret_miss\":" << pred_ret_miss_
     << ",\"ret_hit\":" << pred_ret_hit
     << ",\"ret_miss_rate\":" << safe_div(static_cast<double>(pred_ret_miss_),
                                           static_cast<double>(pred_ret_total_))
     << ",\"call_total\":" << pred_call_total_
     << ",\"cond_update_total\":" << cond_update_total
     << ",\"cond_local_correct\":" << cond_local_correct
     << ",\"cond_global_correct\":" << cond_global_correct
     << ",\"cond_selected_correct\":" << cond_selected_correct
     << ",\"cond_choose_local\":" << cond_choose_local
     << ",\"cond_choose_global\":" << cond_choose_global
     << ",\"cond_local_accuracy\":" << safe_div(static_cast<double>(cond_local_correct),
                                                static_cast<double>(cond_update_total))
     << ",\"cond_global_accuracy\":" << safe_div(static_cast<double>(cond_global_correct),
                                                 static_cast<double>(cond_update_total))
     << ",\"cond_selected_accuracy\":" << safe_div(static_cast<double>(cond_selected_correct),
                                                    static_cast<double>(cond_update_total))
     << ",\"tage_lookup_total\":" << tage_lookup_total << ",\"tage_hit_total\":" << tage_hit_total
     << ",\"tage_hit_rate\":" << safe_div(static_cast<double>(tage_hit_total),
                                           static_cast<double>(tage_lookup_total))
     << ",\"tage_override_total\":" << tage_override_total
     << ",\"tage_override_correct\":" << tage_override_correct
     << ",\"tage_override_accuracy\":"
     << safe_div(static_cast<double>(tage_override_correct),
                 static_cast<double>(tage_override_total))
     << ",\"sc_lookup_total\":" << sc_lookup_total << ",\"sc_confident_total\":" << sc_confident_total
     << ",\"sc_override_total\":" << sc_override_total
     << ",\"sc_override_correct\":" << sc_override_correct
     << ",\"sc_override_accuracy\":"
     << safe_div(static_cast<double>(sc_override_correct),
                 static_cast<double>(sc_override_total))
     << ",\"loop_lookup_total\":" << loop_lookup_total << ",\"loop_hit_total\":" << loop_hit_total
     << ",\"loop_confident_total\":" << loop_confident_total
     << ",\"loop_override_total\":" << loop_override_total
     << ",\"loop_override_correct\":" << loop_override_correct
     << ",\"loop_override_accuracy\":"
     << safe_div(static_cast<double>(loop_override_correct),
                 static_cast<double>(loop_override_total))
     << ",\"ftb\":{"
     << "\"lookup_total\":" << ftb_lookup_total
     << ",\"cond_hit_total\":" << ftb_cond_hit_total
     << ",\"cond_hit_rate\":"
     << safe_div(static_cast<double>(ftb_cond_hit_total), static_cast<double>(ftb_lookup_total))
     << ",\"jump_hit_total\":" << ftb_jump_hit_total
     << ",\"jump_hit_rate\":"
     << safe_div(static_cast<double>(ftb_jump_hit_total), static_cast<double>(ftb_lookup_total))
     << ",\"cond_pick_total\":" << ftb_cond_pick_total
     << ",\"cond_pick_rate\":"
     << safe_div(static_cast<double>(ftb_cond_pick_total), static_cast<double>(ftb_lookup_total))
     << ",\"jump_pick_total\":" << ftb_jump_pick_total
     << ",\"jump_pick_rate\":"
     << safe_div(static_cast<double>(ftb_jump_pick_total), static_cast<double>(ftb_lookup_total))
     << ",\"cond_tag_miss_total\":" << ftb_cond_tag_miss_total
     << ",\"jump_tag_miss_total\":" << ftb_jump_tag_miss_total
     << ",\"train_cond_total\":" << ftb_train_cond_total
     << ",\"train_jump_total\":" << ftb_train_jump_total
     << "},\"ittage\":{"
     << "\"lookup_total\":" << ittage_lookup_total
     << ",\"hit_total\":" << ittage_hit_total
     << ",\"hit_rate\":"
     << safe_div(static_cast<double>(ittage_hit_total), static_cast<double>(ittage_lookup_total))
     << ",\"use_total\":" << ittage_use_total
     << ",\"use_rate\":"
     << safe_div(static_cast<double>(ittage_use_total), static_cast<double>(ittage_lookup_total))
     << ",\"train_total\":" << ittage_train_total
     << "},\"cond_provider\":{"
     << "\"legacy_selected\":" << cond_provider_legacy_selected
     << ",\"legacy_correct\":" << cond_provider_legacy_correct
     << ",\"legacy_accuracy\":"
     << safe_div(static_cast<double>(cond_provider_legacy_correct),
                static_cast<double>(cond_provider_legacy_selected))
     << ",\"tage_selected\":" << cond_provider_tage_selected
     << ",\"tage_correct\":" << cond_provider_tage_correct
     << ",\"tage_accuracy\":"
     << safe_div(static_cast<double>(cond_provider_tage_correct),
                static_cast<double>(cond_provider_tage_selected))
     << ",\"sc_selected\":" << cond_provider_sc_selected
     << ",\"sc_correct\":" << cond_provider_sc_correct
     << ",\"sc_accuracy\":"
     << safe_div(static_cast<double>(cond_provider_sc_correct),
                static_cast<double>(cond_provider_sc_selected))
     << ",\"loop_selected\":" << cond_provider_loop_selected
     << ",\"loop_correct\":" << cond_provider_loop_correct
     << ",\"loop_accuracy\":"
     << safe_div(static_cast<double>(cond_provider_loop_correct),
                static_cast<double>(cond_provider_loop_selected))
     << "},\"cond_wrong_alt\":{"
     << "\"legacy_correct\":" << cond_selected_wrong_alt_legacy_correct
     << ",\"tage_correct\":" << cond_selected_wrong_alt_tage_correct
     << ",\"sc_correct\":" << cond_selected_wrong_alt_sc_correct
     << ",\"loop_correct\":" << cond_selected_wrong_alt_loop_correct
     << ",\"any_correct\":" << cond_selected_wrong_alt_any_correct
     << "}},";

  os << "\"has_commit_detail\":false,\"has_commit_summary\":true,";
  os << "\"stall_mode\":\"cycle\",\"commit_metrics_source\":\"summary\",";
  os << "\"stall_metrics_source\":\"cycle\",\"quality_warnings\":[],";
  os << "\"host_time_us\":0,\"host_time_ms\":0,\"bench_reported_time_ms\":null,";
  os << "\"effective_benchmark_time_ms\":0,\"benchmark_time_source\":\"unknown\"";
  os << "}";

  std::error_code ec;
  const std::filesystem::path out_path(args_.profile_json_path);
  if (out_path.has_parent_path()) {
    std::filesystem::create_directories(out_path.parent_path(), ec);
  }
  std::ofstream out(out_path, std::ios::out | std::ios::trunc);
  if (!out) {
    std::cerr << "[profile-json] failed to open " << args_.profile_json_path << "\n";
    return;
  }
  out << os.str();
  out.close();
  std::cout << "[profile-json] wrote " << args_.profile_json_path << "\n";
}

}  // namespace npc
