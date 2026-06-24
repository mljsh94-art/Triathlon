import global_config_pkg::*;
module bpu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned BTB_ENTRIES = 64,
    parameter int unsigned BHT_ENTRIES = 128,
    parameter int unsigned RAS_DEPTH = 16,
    parameter bit BTB_HASH_ENABLE = 1'b1,
    parameter bit BHT_HASH_ENABLE = 1'b1,
    parameter bit USE_GSHARE = 1'b0,
    parameter bit USE_TAGE = 1'b0,
    parameter bit USE_SC = 1'b0,
    parameter bit USE_TOURNAMENT = 1'b1,
    parameter int unsigned GHR_BITS = 8,
    parameter int unsigned SC_ENTRIES = 512,
    parameter int unsigned SC_CONF_THRESH = 3,
    parameter bit SC_REQUIRE_DISAGREE = 1'b1,
    parameter bit SC_REQUIRE_BOTH_WEAK = 1'b1,
    parameter bit SC_BLOCK_ON_TAGE_HIT = 1'b1,
    parameter bit USE_LOOP = 1'b0,
    parameter int unsigned LOOP_ENTRIES = 64,
    parameter int unsigned LOOP_TAG_BITS = 10,
    parameter int unsigned LOOP_CONF_THRESH = 2,
    parameter bit USE_ITTAGE = 1'b0,
    parameter int unsigned ITTAGE_ENTRIES = 128,
    parameter int unsigned ITTAGE_TAG_BITS = 10,
    parameter int unsigned TAGE_OVERRIDE_MIN_PROVIDER = 0,
    parameter int unsigned TAGE_TAG_BITS = 8,
    parameter int unsigned TAGE_HIST_LEN0 = 2,
    parameter int unsigned TAGE_HIST_LEN1 = 4,
    parameter int unsigned TAGE_HIST_LEN2 = 8,
    parameter int unsigned TAGE_HIST_LEN3 = 16,
    parameter int unsigned PATH_HIST_BITS = 16,
    parameter int unsigned TRACK_DEPTH = 16
) (
    input logic clk_i,
    input logic rst_i,

    // Commit-time predictor update
  
    input logic                update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic                update_is_cond_i,
    input logic                update_taken_i,
    input logic [Cfg.PLEN-1:0] update_target_i,
    input logic                update_is_call_i,
    input logic                update_is_ret_i,
    input logic                update_is_rvc_i,
    input logic [Cfg.NRET-1:0] ras_update_valid_i,
    input logic [Cfg.NRET-1:0] ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0] ras_update_is_rvc_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] ras_update_pc_i,
    input logic                flush_i,
    input logic                redirect_valid_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,

    // FTQ enqueue side
    output logic                    ftq_enq_valid_o,
    input  logic                    ftq_enq_ready_i,
    input  logic [global_config_pkg::FTQ_ID_W-1:0] ftq_enq_id_i,
    input  logic [FETCH_EPOCH_W-1:0] ftq_enq_epoch_i,
    output logic [Cfg.PLEN-1:0]     ftq_enq_pc_o,
    output logic                    ftq_enq_pred_slot_valid_o,
    output logic [SLOT_IDX_W-1:0]   ftq_enq_pred_slot_idx_o,
    output logic [Cfg.PLEN-1:0]     ftq_enq_pred_target_o,
    output logic [Cfg.PLEN-1:0]     ftq_enq_pred_npc_o
);

  // FTB：pred_slot_idx 升级为 fetch block 内的半字 index（0~PRED_SLOT_COUNT-1）。
  localparam int unsigned SLOT_IDX_W = global_config_pkg::PRED_SLOT_IDX_W;
  localparam int unsigned PRED_SLOT_COUNT = global_config_pkg::PRED_SLOT_COUNT;
  // fetch block 16B 对齐掩码：block_base = pc & ~(FETCH_WIDTH-1)。
  localparam logic [Cfg.PLEN-1:0] BLOCK_ALIGN_MASK = ~(Cfg.PLEN'(Cfg.FETCH_WIDTH - 1));
  localparam int unsigned BTB_IDX_W = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
  localparam int unsigned BHT_IDX_W = (BHT_ENTRIES > 1) ? $clog2(BHT_ENTRIES) : 1;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  // RV32C instructions are 16-bit aligned. BHT indexing must include pc[1].
  localparam int unsigned INSTR_ADDR_LSB = 1;
  // FTB/BTB entries are keyed by fetch-block base, not individual halfword PCs.
  localparam int unsigned BLOCK_ADDR_LSB = $clog2(Cfg.FETCH_WIDTH);
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - BLOCK_ADDR_LSB;
  localparam int unsigned RAS_CNT_W = (RAS_DEPTH > 0) ? $clog2(RAS_DEPTH + 1) : 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam int unsigned PATH_HIST_W = (PATH_HIST_BITS > 0) ? PATH_HIST_BITS : 1;
  localparam int unsigned TAGE_TRACK_DEPTH = (TRACK_DEPTH >= 2) ? TRACK_DEPTH : 2;
  localparam int unsigned TAGE_TRACK_PTR_W = (TAGE_TRACK_DEPTH > 1) ? $clog2(TAGE_TRACK_DEPTH) : 1;
  localparam int unsigned TAGE_TRACK_CNT_W = $clog2(TAGE_TRACK_DEPTH + 1);
  localparam logic [1:0] COND_PROVIDER_LEGACY = 2'd0;
  localparam logic [1:0] COND_PROVIDER_TAGE = 2'd1;
  localparam logic [1:0] COND_PROVIDER_SC = 2'd2;
  localparam logic [1:0] COND_PROVIDER_LOOP = 2'd3;
  localparam int unsigned FTB_SLOTS = 4;
  localparam int unsigned FTB_SLOT_IDX_W = (FTB_SLOTS > 1) ? $clog2(FTB_SLOTS) : 1;
  localparam int unsigned FTB_AGE_W = (FTB_SLOTS > 1) ? $clog2(FTB_SLOTS) : 1;
  localparam logic [FTB_AGE_W-1:0] FTB_AGE_MAX = FTB_AGE_W'(FTB_SLOTS - 1);
  logic [Cfg.PLEN-1:0] pc_reg_q;
  // FTB：每个 16B fetch block 保留 4 个统一控制流槽，cond/jump 不再分 way。
  logic [BTB_ENTRIES-1:0][BTB_TAG_W-1:0] btb_tag_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_valid_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_cond_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_rvc_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_call_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_ret_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_backward_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0][SLOT_IDX_W-1:0] btb_slot_offset_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0][Cfg.PLEN-1:0] btb_slot_target_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0][FTB_AGE_W-1:0] btb_slot_age_q;
  logic [BHT_ENTRIES-1:0][1:0] local_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] global_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] chooser_q;
  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_ras_stack_q;
  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_ras_stack_q;
  logic [RAS_CNT_W-1:0] arch_ras_count_q;
  logic [RAS_CNT_W-1:0] spec_ras_count_q;
  logic pred_event_valid_q;
  logic pred_event_is_call_q;
  logic pred_event_is_ret_q;
  logic pred_event_is_rvc_q;
  logic pred_event_is_cond_q;
  logic pred_event_taken_q;
  logic [Cfg.PLEN-1:0] pred_event_pc_q;
  logic [GHR_W-1:0] arch_ghr_q;
  logic [GHR_W-1:0] spec_ghr_q;
  logic [PATH_HIST_W-1:0] arch_path_hist_q;
  logic [PATH_HIST_W-1:0] spec_path_hist_q;
  logic [GHR_W-1:0] ghr_q;
  logic [PATH_HIST_W-1:0] ittage_predict_ctx_w;
  logic [63:0] dbg_cond_update_total_q;
  logic [63:0] dbg_cond_local_correct_q;
  logic [63:0] dbg_cond_global_correct_q;
  logic [63:0] dbg_cond_selected_correct_q;
  logic [63:0] dbg_cond_choose_local_q;
  logic [63:0] dbg_cond_choose_global_q;
  logic [63:0] dbg_tage_lookup_total_q;
  logic [63:0] dbg_tage_hit_total_q;
  logic [63:0] dbg_tage_override_total_q;
  logic [63:0] dbg_tage_override_correct_q;
  logic [63:0] dbg_sc_lookup_total_q;
  logic [63:0] dbg_sc_confident_total_q;
  logic [63:0] dbg_sc_override_total_q;
  logic [63:0] dbg_sc_override_correct_q;
  logic [63:0] dbg_loop_lookup_total_q;
  logic [63:0] dbg_loop_hit_total_q;
  logic [63:0] dbg_loop_confident_total_q;
  logic [63:0] dbg_loop_override_total_q;
  logic [63:0] dbg_loop_override_correct_q;
  logic [63:0] dbg_cond_provider_legacy_selected_q;
  logic [63:0] dbg_cond_provider_tage_selected_q;
  logic [63:0] dbg_cond_provider_sc_selected_q;
  logic [63:0] dbg_cond_provider_loop_selected_q;
  logic [63:0] dbg_cond_provider_legacy_correct_q;
  logic [63:0] dbg_cond_provider_tage_correct_q;
  logic [63:0] dbg_cond_provider_sc_correct_q;
  logic [63:0] dbg_cond_provider_loop_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_legacy_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_tage_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_sc_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_loop_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_any_correct_q;
  logic [63:0] dbg_ftb_lookup_total_q;
  logic [63:0] dbg_ftb_cond_hit_total_q;
  logic [63:0] dbg_ftb_jump_hit_total_q;
  logic [63:0] dbg_ftb_cond_pick_total_q;
  logic [63:0] dbg_ftb_jump_pick_total_q;
  logic [63:0] dbg_ftb_cond_tag_miss_total_q;
  logic [63:0] dbg_ftb_jump_tag_miss_total_q;
  logic [63:0] dbg_ftb_train_cond_total_q;
  logic [63:0] dbg_ftb_train_jump_total_q;
  logic [63:0] dbg_ittage_lookup_total_q;
  logic [63:0] dbg_ittage_hit_total_q;
  logic [63:0] dbg_ittage_use_total_q;
  logic [63:0] dbg_ittage_train_total_q;
  logic dbg_snap_ftb_cond_hit_w;
  logic dbg_snap_ftb_jump_hit_w;
  logic dbg_snap_ftb_pick_cond_w;
  logic dbg_snap_ftb_pick_jump_w;
  logic dbg_snap_ftb_cond_tag_miss_w;
  logic dbg_snap_ftb_jump_tag_miss_w;
  logic dbg_snap_ftb_any_valid_w;
  logic dbg_snap_ftb_tag_hit_w;
  logic [2:0] dbg_snap_ftb_valid_count_w;
  logic [2:0] dbg_snap_ftb_cond_count_w;
  logic [2:0] dbg_snap_ftb_jump_count_w;
  logic dbg_snap_ftb_cond_in_range_w;
  logic dbg_snap_ftb_jump_in_range_w;
  logic dbg_snap_ftb_cond_taken_pred_w;
  logic dbg_snap_ftb_jump_indirect_w;
  logic dbg_snap_ittage_raw_hit_w;
  logic dbg_snap_ittage_use_w;
  // Profile：按 FTQ id 记录预测时刻 FTB 状态，供 mispredict 诊断细分。
  localparam int unsigned FTQ_DEPTH = global_config_pkg::FTQ_DEPTH;
  localparam int unsigned FTQ_ID_W = global_config_pkg::FTQ_ID_W;
  logic [FTQ_DEPTH-1:0] pred_snap_valid_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_hit_q;
  logic [FTQ_DEPTH-1:0] pred_snap_jump_hit_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_tag_miss_q;
  logic [FTQ_DEPTH-1:0] pred_snap_jump_tag_miss_q;
  logic [FTQ_DEPTH-1:0] pred_snap_any_valid_q;
  logic [FTQ_DEPTH-1:0] pred_snap_tag_hit_q;
  logic [FTQ_DEPTH-1:0][2:0] pred_snap_valid_count_q;
  logic [FTQ_DEPTH-1:0][2:0] pred_snap_cond_count_q;
  logic [FTQ_DEPTH-1:0][2:0] pred_snap_jump_count_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_in_range_q;
  logic [FTQ_DEPTH-1:0] pred_snap_jump_in_range_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_taken_pred_q;
  logic [FTQ_DEPTH-1:0] pred_snap_pick_cond_q;
  logic [FTQ_DEPTH-1:0] pred_snap_pick_jump_q;
  logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] pred_snap_fetch_pc_q;
  logic [FTQ_DEPTH-1:0][FETCH_EPOCH_W-1:0] pred_snap_fetch_epoch_q;
  logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] pred_snap_cond_branch_pc_q;
  logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] pred_snap_jump_branch_pc_q;
  logic pred_fire_comb_w;
  logic [TAGE_TRACK_DEPTH-1:0] tage_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] tage_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] tage_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] tage_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] tage_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0] sc_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] sc_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] sc_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] sc_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] sc_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0] loop_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] loop_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] loop_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] loop_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] loop_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0][1:0] cond_track_provider_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_selected_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_legacy_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_tage_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_sc_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_loop_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_tage_candidate_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_sc_candidate_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_loop_candidate_q;
  logic [TAGE_TRACK_PTR_W-1:0] cond_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] cond_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] cond_track_count_q;

  function automatic logic [BTB_IDX_W-1:0] btb_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BTB_IDX_W-1:0] pc_idx;
    logic [BTB_IDX_W-1:0] fold_idx;
    begin
      pc_idx = pc[BLOCK_ADDR_LSB +: BTB_IDX_W];
      fold_idx = '0;
      for (int i = BLOCK_ADDR_LSB + BTB_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (BLOCK_ADDR_LSB + BTB_IDX_W)) % BTB_IDX_W] ^= pc[i];
      end
      btb_index = BTB_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
    end
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_tag(input logic [Cfg.PLEN-1:0] pc);
    btb_tag = pc[Cfg.PLEN-1:BLOCK_ADDR_LSB+BTB_IDX_W];
  endfunction

  function automatic logic [BHT_IDX_W-1:0] bht_pc_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BHT_IDX_W-1:0] pc_idx;
    logic [BHT_IDX_W-1:0] fold_idx;
    logic [BHT_IDX_W-1:0] mixed_pc_idx;
    begin
      pc_idx = pc[INSTR_ADDR_LSB+:BHT_IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + BHT_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (INSTR_ADDR_LSB + BHT_IDX_W)) % BHT_IDX_W] ^= pc[i];
      end
      mixed_pc_idx = BHT_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
      bht_pc_index = mixed_pc_idx;
    end
  endfunction

  function automatic logic [BHT_IDX_W-1:0] bht_global_index(input logic [Cfg.PLEN-1:0] pc,
                                                             input logic [GHR_W-1:0] ghr);
    logic [BHT_IDX_W-1:0] ghr_idx;
    begin
      ghr_idx = '0;
      for (int i = 0; i < BHT_IDX_W; i++) begin
        ghr_idx[i] = ghr[i%GHR_W];
      end
      bht_global_index = bht_pc_index(pc) ^ ghr_idx;
    end
  endfunction

  function automatic logic bht_predict_taken(input logic [Cfg.PLEN-1:0] pc,
                                             input logic [GHR_W-1:0] ghr,
                                             input logic is_backward);
    logic [BHT_IDX_W-1:0] local_idx;
    logic [BHT_IDX_W-1:0] global_idx;
    logic [1:0] local_ctr;
    logic [1:0] global_ctr;
    logic local_taken;
    logic global_taken;
    logic use_global;
    begin
      local_idx = bht_pc_index(pc);
      global_idx = bht_global_index(pc, ghr);
      local_ctr = local_bht_q[local_idx];
      global_ctr = global_bht_q[global_idx];
      local_taken = local_ctr[1] || ((local_ctr == 2'b01) && is_backward);
      global_taken = global_ctr[1] || ((global_ctr == 2'b01) && is_backward);
      use_global = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[local_idx][1]);
      bht_predict_taken = use_global ? global_taken : local_taken;
    end
  endfunction

  function automatic logic [1:0] sat_inc(input logic [1:0] val);
    if (val == 2'b11) sat_inc = val;
    else sat_inc = val + 2'b01;
  endfunction

  function automatic logic [1:0] sat_dec(input logic [1:0] val);
    if (val == 2'b00) sat_dec = val;
    else sat_dec = val - 2'b01;
  endfunction

  function automatic logic [GHR_W-1:0] ghr_shift(input logic [GHR_W-1:0] hist,
                                                 input logic                 taken);
    begin
      ghr_shift = (hist << 1) | GHR_W'(taken);
    end
  endfunction

  function automatic logic [PATH_HIST_W-1:0] path_shift(input logic [PATH_HIST_W-1:0] hist,
                                                         input logic [Cfg.PLEN-1:0]      pc,
                                                         input logic                      taken);
    logic [PATH_HIST_W-1:0] pc_mix;
    begin
      pc_mix = '0;
      for (int i = 0; i < Cfg.PLEN; i++) begin
        pc_mix[i%PATH_HIST_W] ^= pc[i];
      end
      path_shift = {hist[PATH_HIST_W-2:0], taken} ^ pc_mix;
    end
  endfunction

  // FTB 单分支预测：原 [INSTR_PER_FETCH] per-slot 向量收敛为单分支标量。
  logic [Cfg.PLEN-1:0] aligned_base_w;
  logic [BTB_IDX_W-1:0] btb_pred_idx_w;
  logic scan_next_block_w;
  // 双槽各自还原的分支 PC：cond 槽喂 BHT/TAGE/SC/Loop，jump 槽喂 ITTAGE。
  logic [Cfg.PLEN-1:0] cond_branch_pc_w;
  logic [Cfg.PLEN-1:0] jump_branch_pc_w;
  logic predict_hit;
  logic predict_taken;
  logic predict_is_cond;
  logic predict_is_call;
  logic predict_is_ret;
  logic predict_is_rvc;
  logic predict_is_indirect;
  logic [Cfg.PLEN-1:0] predict_target;
  logic ftb_pick_valid_w;
  logic ftb_pick_is_cond_w;
  logic ftb_pick_is_call_w;
  logic ftb_pick_is_ret_w;
  logic ftb_pick_is_rvc_w;
  logic ftb_pick_is_backward_w;
  logic ftb_pick_is_indirect_w;
  logic [SLOT_IDX_W-1:0] ftb_pick_end_idx_w;
  logic [Cfg.PLEN-1:0] ftb_pick_pc_w;
  logic [Cfg.PLEN-1:0] ftb_pick_target_w;
  logic ittage_raw_hit_w;
  logic ittage_hit_w;
  logic [Cfg.PLEN-1:0] ittage_target_w;
  logic [Cfg.PLEN-1:0] spec_ras_top_w;
  logic spec_ras_has_entry_w;
  logic [Cfg.PLEN-1:0] arch_ras_top_w;
  logic arch_ras_has_entry_w;
  logic [SLOT_IDX_W-1:0] pred_slot_idx_w;
  logic pred_slot_valid_w;
  logic pred_slot_is_call_w;
  logic pred_slot_is_ret_w;
  logic pred_slot_is_rvc_w;
  logic pred_slot_is_cond_w;
  logic pred_slot_taken_w;
  logic [Cfg.PLEN-1:0] pred_slot_pc_w;
  logic [Cfg.PLEN-1:0] pred_slot_target_w;
  logic [Cfg.PLEN-1:0] pred_npc_w;
  logic tage_hit_w;
  logic tage_taken_w;
  logic tage_strong_w;
  logic [1:0] tage_provider_w;
  logic [1:0] tage_useful_w;
  logic sc_taken_w;
  logic sc_confident_w;
  logic loop_hit_w;
  logic loop_taken_w;
  logic loop_confident_w;
  logic cond_taken_legacy_w;
  logic cond_tage_override_w;
  logic cond_sc_override_w;
  logic cond_loop_override_w;
  logic cond_tage_candidate_w;
  logic cond_sc_candidate_w;
  logic cond_loop_candidate_w;
  logic [1:0] cond_selected_provider_w;
  logic cond_selected_taken_w;
`ifndef SYNTHESIS

`endif

  assign ghr_q = spec_ghr_q;

  // FTB 查询：用 16B 对齐的 block_base 索引 BTB；lookup 扫描 4 个统一 slot。
  assign aligned_base_w = pc_reg_q & BLOCK_ALIGN_MASK;
  assign btb_pred_idx_w = btb_index(aligned_base_w);
  assign scan_next_block_w = |pc_reg_q[BLOCK_ADDR_LSB-1:0];

  always_comb begin
    ittage_predict_ctx_w = spec_path_hist_q;
    if (!flush_i && pred_event_valid_q && pred_event_is_cond_q) begin
      ittage_predict_ctx_w = path_shift(ittage_predict_ctx_w, pred_event_pc_q, pred_event_taken_q);
    end
  end

  tage #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(1),
      .GHR_BITS(GHR_BITS),
      .TABLE_ENTRIES(Cfg.BPU_BHT_ENTRIES),
      .TAG_BITS(TAGE_TAG_BITS),
      .HIST_LEN0(TAGE_HIST_LEN0),
      .HIST_LEN1(TAGE_HIST_LEN1),
      .HIST_LEN2(TAGE_HIST_LEN2),
      .HIST_LEN3(TAGE_HIST_LEN3)
  ) u_tage (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(cond_branch_pc_w),
      .predict_ghr_i(spec_ghr_q),
      .predict_hit_o(tage_hit_w),
      .predict_taken_o(tage_taken_w),
      .predict_strong_o(tage_strong_w),
      .predict_provider_o(tage_provider_w),
      .predict_useful_o(tage_useful_w),
      .update_valid_i(update_valid_i && update_is_cond_i && USE_TAGE),
      .update_pc_i(update_pc_i),
      .update_ghr_i(arch_ghr_q),
      .update_taken_i(update_taken_i)
  );

  stat_corr #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(1),
      .GHR_BITS(GHR_BITS),
      .ENTRIES(SC_ENTRIES),
      .CTR_BITS(4),
      .CONF_THRESH(SC_CONF_THRESH)
  ) u_stat_corr (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(cond_branch_pc_w),
      .predict_ghr_i(spec_ghr_q),
      .predict_taken_o(sc_taken_w),
      .predict_confident_o(sc_confident_w),
      .update_valid_i(update_valid_i && update_is_cond_i && USE_SC),
      .update_pc_i(update_pc_i),
      .update_ghr_i(arch_ghr_q),
      .update_taken_i(update_taken_i)
  );

  loop_predictor #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(1),
      .ENTRIES(LOOP_ENTRIES),
      .TAG_BITS(LOOP_TAG_BITS),
      .CONF_THRESH(LOOP_CONF_THRESH)
  ) u_loop_predictor (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(cond_branch_pc_w),
      .predict_taken_o(loop_taken_w),
      .predict_confident_o(loop_confident_w),
      .predict_hit_o(loop_hit_w),
      .update_valid_i(update_valid_i && USE_LOOP),
      .update_pc_i(update_pc_i),
      .update_is_cond_i(update_is_cond_i),
      .update_taken_i(update_taken_i)
  );

  ittage #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(1),
      .ENTRIES(ITTAGE_ENTRIES),
      .TAG_BITS(ITTAGE_TAG_BITS),
      .PATH_HIST_BITS(PATH_HIST_W)
  ) u_ittage (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(jump_branch_pc_w),
      .predict_ctx_i(ittage_predict_ctx_w),
      .predict_hit_o(ittage_raw_hit_w),
      .predict_target_o(ittage_target_w),
      .update_valid_i(USE_ITTAGE && update_valid_i && !update_is_cond_i && update_taken_i &&
                      !update_is_call_i && !update_is_ret_i),
      .update_pc_i(update_pc_i),
      .update_ctx_i(ittage_predict_ctx_w),
      .update_target_i(update_target_i)
  );

  always_comb begin
    spec_ras_has_entry_w = (spec_ras_count_q != '0);
    spec_ras_top_w = '0;
    if (spec_ras_has_entry_w) begin
      spec_ras_top_w = spec_ras_stack_q[spec_ras_count_q-1];
    end
  end

  always_comb begin
    arch_ras_has_entry_w = (arch_ras_count_q != '0);
    arch_ras_top_w = '0;
    if (arch_ras_has_entry_w) begin
      arch_ras_top_w = arch_ras_stack_q[arch_ras_count_q-1];
    end
  end

  // FTB 预测：动态 fetch 窗口可能从 16B block 中间开始，因此窗口会跨到下一
  // 个 FTB block。lookup 同时扫描 fetch_start block 和必要时的 next block，
  // 再按真实 slot_pc 落在 [pc_reg_q, pc_reg_q+15] 内选最早 taken。
  // 32-bit 指令低半字若在上一 fetch 尾部，当前 fetch 的 slot0 是其高半字；
  // 这种 carry-end 分支按 slot0 预测，契约仍是“末半字索引”。
  always_comb begin
    logic [BTB_IDX_W-1:0] pick_idx;
    logic [BHT_IDX_W-1:0] local_idx;
    logic [BHT_IDX_W-1:0] global_idx;
    logic [BHT_IDX_W-1:0] chooser_idx;
    logic [1:0] local_ctr_pred;
    logic [1:0] global_ctr_pred;
    logic local_taken_pred;
    logic global_taken_pred;
    logic cond_taken_pred;
    logic use_global_pred;
    logic any_valid;
    logic tag_hit;
    logic cond_hit_any;
    logic jump_hit_any;
    logic cond_in_range_any;
    logic jump_in_range_any;
    logic cond_taken_pred_any;
    logic pick_valid;
    logic [FTB_SLOT_IDX_W-1:0] pick_slot;
    logic [Cfg.PLEN-1:0] pick_branch_pc;
    logic [SLOT_IDX_W-1:0] pick_end_idx;
    logic pick_is_cond;
    logic pick_is_call;
    logic pick_is_ret;
    logic pick_is_rvc;
    logic pick_is_backward;
    logic pick_is_indirect;
    logic cond_snap_set;
    logic jump_snap_set;
    logic [Cfg.PLEN-1:0] cond_snap_pc;
    logic [Cfg.PLEN-1:0] jump_snap_pc;

    cond_hit_any = 1'b0;
    jump_hit_any = 1'b0;
    cond_in_range_any = 1'b0;
    jump_in_range_any = 1'b0;
    cond_taken_pred_any = 1'b0;
    dbg_snap_ftb_valid_count_w = '0;
    dbg_snap_ftb_cond_count_w = '0;
    dbg_snap_ftb_jump_count_w = '0;
    pick_valid = 1'b0;
    pick_idx = '0;
    pick_slot = '0;
    pick_branch_pc = '0;
    pick_end_idx = '0;
    pick_is_cond = 1'b0;
    pick_is_call = 1'b0;
    pick_is_ret = 1'b0;
    pick_is_rvc = 1'b0;
    pick_is_backward = 1'b0;
    pick_is_indirect = 1'b0;
    cond_snap_set = 1'b0;
    jump_snap_set = 1'b0;
    cond_snap_pc = aligned_base_w;
    jump_snap_pc = aligned_base_w;
    cond_branch_pc_w = aligned_base_w;
    jump_branch_pc_w = aligned_base_w;
    any_valid = 1'b0;
    tag_hit = 1'b0;
    dbg_snap_ftb_cond_tag_miss_w = 1'b0;
    dbg_snap_ftb_jump_tag_miss_w = 1'b0;

    for (int b = 0; b < 2; b++) begin
      logic scan_block;
      logic [Cfg.PLEN-1:0] lookup_base;
      logic [BTB_IDX_W-1:0] lookup_idx;
      logic [BTB_TAG_W-1:0] lookup_tag;
      logic lookup_any_valid;
      logic lookup_tag_hit;

      scan_block = (b == 0) || scan_next_block_w;
      lookup_base = aligned_base_w + Cfg.PLEN'(b * Cfg.FETCH_WIDTH);
      lookup_idx = btb_index(lookup_base);
      lookup_tag = btb_tag(lookup_base);
      lookup_any_valid = |btb_slot_valid_q[lookup_idx];
      lookup_tag_hit = lookup_any_valid && (btb_tag_q[lookup_idx] == lookup_tag);

      if (scan_block) begin
        any_valid |= lookup_any_valid;
        tag_hit |= lookup_tag_hit;
        if (lookup_any_valid && !lookup_tag_hit) begin
          for (int s = 0; s < FTB_SLOTS; s++) begin
            if (btb_slot_valid_q[lookup_idx][s] && btb_slot_is_cond_q[lookup_idx][s]) begin
              dbg_snap_ftb_cond_tag_miss_w = 1'b1;
            end else if (btb_slot_valid_q[lookup_idx][s]) begin
              dbg_snap_ftb_jump_tag_miss_w = 1'b1;
            end
          end
        end
      end

      for (int s = 0; s < FTB_SLOTS; s++) begin
        logic slot_hit;
        logic slot_in_range;
        logic slot_carry_end;
        logic slot_taken_pred;
        logic [Cfg.PLEN-1:0] slot_pc;
        logic [Cfg.PLEN-1:0] slot_diff;
        logic [Cfg.PLEN-1:0] slot_start_rel;
        logic [Cfg.PLEN-1:0] slot_end_rel;
        logic [SLOT_IDX_W-1:0] slot_end_idx;

        slot_pc = lookup_base + (Cfg.PLEN'(btb_slot_offset_q[lookup_idx][s]) << 1);
        slot_diff = slot_pc - pc_reg_q;
        slot_start_rel = slot_diff >> 1;
        slot_end_rel = slot_start_rel +
                       (btb_slot_is_rvc_q[lookup_idx][s] ? Cfg.PLEN'(0) : Cfg.PLEN'(1));
        slot_hit = scan_block && lookup_tag_hit && btb_slot_valid_q[lookup_idx][s];
        if (slot_hit) begin
          dbg_snap_ftb_valid_count_w = dbg_snap_ftb_valid_count_w + 3'd1;
          if (btb_slot_is_cond_q[lookup_idx][s]) begin
            dbg_snap_ftb_cond_count_w = dbg_snap_ftb_cond_count_w + 3'd1;
          end else begin
            dbg_snap_ftb_jump_count_w = dbg_snap_ftb_jump_count_w + 3'd1;
          end
        end
        slot_carry_end = slot_hit && !btb_slot_is_rvc_q[lookup_idx][s] &&
                         ((slot_pc + Cfg.PLEN'(2)) == pc_reg_q);
        slot_end_idx = slot_carry_end ? '0 : slot_end_rel[SLOT_IDX_W-1:0];
        slot_in_range = slot_hit &&
                        (((slot_pc >= pc_reg_q) &&
                          (slot_end_rel <= Cfg.PLEN'(PRED_SLOT_COUNT - 1))) ||
                         slot_carry_end);
        slot_taken_pred = !btb_slot_is_cond_q[lookup_idx][s] ||
                          bht_predict_taken(slot_pc, spec_ghr_q,
                                            btb_slot_is_backward_q[lookup_idx][s]);

        if (slot_hit && btb_slot_is_cond_q[lookup_idx][s]) begin
          cond_hit_any = 1'b1;
          if (!cond_snap_set || (slot_pc < cond_snap_pc)) begin
            cond_snap_set = 1'b1;
            cond_snap_pc = slot_pc;
          end
          if (slot_in_range) begin
            cond_in_range_any = 1'b1;
          end
          if (slot_taken_pred) begin
            cond_taken_pred_any = 1'b1;
          end
        end else if (slot_hit) begin
          jump_hit_any = 1'b1;
          if (!jump_snap_set || (slot_pc < jump_snap_pc)) begin
            jump_snap_set = 1'b1;
            jump_snap_pc = slot_pc;
          end
          if (slot_in_range) begin
            jump_in_range_any = 1'b1;
          end
        end

        if (slot_in_range && slot_taken_pred &&
            (!pick_valid || (slot_pc < pick_branch_pc))) begin
          pick_valid = 1'b1;
          pick_idx = lookup_idx;
          pick_slot = FTB_SLOT_IDX_W'(s);
          pick_branch_pc = slot_pc;
          pick_end_idx = slot_end_idx;
        end
      end
    end

    if (cond_snap_set) begin
      cond_branch_pc_w = cond_snap_pc;
    end
    if (jump_snap_set) begin
      jump_branch_pc_w = jump_snap_pc;
    end
    if (pick_valid && btb_slot_is_cond_q[pick_idx][pick_slot]) begin
      cond_branch_pc_w = pick_branch_pc;
    end
    if (pick_valid && !btb_slot_is_cond_q[pick_idx][pick_slot]) begin
      jump_branch_pc_w = pick_branch_pc;
    end

    pick_is_cond = pick_valid && btb_slot_is_cond_q[pick_idx][pick_slot];
    pick_is_call = pick_valid && !pick_is_cond && btb_slot_is_call_q[pick_idx][pick_slot];
    pick_is_ret = pick_valid && !pick_is_cond && btb_slot_is_ret_q[pick_idx][pick_slot];
    pick_is_rvc = pick_valid && btb_slot_is_rvc_q[pick_idx][pick_slot];
    pick_is_backward = pick_valid && btb_slot_is_backward_q[pick_idx][pick_slot];
    pick_is_indirect = pick_valid && !pick_is_cond && !pick_is_call && !pick_is_ret;
    ftb_pick_valid_w = pick_valid;
    ftb_pick_is_cond_w = pick_is_cond;
    ftb_pick_is_call_w = pick_is_call;
    ftb_pick_is_ret_w = pick_is_ret;
    ftb_pick_is_rvc_w = pick_is_rvc;
    ftb_pick_is_backward_w = pick_is_backward;
    ftb_pick_is_indirect_w = pick_is_indirect;
    ftb_pick_end_idx_w = pick_end_idx;
    ftb_pick_pc_w = pick_valid ? pick_branch_pc : '0;
    ftb_pick_target_w = pick_valid ? btb_slot_target_q[pick_idx][pick_slot] : '0;

    local_idx = bht_pc_index(cond_branch_pc_w);
    global_idx = bht_global_index(cond_branch_pc_w, spec_ghr_q);
    chooser_idx = local_idx;

    // ---- cond legacy BHT 方向，供 debug/统计记录 ----
    local_ctr_pred = local_bht_q[local_idx];
    global_ctr_pred = global_bht_q[global_idx];
    local_taken_pred = local_ctr_pred[1] ||
                       ((local_ctr_pred == 2'b01) && ftb_pick_is_backward_w);
    global_taken_pred = global_ctr_pred[1] ||
                        ((global_ctr_pred == 2'b01) && ftb_pick_is_backward_w);
    use_global_pred = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[chooser_idx][1]);
    cond_taken_pred = use_global_pred ? global_taken_pred : local_taken_pred;
    cond_taken_legacy_w = cond_taken_pred;

    dbg_snap_ftb_cond_hit_w = cond_hit_any;
    dbg_snap_ftb_jump_hit_w = jump_hit_any;
    dbg_snap_ftb_any_valid_w = any_valid;
    dbg_snap_ftb_tag_hit_w = tag_hit;
    dbg_snap_ftb_pick_cond_w = pick_valid && pick_is_cond;
    dbg_snap_ftb_pick_jump_w = pick_valid && !pick_is_cond;
    dbg_snap_ftb_cond_in_range_w = cond_in_range_any;
    dbg_snap_ftb_jump_in_range_w = jump_in_range_any;
    dbg_snap_ftb_cond_taken_pred_w = cond_taken_pred_any;
    dbg_snap_ftb_jump_indirect_w = pick_is_indirect;
  end

  always_comb begin
    logic [BHT_IDX_W-1:0] local_idx;
    logic [BHT_IDX_W-1:0] global_idx;
    logic [1:0] local_ctr_pred;
    logic [1:0] global_ctr_pred;
    logic [1:0] selected_ctr_pred;
    logic local_taken_pred;
    logic global_taken_pred;
    logic use_global_pred;
    logic local_legacy_strong;
    logic global_legacy_strong;
    logic local_global_disagree;
    logic selected_legacy_strong;
    logic tage_provider_ok;
    logic tage_pred_nt_w;
    logic tage_strong_nt_w;
    logic tage_useful_ok_w;
    logic tage_nt_override_ok;
    logic tage_allow_override;
    logic sc_allow_override;

    local_idx = bht_pc_index(cond_branch_pc_w);
    global_idx = bht_global_index(cond_branch_pc_w, spec_ghr_q);
    local_ctr_pred = local_bht_q[local_idx];
    global_ctr_pred = global_bht_q[global_idx];
    local_taken_pred = local_ctr_pred[1] ||
                       ((local_ctr_pred == 2'b01) && ftb_pick_is_backward_w);
    global_taken_pred = global_ctr_pred[1] ||
                        ((global_ctr_pred == 2'b01) && ftb_pick_is_backward_w);
    use_global_pred = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[local_idx][1]);
    selected_ctr_pred = use_global_pred ? global_ctr_pred : local_ctr_pred;
    local_legacy_strong = (local_ctr_pred == 2'b00) || (local_ctr_pred == 2'b11);
    global_legacy_strong = (global_ctr_pred == 2'b00) || (global_ctr_pred == 2'b11);
    local_global_disagree = (local_taken_pred != global_taken_pred);
    selected_legacy_strong = (selected_ctr_pred == 2'b00) || (selected_ctr_pred == 2'b11);

    cond_tage_override_w = 1'b0;
    cond_sc_override_w = 1'b0;
    cond_loop_override_w = 1'b0;
    cond_selected_provider_w = COND_PROVIDER_LEGACY;
    cond_selected_taken_w = cond_taken_legacy_w;

    tage_provider_ok = (int'(tage_provider_w) >= int'(TAGE_OVERRIDE_MIN_PROVIDER));
    tage_pred_nt_w = !tage_taken_w;
    tage_strong_nt_w = tage_strong_w && tage_pred_nt_w;
    tage_useful_ok_w = |tage_useful_w;
    // 净正区：3-bit signed strong-NT（ctr 饱和 -4）+ useful>0 + MIN_PROVIDER 门控。
    tage_nt_override_ok = tage_strong_nt_w;
    tage_allow_override = USE_TAGE && tage_hit_w && tage_nt_override_ok && tage_provider_ok &&
                          tage_useful_ok_w;
    cond_tage_candidate_w = ftb_pick_is_cond_w && tage_allow_override;

    sc_allow_override = USE_SC && sc_confident_w;
    if (selected_legacy_strong) begin
      sc_allow_override = 1'b0;
    end
    if (SC_BLOCK_ON_TAGE_HIT && USE_TAGE && tage_hit_w) begin
      sc_allow_override = 1'b0;
    end
    if (SC_REQUIRE_DISAGREE && !local_global_disagree) begin
      sc_allow_override = 1'b0;
    end
    if (SC_REQUIRE_BOTH_WEAK && (local_legacy_strong || global_legacy_strong)) begin
      sc_allow_override = 1'b0;
    end
    cond_sc_candidate_w = ftb_pick_is_cond_w && sc_allow_override;
    cond_loop_candidate_w = USE_LOOP && ftb_pick_is_cond_w && loop_confident_w;

    // TAGE-SC-L 条件方向优先级：Loop > TAGE > SC > Legacy。
    // FTB 只 pick legacy-taken 槽；override 在更高优先级 provider 与 legacy 不一致时生效。
    if (cond_loop_candidate_w) begin
      cond_loop_override_w = (loop_taken_w != cond_taken_legacy_w);
      cond_selected_provider_w = COND_PROVIDER_LOOP;
      cond_selected_taken_w = loop_taken_w;
    end else if (cond_tage_candidate_w) begin
      cond_tage_override_w = 1'b1;
      cond_selected_provider_w = COND_PROVIDER_TAGE;
      cond_selected_taken_w = tage_taken_w;
    end else if (cond_sc_candidate_w) begin
      cond_sc_override_w = (sc_taken_w != cond_taken_legacy_w);
      cond_selected_provider_w = COND_PROVIDER_SC;
      cond_selected_taken_w = sc_taken_w;
    end

    ittage_hit_w = USE_ITTAGE && ftb_pick_is_indirect_w && ittage_raw_hit_w;
    predict_target = ftb_pick_target_w;
    if (ftb_pick_is_ret_w && spec_ras_has_entry_w) begin
      predict_target = spec_ras_top_w;
    end else if (ftb_pick_is_indirect_w && ittage_hit_w) begin
      predict_target = ittage_target_w;
    end

    predict_hit = ftb_pick_valid_w;
    if (ftb_pick_is_cond_w && predict_hit) begin
      predict_taken = cond_selected_taken_w;
    end else begin
      predict_taken = predict_hit;
    end
    predict_is_cond = ftb_pick_is_cond_w;
    predict_is_call = ftb_pick_is_call_w;
    predict_is_ret = ftb_pick_is_ret_w;
    predict_is_indirect = ftb_pick_is_indirect_w;
    predict_is_rvc = ftb_pick_is_rvc_w;

    // 下游 FTQ：只有"有效 taken"才需要重定向；override 成 NT 时按 fall-through 顺序前进。
    pred_slot_valid_w   = predict_hit && predict_taken;
    pred_slot_idx_w     = pred_slot_valid_w ? ftb_pick_end_idx_w : '0;
    pred_slot_is_call_w = pred_slot_valid_w && predict_is_call;
    pred_slot_is_ret_w  = pred_slot_valid_w && predict_is_ret;
    pred_slot_is_rvc_w  = pred_slot_valid_w && predict_is_rvc;
    // cond 事件用于历史/统计：与 taken 解耦，picked cond 无论翻不翻都记一次（方向见
    // pred_slot_taken_w）。picked-cond 集合不变，仅 taken 位随 override 改变。
    pred_slot_is_cond_w = predict_hit && predict_is_cond;
    pred_slot_taken_w   = predict_taken;
    pred_slot_pc_w      = predict_hit ? ftb_pick_pc_w : '0;
    pred_slot_target_w  = predict_target;

    dbg_snap_ittage_raw_hit_w = ittage_raw_hit_w;
    dbg_snap_ittage_use_w = ittage_hit_w;
  end

  assign pred_fire_comb_w = ftq_enq_valid_o && ftq_enq_ready_i;
  assign pred_npc_w = pred_slot_valid_w ? pred_slot_target_w : (pc_reg_q + Cfg.FETCH_WIDTH);

  assign ftq_enq_valid_o = !flush_i && !redirect_valid_i;
  assign ftq_enq_pc_o = pc_reg_q;
  assign ftq_enq_pred_slot_valid_o = pred_slot_valid_w;
  assign ftq_enq_pred_slot_idx_o = pred_slot_idx_w;
  assign ftq_enq_pred_target_o = pred_slot_target_w;
  assign ftq_enq_pred_npc_o = pred_npc_w;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      pc_reg_q <= Cfg.PLEN'(Cfg.RESET_VECTOR);
      btb_slot_valid_q <= '0;
      btb_slot_is_cond_q <= '0;
      btb_slot_is_rvc_q <= '0;
      btb_slot_is_call_q <= '0;
      btb_slot_is_ret_q <= '0;
      btb_slot_is_backward_q <= '0;
      btb_slot_offset_q <= '0;
      btb_slot_age_q <= '0;
      for (int e = 0; e < BTB_ENTRIES; e++) begin
        btb_tag_q[e] <= '0;
        for (int s = 0; s < FTB_SLOTS; s++) begin
          btb_slot_target_q[e][s] <= '0;
        end
      end
      arch_ras_stack_q   <= '0;
      spec_ras_stack_q   <= '0;
      arch_ras_count_q   <= '0;
      spec_ras_count_q   <= '0;
      pred_event_valid_q <= 1'b0;
      pred_event_is_call_q <= 1'b0;
      pred_event_is_ret_q <= 1'b0;
      pred_event_is_rvc_q <= 1'b0;
      pred_event_is_cond_q <= 1'b0;
      pred_event_taken_q <= 1'b0;
      pred_event_pc_q <= '0;
      pred_snap_valid_q <= '0;
      pred_snap_cond_hit_q <= '0;
      pred_snap_jump_hit_q <= '0;
      pred_snap_cond_tag_miss_q <= '0;
      pred_snap_jump_tag_miss_q <= '0;
      pred_snap_any_valid_q <= '0;
      pred_snap_tag_hit_q <= '0;
      pred_snap_valid_count_q <= '0;
      pred_snap_cond_count_q <= '0;
      pred_snap_jump_count_q <= '0;
      pred_snap_cond_in_range_q <= '0;
      pred_snap_jump_in_range_q <= '0;
      pred_snap_cond_taken_pred_q <= '0;
      pred_snap_pick_cond_q <= '0;
      pred_snap_pick_jump_q <= '0;
      pred_snap_fetch_pc_q <= '0;
      pred_snap_fetch_epoch_q <= '0;
      pred_snap_cond_branch_pc_q <= '0;
      pred_snap_jump_branch_pc_q <= '0;
      arch_ghr_q <= '0;
      spec_ghr_q <= '0;
      arch_path_hist_q <= '0;
      spec_path_hist_q <= '0;
      dbg_cond_update_total_q <= '0;
      dbg_cond_local_correct_q <= '0;
      dbg_cond_global_correct_q <= '0;
      dbg_cond_selected_correct_q <= '0;
      dbg_cond_choose_local_q <= '0;
      dbg_cond_choose_global_q <= '0;
      dbg_tage_lookup_total_q <= '0;
      dbg_tage_hit_total_q <= '0;
      dbg_tage_override_total_q <= '0;
      dbg_tage_override_correct_q <= '0;
      dbg_sc_lookup_total_q <= '0;
      dbg_sc_confident_total_q <= '0;
      dbg_sc_override_total_q <= '0;
      dbg_sc_override_correct_q <= '0;
      dbg_loop_lookup_total_q <= '0;
      dbg_loop_hit_total_q <= '0;
      dbg_loop_confident_total_q <= '0;
      dbg_loop_override_total_q <= '0;
      dbg_loop_override_correct_q <= '0;
      dbg_cond_provider_legacy_selected_q <= '0;
      dbg_cond_provider_tage_selected_q <= '0;
      dbg_cond_provider_sc_selected_q <= '0;
      dbg_cond_provider_loop_selected_q <= '0;
      dbg_cond_provider_legacy_correct_q <= '0;
      dbg_cond_provider_tage_correct_q <= '0;
      dbg_cond_provider_sc_correct_q <= '0;
      dbg_cond_provider_loop_correct_q <= '0;
      dbg_cond_selected_wrong_alt_legacy_correct_q <= '0;
      dbg_cond_selected_wrong_alt_tage_correct_q <= '0;
      dbg_cond_selected_wrong_alt_sc_correct_q <= '0;
      dbg_cond_selected_wrong_alt_loop_correct_q <= '0;
      dbg_cond_selected_wrong_alt_any_correct_q <= '0;
      dbg_ftb_lookup_total_q <= '0;
      dbg_ftb_cond_hit_total_q <= '0;
      dbg_ftb_jump_hit_total_q <= '0;
      dbg_ftb_cond_pick_total_q <= '0;
      dbg_ftb_jump_pick_total_q <= '0;
      dbg_ftb_cond_tag_miss_total_q <= '0;
      dbg_ftb_jump_tag_miss_total_q <= '0;
      dbg_ftb_train_cond_total_q <= '0;
      dbg_ftb_train_jump_total_q <= '0;
      dbg_ittage_lookup_total_q <= '0;
      dbg_ittage_hit_total_q <= '0;
      dbg_ittage_use_total_q <= '0;
      dbg_ittage_train_total_q <= '0;
      tage_track_override_q <= '0;
      tage_track_pred_taken_q <= '0;
      tage_track_head_q <= '0;
      tage_track_tail_q <= '0;
      tage_track_count_q <= '0;
      sc_track_override_q <= '0;
      sc_track_pred_taken_q <= '0;
      sc_track_head_q <= '0;
      sc_track_tail_q <= '0;
      sc_track_count_q <= '0;
      loop_track_override_q <= '0;
      loop_track_pred_taken_q <= '0;
      loop_track_head_q <= '0;
      loop_track_tail_q <= '0;
      loop_track_count_q <= '0;
      cond_track_provider_q <= '0;
      cond_track_selected_taken_q <= '0;
      cond_track_legacy_taken_q <= '0;
      cond_track_tage_taken_q <= '0;
      cond_track_sc_taken_q <= '0;
      cond_track_loop_taken_q <= '0;
      cond_track_tage_candidate_q <= '0;
      cond_track_sc_candidate_q <= '0;
      cond_track_loop_candidate_q <= '0;
      cond_track_head_q <= '0;
      cond_track_tail_q <= '0;
      cond_track_count_q <= '0;
`ifndef SYNTHESIS
`endif
      for (int i = 0; i < BHT_ENTRIES; i++) begin
        local_bht_q[i] <= 2'b01;
        global_bht_q[i] <= 2'b01;
        chooser_q[i] <= 2'b01;
      end
    end else begin
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_stack_n;
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_stack_n;
      logic [RAS_CNT_W-1:0] arch_count_n;
      logic [RAS_CNT_W-1:0] spec_count_n;
      logic [Cfg.PLEN-1:0] up_block_base;
      logic [BTB_IDX_W-1:0] up_btb_idx;
      logic [BTB_TAG_W-1:0] up_btb_tag;
      logic [SLOT_IDX_W-1:0] up_offset;
      logic up_do_ftb_train;
      logic up_tag_match;
      logic up_slot_found;
      logic up_empty_found;
      logic [FTB_SLOT_IDX_W-1:0] up_alloc_slot;
      logic [FTB_AGE_W-1:0] up_alloc_age;
      logic [BHT_IDX_W-1:0] up_local_idx;
      logic [BHT_IDX_W-1:0] up_global_idx;
      logic [BHT_IDX_W-1:0] up_chooser_idx;
      logic pred_fire_w;
      logic local_pred_before;
      logic global_pred_before;
      logic selected_pred_before;
      logic choose_global_before;
      logic local_correct;
      logic global_correct;
      logic selected_correct;
      logic [TAGE_TRACK_PTR_W-1:0] tage_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] tage_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] tage_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] tage_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] tage_pred_taken_n;
      logic [TAGE_TRACK_PTR_W-1:0] sc_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] sc_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] sc_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] sc_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] sc_pred_taken_n;
      logic [TAGE_TRACK_PTR_W-1:0] loop_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] loop_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] loop_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] loop_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] loop_pred_taken_n;
      logic tage_pop_override;
      logic tage_pop_pred_taken;
      logic tage_push_override;
      logic sc_pop_override;
      logic sc_pop_pred_taken;
      logic sc_push_override;
      logic loop_pop_override;
      logic loop_pop_pred_taken;
      logic loop_push_override;
      logic [TAGE_TRACK_PTR_W-1:0] cond_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] cond_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] cond_count_n;
      logic [TAGE_TRACK_DEPTH-1:0][1:0] cond_provider_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_selected_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_legacy_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_tage_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_sc_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_loop_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_tage_candidate_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_sc_candidate_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_loop_candidate_n;
      logic [1:0] cond_pop_provider;
      logic cond_pop_selected_taken;
      logic cond_pop_legacy_taken;
      logic cond_pop_tage_taken;
      logic cond_pop_sc_taken;
      logic cond_pop_loop_taken;
      logic cond_pop_tage_candidate;
      logic cond_pop_sc_candidate;
      logic cond_pop_loop_candidate;
      logic cond_selected_pred_correct;
      logic cond_alt_any_correct;
      logic [GHR_W-1:0] arch_ghr_n;
      logic [GHR_W-1:0] spec_ghr_n;
      logic [PATH_HIST_W-1:0] arch_path_hist_n;
      logic [PATH_HIST_W-1:0] spec_path_hist_n;

      arch_stack_n = arch_ras_stack_q;
      spec_stack_n = spec_ras_stack_q;
      arch_count_n = arch_ras_count_q;
      spec_count_n = spec_ras_count_q;
      arch_ghr_n = arch_ghr_q;
      spec_ghr_n = spec_ghr_q;
      arch_path_hist_n = arch_path_hist_q;
      spec_path_hist_n = spec_path_hist_q;
      tage_head_n = tage_track_head_q;
      tage_tail_n = tage_track_tail_q;
      tage_count_n = tage_track_count_q;
      tage_override_n = tage_track_override_q;
      tage_pred_taken_n = tage_track_pred_taken_q;
      sc_head_n = sc_track_head_q;
      sc_tail_n = sc_track_tail_q;
      sc_count_n = sc_track_count_q;
      sc_override_n = sc_track_override_q;
      sc_pred_taken_n = sc_track_pred_taken_q;
      loop_head_n = loop_track_head_q;
      loop_tail_n = loop_track_tail_q;
      loop_count_n = loop_track_count_q;
      loop_override_n = loop_track_override_q;
      loop_pred_taken_n = loop_track_pred_taken_q;
      cond_head_n = cond_track_head_q;
      cond_tail_n = cond_track_tail_q;
      cond_count_n = cond_track_count_q;
      cond_provider_n = cond_track_provider_q;
      cond_selected_taken_n = cond_track_selected_taken_q;
      cond_legacy_taken_n = cond_track_legacy_taken_q;
      cond_tage_taken_n = cond_track_tage_taken_q;
      cond_sc_taken_n = cond_track_sc_taken_q;
      cond_loop_taken_n = cond_track_loop_taken_q;
      cond_tage_candidate_n = cond_track_tage_candidate_q;
      cond_sc_candidate_n = cond_track_sc_candidate_q;
      cond_loop_candidate_n = cond_track_loop_candidate_q;
      tage_pop_override = 1'b0;
      tage_pop_pred_taken = 1'b0;
      tage_push_override = 1'b0;
      sc_pop_override = 1'b0;
      sc_pop_pred_taken = 1'b0;
      sc_push_override = 1'b0;
      loop_pop_override = 1'b0;
      loop_pop_pred_taken = 1'b0;
      loop_push_override = 1'b0;
      cond_pop_provider = COND_PROVIDER_LEGACY;
      cond_pop_selected_taken = 1'b0;
      cond_pop_legacy_taken = 1'b0;
      cond_pop_tage_taken = 1'b0;
      cond_pop_sc_taken = 1'b0;
      cond_pop_loop_taken = 1'b0;
      cond_pop_tage_candidate = 1'b0;
      cond_pop_sc_candidate = 1'b0;
      cond_pop_loop_candidate = 1'b0;
      cond_selected_pred_correct = 1'b0;
      cond_alt_any_correct = 1'b0;
      pred_fire_w = ftq_enq_valid_o && ftq_enq_ready_i;

      if (redirect_valid_i) begin
        pc_reg_q <= redirect_pc_i;
      end else if (pred_fire_w) begin
        pc_reg_q <= pred_npc_w;
      end

      if (update_valid_i) begin
        // FTB 训练：BTB 按 16B 对齐 block_base 索引/打 tag；BHT/TAGE 仍用真实分支 PC。
        up_block_base = update_pc_i & BLOCK_ALIGN_MASK;
        up_btb_idx = btb_index(up_block_base);
        up_btb_tag = btb_tag(up_block_base);
        up_offset = update_pc_i[SLOT_IDX_W:1];
        up_do_ftb_train = !update_is_cond_i || update_taken_i;
        up_tag_match = (|btb_slot_valid_q[up_btb_idx]) &&
                       (btb_tag_q[up_btb_idx] == up_btb_tag);
        up_slot_found = 1'b0;
        up_empty_found = 1'b0;
        up_alloc_slot = '0;
        up_alloc_age = '0;
        up_local_idx = bht_pc_index(update_pc_i);
        up_global_idx = bht_global_index(update_pc_i, arch_ghr_q);
        up_chooser_idx = up_local_idx;

        // FTB 4 槽训练：同 offset 更新，否则空槽插入，再否则替换 LRU。
        if (up_do_ftb_train) begin
          if (up_tag_match) begin
            for (int s = 0; s < FTB_SLOTS; s++) begin
              if (btb_slot_valid_q[up_btb_idx][s] &&
                  (btb_slot_offset_q[up_btb_idx][s] == up_offset) &&
                  !up_slot_found) begin
                up_slot_found = 1'b1;
                up_alloc_slot = FTB_SLOT_IDX_W'(s);
                up_alloc_age = btb_slot_age_q[up_btb_idx][s];
              end
            end
            if (!up_slot_found) begin
              for (int s = 0; s < FTB_SLOTS; s++) begin
                if (!btb_slot_valid_q[up_btb_idx][s] && !up_empty_found) begin
                  up_empty_found = 1'b1;
                  up_alloc_slot = FTB_SLOT_IDX_W'(s);
                end
              end
            end
            if (!up_slot_found && !up_empty_found) begin
              for (int s = 0; s < FTB_SLOTS; s++) begin
                if (btb_slot_age_q[up_btb_idx][s] >= up_alloc_age) begin
                  up_alloc_age = btb_slot_age_q[up_btb_idx][s];
                  up_alloc_slot = FTB_SLOT_IDX_W'(s);
                end
              end
            end
          end

          btb_tag_q[up_btb_idx] <= up_btb_tag;
          if (!up_tag_match) begin
            btb_slot_valid_q[up_btb_idx] <= '0;
            btb_slot_age_q[up_btb_idx] <= '0;
          end else begin
            for (int s = 0; s < FTB_SLOTS; s++) begin
              if (btb_slot_valid_q[up_btb_idx][s] &&
                  (FTB_SLOT_IDX_W'(s) != up_alloc_slot)) begin
                if (up_slot_found) begin
                  if (btb_slot_age_q[up_btb_idx][s] < up_alloc_age) begin
                    btb_slot_age_q[up_btb_idx][s] <= btb_slot_age_q[up_btb_idx][s] +
                                                     FTB_AGE_W'(1);
                  end
                end else if (btb_slot_age_q[up_btb_idx][s] != FTB_AGE_MAX) begin
                  btb_slot_age_q[up_btb_idx][s] <= btb_slot_age_q[up_btb_idx][s] +
                                                   FTB_AGE_W'(1);
                end
              end
            end
          end

          btb_slot_valid_q[up_btb_idx][up_alloc_slot] <= 1'b1;
          btb_slot_is_cond_q[up_btb_idx][up_alloc_slot] <= update_is_cond_i;
          btb_slot_is_rvc_q[up_btb_idx][up_alloc_slot] <= update_is_rvc_i;
          btb_slot_is_call_q[up_btb_idx][up_alloc_slot] <= update_is_call_i;
          btb_slot_is_ret_q[up_btb_idx][up_alloc_slot] <= update_is_ret_i;
          btb_slot_is_backward_q[up_btb_idx][up_alloc_slot] <=
              (update_target_i < update_pc_i);
          btb_slot_offset_q[up_btb_idx][up_alloc_slot] <= up_offset;
          btb_slot_target_q[up_btb_idx][up_alloc_slot] <= update_target_i;
          btb_slot_age_q[up_btb_idx][up_alloc_slot] <= '0;

          if (update_is_cond_i) begin
            dbg_ftb_train_cond_total_q <= dbg_ftb_train_cond_total_q + 64'd1;
          end else begin
            dbg_ftb_train_jump_total_q <= dbg_ftb_train_jump_total_q + 64'd1;
          end
        end
        if (USE_ITTAGE && update_valid_i && !update_is_cond_i && update_taken_i &&
            !update_is_call_i && !update_is_ret_i) begin
          dbg_ittage_train_total_q <= dbg_ittage_train_total_q + 64'd1;
        end

        if (update_is_cond_i) begin
          local_pred_before = local_bht_q[up_local_idx][1] ||
                              ((local_bht_q[up_local_idx] == 2'b01) &&
                               (update_target_i < update_pc_i));
          global_pred_before = global_bht_q[up_global_idx][1] ||
                               ((global_bht_q[up_global_idx] == 2'b01) &&
                                (update_target_i < update_pc_i));
          choose_global_before = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[up_chooser_idx][1]);
          selected_pred_before = choose_global_before ? global_pred_before : local_pred_before;
          local_correct = (local_pred_before == update_taken_i);
          global_correct = (global_pred_before == update_taken_i);
          selected_correct = (selected_pred_before == update_taken_i);

          dbg_cond_update_total_q <= dbg_cond_update_total_q + 64'd1;
          if (local_correct) begin
            dbg_cond_local_correct_q <= dbg_cond_local_correct_q + 64'd1;
          end
          if (global_correct) begin
            dbg_cond_global_correct_q <= dbg_cond_global_correct_q + 64'd1;
          end
          if (selected_correct) begin
            dbg_cond_selected_correct_q <= dbg_cond_selected_correct_q + 64'd1;
          end
          if (choose_global_before) begin
            dbg_cond_choose_global_q <= dbg_cond_choose_global_q + 64'd1;
          end else begin
            dbg_cond_choose_local_q <= dbg_cond_choose_local_q + 64'd1;
          end

          if (update_taken_i) begin
            local_bht_q[up_local_idx] <= sat_inc(local_bht_q[up_local_idx]);
            global_bht_q[up_global_idx] <= sat_inc(global_bht_q[up_global_idx]);
          end else begin
            local_bht_q[up_local_idx] <= sat_dec(local_bht_q[up_local_idx]);
            global_bht_q[up_global_idx] <= sat_dec(global_bht_q[up_global_idx]);
          end

          if (USE_GSHARE && USE_TOURNAMENT && (local_correct != global_correct)) begin
            if (global_correct) begin
              chooser_q[up_chooser_idx] <= sat_inc(chooser_q[up_chooser_idx]);
            end else begin
              chooser_q[up_chooser_idx] <= sat_dec(chooser_q[up_chooser_idx]);
            end
          end

          arch_ghr_n = ghr_shift(arch_ghr_n, update_taken_i);
          arch_path_hist_n = path_shift(arch_path_hist_n, update_pc_i, update_taken_i);
        end

        if (USE_TAGE && update_is_cond_i && (tage_count_n != '0)) begin
          tage_pop_override = tage_override_n[tage_head_n];
          tage_pop_pred_taken = tage_pred_taken_n[tage_head_n];
          tage_head_n = tage_head_n + TAGE_TRACK_PTR_W'(1);
          tage_count_n = tage_count_n - TAGE_TRACK_CNT_W'(1);
          if (tage_pop_override && (tage_pop_pred_taken == update_taken_i)) begin
            dbg_tage_override_correct_q <= dbg_tage_override_correct_q + 64'd1;
          end
        end
        if (USE_SC && update_is_cond_i && (sc_count_n != '0)) begin
          sc_pop_override = sc_override_n[sc_head_n];
          sc_pop_pred_taken = sc_pred_taken_n[sc_head_n];
          sc_head_n = sc_head_n + TAGE_TRACK_PTR_W'(1);
          sc_count_n = sc_count_n - TAGE_TRACK_CNT_W'(1);
          if (sc_pop_override && (sc_pop_pred_taken == update_taken_i)) begin
            dbg_sc_override_correct_q <= dbg_sc_override_correct_q + 64'd1;
          end
        end
        if (USE_LOOP && update_is_cond_i && (loop_count_n != '0)) begin
          loop_pop_override = loop_override_n[loop_head_n];
          loop_pop_pred_taken = loop_pred_taken_n[loop_head_n];
          loop_head_n = loop_head_n + TAGE_TRACK_PTR_W'(1);
          loop_count_n = loop_count_n - TAGE_TRACK_CNT_W'(1);
          if (loop_pop_override && (loop_pop_pred_taken == update_taken_i)) begin
            dbg_loop_override_correct_q <= dbg_loop_override_correct_q + 64'd1;
          end
        end
        if (update_is_cond_i && (cond_count_n != '0)) begin
          cond_pop_provider = cond_provider_n[cond_head_n];
          cond_pop_selected_taken = cond_selected_taken_n[cond_head_n];
          cond_pop_legacy_taken = cond_legacy_taken_n[cond_head_n];
          cond_pop_tage_taken = cond_tage_taken_n[cond_head_n];
          cond_pop_sc_taken = cond_sc_taken_n[cond_head_n];
          cond_pop_loop_taken = cond_loop_taken_n[cond_head_n];
          cond_pop_tage_candidate = cond_tage_candidate_n[cond_head_n];
          cond_pop_sc_candidate = cond_sc_candidate_n[cond_head_n];
          cond_pop_loop_candidate = cond_loop_candidate_n[cond_head_n];
          cond_head_n = cond_head_n + TAGE_TRACK_PTR_W'(1);
          cond_count_n = cond_count_n - TAGE_TRACK_CNT_W'(1);

          cond_selected_pred_correct = (cond_pop_selected_taken == update_taken_i);
          case (cond_pop_provider)
            COND_PROVIDER_TAGE: begin
              dbg_cond_provider_tage_selected_q <= dbg_cond_provider_tage_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_tage_correct_q <= dbg_cond_provider_tage_correct_q + 64'd1;
              end
            end
            COND_PROVIDER_SC: begin
              dbg_cond_provider_sc_selected_q <= dbg_cond_provider_sc_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_sc_correct_q <= dbg_cond_provider_sc_correct_q + 64'd1;
              end
            end
            COND_PROVIDER_LOOP: begin
              dbg_cond_provider_loop_selected_q <= dbg_cond_provider_loop_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_loop_correct_q <= dbg_cond_provider_loop_correct_q + 64'd1;
              end
            end
            default: begin
              dbg_cond_provider_legacy_selected_q <= dbg_cond_provider_legacy_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_legacy_correct_q <= dbg_cond_provider_legacy_correct_q + 64'd1;
              end
            end
          endcase

          if (!cond_selected_pred_correct) begin
            cond_alt_any_correct = 1'b0;
            if ((cond_pop_provider != COND_PROVIDER_LEGACY) &&
                (cond_pop_legacy_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_legacy_correct_q <=
                  dbg_cond_selected_wrong_alt_legacy_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_TAGE) &&
                cond_pop_tage_candidate &&
                (cond_pop_tage_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_tage_correct_q <=
                  dbg_cond_selected_wrong_alt_tage_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_SC) &&
                cond_pop_sc_candidate &&
                (cond_pop_sc_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_sc_correct_q <=
                  dbg_cond_selected_wrong_alt_sc_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_LOOP) &&
                cond_pop_loop_candidate &&
                (cond_pop_loop_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_loop_correct_q <=
                  dbg_cond_selected_wrong_alt_loop_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if (cond_alt_any_correct) begin
              dbg_cond_selected_wrong_alt_any_correct_q <=
                  dbg_cond_selected_wrong_alt_any_correct_q + 64'd1;
            end
          end
        end
      end

      for (int i = 0; i < Cfg.NRET; i++) begin
        if (ras_update_valid_i[i]) begin
          if (ras_update_is_call_i[i]) begin
            logic [Cfg.PLEN-1:0] call_ret_addr;
            call_ret_addr = ras_update_pc_i[i] +
                            (ras_update_is_rvc_i[i] ? Cfg.PLEN'(2) : Cfg.PLEN'(INSTR_BYTES));
            if (arch_count_n < RAS_DEPTH) begin
              arch_stack_n[arch_count_n] = call_ret_addr;
              arch_count_n = arch_count_n + 1'b1;
            end else begin
              for (int j = 0; j < RAS_DEPTH - 1; j++) begin
                arch_stack_n[j] = arch_stack_n[j+1];
              end
              arch_stack_n[RAS_DEPTH-1] = call_ret_addr;
              arch_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
            end
          end else if (ras_update_is_ret_i[i]) begin
            if (arch_count_n != '0) begin
              arch_count_n = arch_count_n - 1'b1;
            end
          end
        end
      end

      if (flush_i) begin
        spec_stack_n = arch_stack_n;
        spec_count_n = arch_count_n;
        spec_path_hist_n = arch_path_hist_n;
      end else if (pred_event_valid_q && pred_event_is_call_q) begin
        logic [Cfg.PLEN-1:0] spec_ret_addr;
        spec_ret_addr = pred_event_pc_q +
                        (pred_event_is_rvc_q ? Cfg.PLEN'(2) : Cfg.PLEN'(INSTR_BYTES));
        if (spec_count_n < RAS_DEPTH) begin
          spec_stack_n[spec_count_n] = spec_ret_addr;
          spec_count_n = spec_count_n + 1'b1;
        end else begin
          for (int i = 0; i < RAS_DEPTH - 1; i++) begin
            spec_stack_n[i] = spec_stack_n[i+1];
          end
          spec_stack_n[RAS_DEPTH-1] = spec_ret_addr;
          spec_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
        end
      end else if (pred_event_valid_q && pred_event_is_ret_q) begin
        if (spec_count_n != '0) begin
          spec_count_n = spec_count_n - 1'b1;
        end
      end

      if (flush_i) begin
        spec_ghr_n = arch_ghr_n;
        tage_head_n = '0;
        tage_tail_n = '0;
        tage_count_n = '0;
        tage_override_n = '0;
        tage_pred_taken_n = '0;
        sc_head_n = '0;
        sc_tail_n = '0;
        sc_count_n = '0;
        sc_override_n = '0;
        sc_pred_taken_n = '0;
        loop_head_n = '0;
        loop_tail_n = '0;
        loop_count_n = '0;
        loop_override_n = '0;
        loop_pred_taken_n = '0;
        cond_head_n = '0;
        cond_tail_n = '0;
        cond_count_n = '0;
        cond_provider_n = '0;
        cond_selected_taken_n = '0;
        cond_legacy_taken_n = '0;
        cond_tage_taken_n = '0;
        cond_sc_taken_n = '0;
        cond_loop_taken_n = '0;
        cond_tage_candidate_n = '0;
        cond_sc_candidate_n = '0;
        cond_loop_candidate_n = '0;
      end else if (pred_event_valid_q && pred_event_is_cond_q) begin
        spec_ghr_n = ghr_shift(spec_ghr_n, pred_event_taken_q);
        spec_path_hist_n = path_shift(spec_path_hist_n, pred_event_pc_q, pred_event_taken_q);
      end
      arch_ras_stack_q <= arch_stack_n;
      arch_ras_count_q <= arch_count_n;
      spec_ras_stack_q <= spec_stack_n;
      spec_ras_count_q <= spec_count_n;
      arch_ghr_q <= arch_ghr_n;
      spec_ghr_q <= spec_ghr_n;
      arch_path_hist_q <= arch_path_hist_n;
      spec_path_hist_q <= spec_path_hist_n;

      if (flush_i) begin
        pred_event_valid_q <= 1'b0;
        pred_event_is_call_q <= 1'b0;
        pred_event_is_ret_q <= 1'b0;
        pred_event_is_rvc_q <= 1'b0;
        pred_event_is_cond_q <= 1'b0;
        pred_event_taken_q <= 1'b0;
        pred_event_pc_q <= '0;
        pred_snap_valid_q <= '0;
      end else begin
        if (USE_TAGE && pred_fire_w && pred_slot_is_cond_w) begin
          dbg_tage_lookup_total_q <= dbg_tage_lookup_total_q + 64'd1;
          if (tage_hit_w) begin
            dbg_tage_hit_total_q <= dbg_tage_hit_total_q + 64'd1;
          end
          tage_push_override = cond_tage_override_w;
          if (tage_push_override) begin
            dbg_tage_override_total_q <= dbg_tage_override_total_q + 64'd1;
          end
          if (tage_count_n < TAGE_TRACK_DEPTH) begin
            tage_override_n[tage_tail_n] = tage_push_override;
            tage_pred_taken_n[tage_tail_n] = pred_slot_taken_w;
            tage_tail_n = tage_tail_n + TAGE_TRACK_PTR_W'(1);
            tage_count_n = tage_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (USE_SC && pred_fire_w && pred_slot_is_cond_w) begin
          dbg_sc_lookup_total_q <= dbg_sc_lookup_total_q + 64'd1;
          if (sc_confident_w) begin
            dbg_sc_confident_total_q <= dbg_sc_confident_total_q + 64'd1;
          end
          sc_push_override = cond_sc_override_w;
          if (sc_push_override) begin
            dbg_sc_override_total_q <= dbg_sc_override_total_q + 64'd1;
          end
          if (sc_count_n < TAGE_TRACK_DEPTH) begin
            sc_override_n[sc_tail_n] = sc_push_override;
            sc_pred_taken_n[sc_tail_n] = pred_slot_taken_w;
            sc_tail_n = sc_tail_n + TAGE_TRACK_PTR_W'(1);
            sc_count_n = sc_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (USE_LOOP && pred_fire_w && pred_slot_is_cond_w) begin
          dbg_loop_lookup_total_q <= dbg_loop_lookup_total_q + 64'd1;
          if (loop_hit_w) begin
            dbg_loop_hit_total_q <= dbg_loop_hit_total_q + 64'd1;
          end
          if (loop_confident_w) begin
            dbg_loop_confident_total_q <= dbg_loop_confident_total_q + 64'd1;
          end
          loop_push_override = cond_loop_override_w;
          if (loop_push_override) begin
            dbg_loop_override_total_q <= dbg_loop_override_total_q + 64'd1;
          end
          if (loop_count_n < TAGE_TRACK_DEPTH) begin
            loop_override_n[loop_tail_n] = loop_push_override;
            loop_pred_taken_n[loop_tail_n] = pred_slot_taken_w;
            loop_tail_n = loop_tail_n + TAGE_TRACK_PTR_W'(1);
            loop_count_n = loop_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (pred_fire_comb_w) begin
          dbg_ftb_lookup_total_q <= dbg_ftb_lookup_total_q + 64'd1;
          if (dbg_snap_ftb_cond_hit_w) begin
            dbg_ftb_cond_hit_total_q <= dbg_ftb_cond_hit_total_q + 64'd1;
          end
          if (dbg_snap_ftb_jump_hit_w) begin
            dbg_ftb_jump_hit_total_q <= dbg_ftb_jump_hit_total_q + 64'd1;
          end
          if (dbg_snap_ftb_pick_cond_w) begin
            dbg_ftb_cond_pick_total_q <= dbg_ftb_cond_pick_total_q + 64'd1;
          end
          if (dbg_snap_ftb_pick_jump_w) begin
            dbg_ftb_jump_pick_total_q <= dbg_ftb_jump_pick_total_q + 64'd1;
          end
          if (dbg_snap_ftb_cond_tag_miss_w) begin
            dbg_ftb_cond_tag_miss_total_q <= dbg_ftb_cond_tag_miss_total_q + 64'd1;
          end
          if (dbg_snap_ftb_jump_tag_miss_w) begin
            dbg_ftb_jump_tag_miss_total_q <= dbg_ftb_jump_tag_miss_total_q + 64'd1;
          end
          if (dbg_snap_ftb_jump_indirect_w) begin
            dbg_ittage_lookup_total_q <= dbg_ittage_lookup_total_q + 64'd1;
            if (dbg_snap_ittage_raw_hit_w) begin
              dbg_ittage_hit_total_q <= dbg_ittage_hit_total_q + 64'd1;
            end
          end
          if (dbg_snap_ittage_use_w) begin
            dbg_ittage_use_total_q <= dbg_ittage_use_total_q + 64'd1;
          end
        end
        if (pred_fire_w && pred_slot_is_cond_w && (cond_count_n < TAGE_TRACK_DEPTH)) begin
          cond_provider_n[cond_tail_n] = cond_selected_provider_w;
          cond_selected_taken_n[cond_tail_n] = cond_selected_taken_w;
          cond_legacy_taken_n[cond_tail_n] = cond_taken_legacy_w;
          cond_tage_taken_n[cond_tail_n] = tage_taken_w;
          cond_sc_taken_n[cond_tail_n] = sc_taken_w;
          cond_loop_taken_n[cond_tail_n] = loop_taken_w;
          cond_tage_candidate_n[cond_tail_n] = cond_tage_candidate_w;
          cond_sc_candidate_n[cond_tail_n] = cond_sc_candidate_w;
          cond_loop_candidate_n[cond_tail_n] = cond_loop_candidate_w;
          cond_tail_n = cond_tail_n + TAGE_TRACK_PTR_W'(1);
          cond_count_n = cond_count_n + TAGE_TRACK_CNT_W'(1);
        end
        pred_event_valid_q <= pred_fire_w;
        pred_event_is_call_q <= pred_fire_w && pred_slot_is_call_w;
        pred_event_is_ret_q <= pred_fire_w && pred_slot_is_ret_w;
        pred_event_is_rvc_q <= pred_fire_w && pred_slot_is_rvc_w;
        pred_event_is_cond_q <= pred_fire_w && pred_slot_is_cond_w;
        pred_event_taken_q <= pred_fire_w && pred_slot_taken_w;
        pred_event_pc_q <= pred_slot_pc_w;
        if (pred_fire_w) begin
          pred_snap_valid_q[ftq_enq_id_i] <= 1'b1;
          pred_snap_fetch_pc_q[ftq_enq_id_i] <= pc_reg_q;
          pred_snap_fetch_epoch_q[ftq_enq_id_i] <= ftq_enq_epoch_i;
          pred_snap_cond_branch_pc_q[ftq_enq_id_i] <= cond_branch_pc_w;
          pred_snap_jump_branch_pc_q[ftq_enq_id_i] <= jump_branch_pc_w;
          pred_snap_cond_hit_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_hit_w;
          pred_snap_jump_hit_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_hit_w;
          pred_snap_cond_tag_miss_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_tag_miss_w;
          pred_snap_jump_tag_miss_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_tag_miss_w;
          pred_snap_any_valid_q[ftq_enq_id_i] <= dbg_snap_ftb_any_valid_w;
          pred_snap_tag_hit_q[ftq_enq_id_i] <= dbg_snap_ftb_tag_hit_w;
          pred_snap_valid_count_q[ftq_enq_id_i] <= dbg_snap_ftb_valid_count_w;
          pred_snap_cond_count_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_count_w;
          pred_snap_jump_count_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_count_w;
          pred_snap_cond_in_range_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_in_range_w;
          pred_snap_jump_in_range_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_in_range_w;
          pred_snap_cond_taken_pred_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_taken_pred_w;
          pred_snap_pick_cond_q[ftq_enq_id_i] <= dbg_snap_ftb_pick_cond_w;
          pred_snap_pick_jump_q[ftq_enq_id_i] <= dbg_snap_ftb_pick_jump_w;
        end
      end
`ifndef SYNTHESIS

`endif
      tage_track_head_q <= tage_head_n;
      tage_track_tail_q <= tage_tail_n;
      tage_track_count_q <= tage_count_n;
      tage_track_override_q <= tage_override_n;
      tage_track_pred_taken_q <= tage_pred_taken_n;
      sc_track_head_q <= sc_head_n;
      sc_track_tail_q <= sc_tail_n;
      sc_track_count_q <= sc_count_n;
      sc_track_override_q <= sc_override_n;
      sc_track_pred_taken_q <= sc_pred_taken_n;
      loop_track_head_q <= loop_head_n;
      loop_track_tail_q <= loop_tail_n;
      loop_track_count_q <= loop_count_n;
      loop_track_override_q <= loop_override_n;
      loop_track_pred_taken_q <= loop_pred_taken_n;
      cond_track_head_q <= cond_head_n;
      cond_track_tail_q <= cond_tail_n;
      cond_track_count_q <= cond_count_n;
      cond_track_provider_q <= cond_provider_n;
      cond_track_selected_taken_q <= cond_selected_taken_n;
      cond_track_legacy_taken_q <= cond_legacy_taken_n;
      cond_track_tage_taken_q <= cond_tage_taken_n;
      cond_track_sc_taken_q <= cond_sc_taken_n;
      cond_track_loop_taken_q <= cond_loop_taken_n;
      cond_track_tage_candidate_q <= cond_tage_candidate_n;
      cond_track_sc_candidate_q <= cond_sc_candidate_n;
      cond_track_loop_candidate_q <= cond_loop_candidate_n;
    end
  end
endmodule : bpu
