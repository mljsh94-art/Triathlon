import global_config_pkg::*;
import bpu_pkg::*;
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
  // RV32C instructions are 16-bit aligned. BHT indexing must include pc[1].
  localparam int unsigned INSTR_ADDR_LSB = 1;
  // FTB/BTB entries are keyed by fetch-block base, not individual halfword PCs.
  localparam int unsigned BLOCK_ADDR_LSB = $clog2(Cfg.FETCH_WIDTH);
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - BLOCK_ADDR_LSB;
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
  // FTB/BTB storage、index/tag、lookup 扫描与训练已抽到 u_ftb (bpu_ftb.sv)。
  // BHT/chooser storage、index 函数、tournament 训练与 cond 计数已抽到 u_bht (bpu_bht.sv)；
  // 顶层只保留只读数组连线与预测期 legacy 方向 sideband。
  logic [BHT_ENTRIES-1:0][1:0] local_bht_w;
  logic [BHT_ENTRIES-1:0][1:0] global_bht_w;
  logic [BHT_ENTRIES-1:0][1:0] chooser_w;
  logic bht_predict_local_legacy_strong_w;
  logic bht_predict_global_legacy_strong_w;
  logic bht_predict_local_global_disagree_w;
  logic bht_predict_selected_legacy_strong_w;
  // RAS state (arch/spec stacks + counts) lives in u_ras (bpu_ras.sv).
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
  // dbg_cond_* (update/local/global/selected correct, choose local/global) 计数已随
  // tournament 训练迁入 u_bht (bpu_bht.sv)；tb 经 i_bpu.u_bht.dbg_cond_*_q 层级引用读取。
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

  // bht_pc_index / bht_global_index / sat_inc / sat_dec 已随 BHT 抽入 u_bht (bpu_bht.sv)。

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

  // Bundle contract: predict/update 收口（逻辑不变，仅连线层）。
  predict_req_t  cond_pred_req_w;
  predict_req_t  jump_pred_req_w;
  predict_resp_t tage_pred_resp_w;
  predict_resp_t sc_pred_resp_w;
  predict_resp_t loop_pred_resp_w;
  predict_resp_t ittage_pred_resp_w;
  predict_resp_t pred_resp_w;
  update_t       ftq_update_w;
  update_t       tage_update_w;
  update_t       sc_update_w;
  update_t       loop_update_w;
  update_t       ittage_update_w;

  assign ghr_q = spec_ghr_q;

  always_comb begin
    ittage_predict_ctx_w = spec_path_hist_q;
    if (!flush_i && pred_event_valid_q && pred_event_is_cond_q) begin
      ittage_predict_ctx_w = path_shift(ittage_predict_ctx_w, pred_event_pc_q, pred_event_taken_q);
    end
  end

  always_comb begin
    ftq_update_w.valid    = update_valid_i;
    ftq_update_w.pc       = update_pc_i;
    ftq_update_w.taken    = update_taken_i;
    ftq_update_w.target   = update_target_i;
    ftq_update_w.mispred  = 1'b0;
    ftq_update_w.is_cond  = update_is_cond_i;
    ftq_update_w.is_call  = update_is_call_i;
    ftq_update_w.is_ret   = update_is_ret_i;
    ftq_update_w.is_rvc   = update_is_rvc_i;
    ftq_update_w.meta.ghr  = arch_ghr_q;
    ftq_update_w.meta.path = ittage_predict_ctx_w;

    tage_update_w = ftq_update_w;
    tage_update_w.valid = ftq_update_w.valid && ftq_update_w.is_cond && USE_TAGE;
    sc_update_w = ftq_update_w;
    sc_update_w.valid = ftq_update_w.valid && ftq_update_w.is_cond && USE_SC;
    loop_update_w = ftq_update_w;
    loop_update_w.valid = ftq_update_w.valid && USE_LOOP;
    ittage_update_w = ftq_update_w;
    ittage_update_w.valid = USE_ITTAGE && ftq_update_w.valid && !ftq_update_w.is_cond &&
                            ftq_update_w.taken && !ftq_update_w.is_call && !ftq_update_w.is_ret;
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
      .predict_base_pc_i(cond_pred_req_w.pc),
      .predict_ghr_i(cond_pred_req_w.ghr),
      .predict_hit_o(tage_hit_w),
      .predict_taken_o(tage_taken_w),
      .predict_strong_o(tage_strong_w),
      .predict_provider_o(tage_provider_w),
      .predict_useful_o(tage_useful_w),
      .update_valid_i(tage_update_w.valid),
      .update_pc_i(tage_update_w.pc),
      .update_ghr_i(tage_update_w.meta.ghr),
      .update_taken_i(tage_update_w.taken)
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
      .predict_base_pc_i(cond_pred_req_w.pc),
      .predict_ghr_i(cond_pred_req_w.ghr),
      .predict_taken_o(sc_taken_w),
      .predict_confident_o(sc_confident_w),
      .update_valid_i(sc_update_w.valid),
      .update_pc_i(sc_update_w.pc),
      .update_ghr_i(sc_update_w.meta.ghr),
      .update_taken_i(sc_update_w.taken)
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
      .predict_base_pc_i(cond_pred_req_w.pc),
      .predict_taken_o(loop_taken_w),
      .predict_confident_o(loop_confident_w),
      .predict_hit_o(loop_hit_w),
      .update_valid_i(loop_update_w.valid),
      .update_pc_i(loop_update_w.pc),
      .update_is_cond_i(loop_update_w.is_cond),
      .update_taken_i(loop_update_w.taken)
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
      .predict_base_pc_i(jump_pred_req_w.pc),
      .predict_ctx_i(jump_pred_req_w.path),
      .predict_hit_o(ittage_raw_hit_w),
      .predict_target_o(ittage_target_w),
      .update_valid_i(ittage_update_w.valid),
      .update_pc_i(ittage_update_w.pc),
      .update_ctx_i(ittage_update_w.meta.path),
      .update_target_i(ittage_update_w.target)
  );

  bpu_ras #(
      .Cfg(Cfg),
      .RAS_DEPTH(RAS_DEPTH)
  ) u_ras (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .ras_update_valid_i(ras_update_valid_i),
      .ras_update_is_call_i(ras_update_is_call_i),
      .ras_update_is_ret_i(ras_update_is_ret_i),
      .ras_update_is_rvc_i(ras_update_is_rvc_i),
      .ras_update_pc_i(ras_update_pc_i),
      .flush_i(flush_i),
      .pred_event_valid_i(pred_event_valid_q),
      .pred_event_is_call_i(pred_event_is_call_q),
      .pred_event_is_ret_i(pred_event_is_ret_q),
      .pred_event_is_rvc_i(pred_event_is_rvc_q),
      .pred_event_pc_i(pred_event_pc_q),
      .spec_ras_top_o(spec_ras_top_w),
      .spec_ras_has_entry_o(spec_ras_has_entry_w),
      // arch_ras_* outputs are debug-only; TB reads them via u_ras hierarchy.
      .arch_ras_top_o(),
      .arch_ras_has_entry_o()
  );

  // BHT/chooser storage、index 函数、tournament 训练与 cond 计数。预测期暴露 legacy
  // 方向 sideband 给顶层做 SC override 门控；计数数组只读输出给 u_ftb 复用。
  bpu_bht #(
      .Cfg(Cfg),
      .BHT_ENTRIES(BHT_ENTRIES),
      .BHT_HASH_ENABLE(BHT_HASH_ENABLE),
      .USE_GSHARE(USE_GSHARE),
      .USE_TOURNAMENT(USE_TOURNAMENT),
      .GHR_BITS(GHR_BITS)
  ) u_bht (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .local_bht_o(local_bht_w),
      .global_bht_o(global_bht_w),
      .chooser_o(chooser_w),
      .predict_pc_i(cond_branch_pc_w),
      .predict_ghr_i(spec_ghr_q),
      .predict_is_backward_i(ftb_pick_is_backward_w),
      .predict_local_legacy_strong_o(bht_predict_local_legacy_strong_w),
      .predict_global_legacy_strong_o(bht_predict_global_legacy_strong_w),
      .predict_local_global_disagree_o(bht_predict_local_global_disagree_w),
      .predict_selected_legacy_strong_o(bht_predict_selected_legacy_strong_w),
      .update_valid_i(ftq_update_w.valid),
      .update_is_cond_i(ftq_update_w.is_cond),
      .update_pc_i(ftq_update_w.pc),
      .update_taken_i(ftq_update_w.taken),
      .update_target_i(ftq_update_w.target),
      .update_ghr_i(arch_ghr_q),
      .dbg_cond_update_total_o(),
      .dbg_cond_local_correct_o(),
      .dbg_cond_global_correct_o(),
      .dbg_cond_selected_correct_o(),
      .dbg_cond_choose_local_o(),
      .dbg_cond_choose_global_o()
  );

  // FTB/BTB storage、index/tag、predict-time lookup 扫描与 commit-time 训练。
  // FTB pick 需要 cond 槽的 legacy BHT 方向来选最早 taken，故把 u_bht 的计数器
  // 数组只读传入。
  bpu_ftb #(
      .Cfg(Cfg),
      .BTB_ENTRIES(BTB_ENTRIES),
      .BHT_ENTRIES(BHT_ENTRIES),
      .BTB_HASH_ENABLE(BTB_HASH_ENABLE),
      .BHT_HASH_ENABLE(BHT_HASH_ENABLE),
      .USE_GSHARE(USE_GSHARE),
      .USE_TOURNAMENT(USE_TOURNAMENT),
      .GHR_BITS(GHR_BITS)
  ) u_ftb (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .pc_reg_i(pc_reg_q),
      .spec_ghr_i(spec_ghr_q),
      .local_bht_i(local_bht_w),
      .global_bht_i(global_bht_w),
      .chooser_i(chooser_w),
      .update_valid_i(ftq_update_w.valid),
      .update_pc_i(ftq_update_w.pc),
      .update_taken_i(ftq_update_w.taken),
      .update_target_i(ftq_update_w.target),
      .update_is_cond_i(ftq_update_w.is_cond),
      .update_is_call_i(ftq_update_w.is_call),
      .update_is_ret_i(ftq_update_w.is_ret),
      .update_is_rvc_i(ftq_update_w.is_rvc),
      .ftb_pick_valid_o(ftb_pick_valid_w),
      .ftb_pick_is_cond_o(ftb_pick_is_cond_w),
      .ftb_pick_is_call_o(ftb_pick_is_call_w),
      .ftb_pick_is_ret_o(ftb_pick_is_ret_w),
      .ftb_pick_is_rvc_o(ftb_pick_is_rvc_w),
      .ftb_pick_is_backward_o(ftb_pick_is_backward_w),
      .ftb_pick_is_indirect_o(ftb_pick_is_indirect_w),
      .ftb_pick_end_idx_o(ftb_pick_end_idx_w),
      .ftb_pick_pc_o(ftb_pick_pc_w),
      .ftb_pick_target_o(ftb_pick_target_w),
      .cond_branch_pc_o(cond_branch_pc_w),
      .jump_branch_pc_o(jump_branch_pc_w),
      .cond_taken_legacy_o(cond_taken_legacy_w),
      .dbg_snap_ftb_cond_hit_o(dbg_snap_ftb_cond_hit_w),
      .dbg_snap_ftb_jump_hit_o(dbg_snap_ftb_jump_hit_w),
      .dbg_snap_ftb_pick_cond_o(dbg_snap_ftb_pick_cond_w),
      .dbg_snap_ftb_pick_jump_o(dbg_snap_ftb_pick_jump_w),
      .dbg_snap_ftb_cond_tag_miss_o(dbg_snap_ftb_cond_tag_miss_w),
      .dbg_snap_ftb_jump_tag_miss_o(dbg_snap_ftb_jump_tag_miss_w),
      .dbg_snap_ftb_any_valid_o(dbg_snap_ftb_any_valid_w),
      .dbg_snap_ftb_tag_hit_o(dbg_snap_ftb_tag_hit_w),
      .dbg_snap_ftb_valid_count_o(dbg_snap_ftb_valid_count_w),
      .dbg_snap_ftb_cond_count_o(dbg_snap_ftb_cond_count_w),
      .dbg_snap_ftb_jump_count_o(dbg_snap_ftb_jump_count_w),
      .dbg_snap_ftb_cond_in_range_o(dbg_snap_ftb_cond_in_range_w),
      .dbg_snap_ftb_jump_in_range_o(dbg_snap_ftb_jump_in_range_w),
      .dbg_snap_ftb_cond_taken_pred_o(dbg_snap_ftb_cond_taken_pred_w),
      .dbg_snap_ftb_jump_indirect_o(dbg_snap_ftb_jump_indirect_w)
  );

  always_comb begin
    cond_pred_req_w.valid = !flush_i && !redirect_valid_i;
    cond_pred_req_w.pc    = cond_branch_pc_w;
    cond_pred_req_w.ghr   = spec_ghr_q;
    cond_pred_req_w.path  = '0;

    jump_pred_req_w.valid = !flush_i && !redirect_valid_i;
    jump_pred_req_w.pc    = jump_branch_pc_w;
    jump_pred_req_w.ghr   = '0;
    jump_pred_req_w.path  = ittage_predict_ctx_w;
  end

  always_comb begin
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

    // 预测期 legacy 方向 sideband 由 u_bht 直接给出（逻辑与原内联读表完全一致）。
    local_legacy_strong = bht_predict_local_legacy_strong_w;
    global_legacy_strong = bht_predict_global_legacy_strong_w;
    local_global_disagree = bht_predict_local_global_disagree_w;
    selected_legacy_strong = bht_predict_selected_legacy_strong_w;

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

    tage_pred_resp_w.hit           = tage_hit_w;
    tage_pred_resp_w.taken         = tage_taken_w;
    tage_pred_resp_w.target        = '0;
    tage_pred_resp_w.provider      = tage_provider_w;
    tage_pred_resp_w.meta.is_strong   = tage_strong_w;
    tage_pred_resp_w.meta.useful   = tage_useful_w;
    tage_pred_resp_w.meta.confident = 1'b0;
    tage_pred_resp_w.meta.loop_hit = 1'b0;
    tage_pred_resp_w.meta.is_backward = ftb_pick_is_backward_w;
    tage_pred_resp_w.meta.is_call  = ftb_pick_is_call_w;
    tage_pred_resp_w.meta.is_ret   = ftb_pick_is_ret_w;
    tage_pred_resp_w.meta.is_rvc   = ftb_pick_is_rvc_w;
    tage_pred_resp_w.meta.is_cond  = ftb_pick_is_cond_w;
    tage_pred_resp_w.meta.is_indirect = ftb_pick_is_indirect_w;

    sc_pred_resp_w.hit             = 1'b0;
    sc_pred_resp_w.taken           = sc_taken_w;
    sc_pred_resp_w.target          = '0;
    sc_pred_resp_w.provider        = COND_PROVIDER_SC;
    sc_pred_resp_w.meta.is_strong     = 1'b0;
    sc_pred_resp_w.meta.useful     = '0;
    sc_pred_resp_w.meta.confident  = sc_confident_w;
    sc_pred_resp_w.meta.loop_hit   = 1'b0;
    sc_pred_resp_w.meta.is_backward = ftb_pick_is_backward_w;
    sc_pred_resp_w.meta.is_call    = ftb_pick_is_call_w;
    sc_pred_resp_w.meta.is_ret     = ftb_pick_is_ret_w;
    sc_pred_resp_w.meta.is_rvc     = ftb_pick_is_rvc_w;
    sc_pred_resp_w.meta.is_cond    = ftb_pick_is_cond_w;
    sc_pred_resp_w.meta.is_indirect = ftb_pick_is_indirect_w;

    loop_pred_resp_w.hit           = loop_hit_w;
    loop_pred_resp_w.taken         = loop_taken_w;
    loop_pred_resp_w.target        = '0;
    loop_pred_resp_w.provider      = COND_PROVIDER_LOOP;
    loop_pred_resp_w.meta.is_strong   = 1'b0;
    loop_pred_resp_w.meta.useful   = '0;
    loop_pred_resp_w.meta.confident = loop_confident_w;
    loop_pred_resp_w.meta.loop_hit = loop_hit_w;
    loop_pred_resp_w.meta.is_backward = ftb_pick_is_backward_w;
    loop_pred_resp_w.meta.is_call  = ftb_pick_is_call_w;
    loop_pred_resp_w.meta.is_ret   = ftb_pick_is_ret_w;
    loop_pred_resp_w.meta.is_rvc   = ftb_pick_is_rvc_w;
    loop_pred_resp_w.meta.is_cond  = ftb_pick_is_cond_w;
    loop_pred_resp_w.meta.is_indirect = ftb_pick_is_indirect_w;

    ittage_pred_resp_w.hit         = ittage_raw_hit_w;
    ittage_pred_resp_w.taken       = ittage_hit_w;
    ittage_pred_resp_w.target      = ittage_target_w;
    ittage_pred_resp_w.provider    = '0;
    ittage_pred_resp_w.meta        = '0;

    pred_resp_w.hit                = predict_hit;
    pred_resp_w.taken              = predict_taken;
    pred_resp_w.target             = predict_target;
    pred_resp_w.provider           = cond_selected_provider_w;
    pred_resp_w.meta.is_strong        = tage_pred_resp_w.meta.is_strong;
    pred_resp_w.meta.useful        = tage_pred_resp_w.meta.useful;
    pred_resp_w.meta.confident     = sc_pred_resp_w.meta.confident | loop_pred_resp_w.meta.confident;
    pred_resp_w.meta.loop_hit      = loop_pred_resp_w.meta.loop_hit;
    pred_resp_w.meta.is_backward   = ftb_pick_is_backward_w;
    pred_resp_w.meta.is_call       = predict_is_call;
    pred_resp_w.meta.is_ret        = predict_is_ret;
    pred_resp_w.meta.is_rvc        = predict_is_rvc;
    pred_resp_w.meta.is_cond       = predict_is_cond;
    pred_resp_w.meta.is_indirect   = predict_is_indirect;
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
      // BHT/chooser 复位（2'b01 弱不跳）已随存储迁入 u_bht。
    end else begin
      logic pred_fire_w;
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

      if (ftq_update_w.valid) begin
        // FTB BTB 训练已移至 u_ftb；BHT/chooser 训练与 cond 计数已移至 u_bht。
        // 此处只保留 FTB/ITTAGE 训练计数与架构历史（GHR/path）推进。

        // FTB 训练计数：与 u_ftb 内 up_do_ftb_train 条件保持一致。
        if (!ftq_update_w.is_cond || ftq_update_w.taken) begin
          if (ftq_update_w.is_cond) begin
            dbg_ftb_train_cond_total_q <= dbg_ftb_train_cond_total_q + 64'd1;
          end else begin
            dbg_ftb_train_jump_total_q <= dbg_ftb_train_jump_total_q + 64'd1;
          end
        end
        if (ittage_update_w.valid) begin
          dbg_ittage_train_total_q <= dbg_ittage_train_total_q + 64'd1;
        end

        if (ftq_update_w.is_cond) begin
          arch_ghr_n = ghr_shift(arch_ghr_n, ftq_update_w.taken);
          arch_path_hist_n = path_shift(arch_path_hist_n, ftq_update_w.pc, ftq_update_w.taken);
        end

        if (USE_TAGE && ftq_update_w.is_cond && (tage_count_n != '0)) begin
          tage_pop_override = tage_override_n[tage_head_n];
          tage_pop_pred_taken = tage_pred_taken_n[tage_head_n];
          tage_head_n = tage_head_n + TAGE_TRACK_PTR_W'(1);
          tage_count_n = tage_count_n - TAGE_TRACK_CNT_W'(1);
          if (tage_pop_override && (tage_pop_pred_taken == ftq_update_w.taken)) begin
            dbg_tage_override_correct_q <= dbg_tage_override_correct_q + 64'd1;
          end
        end
        if (USE_SC && ftq_update_w.is_cond && (sc_count_n != '0)) begin
          sc_pop_override = sc_override_n[sc_head_n];
          sc_pop_pred_taken = sc_pred_taken_n[sc_head_n];
          sc_head_n = sc_head_n + TAGE_TRACK_PTR_W'(1);
          sc_count_n = sc_count_n - TAGE_TRACK_CNT_W'(1);
          if (sc_pop_override && (sc_pop_pred_taken == ftq_update_w.taken)) begin
            dbg_sc_override_correct_q <= dbg_sc_override_correct_q + 64'd1;
          end
        end
        if (USE_LOOP && ftq_update_w.is_cond && (loop_count_n != '0)) begin
          loop_pop_override = loop_override_n[loop_head_n];
          loop_pop_pred_taken = loop_pred_taken_n[loop_head_n];
          loop_head_n = loop_head_n + TAGE_TRACK_PTR_W'(1);
          loop_count_n = loop_count_n - TAGE_TRACK_CNT_W'(1);
          if (loop_pop_override && (loop_pop_pred_taken == ftq_update_w.taken)) begin
            dbg_loop_override_correct_q <= dbg_loop_override_correct_q + 64'd1;
          end
        end
        if (ftq_update_w.is_cond && (cond_count_n != '0)) begin
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

          cond_selected_pred_correct = (cond_pop_selected_taken == ftq_update_w.taken);
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
                (cond_pop_legacy_taken == ftq_update_w.taken)) begin
              dbg_cond_selected_wrong_alt_legacy_correct_q <=
                  dbg_cond_selected_wrong_alt_legacy_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_TAGE) &&
                cond_pop_tage_candidate &&
                (cond_pop_tage_taken == ftq_update_w.taken)) begin
              dbg_cond_selected_wrong_alt_tage_correct_q <=
                  dbg_cond_selected_wrong_alt_tage_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_SC) &&
                cond_pop_sc_candidate &&
                (cond_pop_sc_taken == ftq_update_w.taken)) begin
              dbg_cond_selected_wrong_alt_sc_correct_q <=
                  dbg_cond_selected_wrong_alt_sc_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_LOOP) &&
                cond_pop_loop_candidate &&
                (cond_pop_loop_taken == ftq_update_w.taken)) begin
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

      // RAS arch/spec push-pop now handled by u_ras (bpu_ras.sv).
      if (flush_i) begin
        spec_path_hist_n = arch_path_hist_n;
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
