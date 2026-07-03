#include "profile_collector.h"

#include "Vtb_triathlon.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <vector>

namespace npc {

namespace {

constexpr int kProfileSchemaVersion = 2;

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

void append_uint_key_map(std::ostringstream &os,
                         const std::unordered_map<uint32_t, uint64_t> &m) {
  bool first = true;
  os << "{";
  std::vector<std::pair<uint32_t, uint64_t>> items(m.begin(), m.end());
  std::sort(items.begin(), items.end(),
            [](const auto &a, const auto &b) { return a.first < b.first; });
  for (const auto &kv : items) {
    if (!first) os << ",";
    first = false;
    os << "\"" << kv.first << "\":" << kv.second;
  }
  os << "}";
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

template <size_t N>
void append_frontend_empty_detail(std::ostringstream &os,
                                  const std::array<uint64_t, N> &hist) {
  os << "{";
  bool fe_first = true;
  for (size_t i = 0; i < hist.size(); i++) {
    if (hist[i] == 0) continue;
    if (!fe_first) os << ",";
    fe_first = false;
    os << "\"" << frontend_empty_detail_key(static_cast<int>(i)) << "\":" << hist[i];
  }
  os << "}";
}

void append_quality_warnings(std::ostringstream &os,
                             uint64_t flush_count,
                             uint64_t flush_recovery_cycles,
                             uint64_t frontend_empty_cycles,
                             uint64_t fe_req_fire_no_inflight,
                             uint64_t fe_redirect_recovery,
                             uint64_t pipeline_bubble_cycles,
                             uint64_t stall_total) {
  os << "[";
  bool first = true;
  auto add_warning = [&](const char *msg) {
    if (!first) os << ",";
    first = false;
    os << "\"" << json_escape(msg) << "\"";
  };

  if (flush_count > 0 && flush_recovery_cycles == 0) {
    add_warning(
        "flush_recovery counts zero-commit cycles with backend_flush_o asserted; "
        "post-mispredict recovery usually appears under frontend_empty "
        "(fe_req_fire_no_inflight / fe_redirect_recovery).");
  }
  if (stall_total > 0 && pipeline_bubble_cycles > stall_total / 2) {
    add_warning(
        "pipeline_bubble is large: zero-commit cycles while decode and ROB accept, "
        "often execution/writeback/ROB-head wait (see stall.pipeline_bubble.detail).");
  }
  if (frontend_empty_cycles > 0 &&
      fe_req_fire_no_inflight + fe_redirect_recovery > frontend_empty_cycles / 2) {
    add_warning(
        "frontend_empty is dominated by flush/redirect recovery bubbles, not sustained "
        "I-cache starvation.");
  }
  add_warning("predict._doc 说明各 BPU 字段口径; 提交侧误预测以 flush.mispredict + retire_miss_rate 为准.");
  add_warning(
      "flush.redirect pc_delta_bytes_* is |redirect_pc-src_pc| in bytes, not pipeline penalty.");
  add_warning(
      "flush.bru_mispred_count only counts dbg_bru_mispred_o at flush, not all mispredicts.");
  os << "]";
}

void append_predict_doc(std::ostringstream &os) {
  os << "\"_doc\":{";
  os << "\"retire_executed\":\"已退休控制流指令数(误预测率分母). 误预测次数见 flush.mispredict\",";
  os << "\"retire_miss_rate\":\"提交侧误预测率=flush.mispredict/retire_executed. 衡量 IPC 影响的主 KPI\",";
  os << "\"bpu_train\":\"BPU 训练更新时 TAGE 方向自检(更新前预测 vs 实际 taken). 非取指时刻预测精度\",";
  os << "\"tage\":\"取指 cond 槽 TAGE lookup. table_hit_rate=表命中/lookup, 非提交误预测率\",";
  os << "\"ftb\":\"FTB 在 BPU lookup 中的选用率与 tag miss(结构缺失)\",";
  os << "\"ittage\":\"间接跳转目标预测. table_hit_rate=表命中, use_rate=实际采用 ITTAGE 目标\",";
  os << "\"provider\":\"取指时 cond 方向 provider(T0 base / TAGE override) 及训练回溯准确率(样本=selected)\"";
  os << "}";
}

void append_predict_section(std::ostringstream &os,
                            uint64_t pred_cond_total,
                            uint64_t pred_jump_total,
                            uint64_t pred_jump_direct_total,
                            uint64_t pred_jump_indirect_total,
                            uint64_t pred_ret_total,
                            uint64_t pred_cond_miss,
                            uint64_t pred_jump_miss,
                            uint64_t pred_jump_direct_miss,
                            uint64_t pred_jump_indirect_miss,
                            uint64_t pred_ret_miss,
                            uint64_t cond_update_total,
                            uint64_t cond_selected_correct,
                            uint64_t tage_lookup_total,
                            uint64_t tage_hit_total,
                            uint64_t tage_override_total,
                            uint64_t tage_override_correct,
                            uint64_t ftb_lookup_total,
                            uint64_t ftb_cond_pick_total,
                            uint64_t ftb_jump_pick_total,
                            uint64_t ftb_cond_tag_miss_total,
                            uint64_t ftb_jump_tag_miss_total,
                            uint64_t ftb_multi_ir_cond_earlier_non_pick_taken_total,
                            uint64_t ittage_lookup_total,
                            uint64_t ittage_hit_total,
                            uint64_t ittage_use_total,
                            uint64_t t0_base_selected,
                            uint64_t t0_base_correct,
                            uint64_t tage_selected,
                            uint64_t tage_correct) {
  os << "\"predict\":{";
  append_predict_doc(os);
  os << ",\"retire_executed\":{";
  os << "\"cond\":" << pred_cond_total << ",\"jump\":" << pred_jump_total
     << ",\"jump_direct\":" << pred_jump_direct_total
     << ",\"jump_indirect\":" << pred_jump_indirect_total << ",\"ret\":" << pred_ret_total;
  os << "},\"retire_miss_rate\":{";
  os << "\"cond\":" << safe_div(static_cast<double>(pred_cond_miss), static_cast<double>(pred_cond_total))
     << ",\"jump\":" << safe_div(static_cast<double>(pred_jump_miss), static_cast<double>(pred_jump_total))
     << ",\"jump_direct\":"
     << safe_div(static_cast<double>(pred_jump_direct_miss),
                 static_cast<double>(pred_jump_direct_total))
     << ",\"jump_indirect\":"
     << safe_div(static_cast<double>(pred_jump_indirect_miss),
                 static_cast<double>(pred_jump_indirect_total))
     << ",\"ret\":" << safe_div(static_cast<double>(pred_ret_miss), static_cast<double>(pred_ret_total));
  os << "},\"bpu_train\":{";
  os << "\"cond_updates\":" << cond_update_total
     << ",\"cond_selected_correct\":" << cond_selected_correct
     << ",\"cond_selected_accuracy\":"
     << safe_div(static_cast<double>(cond_selected_correct), static_cast<double>(cond_update_total));
  os << "}";
  if (tage_lookup_total > 0) {
    os << ",\"tage\":{";
    os << "\"lookups\":" << tage_lookup_total
       << ",\"table_hits\":" << tage_hit_total
       << ",\"table_hit_rate\":"
       << safe_div(static_cast<double>(tage_hit_total), static_cast<double>(tage_lookup_total));
    if (tage_override_total > 0) {
      os << ",\"override_updates\":" << tage_override_total
         << ",\"override_correct\":" << tage_override_correct
         << ",\"override_accuracy\":"
         << safe_div(static_cast<double>(tage_override_correct),
                     static_cast<double>(tage_override_total));
    }
    os << "}";
  }
  if (ftb_lookup_total > 0) {
    os << ",\"ftb\":{";
    os << "\"lookups\":" << ftb_lookup_total
       << ",\"cond_pick_rate\":"
       << safe_div(static_cast<double>(ftb_cond_pick_total), static_cast<double>(ftb_lookup_total))
       << ",\"jump_pick_rate\":"
       << safe_div(static_cast<double>(ftb_jump_pick_total), static_cast<double>(ftb_lookup_total))
       << ",\"cond_tag_miss\":" << ftb_cond_tag_miss_total
       << ",\"jump_tag_miss\":" << ftb_jump_tag_miss_total
       << ",\"multi_ir_cond_earlier_non_pick_taken\":"
       << ftb_multi_ir_cond_earlier_non_pick_taken_total;
    os << "}";
  }
  if (ittage_lookup_total > 0) {
    os << ",\"ittage\":{";
    os << "\"lookups\":" << ittage_lookup_total
       << ",\"table_hits\":" << ittage_hit_total
       << ",\"table_hit_rate\":"
       << safe_div(static_cast<double>(ittage_hit_total), static_cast<double>(ittage_lookup_total))
       << ",\"uses\":" << ittage_use_total
       << ",\"use_rate\":"
       << safe_div(static_cast<double>(ittage_use_total), static_cast<double>(ittage_lookup_total));
    os << "}";
  }
  os << ",\"provider\":{";
  os << "\"t0_base\":{";
  os << "\"selected\":" << t0_base_selected << ",\"correct\":" << t0_base_correct
     << ",\"accuracy\":"
     << safe_div(static_cast<double>(t0_base_correct), static_cast<double>(t0_base_selected));
  os << "}";
  if (tage_selected > 0) {
    os << ",\"tage_override\":{";
    os << "\"selected\":" << tage_selected << ",\"correct\":" << tage_correct
       << ",\"accuracy\":"
       << safe_div(static_cast<double>(tage_correct), static_cast<double>(tage_selected));
    os << "}";
  }
  os << "}},";
}

void append_dbg_bpu_section(std::ostringstream &os, const Vtb_triathlon *top) {
  os << "\"dbg_bpu\":{";
  os << "\"arch_ras_count\":" << static_cast<uint64_t>(top->dbg_bpu_arch_ras_count_o)
     << ",\"spec_ras_count\":" << static_cast<uint64_t>(top->dbg_bpu_spec_ras_count_o)
     << ",\"arch_ras_top\":" << static_cast<uint64_t>(top->dbg_bpu_arch_ras_top_o)
     << ",\"spec_ras_top\":" << static_cast<uint64_t>(top->dbg_bpu_spec_ras_top_o)
     << ",\"cond_update_total\":" << static_cast<uint64_t>(top->dbg_bpu_cond_update_total_o)
     << ",\"cond_tage_correct\":" << static_cast<uint64_t>(top->dbg_bpu_cond_local_correct_o)
     << ",\"cond_selected_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_selected_correct_o)
     << ",\"cond_t0_selected\":" << static_cast<uint64_t>(top->dbg_bpu_cond_choose_local_o)
     << ",\"tage_lookup_total\":" << static_cast<uint64_t>(top->dbg_bpu_tage_lookup_total_o)
     << ",\"tage_hit_total\":" << static_cast<uint64_t>(top->dbg_bpu_tage_hit_total_o)
     << ",\"tage_override_total\":" << static_cast<uint64_t>(top->dbg_bpu_tage_override_total_o)
     << ",\"tage_override_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_tage_override_correct_o)
     << ",\"sc_lookup_total\":" << static_cast<uint64_t>(top->dbg_bpu_sc_lookup_total_o)
     << ",\"sc_confident_total\":" << static_cast<uint64_t>(top->dbg_bpu_sc_confident_total_o)
     << ",\"sc_override_total\":" << static_cast<uint64_t>(top->dbg_bpu_sc_override_total_o)
     << ",\"sc_override_correct\":" << static_cast<uint64_t>(top->dbg_bpu_sc_override_correct_o)
     << ",\"loop_lookup_total\":" << static_cast<uint64_t>(top->dbg_bpu_loop_lookup_total_o)
     << ",\"loop_hit_total\":" << static_cast<uint64_t>(top->dbg_bpu_loop_hit_total_o)
     << ",\"loop_confident_total\":" << static_cast<uint64_t>(top->dbg_bpu_loop_confident_total_o)
     << ",\"loop_override_total\":" << static_cast<uint64_t>(top->dbg_bpu_loop_override_total_o)
     << ",\"loop_override_correct\":" << static_cast<uint64_t>(top->dbg_bpu_loop_override_correct_o)
     << ",\"cond_provider_t0_selected\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_selected_o)
     << ",\"cond_provider_tage_selected\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_selected_o)
     << ",\"cond_provider_sc_selected\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_sc_selected_o)
     << ",\"cond_provider_loop_selected\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_loop_selected_o)
     << ",\"cond_provider_t0_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_correct_o)
     << ",\"cond_provider_tage_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_correct_o)
     << ",\"cond_provider_sc_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_sc_correct_o)
     << ",\"cond_provider_loop_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_provider_loop_correct_o)
     << ",\"cond_selected_wrong_alt_t0_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_legacy_correct_o)
     << ",\"cond_selected_wrong_alt_tage_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_tage_correct_o)
     << ",\"cond_selected_wrong_alt_sc_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_sc_correct_o)
     << ",\"cond_selected_wrong_alt_loop_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_loop_correct_o)
     << ",\"cond_selected_wrong_alt_any_correct\":"
     << static_cast<uint64_t>(top->dbg_bpu_cond_selected_wrong_alt_any_correct_o)
     << ",\"ftb_lookup_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_lookup_total_o)
     << ",\"ftb_cond_hit_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_cond_hit_total_o)
     << ",\"ftb_jump_hit_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_jump_hit_total_o)
     << ",\"ftb_cond_pick_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_cond_pick_total_o)
     << ",\"ftb_jump_pick_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_jump_pick_total_o)
     << ",\"ftb_cond_tag_miss_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_cond_tag_miss_total_o)
     << ",\"ftb_jump_tag_miss_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_jump_tag_miss_total_o)
     << ",\"ftb_train_cond_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_train_cond_total_o)
     << ",\"ftb_train_jump_total\":" << static_cast<uint64_t>(top->dbg_bpu_ftb_train_jump_total_o)
     << ",\"ftb_multi_ir_cond_earlier_non_pick_taken_total\":"
     << static_cast<uint64_t>(top->dbg_bpu_ftb_multi_ir_cond_earlier_non_pick_taken_total_o)
     << ",\"ittage_lookup_total\":" << static_cast<uint64_t>(top->dbg_bpu_ittage_lookup_total_o)
     << ",\"ittage_hit_total\":" << static_cast<uint64_t>(top->dbg_bpu_ittage_hit_total_o)
     << ",\"ittage_use_total\":" << static_cast<uint64_t>(top->dbg_bpu_ittage_use_total_o)
     << ",\"ittage_train_total\":" << static_cast<uint64_t>(top->dbg_bpu_ittage_train_total_o);
  os << "},";
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
      "frontend_empty",     "decode_blocked",   "lsu_req_blocked",  "pipeline_bubble",
  };

  const uint64_t cond_update_total = static_cast<uint64_t>(top->dbg_bpu_cond_update_total_o);
  const uint64_t cond_selected_correct = static_cast<uint64_t>(top->dbg_bpu_cond_selected_correct_o);
  const uint64_t tage_lookup_total = static_cast<uint64_t>(top->dbg_bpu_tage_lookup_total_o);
  const uint64_t tage_hit_total = static_cast<uint64_t>(top->dbg_bpu_tage_hit_total_o);
  const uint64_t tage_override_total = static_cast<uint64_t>(top->dbg_bpu_tage_override_total_o);
  const uint64_t tage_override_correct = static_cast<uint64_t>(top->dbg_bpu_tage_override_correct_o);

  const uint64_t ftb_lookup_total = static_cast<uint64_t>(top->dbg_bpu_ftb_lookup_total_o);
  const uint64_t ftb_cond_pick_total = static_cast<uint64_t>(top->dbg_bpu_ftb_cond_pick_total_o);
  const uint64_t ftb_jump_pick_total = static_cast<uint64_t>(top->dbg_bpu_ftb_jump_pick_total_o);
  const uint64_t ftb_cond_tag_miss_total = static_cast<uint64_t>(top->dbg_bpu_ftb_cond_tag_miss_total_o);
  const uint64_t ftb_jump_tag_miss_total = static_cast<uint64_t>(top->dbg_bpu_ftb_jump_tag_miss_total_o);
  const uint64_t ftb_multi_ir_cond_earlier_non_pick_taken_total =
      static_cast<uint64_t>(top->dbg_bpu_ftb_multi_ir_cond_earlier_non_pick_taken_total_o);
  const uint64_t ittage_lookup_total = static_cast<uint64_t>(top->dbg_bpu_ittage_lookup_total_o);
  const uint64_t ittage_hit_total = static_cast<uint64_t>(top->dbg_bpu_ittage_hit_total_o);
  const uint64_t ittage_use_total = static_cast<uint64_t>(top->dbg_bpu_ittage_use_total_o);
  const uint64_t cond_provider_t0_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_selected_o);
  const uint64_t cond_provider_tage_selected =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_selected_o);
  const uint64_t cond_provider_t0_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_legacy_correct_o);
  const uint64_t cond_provider_tage_correct =
      static_cast<uint64_t>(top->dbg_bpu_cond_provider_tage_correct_o);

  const uint64_t control_total =
      control_branch_count_ + control_jal_count_ + control_jalr_count_;
  const uint64_t fq_samples = cycles;
  const uint64_t fq_nonempty_cycles =
      ifu_fq_nonempty_cycles_ > 0 ? ifu_fq_nonempty_cycles_
                                 : (fq_samples > ifu_fq_empty_cycles_ ? fq_samples - ifu_fq_empty_cycles_ : 0);

  std::ostringstream os;
  os << std::fixed << std::setprecision(6);
  os << "{";
  os << "\"schema_version\":" << kProfileSchemaVersion << ",";

  const uint64_t flush_recovery_cycles = stall_cycle_hist_[kStallFlushRecovery];
  const uint64_t frontend_empty_cycles = stall_cycle_hist_[kStallFrontendEmpty];
  const uint64_t pipeline_bubble_cycles = stall_cycle_hist_[kStallOther];
  const uint64_t fe_req_fire_no_inflight = stall_frontend_empty_hist_[kFeReqFireNoInflight];
  const uint64_t fe_redirect_recovery = stall_frontend_empty_hist_[kFeRedirectRecovery];

  os << "\"meta\":{";
  os << "\"log_path\":\"" << json_escape(args_.profile_json_path) << "\",";
  os << "\"has_commit_detail\":false,\"has_commit_summary\":true,";
  os << "\"stall_mode\":\"cycle\",\"commit_metrics_source\":\"summary\",";
  os << "\"stall_metrics_source\":\"cycle\",\"quality_warnings\":";
  append_quality_warnings(os, flush_count_, flush_recovery_cycles, frontend_empty_cycles,
                          fe_req_fire_no_inflight, fe_redirect_recovery, pipeline_bubble_cycles,
                          stall_total);
  os << ",\"host_time_us\":0,\"host_time_ms\":0,\"bench_reported_time_ms\":null,";
  os << "\"effective_benchmark_time_ms\":0,\"benchmark_time_source\":\"unknown\"";
  os << "},";

  os << "\"kpi\":{";
  os << "\"ipc\":" << ipc << ",\"cpi\":" << cpi << ",\"cycles\":" << cycles
     << ",\"commits\":" << commits;
  os << "},";

  os << "\"commit\":{";
  os << "\"width_hist\":{";
  for (size_t i = 0; i < commit_width_hist_.size(); i++) {
    if (i > 0) os << ",";
    os << "\"" << i << "\":" << commit_width_hist_[i];
  }
  os << "}},";

  os << "\"flush\":{";
  os << "\"count\":" << flush_count_
     << ",\"bru_mispred_count\":" << bru_count_
     << ",\"per_kcommit\":" << safe_div(static_cast<double>(flush_count_) * 1000.0,
                                        static_cast<double>(commits))
     << ",\"bru_per_kcommit\":" << safe_div(static_cast<double>(bru_count_) * 1000.0,
                                            static_cast<double>(commits))
     << ",\"branch_penalty_cycles\":" << branch_penalty_cycles_
     << ",\"wrong_path_kill_uops\":" << wrong_path_killed_uops_ << ",";
  os << "\"mispredict\":{";
  os << "\"flush_count\":" << mispredict_flush_count_
     << ",\"cond\":" << pred_cond_miss_
     << ",\"jump\":" << pred_jump_miss_
     << ",\"jump_direct\":" << pred_jump_direct_miss_
     << ",\"jump_indirect\":" << pred_jump_indirect_miss_
     << ",\"ret\":" << pred_ret_miss_;
  os << "},";
  const uint64_t md_dir_wrong = mispredict_diag_dir_wrong_;
  const uint64_t md_dir_ok_target_wrong = mispredict_diag_dir_ok_target_wrong_;
  const uint64_t md_slot_offset_bind = mispredict_diag_slot_offset_bind_;
  const uint64_t md_ftb_no_entry = mispredict_diag_ftb_no_entry_tag_miss_;
  const uint64_t md_ftb_hit_cond_nt = mispredict_diag_ftb_hit_cond_nt_;
  const uint64_t md_ftb_hit_oor = mispredict_diag_ftb_hit_out_of_range_;
  const uint64_t md_ftb_hit_shadowed = mispredict_diag_ftb_hit_shadowed_;
  const uint64_t md_ftb_hit_shadowed_cond_nt = mispredict_diag_ftb_hit_shadowed_cond_nt_;
  const uint64_t md_ftb_snap_epoch_mismatch = mispredict_diag_ftb_snap_epoch_mismatch_;
  const uint64_t md_ftb_hit_oor_epoch_ok = mispredict_diag_ftb_hit_out_of_range_epoch_ok_;
  const uint64_t md_ftb_unclassified = mispredict_diag_ftb_unclassified_;
  const uint64_t md_other = mispredict_diag_other_;
  const uint64_t md_no_commit_slot = mispredict_diag_no_commit_slot_;
  const uint64_t md_tage_direction =
      md_dir_wrong + md_ftb_hit_cond_nt + md_ftb_hit_shadowed_cond_nt;
  const uint64_t md_ftb_structural =
      md_ftb_no_entry + md_ftb_hit_oor + md_ftb_hit_shadowed + md_slot_offset_bind;
  const uint64_t md_target_wrong = md_dir_ok_target_wrong;
  const uint64_t md_unclassified =
      md_ftb_unclassified + md_other + md_no_commit_slot + md_ftb_snap_epoch_mismatch;
  const uint64_t md_classified_total =
      md_tage_direction + md_ftb_structural + md_target_wrong + md_unclassified;
  os << "\"mispredict_diag\":{";
  os << "\"dir_wrong\":" << md_dir_wrong
     << ",\"dir_ok_target_wrong\":" << md_dir_ok_target_wrong
     << ",\"slot_offset_bind\":" << md_slot_offset_bind
     << ",\"ftb_no_entry_tag_miss\":" << md_ftb_no_entry
     << ",\"ftb_hit_cond_nt\":" << md_ftb_hit_cond_nt
     << ",\"ftb_hit_out_of_range\":" << md_ftb_hit_oor
     << ",\"ftb_hit_shadowed\":" << md_ftb_hit_shadowed
     << ",\"ftb_hit_shadowed_cond_nt\":" << md_ftb_hit_shadowed_cond_nt
     << ",\"ftb_snap_epoch_mismatch\":" << md_ftb_snap_epoch_mismatch
     << ",\"ftb_hit_out_of_range_epoch_ok\":" << md_ftb_hit_oor_epoch_ok
     << ",\"ftb_unclassified\":" << md_ftb_unclassified
     << ",\"other\":" << md_other
     << ",\"no_commit_slot\":" << md_no_commit_slot
     << ",\"classified_total\":" << md_classified_total
     << ",\"rollup\":{"
     << "\"tage_direction\":" << md_tage_direction
     << ",\"tage_direction_ratio\":"
     << safe_div(static_cast<double>(md_tage_direction), static_cast<double>(mispredict_flush_count_))
     << ",\"ftb_structural\":" << md_ftb_structural
     << ",\"ftb_structural_ratio\":"
     << safe_div(static_cast<double>(md_ftb_structural), static_cast<double>(mispredict_flush_count_))
     << ",\"target_wrong\":" << md_target_wrong
     << ",\"target_wrong_ratio\":"
     << safe_div(static_cast<double>(md_target_wrong), static_cast<double>(mispredict_flush_count_))
     << ",\"unclassified\":" << md_unclassified
     << ",\"unclassified_ratio\":"
     << safe_div(static_cast<double>(md_unclassified), static_cast<double>(mispredict_flush_count_))
     << "}";
  os << ",\"detail\":{";
  os << "\"dir_wrong\":{";
  os << "\"top_pc\":";
  append_top_uint(os, mispredict_diag_dir_wrong_pc_hist_, "pc");
  os << ",\"kind\":";
  append_str_map(os, mispredict_diag_dir_wrong_kind_hist_);
  os << "},\"ftb_no_entry_tag_miss\":{";
  os << "\"top_branch_pc\":";
  append_top_uint(os, mispredict_diag_ftb_no_entry_branch_pc_hist_, "pc");
  os << ",\"top_fetch_pc\":";
  append_top_uint(os, mispredict_diag_ftb_no_entry_fetch_pc_hist_, "pc");
  os << ",\"fetch_rel\":";
  append_uint_key_map(os, mispredict_diag_ftb_no_entry_fetch_rel_hist_);
  os << ",\"fetch_byte_off\":";
  append_uint_key_map(os, mispredict_diag_ftb_no_entry_fetch_byte_off_hist_);
  os << ",\"block_byte_off\":";
  append_uint_key_map(os, mispredict_diag_ftb_no_entry_block_byte_off_hist_);
  os << ",\"block_delta\":";
  append_str_map(os, mispredict_diag_ftb_no_entry_block_delta_hist_);
  os << ",\"valid_count\":";
  append_uint_key_map(os, mispredict_diag_ftb_no_entry_valid_count_hist_);
  os << ",\"cond_count\":";
  append_uint_key_map(os, mispredict_diag_ftb_no_entry_cond_count_hist_);
  os << ",\"jump_count\":";
  append_uint_key_map(os, mispredict_diag_ftb_no_entry_jump_count_hist_);
  os << ",\"kind\":";
  append_str_map(os, mispredict_diag_ftb_no_entry_kind_hist_);
  os << ",\"cause\":";
  append_str_map(os, mispredict_diag_ftb_no_entry_cause_hist_);
  os << "},\"ftb_hit_cond_nt\":{";
  os << "\"top_branch_pc\":";
  append_top_uint(os, mispredict_diag_ftb_hit_cond_nt_branch_pc_hist_, "pc");
  os << ",\"top_fetch_pc\":";
  append_top_uint(os, mispredict_diag_ftb_hit_cond_nt_fetch_pc_hist_, "pc");
  os << ",\"block_byte_off\":";
  append_uint_key_map(os, mispredict_diag_ftb_hit_cond_nt_block_byte_off_hist_);
  os << ",\"valid_count\":";
  append_uint_key_map(os, mispredict_diag_ftb_hit_cond_nt_valid_count_hist_);
  os << ",\"cond_count\":";
  append_uint_key_map(os, mispredict_diag_ftb_hit_cond_nt_cond_count_hist_);
  os << ",\"jump_count\":";
  append_uint_key_map(os, mispredict_diag_ftb_hit_cond_nt_jump_count_hist_);
  os << ",\"kind\":";
  append_str_map(os, mispredict_diag_ftb_hit_cond_nt_kind_hist_);
  os << "},\"ftb_hit_shadowed\":{";
  os << "\"top_branch_pc\":";
  append_top_uint(os, mispredict_diag_ftb_hit_shadowed_branch_pc_hist_, "pc");
  os << ",\"top_snap_pc\":";
  append_top_uint(os, mispredict_diag_ftb_hit_shadowed_snap_pc_hist_, "pc");
  os << ",\"block_byte_off\":";
  append_uint_key_map(os, mispredict_diag_ftb_hit_shadowed_block_byte_off_hist_);
  os << ",\"kind\":";
  append_str_map(os, mispredict_diag_ftb_hit_shadowed_kind_hist_);
  os << ",\"pick\":";
  append_str_map(os, mispredict_diag_ftb_hit_shadowed_pick_hist_);
  os << "},\"ftb_hit_shadowed_cond_nt\":{";
  os << "\"top_branch_pc\":";
  append_top_uint(os, mispredict_diag_ftb_hit_shadowed_cond_nt_branch_pc_hist_, "pc");
  os << ",\"top_shadow_pc\":";
  append_top_uint(os, mispredict_diag_ftb_hit_shadowed_cond_nt_shadow_pc_hist_, "pc");
  os << ",\"block_byte_off\":";
  append_uint_key_map(os, mispredict_diag_ftb_hit_shadowed_cond_nt_block_byte_off_hist_);
  os << ",\"kind\":";
  append_str_map(os, mispredict_diag_ftb_hit_shadowed_cond_nt_kind_hist_);
  os << ",\"pick\":";
  append_str_map(os, mispredict_diag_ftb_hit_shadowed_cond_nt_pick_hist_);
  os << "},\"ftb_hit_out_of_range\":{";
  os << "\"top_branch_pc\":";
  append_top_uint(os, mispredict_diag_ftb_oor_branch_pc_hist_, "pc");
  os << ",\"top_snap_pc\":";
  append_top_uint(os, mispredict_diag_ftb_oor_snap_pc_hist_, "pc");
  os << ",\"block_byte_off\":";
  append_uint_key_map(os, mispredict_diag_ftb_oor_block_byte_off_hist_);
  os << ",\"kind\":";
  append_str_map(os, mispredict_diag_ftb_oor_kind_hist_);
  os << "}}";
  os << "},";
  os << "\"redirect\":{";
  os << "\"pc_delta_bytes_sum\":" << redirect_distance_sum_
     << ",\"pc_delta_bytes_samples\":" << redirect_distance_samples_
     << ",\"pc_delta_bytes_avg\":" << safe_div(static_cast<double>(redirect_distance_sum_),
                                              static_cast<double>(redirect_distance_samples_))
     << ",\"pc_delta_bytes_max\":" << redirect_distance_max_;
  os << "},";
  os << "\"reason_histogram\":";
  append_str_map(os, flush_reason_hist_);
  os << ",\"source_histogram\":";
  append_str_map(os, flush_source_hist_);
  os << "},";

  os << "\"stall\":{";
  os << "\"total\":" << stall_total << ",\"post_flush_window_cycles\":16,";
  os << "\"category\":{";
  for (int i = 0; i < 8; i++) {
    if (i > 0) os << ",";
    os << "\"" << kStallKeys[i] << "\":" << stall_cycle_hist_[static_cast<size_t>(i)];
  }
  os << "},";
  os << "\"decode_blocked\":{";
  os << "\"total\":" << stall_cycle_hist_[kStallDecodeBlocked]
     << ",\"post_flush\":0,\"post_flush_ratio\":0"
     << ",\"post_branch_flush\":0,\"post_branch_flush_ratio\":0,\"detail\":";
  append_str_map(os, stall_decode_blocked_detail_hist_);
  os << "},";
  os << "\"rob_backpressure\":{";
  os << "\"total\":" << stall_cycle_hist_[kStallROBBackpressure] << ",\"detail\":";
  append_str_map(os, stall_rob_backpressure_detail_hist_);
  os << "},";
  os << "\"frontend_empty\":{";
  os << "\"total\":" << stall_cycle_hist_[kStallFrontendEmpty] << ",\"detail\":";
  append_frontend_empty_detail(os, stall_frontend_empty_hist_);
  os << "},";
  os << "\"pipeline_bubble\":{";
  os << "\"total\":" << stall_cycle_hist_[kStallOther] << ",\"detail\":";
  append_str_map(os, stall_other_detail_hist_);
  os << ",\"aux\":{";
  os << "\"branch_ready_not_issued\":" << branch_ready_not_issued_cycles_
     << ",\"alu_ready_not_issued\":" << alu_ready_not_issued_cycles_
     << ",\"complete_not_visible_to_rob\":" << complete_not_visible_cycles_;
  os << "}},";
  os << "\"hol_load_detail\":{";
  os << "\"detail\":";
  append_str_map(os, stall_hol_load_detail_hist_);
  os << "}},";

  os << "\"frontend\":{";
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
                                               static_cast<double>(fq_samples));
  os << "}},";

  os << "\"control\":{";
  os << "\"branch_count\":" << control_branch_count_ << ",\"jal_count\":" << control_jal_count_
     << ",\"jalr_count\":" << control_jalr_count_
     << ",\"branch_taken_count\":" << control_branch_taken_count_
     << ",\"call_count\":" << control_call_count_ << ",\"ret_count\":" << control_ret_count_
     << ",\"control_count\":" << control_total
     << ",\"control_ratio\":" << safe_div(static_cast<double>(control_total), static_cast<double>(commits));
  os << "},";

  append_predict_section(
      os, pred_cond_total_, pred_jump_total_, pred_jump_direct_total_, pred_jump_indirect_total_,
      pred_ret_total_, pred_cond_miss_, pred_jump_miss_, pred_jump_direct_miss_,
      pred_jump_indirect_miss_, pred_ret_miss_, cond_update_total, cond_selected_correct,
      tage_lookup_total, tage_hit_total, tage_override_total, tage_override_correct,
      ftb_lookup_total, ftb_cond_pick_total, ftb_jump_pick_total, ftb_cond_tag_miss_total,
      ftb_jump_tag_miss_total, ftb_multi_ir_cond_earlier_non_pick_taken_total,
      ittage_lookup_total, ittage_hit_total, ittage_use_total,
      cond_provider_t0_selected, cond_provider_t0_correct, cond_provider_tage_selected,
      cond_provider_tage_correct);

  append_dbg_bpu_section(os, top);

  os << "\"hotspots\":{";
  os << "\"top_pc\":";
  append_top_uint(os, commit_pc_hist_, "pc");
  os << ",\"top_inst\":";
  append_top_uint(os, commit_inst_hist_, "inst");
  os << ",\"bpu_taken_control_pc_top\":";
  append_top_uint(os, bpu_taken_control_pc_hist_, "pc");
  os << ",\"bpu_update_pc_top\":";
  append_top_uint(os, bpu_update_pc_hist_, "pc");
  os << ",\"bpu_update_kind\":";
  append_str_map(os, bpu_update_kind_hist_);
  os << "}";

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
