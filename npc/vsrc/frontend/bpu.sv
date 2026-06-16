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
    parameter bit TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK = 1'b0,
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
  // RV32C instructions are 16-bit aligned. Predictor indexing/tagging must include pc[1].
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - INSTR_ADDR_LSB;
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
  logic [Cfg.PLEN-1:0] pc_reg_q;
  // FTB 双槽（方案 A）：每个 fetch block 同时保留 1 个条件分支槽 + 1 个无条件跳转槽，
  // 消除原单 entry 下 cond/jump 同 block 互相覆盖导致的预测退化。两个 way 各自独立
  // tag/valid，按 16B 对齐 block_base 共享同一 BTB index。
  // -- Way-0：条件分支（taken 时训练写入）--
  logic [BTB_ENTRIES-1:0] btb_cond_valid_q;
  logic [BTB_ENTRIES-1:0] btb_cond_is_backward_q;
  logic [BTB_ENTRIES-1:0] btb_cond_is_rvc_q;
  logic [BTB_ENTRIES-1:0][BTB_TAG_W-1:0] btb_cond_tag_q;
  logic [BTB_ENTRIES-1:0][Cfg.PLEN-1:0] btb_cond_target_q;
  logic [BTB_ENTRIES-1:0][SLOT_IDX_W-1:0] btb_cond_offset_q;
  // -- Way-1：无条件控制流（JAL/JALR/call/ret）--
  logic [BTB_ENTRIES-1:0] btb_jump_valid_q;
  logic [BTB_ENTRIES-1:0] btb_jump_is_call_q;
  logic [BTB_ENTRIES-1:0] btb_jump_is_ret_q;
  logic [BTB_ENTRIES-1:0] btb_jump_use_ras_q;
  logic [BTB_ENTRIES-1:0] btb_jump_is_rvc_q;
  logic [BTB_ENTRIES-1:0][BTB_TAG_W-1:0] btb_jump_tag_q;
  logic [BTB_ENTRIES-1:0][Cfg.PLEN-1:0] btb_jump_target_q;
  logic [BTB_ENTRIES-1:0][SLOT_IDX_W-1:0] btb_jump_offset_q;
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
      pc_idx = pc[INSTR_ADDR_LSB +: BTB_IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + BTB_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (INSTR_ADDR_LSB + BTB_IDX_W)) % BTB_IDX_W] ^= pc[i];
      end
      btb_index = BTB_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
    end
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_tag(input logic [Cfg.PLEN-1:0] pc);
    btb_tag = pc[Cfg.PLEN-1:INSTR_ADDR_LSB+BTB_IDX_W];
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

  // FTB 单查询：用 16B 对齐的 block_base 索引 BTB；分支 PC 由 block_base + (hw_offset<<1) 还原。
  // 方向/间接预测器统一查这个 branch_pc（与 commit 训练用的 update_pc 一致）。
  assign aligned_base_w = pc_reg_q & BLOCK_ALIGN_MASK;
  assign btb_pred_idx_w = btb_index(aligned_base_w);
  assign cond_branch_pc_w = aligned_base_w +
                            (Cfg.PLEN'(btb_cond_offset_q[btb_pred_idx_w]) << 1);
  assign jump_branch_pc_w = aligned_base_w +
                            (Cfg.PLEN'(btb_jump_offset_q[btb_pred_idx_w]) << 1);

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

  // FTB 双槽预测：单次 BTB 读取出 cond way + jump way；cond 槽走方向预测器，jump 槽默认
  // taken（ret 用 RAS、indirect 用 ITTAGE）。两槽都 taken 时取 block 内 offset 更早者。
  always_comb begin
    logic [BTB_IDX_W-1:0] idx;
    logic [BHT_IDX_W-1:0] local_idx;
    logic [BHT_IDX_W-1:0] global_idx;
    logic [BHT_IDX_W-1:0] chooser_idx;
    logic [1:0] local_ctr_pred;
    logic [1:0] global_ctr_pred;
    logic [1:0] selected_ctr_pred;
    logic local_taken_pred;
    logic global_taken_pred;
    logic cond_taken_pred;
    logic use_global_pred;
    logic local_legacy_strong;
    logic global_legacy_strong;
    logic local_global_disagree;
    logic selected_legacy_strong;
    logic tage_provider_ok;
    logic tage_allow_override;
    logic sc_allow_override;
    logic [BTB_TAG_W-1:0] block_tag;
    // 两个 way 的解码结果
    logic cond_hit;
    logic cond_is_backward_l;
    logic cond_is_rvc_l;
    logic [Cfg.PLEN-1:0] cond_target_l;
    logic jump_hit;
    logic jump_is_call_l;
    logic jump_is_ret_l;
    logic jump_is_rvc_l;
    logic jump_is_indirect_l;
    logic [Cfg.PLEN-1:0] jump_target_l;
    // 每槽 in_range（须落在本 fetch group [pc_reg_q, pc_reg_q+FETCH_WIDTH) 内且整条不越组）
    logic [Cfg.PLEN-1:0] cond_diff_w;
    logic [Cfg.PLEN-1:0] cond_start_rel_w;
    logic [Cfg.PLEN-1:0] cond_end_rel_w;
    logic cond_ge_w;
    logic cond_in_range_w;
    logic [Cfg.PLEN-1:0] jump_diff_w;
    logic [Cfg.PLEN-1:0] jump_start_rel_w;
    logic [Cfg.PLEN-1:0] jump_end_rel_w;
    logic jump_ge_w;
    logic jump_in_range_w;
    logic cond_candidate_w;
    logic jump_candidate_w;
    logic pick_cond_w;
    logic pick_jump_w;

    idx = btb_pred_idx_w;
    block_tag = btb_tag(aligned_base_w);
    // cond 槽方向预测查 cond_branch_pc，jump 槽 ITTAGE 查 jump_branch_pc。
    local_idx = bht_pc_index(cond_branch_pc_w);
    global_idx = bht_global_index(cond_branch_pc_w, spec_ghr_q);
    chooser_idx = local_idx;

    // ---- Way-0：条件分支解码 ----
    cond_hit = btb_cond_valid_q[idx] && (btb_cond_tag_q[idx] == block_tag);
    cond_is_backward_l = btb_cond_is_backward_q[idx];
    cond_is_rvc_l = btb_cond_is_rvc_q[idx];
    cond_target_l = btb_cond_target_q[idx];

    // ---- Way-1：无条件控制流解码 ----
    jump_hit = btb_jump_valid_q[idx] && (btb_jump_tag_q[idx] == block_tag);
    jump_is_call_l = btb_jump_is_call_q[idx];
    jump_is_ret_l = btb_jump_is_ret_q[idx];
    jump_is_rvc_l = btb_jump_is_rvc_q[idx];
    jump_is_indirect_l = jump_hit && !jump_is_call_l && !jump_is_ret_l;
    jump_target_l = btb_jump_target_q[idx];
    ittage_hit_w = USE_ITTAGE && jump_is_indirect_l && ittage_raw_hit_w;
    // jump 槽预测 target：ret→RAS，indirect→ITTAGE，否则 BTB 直接目标。
    if (jump_is_ret_l && spec_ras_has_entry_w) begin
      jump_target_l = spec_ras_top_w;
    end else if (jump_is_indirect_l && ittage_hit_w) begin
      jump_target_l = ittage_target_w;
    end

    // ---- cond 方向预测（沿用 legacy/TAGE/SC/Loop override 链）----
    local_ctr_pred = local_bht_q[local_idx];
    global_ctr_pred = global_bht_q[global_idx];
    local_taken_pred = local_ctr_pred[1] ||
                       ((local_ctr_pred == 2'b01) && cond_is_backward_l);
    global_taken_pred = global_ctr_pred[1] ||
                        ((global_ctr_pred == 2'b01) && cond_is_backward_l);
    use_global_pred = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[chooser_idx][1]);
    selected_ctr_pred = use_global_pred ? global_ctr_pred : local_ctr_pred;
    local_legacy_strong = (local_ctr_pred == 2'b00) || (local_ctr_pred == 2'b11);
    global_legacy_strong = (global_ctr_pred == 2'b00) || (global_ctr_pred == 2'b11);
    local_global_disagree = (local_taken_pred != global_taken_pred);
    selected_legacy_strong = (selected_ctr_pred == 2'b00) || (selected_ctr_pred == 2'b11);
    cond_taken_pred = use_global_pred ? global_taken_pred : local_taken_pred;
    cond_taken_legacy_w = cond_taken_pred;
    cond_tage_override_w = 1'b0;
    cond_sc_override_w = 1'b0;
    cond_loop_override_w = 1'b0;
    cond_tage_candidate_w = 1'b0;
    cond_sc_candidate_w = 1'b0;
    cond_loop_candidate_w = 1'b0;
    cond_selected_provider_w = COND_PROVIDER_LEGACY;

    tage_provider_ok = (int'(tage_provider_w) >= int'(TAGE_OVERRIDE_MIN_PROVIDER));
    tage_allow_override = USE_TAGE && tage_hit_w && tage_strong_w && tage_provider_ok;
    if (TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK && selected_legacy_strong) begin
      tage_allow_override = 1'b0;
    end
    cond_tage_candidate_w = cond_hit && tage_allow_override;

    if (tage_allow_override && (tage_taken_w != cond_taken_legacy_w)) begin
      cond_tage_override_w = 1'b1;
      cond_taken_pred = tage_taken_w;
      cond_selected_provider_w = COND_PROVIDER_TAGE;
    end

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
    cond_sc_candidate_w = cond_hit && sc_allow_override;
    if (sc_allow_override && (sc_taken_w != cond_taken_pred)) begin
      cond_sc_override_w = 1'b1;
      cond_taken_pred = sc_taken_w;
      cond_selected_provider_w = COND_PROVIDER_SC;
    end
    cond_loop_candidate_w = USE_LOOP && cond_hit && loop_confident_w;
    if (USE_LOOP && cond_hit && loop_confident_w &&
        (loop_taken_w != cond_taken_pred)) begin
      cond_loop_override_w = 1'b1;
      cond_taken_pred = loop_taken_w;
      cond_selected_provider_w = COND_PROVIDER_LOOP;
    end
    cond_selected_taken_w = cond_taken_pred;

    // ---- 每槽 in_range ----
    cond_diff_w = cond_branch_pc_w - pc_reg_q;
    cond_ge_w = (cond_branch_pc_w >= pc_reg_q);
    cond_start_rel_w = cond_diff_w >> 1;
    cond_end_rel_w = cond_start_rel_w + (cond_is_rvc_l ? Cfg.PLEN'(0) : Cfg.PLEN'(1));
    cond_in_range_w = cond_ge_w && (cond_end_rel_w <= Cfg.PLEN'(PRED_SLOT_COUNT - 1));

    jump_diff_w = jump_branch_pc_w - pc_reg_q;
    jump_ge_w = (jump_branch_pc_w >= pc_reg_q);
    jump_start_rel_w = jump_diff_w >> 1;
    jump_end_rel_w = jump_start_rel_w + (jump_is_rvc_l ? Cfg.PLEN'(0) : Cfg.PLEN'(1));
    jump_in_range_w = jump_ge_w && (jump_end_rel_w <= Cfg.PLEN'(PRED_SLOT_COUNT - 1));

    // ---- 候选与选择：cond 须方向预测 taken；jump 命中即 taken。取 offset 更早者 ----
    cond_candidate_w = cond_hit && cond_taken_pred && cond_in_range_w;
    jump_candidate_w = jump_hit && jump_in_range_w;
    pick_cond_w = cond_candidate_w &&
                  (!jump_candidate_w || (cond_start_rel_w <= jump_start_rel_w));
    pick_jump_w = jump_candidate_w && !pick_cond_w;

    // 选中槽属性投影到原有 predict_* / pred_slot_* 接口。
    predict_hit = pick_cond_w || pick_jump_w;
    predict_taken = predict_hit;
    predict_is_cond = pick_cond_w;
    predict_is_call = pick_jump_w && jump_is_call_l;
    predict_is_ret = pick_jump_w && jump_is_ret_l;
    predict_is_indirect = pick_jump_w && jump_is_indirect_l;
    predict_is_rvc = pick_cond_w ? cond_is_rvc_l : (pick_jump_w && jump_is_rvc_l);
    predict_target = pick_cond_w ? cond_target_l : jump_target_l;

    pred_slot_valid_w   = predict_hit;
    pred_slot_idx_w     = pred_slot_valid_w
                            ? (pick_cond_w ? cond_end_rel_w[SLOT_IDX_W-1:0]
                                           : jump_end_rel_w[SLOT_IDX_W-1:0])
                            : '0;
    pred_slot_is_call_w = pred_slot_valid_w && predict_is_call;
    pred_slot_is_ret_w  = pred_slot_valid_w && predict_is_ret;
    pred_slot_is_rvc_w  = pred_slot_valid_w && predict_is_rvc;
    pred_slot_is_cond_w = pred_slot_valid_w && predict_is_cond;
    pred_slot_taken_w   = pred_slot_valid_w;
    pred_slot_pc_w      = pick_cond_w ? cond_branch_pc_w : jump_branch_pc_w;
    pred_slot_target_w  = predict_target;
  end

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
      btb_cond_valid_q <= '0;
      btb_cond_is_backward_q <= '0;
      btb_cond_is_rvc_q <= '0;
      btb_cond_tag_q <= '0;
      btb_cond_target_q <= '0;
      btb_cond_offset_q <= '0;
      btb_jump_valid_q <= '0;
      btb_jump_is_call_q <= '0;
      btb_jump_is_ret_q <= '0;
      btb_jump_use_ras_q <= '0;
      btb_jump_is_rvc_q <= '0;
      btb_jump_tag_q <= '0;
      btb_jump_target_q <= '0;
      btb_jump_offset_q <= '0;
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
        up_local_idx = bht_pc_index(update_pc_i);
        up_global_idx = bht_global_index(update_pc_i, arch_ghr_q);
        up_chooser_idx = up_local_idx;
        // FTB 双槽训练：条件分支（仅 taken）写 cond way；无条件控制流写 jump way。
        // 半字 offset = (update_pc - block_base) >> 1 = update_pc[SLOT_IDX_W:1]。
        if (update_is_cond_i) begin
          if (update_taken_i) begin
            btb_cond_valid_q[up_btb_idx] <= 1'b1;
            btb_cond_is_backward_q[up_btb_idx] <= (update_target_i < update_pc_i);
            btb_cond_is_rvc_q[up_btb_idx] <= update_is_rvc_i;
            btb_cond_tag_q[up_btb_idx] <= btb_tag(up_block_base);
            btb_cond_target_q[up_btb_idx] <= update_target_i;
            btb_cond_offset_q[up_btb_idx] <= update_pc_i[SLOT_IDX_W:1];
          end
        end else begin
          btb_jump_valid_q[up_btb_idx] <= 1'b1;
          btb_jump_is_call_q[up_btb_idx] <= update_is_call_i;
          btb_jump_is_ret_q[up_btb_idx] <= update_is_ret_i;
          btb_jump_is_rvc_q[up_btb_idx] <= update_is_rvc_i;
          if (update_is_ret_i) begin
            btb_jump_use_ras_q[up_btb_idx] <= !arch_ras_has_entry_w || (arch_ras_top_w == update_target_i);
          end else begin
            btb_jump_use_ras_q[up_btb_idx] <= 1'b0;
          end
          btb_jump_tag_q[up_btb_idx] <= btb_tag(up_block_base);
          btb_jump_target_q[up_btb_idx] <= update_target_i;
          btb_jump_offset_q[up_btb_idx] <= update_pc_i[SLOT_IDX_W:1];
        end

        if (update_is_cond_i) begin
          local_pred_before = local_bht_q[up_local_idx][1] ||
                              ((local_bht_q[up_local_idx] == 2'b01) &&
                               btb_cond_is_backward_q[up_btb_idx]);
          global_pred_before = global_bht_q[up_global_idx][1] ||
                               ((global_bht_q[up_global_idx] == 2'b01) &&
                                btb_cond_is_backward_q[up_btb_idx]);
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
